import AVFoundation
import Accelerate

/// Records audio using AVAudioEngine. Engine created once, tap installed/removed per session.
final class AudioRecorder {
    let targetSampleRate: Int
    var onLevel: ((Float) -> Void)?

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
        return resample(audio)
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

    private func resample(_ audio: [Float]) -> [Float] {
        guard !audio.isEmpty, hwSampleRate != targetSampleRate else { return audio }

        if hwSampleRate % targetSampleRate == 0 {
            // Integer ratio decimation (e.g. 48k -> 16k = take every 3rd)
            let ratio = hwSampleRate / targetSampleRate
            return stride(from: 0, to: audio.count, by: ratio).map { audio[$0] }
        }

        // Linear interpolation for non-integer ratios
        let targetCount = Int(Double(audio.count) * Double(targetSampleRate) / Double(hwSampleRate))
        guard targetCount > 0 else { return [] }
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
}
