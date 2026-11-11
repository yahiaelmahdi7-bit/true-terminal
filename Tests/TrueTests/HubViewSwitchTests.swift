import Testing
@testable import True

@Suite struct HubViewSwitchTests {
    @Test func switchMapsOntoFilter() {
        #expect(HubView(filter: .all) == .work)
        #expect(HubView(filter: .seats) == .work)
        #expect(HubView(filter: .crew) == .work)
        #expect(HubView(filter: .chat) == .chat)
    }

    @Test func workReturnsToRememberedFilter() {
        #expect(HubView.chat.filter(workFilter: .crew) == .chat)
        #expect(HubView.work.filter(workFilter: .crew) == .crew)
        #expect(HubView.work.filter(workFilter: .chat) == .all)
    }
}
