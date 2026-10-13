import Testing
import Foundation
@testable import True

@Suite struct AgentHueTests {
    @Test func derivedHueIsStable() {
        // FNV-1a 32-bit mod 10 — pinned so colours never change between launches or releases.
        #expect(AgentHue.derived(from: "lead") == .aqua)
        #expect(AgentHue.derived(from: "cfo") == .aqua)
        #expect(AgentHue.derived(from: "true-hub-design") == .coral)
        #expect(AgentHue.derived(from: "lead") == AgentHue.derived(from: "lead"))
    }

    @Test func invalidStoredHueFallsBackToDerived() {
        let a = Agent(name: "lead", role: .lead, repo: "/tmp/x", hue: "not-a-hue")
        #expect(a.resolvedHue == AgentHue.derived(from: "lead"))
        #expect(Agent(name: "lead", role: .lead, repo: "/tmp/x", hue: "rose").resolvedHue == .rose)
        #expect(Agent(name: "lead", role: .lead, repo: "/tmp/x").resolvedHue == .aqua)
    }

    @Test func oldJSONWithoutHueDecodes() throws {
        let json = #"{"name":"lead","role":"lead","repo":"/tmp/x"}"#.data(using: .utf8)!
        let a = try JSONDecoder().decode(Agent.self, from: json)
        #expect(a.hue == nil)
        #expect(a.name == "lead")
    }

    @Test func hueRoundTrips() throws {
        let a = Agent(name: "cfo", role: .lead, repo: "/tmp/x", hue: "magenta")
        let back = try JSONDecoder().decode(Agent.self, from: JSONEncoder().encode(a))
        #expect(back.hue == "magenta")
        #expect(back.resolvedHue == .magenta)
    }

    @Test @MainActor func parentHueResolvesBySeatName() {
        let seats = [Agent(name: "lead", role: .lead, repo: "/tmp/x", hue: "coral"),
                     Agent(name: "cfo", role: .lead, repo: "/tmp/y")]
        #expect(HubAvatar.parentHue(of: "lead", seats: seats) == .coral)
        #expect(HubAvatar.parentHue(of: "cfo", seats: seats) == AgentHue.derived(from: "cfo"))
        #expect(HubAvatar.parentHue(of: "ghost", seats: seats) == nil)
        #expect(HubAvatar.parentHue(of: nil, seats: seats) == nil)
    }

    @Test func glyphContrastTable() {
        let dark: Set<AgentHue> = [.sun, .lime, .mint, .aqua]
        for h in AgentHue.allCases { #expect(h.glyphIsDark == dark.contains(h)) }
        #expect(AgentHue.allCases.count == 10)
    }
}
