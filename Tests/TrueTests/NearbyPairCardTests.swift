import Testing
import SwiftUI
import AppKit
import TrueRemoteClient
@testable import True

@MainActor @Suite struct NearbyPairCardTests {
    /// A card wired to counters instead of RemoteAccess. No panel, no Bluetooth, no pasteboard.
    @MainActor final class Harness {
        var codeNumber = 0
        var devices = 0
        var pairedNotified = 0
        var clock = Date(timeIntervalSince1970: 1_000_000)
        var controller: NearbyPairCardController!

        init(autoHide: Duration = .seconds(60), pairedHide: Duration = .seconds(1.5)) {
            let source = NearbyCardSource(
                macName: { "the user's MacBook" },
                newCode: { [unowned self] in codeNumber += 1 },
                code: { [unowned self] in String(format: "%06d", codeNumber) },
                address: { "yoshii-mac.tail1234.ts.net:8444" },
                deviceCount: { [unowned self] in devices },
                phonePaired: { [unowned self] in pairedNotified += 1 })
            controller = NearbyPairCardController(source: source, now: { [unowned self] in clock },
                                                  autoHide: autoHide, pairedHide: pairedHide, usesPanel: false)
        }
    }

    @Test func helloPresentsCardWithFreshCode() {
        let h = Harness()
        #expect(h.controller.present(phoneName: "YOSHII iPhone", phoneID: "A"))
        #expect(h.controller.visible)
        #expect(h.controller.phoneName == "YOSHII iPhone")
        #expect(h.codeNumber == 1)
        #expect(h.controller.qrImage != nil)
    }

    @Test func samePhoneWithinFiveMinutesGetsNoSecondCard() {
        let h = Harness()
        h.controller.present(phoneName: "P", phoneID: "A")
        h.controller.dismiss()
        h.clock.addTimeInterval(120)
        #expect(!h.controller.present(phoneName: "P", phoneID: "A"))
        #expect(!h.controller.visible)
        #expect(h.codeNumber == 1)   // a refused hello must not burn the live code either
        h.clock.addTimeInterval(200)
        #expect(h.controller.present(phoneName: "P", phoneID: "A"))
        #expect(h.codeNumber == 2)
    }

    @Test func differentPhoneGetsACardButNotInstantly() {
        let h = Harness()
        h.controller.present(phoneName: "P", phoneID: "A")
        #expect(!h.controller.present(phoneName: "Q", phoneID: "B"))   // within the global spacing
        h.clock.addTimeInterval(NearbyCardRateLimit.anyPhone + 1)
        #expect(h.controller.present(phoneName: "Q", phoneID: "B"))
        #expect(h.controller.phoneName == "Q")
    }

    @Test func autoHidesAfterTheTimeout() async throws {
        let h = Harness(autoHide: .milliseconds(60))
        h.controller.present(phoneName: "P", phoneID: "A")
        #expect(h.controller.visible)
        try await Task.sleep(for: .milliseconds(250))
        #expect(!h.controller.visible)
    }

    @Test func pairingWhileUpFlipsThenHides() async throws {
        let h = Harness(pairedHide: .milliseconds(60))
        h.controller.present(phoneName: "P", phoneID: "A")
        h.controller.tick()
        #expect(!h.controller.paired)
        h.devices += 1
        h.controller.tick()
        #expect(h.controller.paired)
        #expect(h.pairedNotified == 1)
        h.controller.tick()
        #expect(h.pairedNotified == 1)   // notified once
        try await Task.sleep(for: .milliseconds(250))
        #expect(!h.controller.visible)
    }

    @Test func nameIsTruncatedForDisplay() {
        let h = Harness()
        h.controller.present(phoneName: String(repeating: "x", count: 200), phoneID: "A")
        #expect(h.controller.phoneName.count == 40)
    }

    @Test func rendersLightAndDarkSnapshots() throws {
        let h = Harness()
        h.controller.present(phoneName: "YOSHII iPhone", phoneID: "A")
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().appendingPathComponent(".out/run30")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for (name, scheme, appearance) in [("light", ColorScheme.light, NSAppearance.Name.aqua),
                                           ("dark", ColorScheme.dark, NSAppearance.Name.darkAqua)] {
            for paired in [false, true] {
                let view = NearbyPairCardView(macName: "the user's MacBook", phoneName: "YOSHII iPhone",
                                              qr: h.controller.qrImage, code: "482 913".replacingOccurrences(of: " ", with: ""),
                                              paired: paired)
                    .padding(24)
                    .background(scheme == .dark ? Color(white: 0.12) : Color(white: 0.85))
                    .environment(\.colorScheme, scheme)
                NSAppearance.current = NSAppearance(named: appearance)
                let r = ImageRenderer(content: view); r.scale = 2
                let img = try #require(r.nsImage)
                let tiff = try #require(img.tiffRepresentation)
                let png = try #require(NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]))
                try png.write(to: root.appendingPathComponent("mac-card\(paired ? "-paired" : "")-\(name).png"))
            }
        }
    }
}
