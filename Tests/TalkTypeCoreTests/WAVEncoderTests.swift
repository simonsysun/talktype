import XCTest
@testable import TalkTypeCore

final class WAVEncoderTests: XCTestCase {

    private func u32(_ data: Data, at offset: Int) -> UInt32 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 4]
        return bytes.reversed().reduce(UInt32(0)) { ($0 << 8) | UInt32($1) }
    }

    private func u16(_ data: Data, at offset: Int) -> UInt16 {
        let bytes = data[data.startIndex + offset ..< data.startIndex + offset + 2]
        return bytes.reversed().reduce(UInt16(0)) { ($0 << 8) | UInt16($1) }
    }

    private func i16(_ data: Data, at offset: Int) -> Int16 {
        Int16(bitPattern: u16(data, at: offset))
    }

    private func ascii(_ data: Data, at offset: Int, length: Int) -> String {
        String(decoding: data[data.startIndex + offset ..< data.startIndex + offset + length], as: UTF8.self)
    }

    func testHeaderIsWellFormed() {
        let samples = [Float](repeating: 0, count: 100)
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)

        XCTAssertEqual(wav.count, WAVEncoder.headerSize + 200)
        XCTAssertEqual(ascii(wav, at: 0, length: 4), "RIFF")
        XCTAssertEqual(u32(wav, at: 4), UInt32(36 + 200))       // file size - 8
        XCTAssertEqual(ascii(wav, at: 8, length: 4), "WAVE")
        XCTAssertEqual(ascii(wav, at: 12, length: 4), "fmt ")
        XCTAssertEqual(u32(wav, at: 16), 16)                    // fmt chunk size
        XCTAssertEqual(u16(wav, at: 20), 1)                     // PCM
        XCTAssertEqual(u16(wav, at: 22), 1)                     // mono
        XCTAssertEqual(u32(wav, at: 24), 16000)                 // sample rate
        XCTAssertEqual(u32(wav, at: 28), 32000)                 // byte rate
        XCTAssertEqual(u16(wav, at: 32), 2)                     // block align
        XCTAssertEqual(u16(wav, at: 34), 16)                    // bits per sample
        XCTAssertEqual(ascii(wav, at: 36, length: 4), "data")
        XCTAssertEqual(u32(wav, at: 40), 200)                   // data size
    }

    func testSampleRateIsReflectedInHeader() {
        let wav = WAVEncoder.encode(samples: [0, 0], sampleRate: 48000)
        XCTAssertEqual(u32(wav, at: 24), 48000)
        XCTAssertEqual(u32(wav, at: 28), 96000)
    }

    func testEmptyInputProducesHeaderOnly() {
        let wav = WAVEncoder.encode(samples: [], sampleRate: 16000)
        XCTAssertEqual(wav.count, WAVEncoder.headerSize)
        XCTAssertEqual(u32(wav, at: 40), 0)
    }

    func testSamplesAreScaledAndLittleEndian() {
        let wav = WAVEncoder.encode(samples: [0.0, 1.0, -1.0, 0.5], sampleRate: 16000)
        let base = WAVEncoder.headerSize

        XCTAssertEqual(i16(wav, at: base + 0), 0)
        XCTAssertEqual(i16(wav, at: base + 2), 32767)
        XCTAssertEqual(i16(wav, at: base + 4), -32767)
        XCTAssertEqual(i16(wav, at: base + 6), 16383)

        // 32767 == 0x7FFF, little-endian on the wire
        XCTAssertEqual(wav[wav.startIndex + base + 2], 0xFF)
        XCTAssertEqual(wav[wav.startIndex + base + 3], 0x7F)
    }

    /// Out-of-range floats must clamp, not trap: Int16(1.5 * 32767) would overflow.
    func testOutOfRangeSamplesClamp() {
        let wav = WAVEncoder.encode(samples: [2.5, -3.0, .infinity, -.infinity], sampleRate: 16000)
        let base = WAVEncoder.headerSize
        XCTAssertEqual(i16(wav, at: base + 0), 32767)
        XCTAssertEqual(i16(wav, at: base + 2), -32767)
        XCTAssertEqual(i16(wav, at: base + 4), 32767)
        XCTAssertEqual(i16(wav, at: base + 6), -32767)
    }

    /// Regression guard, not a perf claim: 30 s encodes in ~0.5 ms on Apple silicon.
    /// The bound is loose on purpose — it only catches a return to per-sample appends
    /// or an accidental quadratic copy.
    func testLongRecordingEncodesQuickly() {
        let samples = (0..<480_000).map { Float(sin(Double($0) * 0.01)) }
        let start = Date()
        let wav = WAVEncoder.encode(samples: samples, sampleRate: 16000)
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertEqual(wav.count, WAVEncoder.headerSize + 960_000)
        XCTAssertLessThan(elapsed, 0.25, "30 s of audio should encode in well under 250 ms")
    }
}
