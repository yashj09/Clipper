import Foundation
import Testing
@testable import ClipperEngine

@Suite struct StreamingResamplerTests {
    static func signal(_ count: Int) -> [Float] {
        var state: UInt64 = 99
        return (0..<count).map { i in
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let noise = Float(Double(state >> 11) / Double(1 << 53) - 0.5) * 0.1
            return 0.4 * Float(sin(Double(i) * 0.031)) + noise
        }
    }

    @Test(arguments: [(22_050.0, 16_000.0), (48_000.0, 16_000.0), (44_100.0, 16_000.0), (16_000.0, 16_000.0)])
    func matchesTheWholeSignalResampler(rates: (Double, Double)) {
        let input = Self.signal(Int(rates.0 * 7.3))
        let reference = Resampler.resample(input, from: rates.0, to: rates.1)
        for chunk in [1024, 4410, 65_536, 300_000] {
            let r = StreamingResampler(from: rates.0, to: rates.1)
            var out: [Float] = []
            var i = 0
            while i < input.count {
                let end = min(input.count, i + chunk)
                out += input.withUnsafeBufferPointer { r.push(UnsafeBufferPointer(rebasing: $0[i..<end])) }
                i = end
            }
            out += r.finish()
            #expect(out.count == reference.count, "\(rates) chunk \(chunk)")
            let worst = zip(out, reference).map { abs($0 - $1) }.max() ?? 0
            #expect(worst == 0, "\(rates) chunk \(chunk): max difference \(worst)")
        }
    }
}
