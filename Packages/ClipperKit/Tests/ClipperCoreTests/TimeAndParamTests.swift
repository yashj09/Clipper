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

/// Regression: AVPlayer reports nanosecond times (timescale 1e9); cross-multiplying for == / < overflowed Int64
/// after ~9.2 s of playback and crashed the app (Time.swift:72, "arithmetic overflow").
@Suite struct RationalTimeOverflowTests {
    let ns = Int32(1_000_000_000)

    @Test func comparesNanosecondTimesWithoutOverflow() {
        let player = RationalTime(value: 9_500_000_000, scale: ns)          // 9.5 s from AVPlayer
        let other = RationalTime(value: 9_533_333_333, scale: ns)
        #expect(player != other)
        #expect(player < other)
        #expect(RationalTime(value: 285, scale: 30) == player)              // 9.5 s at 30 fps
        #expect(RationalTime(value: 570_000, scale: 60_000) == player)
        let hour = RationalTime(value: 3_600 * 1_000_000_000, scale: ns)    // long VODs: hours in nanoseconds
        #expect(hour == RationalTime(value: 3_600, scale: 1))
        #expect(hour > RationalTime(value: 3_599, scale: 1))
        #expect(RationalTime.max(hour, player) == hour)
    }

    @Test func extremeValuesCompareCorrectly() {
        let big = RationalTime(value: .max / 2, scale: ns), bigger = RationalTime(value: .max / 2 + 1, scale: ns)
        #expect(big < bigger && big != bigger)
        #expect(RationalTime(value: -9_000_000_000_000, scale: ns) < RationalTime(value: 1, scale: 1))
        #expect(RationalTime(value: .max, scale: 1) > RationalTime(value: .max, scale: ns))
    }
}

@Suite struct KeyframeEditingTests {
    let half = RationalTime(value: 1, scale: 60)
    func s(_ x: Double) -> RationalTime { RationalTime(seconds: x) }

    @Test func settingAddsReplacesAndAnimates() {
        var p = Param<Double>.constant(1)
        p = p.setting(1, at: s(0), tolerance: half)
        #expect(p.isAnimated && p.keys.count == 1 && p.value(at: s(5)) == 1)
        p = p.setting(2, at: s(2), tolerance: half)
        #expect(p.keys.map(\.time) == [s(0), s(2)])
        #expect(p.value(at: s(1)) == 1.5)                        // easeInOut is symmetric at the midpoint
        p = p.setting(3, at: s(2.01), tolerance: half)            // within half a frame: replaces, keeps the key's time
        #expect(p.keys.count == 2 && p.keys[1].time == s(2) && p.keys[1].value == 3)
        #expect(p.key(at: s(2.01), tolerance: half)?.value == 3)
        #expect(p.key(at: s(1), tolerance: half) == nil)
    }

    @Test func removingTheLastKeyLeavesAConstant() {
        var p = Param<Double>.constant(1).setting(1, at: s(0), tolerance: half).setting(4, at: s(2), tolerance: half)
        p = p.removingKey(at: s(0), tolerance: half)
        #expect(p.keys.map(\.time) == [s(2)])
        p = p.removingKey(at: s(2), tolerance: half)
        #expect(p == .constant(4))
        #expect(Param<Double>.constant(7).removingKey(at: s(0), tolerance: half) == .constant(7))
    }

    @Test func itemListsVisualKeyTimesOnce() {
        var item = Item(range: TimeRange(seconds: 0, 4), content: .solid(.black))
        item.opacity = Param.constant(1).setting(0, at: s(1), tolerance: half)
        item.transform.scale = Param.constant(1).setting(2, at: s(1), tolerance: half).setting(1, at: s(3), tolerance: half)
        item.gain = Param.constant(0).setting(-10, at: s(2), tolerance: half)
        #expect(item.visualKeyframeTimes == [s(1), s(3)])
    }
}
