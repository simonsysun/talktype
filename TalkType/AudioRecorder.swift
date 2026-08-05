import AVFoundation
import Accelerate
#if os(macOS)
import CoreAudio
#endif

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

/// Records audio using AVAudioEngine. Engine created once, tap installed/removed per session.
final class AudioRecorder {
    private static let requestedTapFrames: AVAudioFrameCount = 2048

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
        // Pin the capture device before the format is read. An empty UID means
        // Automatic: resolve the system default *now*, at capture time, so a headset
        // connected since launch is picked up without a restart. A pinned device that
        // is no longer connected resolves to nil, and CoreAudio picks the system
        // default — unplugging the chosen mic should not stop dictation working.
        let captureDevice: AudioDevices.Device?
        if let uid = preferredDeviceUID, !uid.isEmpty {
            captureDevice = AudioDevices.device(forUID: uid)
        } else {
            captureDevice = AudioDevices.automaticInput()
        }
        // Only a device we actually pinned has a trustworthy nominal rate; if the pin
        // failed, capture falls back to the system default and we must not compare
        // against the intended device's rate.
        var pinnedRate: Double?
        if let device = captureDevice,
           device.id != appliedDeviceID,
           let unit = inputNode.audioUnit {
            var deviceID = device.id
            let status = AudioUnitSetProperty(
                unit, kAudioOutputUnitProperty_CurrentDevice, kAudioUnitScope_Global, 0,
                &deviceID, UInt32(MemoryLayout<AudioDeviceID>.size))
            if status == noErr {
                appliedDeviceID = device.id
                captureDeviceName = device.name
                pinnedRate = AudioDevices.nominalSampleRate(device.id)
                Log.write("[mic] input device: \(device.name)")
            } else {
                captureDeviceName = nil
                Log.write("[mic] could not select \(device.name) (OSStatus \(status)) — using system default")
            }
        }
        #endif

        // Always re-read the format: Bluetooth (HFP) renegotiates asynchronously after
        // being pinned, and the value is not safe to cache across sessions (a headset
        // drops back to A2DP once recording stops). Poll until the node format matches
        // the device's nominal rate — the switch can go "old valid format → new format",
        // so non-zero alone is not "settled". Short cap: beyond this the device is not
        // coming up, and blocking the main thread longer just loses the user's first words.
        var format = inputNode.outputFormat(forBus: 0)
        let deadline = Date().addingTimeInterval(0.8)
        var settled = false
        while Date() < deadline {
            if format.channelCount > 0, format.sampleRate > 0 {
                if let pinnedRate = pinnedRate, pinnedRate > 0 {
                    if abs(Double(format.sampleRate) - pinnedRate) < 1 {
                        settled = true
                        break
                    }
                } else {
                    settled = true
                    break
                }
            }
            usleep(100_000)
            format = inputNode.outputFormat(forBus: 0)
        }
        let nominalText = pinnedRate.map { "\($0)" } ?? "unknown"
        Log.write("[mic] format: \(Int(format.sampleRate)) Hz x\(format.channelCount) "
                  + "settled=\(settled) nominal=\(nominalText) device=\(captureDevice?.name ?? "automatic")")
        guard format.channelCount > 0, format.sampleRate > 0 else {
            // Do not cache a bad format: reset so the next attempt re-pins and re-reads.
            appliedDeviceID = nil
            Log.write("[mic] input format never became valid (device=\(captureDevice?.name ?? "?") nominal=\(nominalText))")
            throw NSError(domain: "AudioRecorder", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "Input not ready — Bluetooth device still switching."])
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
            throw error
        }
    }

    func stop() -> [Float] {
        let wasRecording = captureBuffer.isCapturing || tapInstalled
        guard wasRecording else { return [] }

        let chunks = captureBuffer.stop { [self] in
            if let engine = engine {
                if tapInstalled {
                    engine.inputNode.removeTap(onBus: 0)
                }
                tapInstalled = false
                engine.stop()
            }
        }

        let audio = chunks.flatMap { $0 }
        captureFormatLock.lock()
        let capturedSampleRate = hwSampleRate
        captureFormatLock.unlock()
        return Self.resample(audio, from: capturedSampleRate, to: targetSampleRate)
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
