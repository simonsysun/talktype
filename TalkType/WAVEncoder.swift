import Foundation

/// Turns the recorder's float samples into the 16-bit mono WAV every provider accepts.
///
/// The PCM block is converted once and appended in a single bulk copy rather than one
/// `Data.append` per sample. Measured on Apple silicon this is ~20x faster but saves only
/// ~10 ms on a 30 s recording — negligible next to the network. It lives in its own file
/// so it can be tested directly.
enum WAVEncoder {
    static let headerSize = 44

    static func encode(samples: [Float], sampleRate: Int) -> Data {
        let dataSize = samples.count * 2
        var wav = Data(capacity: headerSize + dataSize)

        wav.append(contentsOf: "RIFF".utf8)
        wav.appendLittleEndian(UInt32(36 + dataSize))   // file size - 8
        wav.append(contentsOf: "WAVE".utf8)

        // fmt chunk
        wav.append(contentsOf: "fmt ".utf8)
        wav.appendLittleEndian(UInt32(16))              // chunk size
        wav.appendLittleEndian(UInt16(1))               // PCM format
        wav.appendLittleEndian(UInt16(1))               // mono
        wav.appendLittleEndian(UInt32(sampleRate))
        wav.appendLittleEndian(UInt32(sampleRate * 2))  // byte rate
        wav.appendLittleEndian(UInt16(2))               // block align
        wav.appendLittleEndian(UInt16(16))              // bits per sample

        // data chunk
        wav.append(contentsOf: "data".utf8)
        wav.appendLittleEndian(UInt32(dataSize))

        guard !samples.isEmpty else { return wav }

        // Store little-endian explicitly so the bulk copy below is byte-exact
        // regardless of host endianness.
        var pcm = [Int16](repeating: 0, count: samples.count)
        for i in samples.indices {
            let clamped = max(-1.0, min(1.0, samples[i]))
            pcm[i] = Int16(clamped * 32767.0).littleEndian
        }
        pcm.withUnsafeBytes { wav.append(contentsOf: $0) }

        return wav
    }
}

// MARK: - Data helpers

private extension Data {
    mutating func appendLittleEndian<T: FixedWidthInteger>(_ value: T) {
        var le = value.littleEndian
        Swift.withUnsafeBytes(of: &le) { append(contentsOf: $0) }
    }
}
