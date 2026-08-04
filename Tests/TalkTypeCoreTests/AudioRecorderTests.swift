import XCTest
@testable import TalkTypeCore

final class AudioRecorderTests: XCTestCase {

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

    /// Silence detection compares RMS against these config defaults, so their
    /// ordering is the invariant: quiet-but-real speech must clear the transcribe bar.
    func testSilenceThresholdsAreOrdered() {
        let config = AppConfig()
        XCTAssertLessThan(config.silenceRmsThreshold, config.minTranscribeRms,
                          "auto-stop must trigger below the transcribe cutoff, not above it")
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
