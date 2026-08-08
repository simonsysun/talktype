import XCTest
@testable import TalkTypeCore

final class AudioRecorderTests: XCTestCase {

    /// Regression for the manual-stop truncation: an audio callback can already be in
    /// flight when the user releases the hotkey. Stopping capture must wait for that
    /// callback and include its samples instead of snapshotting the older buffer first.
    func testStopIncludesChunkWhoseCallbackWasAlreadyInFlight() {
        let capture = AudioCaptureBuffer()
        capture.start()
        XCTAssertTrue(capture.beginChunk())

        let hardwareStopBegan = expectation(description: "hardware stop began")
        let captureStopped = DispatchSemaphore(value: 0)
        let resultLock = NSLock()
        var result: [[Float]] = []

        DispatchQueue.global(qos: .userInitiated).async {
            let captured = capture.stop {
                hardwareStopBegan.fulfill()
            }
            resultLock.lock()
            result = captured
            resultLock.unlock()
            captureStopped.signal()
        }

        wait(for: [hardwareStopBegan], timeout: 1)
        XCTAssertEqual(captureStopped.wait(timeout: .now() + 0.02), .timedOut,
                       "stop must wait after hardware shutdown while the callback is in flight")
        capture.finishChunk([0.25, 0.5, 0.75])
        XCTAssertEqual(captureStopped.wait(timeout: .now() + 1), .success)

        resultLock.lock()
        XCTAssertEqual(result, [[0.25, 0.5, 0.75]])
        resultLock.unlock()
    }

    func testManualStopTailCoversActualCallbackQuantum() {
        XCTAssertEqual(AudioRecorder.stopTailDuration(callbackFrames: 2_048,
                                                      hardwareSampleRate: 48_000), 0.12,
                       accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.stopTailDuration(callbackFrames: 2_048,
                                                      hardwareSampleRate: 16_000), 0.148,
                       accuracy: 0.001)
        XCTAssertEqual(AudioRecorder.stopTailDuration(callbackFrames: 4_800,
                                                      hardwareSampleRate: 16_000), 0.32,
                       accuracy: 0.001,
                       "an implementation-selected larger callback must not be clipped")
    }

    /// A long-running menu-bar app repeats this lifecycle thousands of times. Chunks
    /// from a completed dictation must never accumulate into the next one.
    func testCaptureBufferIsEmptyBetweenRepeatedDictations() {
        let capture = AudioCaptureBuffer()
        for value in 0..<2_000 {
            capture.start()
            XCTAssertTrue(capture.beginChunk())
            capture.finishChunk([Float(value)])
            XCTAssertEqual(capture.stop(stoppingHardware: {}), [[Float(value)]])
            XCTAssertFalse(capture.isCapturing)
        }
    }

    func testCapturedAudioFlattensEveryChunkBeforeResampling() {
        let capture = CapturedAudio(chunks: [[0.1, 0.2], [0.3], [], [0.4]], sampleRate: 16_000)
        XCTAssertEqual(capture.samples(at: 16_000), [0.1, 0.2, 0.3, 0.4])
    }

    func testRMSOfSilenceIsZero() {
        XCTAssertEqual(AudioRecorder.calculateRMS([Float](repeating: 0, count: 100)), 0)
    }

    func testRMSOfEmptyInputIsZero() {
        XCTAssertEqual(AudioRecorder.calculateRMS([]), 0)
    }

    func testRMSOfConstantSignalIsItsMagnitude() {
        XCTAssertEqual(AudioRecorder.calculateRMS([Float](repeating: 0.5, count: 1000)), 0.5, accuracy: 1e-5)
        XCTAssertEqual(AudioRecorder.calculateRMS([Float](repeating: -0.5, count: 1000)), 0.5, accuracy: 1e-5)
    }

    /// A full-scale sine wave has RMS 1/sqrt(2) — the sanity check for the whole
    /// silence-detection chain, which compares this value against config thresholds.
    func testRMSOfFullScaleSineIsRootHalf() {
        let samples = (0..<16000).map { Float(sin(2 * Double.pi * Double($0) / 100.0)) }
        XCTAssertEqual(AudioRecorder.calculateRMS(samples), 0.7071, accuracy: 1e-3)
    }

    /// Regression from a real failed dictation: the microphone captured non-zero speech at
    /// RMS 0.00601, but the old 0.012 loudness gate cancelled STT before the API could see it.
    func testQuietNonzeroCaptureStillReachesSpeechRecognition() {
        XCTAssertTrue(TranscriptionAudioGate.shouldTranscribe(rms: 0.00601))
    }

    func testAllZeroCaptureStillDoesNotReachSpeechRecognition() {
        XCTAssertFalse(TranscriptionAudioGate.shouldTranscribe(rms: 0))
    }

    // MARK: - resample

    func testMatchingRateIsPassedThrough() {
        let audio: [Float] = [0.1, 0.2, 0.3]
        XCTAssertEqual(AudioRecorder.resample(audio, from: 16000, to: 16000), audio)
    }

    func testEmptyInputResamplesToEmpty() {
        XCTAssertEqual(AudioRecorder.resample([], from: 48000, to: 16000), [])
    }

    /// DC passes through the anti-aliasing filter unchanged (unity gain at 0 Hz), so a
    /// constant signal still decimates exactly.
    func testIntegerRatioDecimationPassesDCThrough() {
        let audio = [Float](repeating: 0.5, count: 36)
        let out = AudioRecorder.resample(audio, from: 48000, to: 16000)
        XCTAssertEqual(out.count, 12)
        XCTAssertEqual(out.first ?? 0, 0.5, accuracy: 1e-4)
    }

    /// A tone well below the target Nyquist survives decimation at full amplitude.
    func testLowFrequencySurvivesDecimation() {
        let tone = (0..<48000).map { Float(sin(2 * .pi * 1000 * Double($0) / 48000.0)) }
        let out = AudioRecorder.resample(tone, from: 48000, to: 16000)
        XCTAssertEqual(out.count, 16000)
        XCTAssertEqual(AudioRecorder.calculateRMS(out), 0.7071, accuracy: 0.05)
    }

    /// A tone above the target Nyquist (20 kHz, which would alias down to 4 kHz) is
    /// attenuated before it can fold into the passband.
    func testHighFrequencyIsAttenuatedBeforeDecimation() {
        let tone = (0..<48000).map { Float(sin(2 * .pi * 20000 * Double($0) / 48000.0)) }
        let out = AudioRecorder.resample(tone, from: 48000, to: 16000)
        XCTAssertEqual(out.count, 16000)
        XCTAssertLessThan(AudioRecorder.calculateRMS(out), 0.15,
                          "unfiltered decimation would fold 20 kHz down to 4 kHz at full amplitude")
    }

    func testNonIntegerRatioInterpolates() throws {
        let audio = (0..<441).map { Float($0) }
        let out = AudioRecorder.resample(audio, from: 44100, to: 16000)
        XCTAssertEqual(out.count, 160)
        XCTAssertEqual(out.first, 0)
        XCTAssertEqual(try XCTUnwrap(out.last), 440, accuracy: 0.001)
    }

    /// Regression: a single output sample made the interpolation ratio divide by zero,
    /// and Int(infinity) traps. Crashed the menu bar app and would kill the keyboard.
    func testSingleOutputSampleDoesNotTrap() {
        XCTAssertEqual(AudioRecorder.resample([0.1, 0.2, 0.3], from: 44100, to: 16000), [0.1])
        XCTAssertEqual(AudioRecorder.resample([0.1, 0.2, 0.3, 0.4, 0.5], from: 44100, to: 16000), [0.1])
    }

    func testTooFewSamplesResamplesToEmpty() {
        XCTAssertEqual(AudioRecorder.resample([0.1, 0.2], from: 44100, to: 16000), [])
    }
}
