import AVFoundation
import Accelerate
#if os(macOS)
import CoreAudio
#endif

/// Records audio using AVAudioEngine. Engine created once, tap installed/removed per session.
final class AudioRecorder {
    let targetSampleRate: Int
    var onLevel: ((Float) -> Void)?

    #if os(macOS)
    /// UID of the input device to capture from. nil or unknown means follow the system
    /// default, which is also what happens when the chosen device is unplugged.
    var preferredDeviceUID: String? {
        didSet { if preferredDeviceUID != oldValue { appliedDeviceID = nil } }
    }
    private var appliedDeviceID: AudioDeviceID?
    #endif

    private var engine: AVAudioEngine?
    private var hwSampleRate: Int = 48000
    private var hwFormat: AVAudioFormat?
    private var buffer: [[Float]] = []
    private var recording = false
    private var tapInstalled = false
    private let lock = NSLock()

    var isRecording: Bool { recording }

    init(sampleRate: Int = 16000, onLevel: ((Float) -> Void)? = nil) {
        self.targetSampleRate = sampleRate
        self.onLevel = onLevel
    }

    /// Create the engine object early but do NOT access inputNode yet.
    /// Accessing inputNode triggers Bluetooth A2DP→HFP profile switching.
    func prepare() {
        engine = AVAudioEngine()
        print("[audio] engine created (inputNode deferred)")
    }

    func start() throws {
        if engine == nil {
            prepare()
        }
        guard let engine = engine else {
            throw NSError(domain: "AudioRecorder", code: 1, userInfo: [NSLocalizedDescriptionKey: "No engine"])
        }

        // Lazily read hardware format on first start — this is when inputNode
        // is first accessed, which triggers the mic indicator and any Bluetooth
        // profile negotiation.
        let inputNode = engine.inputNode

        #if os(macOS)
        // Pin the capture device before the format is read. A pinned device that is no
        // longer connected resolves to nil, and CoreAudio picks the system default —
        // unplugging the chosen mic should not stop dictation working.
        if let device = AudioDevices.device(forUID: preferredDeviceUID),
           device.id != appliedDeviceID,
           let unit = inputNode.audioUnit {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                appliedDeviceID = device.id
                hwFormat = nil          // the new device may run at a different rate
                print("[audio] input device: \(device.name)")
            } else {
                print("[audio] could not select \(device.name) (OSStatus \(status)) — using system default")
            }
        }
        #endif

        if hwFormat == nil {
            let format = inputNode.outputFormat(forBus: 0)
            hwFormat = format
            hwSampleRate = Int(format.sampleRate)
            print("[audio] hardware sample rate: \(hwSampleRate) Hz")
        }

        lock.lock()
        if recording {
            lock.unlock()
            return
        }
        buffer = []
        recording = true
        lock.unlock()

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        inputNode.installTap(onBus: 0, bufferSize: 4800, format: hwFormat) { [weak self] pcmBuffer, _ in
            self?.tapCallback(pcmBuffer)
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            lock.lock()
            recording = false
            buffer = []
            lock.unlock()
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
            throw error
        }
    }

    func stop() -> [Float] {
        lock.lock()
        let wasRecording = recording || tapInstalled
        recording = false
        let chunks = buffer
        buffer = []
        lock.unlock()

        guard wasRecording else { return [] }

        if let engine = engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            tapInstalled = false
            engine.stop()
        }

        let audio = chunks.flatMap { $0 }
        return Self.resample(audio, from: hwSampleRate, to: targetSampleRate)
    }

    func shutdown() {
        if let engine = engine {
            if tapInstalled {
                engine.inputNode.removeTap(onBus: 0)
            }
            tapInstalled = false
            engine.stop()
        }
        engine = nil
    }

    // MARK: - Private

    private func tapCallback(_ pcmBuffer: AVAudioPCMBuffer) {
        guard let channelData = pcmBuffer.floatChannelData else { return }
        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else { return }

        let ptr = channelData[0]
        let arr = Array(UnsafeBufferPointer(start: ptr, count: frameLength))

        lock.lock()
        let isRecording = recording
        if isRecording {
            buffer.append(arr)
        }
        lock.unlock()

        if isRecording, let onLevel = onLevel {
            let rms = Self.calculateRMS(arr)
            let level = min(1.0, rms / 0.15)
            onLevel(level)
        }
    }

    static func calculateRMS(_ samples: [Float]) -> Float {
        guard !samples.isEmpty else { return 0 }
        var sumSquares: Float = 0
        vDSP_svesq(samples, 1, &sumSquares, vDSP_Length(samples.count))
        return sqrtf(sumSquares / Float(samples.count))
    }

    static func resample(_ audio: [Float], from hwSampleRate: Int, to targetSampleRate: Int) -> [Float] {
        guard !audio.isEmpty, hwSampleRate != targetSampleRate else { return audio }

        if hwSampleRate % targetSampleRate == 0 {
            // Integer ratio decimation (e.g. 48k -> 16k = take every 3rd)
            let ratio = hwSampleRate / targetSampleRate
            // Decimation without a low-pass folds everything above the new Nyquist
            // (8 kHz for 48k -> 16k) back into the passband. A short windowed-sinc
            // first keeps the fold-back below the frequencies speech carries.
            return antiAliasFilter(audio, decimation: ratio)
        }

        // Linear interpolation for non-integer ratios
        let targetCount = Int(Double(audio.count) * Double(targetSampleRate) / Double(hwSampleRate))
        guard targetCount > 0 else { return [] }
        // A single output sample would make the ratio below divide by zero, producing
        // infinity and then trapping in Int(srcIdx). Reachable with a 44.1 kHz input
        // and a few captured samples.
        guard targetCount > 1 else { return [audio[0]] }
        var result = [Float](repeating: 0, count: targetCount)
        let ratio = Double(audio.count - 1) / Double(targetCount - 1)
        for i in 0..<targetCount {
            let srcIdx = Double(i) * ratio
            let lo = Int(srcIdx)
            let hi = min(lo + 1, audio.count - 1)
            let frac = Float(srcIdx - Double(lo))
            result[i] = audio[lo] * (1 - frac) + audio[hi] * frac
        }
        return result
    }

    /// Low-pass FIR (Blackman-windowed sinc) with the cutoff at the target Nyquist —
    /// 0.5/ratio of the original rate. 33 taps is cheap (a 30 s clip is well under a
    /// millisecond of work) and gives a clean stopband for speech purposes.
    private static func antiAliasFilter(_ audio: [Float], decimation: Int) -> [Float] {
        let taps = 33
        let half = (taps - 1) / 2
        let cutoff = 0.5 / Double(decimation)

        var kernel = [Float](repeating: 0, count: taps)
        var sum: Float = 0
        for i in 0..<taps {
            let n = i - half
            let sinc = n == 0
                ? Float(2 * cutoff)
                : Float(sin(.pi * 2 * cutoff * Double(n)) / (.pi * Double(n)))
            let window = 0.42 - 0.5 * cos(2 * .pi * Double(i) / Double(taps - 1))
                + 0.08 * cos(4 * .pi * Double(i) / Double(taps - 1))
            kernel[i] = sinc * Float(window)
            sum += kernel[i]
        }
        for i in 0..<taps { kernel[i] /= sum }   // unity gain at DC

        // Pad by half the kernel on each side, replicating the edge values, so every
        // output sample keeps its full kernel support. Zero padding would present the
        // filter with a step at the boundary and smear the transient into the signal.
        let padded = [Float](repeating: audio[0], count: half)
            + audio
            + [Float](repeating: audio[audio.count - 1], count: half)
        var filtered = [Float](repeating: 0, count: padded.count)
        for n in 0..<padded.count {
            var acc: Float = 0
            for k in 0..<taps {
                let idx = n + k - half
                guard idx >= 0 && idx < padded.count else { continue }
                acc += padded[idx] * kernel[k]
            }
            filtered[n] = acc
        }
        // The padding exists only to feed the kernel; the decimated samples come from
        // the middle, where the filter has full support.
        return stride(from: half, to: half + audio.count, by: decimation).map { filtered[$0] }
    }
}
