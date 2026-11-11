import Testing
import SwiftUI
@testable import True

@Suite struct DesignTokensTests {
    private let schemes: [(String, Theme.Palette)] = [("light", .light), ("dark", .dark)]

    @Test func everyTextTokenMeetsAAOnEveryBackground() {
        for (scheme, p) in schemes {
            for (name, fg) in p.textTokens {
                for (i, bg) in p.backgrounds.enumerated() {
                    let r = Contrast.ratio(fg, bg)
                    #expect(r >= 4.5, "\(scheme) \(name) on bg\(i) = \(r)")
                }
            }
        }
    }

    @Test func onAccentReadsOnAccentInk() {
        for (scheme, p) in schemes {
            let r = Contrast.ratio(p.onAccent, p.accentInk)
            #expect(r >= 4.5, "\(scheme) onAccent on accentInk = \(r)")
        }
    }

    @Test func ratioMatchesKnownValues() {
        #expect(abs(Contrast.ratio(0xFFFFFF, 0x000000) - 21) < 0.01)
        // tokens.md: light t0 on bg0 = 16.34, dark t3 on bg3 = 5.28
        #expect(abs(Contrast.ratio(0x1D1A16, 0xFAF8F4) - 16.34) < 0.05)
        #expect(abs(Contrast.ratio(0x8C8C8C, 0x181818) - 5.28) < 0.05)
    }

    @Test func scalesMatchTheTokenTable() {
        #expect(Theme.TypeScale.all == [11, 12.5, 14, 16, 19, 25])
        #expect(Theme.Space.all == [4, 8, 12, 16, 24, 32, 48])
        #expect([Theme.Radius.sm, Theme.Radius.md, Theme.Radius.lg] == [9, 14, 20])
        #expect(Theme.Alpha.disabled == 0.38 && Theme.Alpha.hairline == 0.10)
    }

    @Test func motionSpringsAndReduceMotionFallback() {
        #expect(Motion.micro.response == 0.22 && Motion.micro.damping == 1.0)
        #expect(Motion.list.response == 0.38 && Motion.list.damping == 0.92)
        #expect(Motion.panel.response == 0.5 && Motion.panel.damping == 0.86)
        #expect(Motion.reducedDuration == 0.12)
        for m in Motion.allCases { _ = m.animation(reduceMotion: true); _ = m.animation(reduceMotion: false) }
    }

    @Test func paletteFollowsScheme() {
        #expect(Theme.Palette.for(.dark).bg0 == 0x000000)
        #expect(Theme.Palette.for(.light).bg0 == 0xFAF8F4)
    }

    @Test func tokenisedHuesMeetAAOnTheirSurface() {
        for (name, fg, p) in [("siteLive dark", Theme.Hue.siteLiveDark, Theme.Palette.dark),
                              ("siteLive light", Theme.Hue.siteLiveLight, .light),
                              ("peerFail dark", Theme.Hue.peerFailDark, .dark),
                              ("peerFail light", Theme.Hue.peerFailLight, .light),
                              ("notice dark", Theme.Hue.noticeDark, .dark),
                              ("notice light", Theme.Hue.noticeLight, .light)] {
            for (i, bg) in p.backgrounds.enumerated() {
                let r = Contrast.ratio(fg, bg)
                #expect(r >= 4.5, "\(name) on bg\(i) = \(r)")
            }
        }
    }
}
