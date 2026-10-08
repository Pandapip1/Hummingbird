import Foundation

/// Just enough WAV/PCM analysis to tell "silence" from "a real tone" without
/// pulling in a new dependency: a minimal RIFF/PCM header reader plus RMS and a
/// single-frequency Goertzel magnitude (we only ever need to check one or two
/// known bins, so a full FFT would be overkill).
struct WAVSamples {
    let sampleRate: Int
    let channels: Int
    /// Interleaved samples, normalized to [-1, 1].
    let samples: [Double]

    /// Mono-mixed samples, for frequency/amplitude analysis that doesn't care about channel layout.
    var mono: [Double] {
        guard channels > 1 else { return samples }
        var out = [Double](repeating: 0, count: samples.count / channels)
        for frame in 0..<out.count {
            var sum = 0.0
            for ch in 0..<channels { sum += samples[frame * channels + ch] }
            out[frame] = sum / Double(channels)
        }
        return out
    }

    static func read(_ url: URL) throws -> WAVSamples {
        let data = try Data(contentsOf: url)
        // >= 44, not > 44: a header with a zero-length data chunk (nothing was ever
        // captured) is a well-formed, empty WAV file, not a corrupt one — callers
        // that care about an empty capture check `samples.isEmpty` themselves.
        guard data.count >= 44, data[0...3].elementsEqual("RIFF".utf8), data[8...11].elementsEqual("WAVE".utf8) else {
            throw CocoaError(.fileReadCorruptFile)
        }
        var offset = 12
        var channels = 0, sampleRate = 0, bitsPerSample = 0, audioFormat = 0
        var dataRange: Range<Int>?
        while offset + 8 <= data.count {
            let id = data[offset..<offset + 4]
            let size = Int(readLE32(data, offset + 4))
            let body = offset + 8
            if id.elementsEqual("fmt ".utf8) {
                audioFormat = Int(readLE16(data, body))
                channels = Int(readLE16(data, body + 2))
                sampleRate = Int(readLE32(data, body + 4))
                bitsPerSample = Int(readLE16(data, body + 14))
            } else if id.elementsEqual("data".utf8) {
                dataRange = body..<min(body + size, data.count)
            }
            offset = body + size + (size % 2)
        }
        guard let dataRange, channels > 0, sampleRate > 0, bitsPerSample == 16,
              audioFormat == 1 || audioFormat == 0xFFFE /* WAVE_FORMAT_EXTENSIBLE, e.g. pw-cat's output */ else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        let bytes = data[dataRange]
        var samples: [Double] = []
        samples.reserveCapacity(bytes.count / 2)
        var i = bytes.startIndex
        while i + 1 < bytes.endIndex {
            let lo = Int16(bytes[i])
            let hi = Int16(bytes[i + 1])
            let value = Int16(bitPattern: UInt16(lo) | (UInt16(hi) << 8))
            samples.append(Double(value) / 32768.0)
            i += 2
        }
        return WAVSamples(sampleRate: sampleRate, channels: channels, samples: samples)
    }

    private static func readLE32(_ data: Data, _ at: Int) -> UInt32 {
        UInt32(data[at]) | (UInt32(data[at + 1]) << 8) | (UInt32(data[at + 2]) << 16) | (UInt32(data[at + 3]) << 24)
    }
    private static func readLE16(_ data: Data, _ at: Int) -> UInt16 {
        UInt16(data[at]) | (UInt16(data[at + 1]) << 8)
    }
}

enum AudioAnalysis {
    static func rms(_ samples: [Double]) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sumSquares = samples.reduce(0) { $0 + $1 * $1 }
        return (sumSquares / Double(samples.count)).squareRoot()
    }

    /// Energy of `samples` at `frequency`, via a single-bin Goertzel — cheaper and
    /// simpler than an FFT when only one (or a couple of) known frequencies matter.
    static func goertzelMagnitude(_ samples: [Double], sampleRate: Int, frequency: Double) -> Double {
        guard !samples.isEmpty else { return 0 }
        let omega = 2 * Double.pi * frequency / Double(sampleRate)
        let coeff = 2 * cos(omega)
        var q0 = 0.0, q1 = 0.0, q2 = 0.0
        for sample in samples {
            q0 = coeff * q1 - q2 + sample
            q2 = q1
            q1 = q0
        }
        let real = q1 - q2 * cos(omega)
        let imag = q2 * sin(omega)
        return (real * real + imag * imag).squareRoot()
    }
}
