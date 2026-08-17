import AVFoundation
import Accelerate
import CoreAudio

/// Owns captured chunks and closes them without racing an AVAudioEngine tap callback.
/// A callback that began before hardware shutdown must be allowed to finish and become
/// part of the recording; otherwise the last render quantum disappears at manual stop.
final class AudioCaptureBuffer {
    private let condition = NSCondition()
    private var chunks: [[Float]] = []
    private var acceptingChunks = false
    private var callbacksInFlight = 0

    var isCapturing: Bool {
        condition.lock()
        defer { condition.unlock() }
        return acceptingChunks
    }

    func start() {
        condition.lock()
        chunks = []
        callbacksInFlight = 0
        acceptingChunks = true
        condition.unlock()
    }

    /// Called at the very start of the tap callback, before copying PCM memory.
    func beginChunk() -> Bool {
        condition.lock()
        defer { condition.unlock() }
        guard acceptingChunks else { return false }
        callbacksInFlight += 1
        return true
    }

    func finishChunk(_ samples: [Float]) {
        condition.lock()
        if !samples.isEmpty { chunks.append(samples) }
        callbacksInFlight -= 1
        if callbacksInFlight == 0 { condition.broadcast() }
        condition.unlock()
    }

    /// Hardware is stopped first so no new callback can be scheduled. Any callback that
    /// already began is tracked and drained before the final snapshot is returned.
    func stop(stoppingHardware: () -> Void) -> [[Float]] {
        stoppingHardware()

        condition.lock()
        acceptingChunks = false
        while callbacksInFlight > 0 {
            condition.wait()
        }
        let result = chunks
        chunks = []
        condition.unlock()
        return result
    }
}

/// Raw hardware-rate chunks returned immediately after the engine stops. Flattening and
/// resampling can be tens or hundreds of milliseconds for a long dictation, so callers can do
/// that work off the main thread while the processing animation keeps moving.
struct CapturedAudio {
    let chunks: [[Float]]
    let sampleRate: Int

    func samples(at targetSampleRate: Int) -> [Float] {
        AudioRecorder.resample(chunks.flatMap { $0 }, from: sampleRate, to: targetSampleRate)
    }
}

/// Exact zero means the capture path failed. Any non-zero signal belongs with the speech
/// recognizer: a fixed local loudness threshold cannot distinguish a quiet voice from noise,
/// and the streaming recognizer has already received the audio by the time this runs.
enum TranscriptionAudioGate {
    static func shouldTranscribe(rms: Float) -> Bool {
        rms > 0
    }
}

/// Records audio using AVAudioEngine. Engine created once, tap installed/removed per session.
final class AudioRecorder {
    private static let requestedTapFrames: AVAudioFrameCount = 2048

    let targetSampleRate: Int
    var onLevel: ((Float) -> Void)?
    /// Hardware-rate mono chunks for consumers that need to work during capture (streaming STT).
    /// The callback must return quickly; AudioRecorder waits for it before closing a recording.
    var onSamples: (([Float], Int) -> Void)?

    /// Why a recording could not be started. The distinction matters upstream: only one
    /// of these is ever fixed in System Settings, and treating every failure as a denied
    /// permission is what made a webcam microphone reopen the Privacy pane on every
    /// hotkey press.
    enum StartFailure: Error, LocalizedError {
        /// No usable input format appeared in time — a Bluetooth device mid-switch.
        case formatUnsettled(device: String)
        /// CoreAudio refused to run the device. Permission is not the problem; the
        /// device is (a USB microphone whose driver will not start IO, say).
        case deviceRefused(device: String, status: OSStatus)
        case noEngine

        var errorDescription: String? {
            switch self {
            case .formatUnsettled:
                return "Input not ready — Bluetooth device still switching."
            case .deviceRefused(let device, let status):
                return "\(device) would not start recording (CoreAudio \(status))."
            case .noEngine:
                return "Audio engine unavailable."
            }
        }
    }

    /// UID of the input device to capture from. nil or unknown means follow the system
    /// default, which is also what happens when the chosen device is unplugged.
    var preferredDeviceUID: String? {
        didSet { if preferredDeviceUID != oldValue { appliedDeviceID = nil } }
    }
    private var appliedDeviceID: AudioDeviceID?
    /// Set when the chosen input refused to start and capture fell back to another
    /// device, so the caller can say which microphone is actually recording.
    private(set) var substitutedDevice: (requested: String, used: String)?

    private var engine: AVAudioEngine?
    private var hwSampleRate: Int = 48000
    private var largestObservedTapFrames = Int(requestedTapFrames)
    private let captureFormatLock = NSLock()
    private var tapInstalled = false
    private let captureBuffer = AudioCaptureBuffer()
    /// Name of the capture device pinned by the last `start()`, for diagnostics.
    private(set) var captureDeviceName: String?

    var isRecording: Bool { captureBuffer.isCapturing }

    /// One observed tap quantum plus a small scheduling margin. AVAudioEngine may ignore
    /// the requested frame count, so the real callback size is the only safe boundary.
    var manualStopTailDuration: TimeInterval {
        captureFormatLock.lock()
        let sampleRate = hwSampleRate
        let frames = largestObservedTapFrames
        captureFormatLock.unlock()
        return Self.stopTailDuration(callbackFrames: frames, hardwareSampleRate: sampleRate)
    }

    static func stopTailDuration(callbackFrames: Int, hardwareSampleRate sampleRate: Int) -> TimeInterval {
        guard callbackFrames > 0, sampleRate > 0 else { return 0.15 }
        let quantum = Double(callbackFrames) / Double(sampleRate)
        return max(0.12, quantum + 0.02)
    }

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
        substitutedDevice = nil

        // An empty UID means Automatic: resolve the system default *now*, at capture
        // time, so a headset connected since launch is picked up without a restart. A
        // pinned device that is no longer connected resolves to nil, and CoreAudio picks
        // the system default — unplugging the chosen mic should not stop dictation.
        let intended: AudioDevices.Device?
        if let uid = preferredDeviceUID, !uid.isEmpty {
            intended = AudioDevices.device(forUID: uid)
        } else {
            intended = AudioDevices.automaticInput()
        }

        do {
            try startEngine(pinning: intended)
        } catch let failure as StartFailure {
            // A device that will not start is not a reason to lose the dictation: try
            // one other live input before giving up, and let the caller say so.
            guard case .deviceRefused(let refused, let status) = failure,
                  let alternative = AudioDevices.alternativeInput(to: intended) else { throw failure }
            Log.write("[mic] \(refused) refused to start (OSStatus \(status)) — trying \(alternative.name)")
            appliedDeviceID = nil
            try startEngine(pinning: alternative)
            substitutedDevice = (requested: refused, used: alternative.name)
        }
    }

    private func startEngine(pinning device: AudioDevices.Device?) throws {
        if engine == nil {
            prepare()
        }
        guard let engine = engine else { throw StartFailure.noEngine }

        // Lazily read hardware format on first start — this is when inputNode
        // is first accessed, which triggers the mic indicator and any Bluetooth
        // profile negotiation.
        let inputNode = engine.inputNode
        let deviceLabel = device?.name ?? "system default"

        // Pin the capture device before the format is read.
        if let device = device, device.id != appliedDeviceID, let unit = inputNode.audioUnit {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                appliedDeviceID = device.id
                captureDeviceName = device.name
                Log.write("[mic] input device: \(device.name)")
            } else {
                captureDeviceName = nil
                Log.write("[mic] could not select \(device.name) (OSStatus \(status)) — using system default")
            }
        } else if device != nil {
            captureDeviceName = device?.name
        }
        // Only a device we actually pinned has a trustworthy nominal rate; if the pin
        // failed, capture falls back to the system default and we must not align
        // against the intended device's rate.
        let pinned: AudioDevices.Device? = (device?.id == appliedDeviceID) ? device : nil

        // AVAudioEngine keeps the input node at the sample rate it first saw, so pinning
        // a device that runs at another rate (a 16 kHz webcam mic, a 24 kHz headset in
        // HFP mode) leaves the node stale and the graph refuses to build at all
        // (kAudioUnitErr_FormatNotSupported, -10868). Pushing the device's rate into the
        // unit's own output scope is what makes the node adopt it. The device's rate can
        // still be moving while a Bluetooth link renegotiates, so re-read it each pass
        // rather than trusting the first value; the loop is capped because beyond it the
        // device is not coming up and blocking the main thread only loses first words.
        var format = inputNode.outputFormat(forBus: 0)
        var settled = false
        var deviceRate: Double = 0
        let deadline = Date().addingTimeInterval(0.8)
        while true {
            if let pinned = pinned {
                deviceRate = AudioDevices.nominalSampleRate(pinned.id) ?? 0
                if deviceRate > 0, abs(format.sampleRate - deviceRate) >= 1, let unit = inputNode.audioUnit {
                    _ = Self.alignClientRate(unit, to: deviceRate)
                    format = inputNode.outputFormat(forBus: 0)
                }
                settled = deviceRate > 0 && abs(format.sampleRate - deviceRate) < 1 && format.channelCount > 0
            } else {
                settled = format.sampleRate > 0 && format.channelCount > 0
            }
            if settled || Date() >= deadline { break }
            usleep(100_000)
            format = inputNode.outputFormat(forBus: 0)
        }
        let nominalText = deviceRate > 0 ? "\(deviceRate)" : "unknown"
        Log.write("[mic] format: \(Int(format.sampleRate)) Hz x\(format.channelCount) "
                  + "settled=\(settled) nominal=\(nominalText) device=\(deviceLabel)")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            // Do not cache a bad format: reset so the next attempt re-pins and re-reads.
            appliedDeviceID = nil
            Log.write("[mic] input format never became valid (device=\(deviceLabel) nominal=\(nominalText))")
            throw StartFailure.formatUnsettled(device: deviceLabel)
        }
        captureFormatLock.lock()
        hwSampleRate = Int(format.sampleRate)
        largestObservedTapFrames = Int(Self.requestedTapFrames)
        captureFormatLock.unlock()

        if captureBuffer.isCapturing { return }
        captureBuffer.start()

        if tapInstalled {
            inputNode.removeTap(onBus: 0)
            tapInstalled = false
        }

        // format: nil lets the bus's live format decide — a Bluetooth device can still
        // be settling here, and installing an explicit stale format can raise an ObjC
        // exception that Swift cannot catch.
        inputNode.installTap(onBus: 0, bufferSize: Self.requestedTapFrames, format: nil) { [weak self] pcmBuffer, _ in
            self?.tapCallback(pcmBuffer)
        }
        tapInstalled = true

        do {
            try engine.start()
        } catch {
            _ = captureBuffer.stop {
                inputNode.removeTap(onBus: 0)
                tapInstalled = false
                engine.stop()
            }
            // The device was pinned but never ran; forget it so the next attempt re-pins
            // from scratch instead of inheriting half-configured state.
            appliedDeviceID = nil
            throw StartFailure.deviceRefused(device: deviceLabel, status: OSStatus((error as NSError).code))
        }
    }

    /// Rewrite the input unit's client sample rate. Only the rate is touched: the channel
    /// count and layout AVAudioEngine chose for the node are still correct.
    private static func alignClientRate(_ unit: AudioUnit, to sampleRate: Double) -> OSStatus {
        var description = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let read = AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat,
                                        kAudioUnitScope_Output, 1, &description, &size)
        guard read == noErr else { return read }
        description.mSampleRate = sampleRate
        return AudioUnitSetProperty(unit, kAudioUnitProperty_StreamFormat,
                                    kAudioUnitScope_Output, 1, &description, size)
    }

    /// Stops AVAudioEngine and snapshots its chunks. This part stays on main because AppKit owns
    /// the recorder lifecycle; the expensive flatten/resample step belongs on a worker queue.
    func stopCapture() -> CapturedAudio {
        let wasRecording = captureBuffer.isCapturing || tapInstalled
        guard wasRecording else {
            return CapturedAudio(chunks: [], sampleRate: targetSampleRate)
        }

        let chunks = captureBuffer.stop { [self] in
            if let engine = engine {
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                }
                tapInstalled = false
                engine.stop()
            }
        }

        captureFormatLock.lock()
        let capturedSampleRate = hwSampleRate
        captureFormatLock.unlock()
        return CapturedAudio(chunks: chunks, sampleRate: capturedSampleRate)
    }

    func shutdown() {
        _ = captureBuffer.stop { [self] in
            if let engine = engine {
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                }
                tapInstalled = false
                engine.stop()
            }
        }
        engine = nil
    }

    // MARK: - Private

    private func tapCallback(_ pcmBuffer: AVAudioPCMBuffer) {
        guard captureBuffer.beginChunk() else { return }
        guard let channelData = pcmBuffer.floatChannelData else {
            captureBuffer.finishChunk([])
            return
        }
        let frameLength = Int(pcmBuffer.frameLength)
        guard frameLength > 0 else {
            captureBuffer.finishChunk([])
            return
        }

        // The buffer's format is the truth: a Bluetooth device can settle after the tap
        // is installed, and resampling with the stale rate would pitch-shift the audio.
        let bufferRate = Int(pcmBuffer.format.sampleRate)
        captureFormatLock.lock()
        hwSampleRate = bufferRate
        largestObservedTapFrames = max(largestObservedTapFrames, frameLength)
        captureFormatLock.unlock()

        let ptr = channelData[0]
        let arr = Array(UnsafeBufferPointer(start: ptr, count: frameLength))
        onSamples?(arr, bufferRate)
        captureBuffer.finishChunk(arr)

        if let onLevel = onLevel {
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
    /// 0.5/ratio of the original rate. 33 taps gives a clean stopband for speech; its
    /// work scales linearly with recording length, so long clips need profiling at stop.
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
