import Foundation
import Testing
@testable import ClipperCore

@Suite struct RationalTimeTests {
    @Test func equalityAcrossScales() {
        #expect(RationalTime(value: 1, scale: 2) == RationalTime(value: 30, scale: 60))
        #expect(RationalTime(value: 1, scale: 2).hashValue == RationalTime(value: 30, scale: 60).hashValue)
        #expect(RationalTime(value: 1001, scale: 30000) < RationalTime(value: 1, scale: 29))
    }

    @Test func arithmeticIsExactForNTSC() {
        let frame = FrameRate.ntsc30.frameDuration
        var t = RationalTime.zero
        for _ in 0..<30_000 { t += frame }
        #expect(t == RationalTime(value: 1001, scale: 1))   // 30000 frames of 1001/30000 s = 1001 s exactly
    }

    @Test func mixedScalesUseCommonScale() {
        let a = RationalTime(value: 1, scale: 24), b = RationalTime(value: 1, scale: 30)
        #expect(a + b == RationalTime(value: 9, scale: 120))
        #expect(a - b == RationalTime(value: 1, scale: 120))
    }

    @Test func frameSnapping() {
        let t = RationalTime(seconds: 1.016)                // between frame 30 (1.0) and 31 (1.0333) at 30 fps
        #expect(t.roundedToFrame(.fps30) == RationalTime(value: 30, scale: 30))
        #expect(RationalTime(seconds: 1.02).roundedToFrame(.fps30) == RationalTime(value: 31, scale: 30))
        #expect(RationalTime(seconds: 1.0333).floorToFrame(.fps30) == RationalTime(value: 30, scale: 30))
    }

    @Test func codableAsStringOrSeconds() throws {
        let data = try ClipperJSON.encode([RationalTime(value: 1001, scale: 30000)])
        #expect(String(decoding: data, as: UTF8.self).contains("\"1001/30000\""))
        let decoded = try ClipperJSON.decode([RationalTime].self, from: Data("[\"3/2\", 2.5]".utf8))
        #expect(decoded == [RationalTime(value: 3, scale: 2), RationalTime(seconds: 2.5)])
    }

    @Test func nearestStandardRate() {
        #expect(FrameRate.nearestStandard(to: 29.55) == .ntsc30 || FrameRate.nearestStandard(to: 29.55) == .fps30)
        #expect(FrameRate.nearestStandard(to: 59.94) == .ntsc60)
        #expect(FrameRate.nearestStandard(to: 24.0) == .fps24)
    }

    @Test func rangeOps() {
        let a = TimeRange(seconds: 1, 3), b = TimeRange(seconds: 2, 5)
        #expect(a.overlaps(b))
        #expect(a.intersection(b) == TimeRange(seconds: 2, 3))
        #expect(!a.overlaps(TimeRange(seconds: 3, 4)))   // half-open
    }
}

@Suite struct ParamTests {
    @Test func constantAndKeyframed() {
        let p = Param<Double>.keyframes([Keyframe(.zero, 0, .linear), Keyframe(RationalTime(seconds: 2), 10, .linear)])
        #expect(p.value(at: RationalTime(seconds: -1)) == 0)
        #expect(p.value(at: RationalTime(seconds: 1)) == 5)
        #expect(p.value(at: RationalTime(seconds: 5)) == 10)
        #expect(Param<Double>.constant(3).value(at: RationalTime(seconds: 9)) == 3)
    }

    @Test func holdAndEase() {
        let hold = Param<Double>.keyframes([Keyframe(.zero, 1, .hold), Keyframe(RationalTime(seconds: 1), 2, .hold)])
        #expect(hold.value(at: RationalTime(seconds: 0.99)) == 1)
        let ease = Param<Double>.keyframes([Keyframe(.zero, 0, .easeInOut), Keyframe(RationalTime(seconds: 1), 1)])
        #expect(ease.value(at: RationalTime(seconds: 0.25)) < 0.25)   // slow start
        #expect(ease.value(at: RationalTime(seconds: 0.5)) == 0.5)
    }

    @Test func codableShapes() throws {
        let c: Param<Double> = .constant(1.5)
        #expect(String(decoding: try ClipperJSON.encode(c), as: UTF8.self) == "1.5")
        let k: Param<NormPoint> = .keyframes([Keyframe(.zero, .center), Keyframe(RationalTime(value: 1, scale: 1), NormPoint(0.2, 0.3))])
        let json = try ClipperJSON.encode(k)
        #expect(String(decoding: json, as: UTF8.self).contains("\"keys\""))
        #expect(try ClipperJSON.decode(Param<NormPoint>.self, from: json) == k)
        #expect(try ClipperJSON.decode(Param<NormPoint>.self, from: Data(#"{"x":0.1,"y":0.9}"#.utf8)) == .constant(NormPoint(0.1, 0.9)))
    }

    @Test func fromCollapsesUniformKeys() {
        let p = Param<Double>.from([Keyframe(.zero, 2), Keyframe(RationalTime(seconds: 1), 2)])
        #expect(p == .constant(2))
    }
}

@Suite struct ColorAndIDTests {
    @Test func hexRoundTrip() {
        #expect(RGBA(hex: "#FF8000")?.hex == "#FF8000")
        #expect(RGBA(hex: "#00000080")?.a ?? 0 > 0.49)
        #expect(RGBA(hex: "nope") == nil)
    }

    @Test func idGeneratorIsDeterministic() {
        var a = IDGenerator(seed: 42), b = IDGenerator(seed: 42), c = IDGenerator(seed: 43)
        let ua = (0..<5).map { _ in a.uuid() }
        #expect(ua == (0..<5).map { _ in b.uuid() })
        #expect(ua.first != c.uuid())
        #expect(Set(ua).count == 5)
    }
}
