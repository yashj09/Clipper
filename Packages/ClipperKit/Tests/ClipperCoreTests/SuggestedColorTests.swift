import ClipperCore
import Testing

@Suite struct SuggestedColorTests {
    static let balanced = ColorStats(luma: 0.45, p01: 0.05, p99: 0.95, saturation: 0.35, r: 0.45, g: 0.45, b: 0.45)

    static func stats(_ change: (inout ColorStats) -> Void) -> ColorStats {
        var s = balanced
        change(&s)
        return s
    }

    @Test func balancedClipIsLeftAlone() {
        #expect(ColorAdjust.suggested(for: Self.balanced) == .none)
        let nearlyBalanced = Self.stats { $0.luma = 0.48; $0.r = 0.46; $0.saturation = 0.32 }
        #expect(ColorAdjust.suggested(for: nearlyBalanced) == .none)
    }

    @Test func exposureMovesTowardMidGrey() {
        let dark = ColorAdjust.suggested(for: Self.stats { $0.luma = 0.2; $0.p01 = 0.02; $0.p99 = 0.45 })
        let bright = ColorAdjust.suggested(for: Self.stats { $0.luma = 0.75; $0.p01 = 0.3; $0.p99 = 1 })
        #expect(dark.exposure > 0.5 && bright.exposure < -0.5)
        #expect(ColorAdjust.suggested(for: Self.stats { $0.luma = 0; $0.p01 = 0; $0.p99 = 0 }).exposure == 3)
    }

    @Test func contrastStretchesAFlatRangeButNotOneExposureAlreadyOpens() {
        let flat = ColorAdjust.suggested(for: Self.stats { $0.p01 = 0.25; $0.p99 = 0.7 })
        #expect(flat.contrast > 0 && flat.exposure == 0)
        // Exposure nearly doubles this dark clip's values, which already spreads 0.03…0.48 across nearly the whole range.
        let dark = ColorAdjust.suggested(for: Self.stats { $0.luma = 0.2; $0.p01 = 0.03; $0.p99 = 0.48 })
        #expect(dark.exposure > 0 && dark.contrast == 0)
    }

    @Test func whiteBalanceCountersTheCast() {
        let warm = ColorAdjust.suggested(for: Self.stats { $0.r = 0.55; $0.b = 0.38 })
        let cool = ColorAdjust.suggested(for: Self.stats { $0.r = 0.38; $0.b = 0.55 })
        let green = ColorAdjust.suggested(for: Self.stats { $0.g = 0.52 })
        #expect(warm.temperature < 0 && cool.temperature > 0)
        #expect(green.tint > 0 && green.temperature == 0)
        #expect(abs(warm.temperature) <= 0.25 && abs(green.tint) <= 0.15)
    }

    @Test func saturationLiftsDullFootageAndLeavesVividAlone() {
        #expect(ColorAdjust.suggested(for: Self.stats { $0.saturation = 0.15 }).saturation > 0)
        #expect(ColorAdjust.suggested(for: Self.stats { $0.saturation = 0.8 }).saturation == 0)
    }

    @Test func noneLookChangesNothing() {
        #expect(ColorAdjust.suggested(for: Self.stats { $0.luma = 0.1 }, look: .none) == .none)
    }
}
