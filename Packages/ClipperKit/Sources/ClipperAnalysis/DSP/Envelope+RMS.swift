import Accelerate
import ClipperCore

extension Envelope {
    /// Silence floor in dBFS for envelopes produced here.
    public static let silenceDB: Float = -120

    /// RMS in dBFS per hop (default 10 ms), vDSP-accelerated. Silence clamps to -120.
    /// The hop is rounded to a whole number of samples; the returned envelope's `hop` is that exact value
    /// (e.g. 220/22050 s for 10 ms at 22.05 kHz) so frame times stay aligned with the samples.
    /// Only whole frames are emitted; a trailing partial frame is dropped.
    public static func rms(samples: [Float], sampleRate: Double, hop: Double = 0.01) -> Envelope {
        let k = max(1, Int((hop * sampleRate).rounded()))
        let exactHop = Double(k) / sampleRate
        let n = samples.count / k
        guard n > 0 else { return Envelope(hop: exactHop, values: []) }
        var values = [Float](repeating: 0, count: n)
        samples.withUnsafeBufferPointer { src in
            values.withUnsafeMutableBufferPointer { dst in
                let base = src.baseAddress!
                for i in 0..<n {
                    vDSP_measqv(base + i * k, 1, dst.baseAddress! + i, vDSP_Length(k))
                }
                // 10·log10(max(meanSquare, 1e-12)) → clamps silence to -120 dBFS.
                var floor: Float = 1e-12
                vDSP_vthr(dst.baseAddress!, 1, &floor, dst.baseAddress!, 1, vDSP_Length(n))
                var count = Int32(n)
                vvlog10f(dst.baseAddress!, dst.baseAddress!, &count)
                var ten: Float = 10
                vDSP_vsmul(dst.baseAddress!, 1, &ten, dst.baseAddress!, 1, vDSP_Length(n))
            }
        }
        return Envelope(hop: exactHop, values: values)
    }
}
