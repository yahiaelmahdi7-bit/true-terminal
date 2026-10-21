import Testing
import Foundation
import TrueRemoteClient
@testable import True

@MainActor @Suite struct NearbyHostTests {
    private func make(_ fake: FakeAdvertiser, hellos: @escaping (NearbyPairing.Hello) -> Void = { _ in }) -> NearbyHost {
        NearbyHost(advertiser: fake, computerName: { "the user's MacBook" }, address: { "mac.ts.net:8444" }, onHello: hellos)
    }

    @Test func advertisesOnlyWhenRemoteAccessAndCardToggleAreBothOn() {
        let fake = FakeAdvertiser(); let host = make(fake)
        host.sync(remoteOn: false, cardOn: true);  #expect(!fake.isAdvertising)
        host.sync(remoteOn: true, cardOn: false);  #expect(!fake.isAdvertising)
        host.sync(remoteOn: true, cardOn: true);   #expect(fake.isAdvertising)
        host.sync(remoteOn: true, cardOn: false);  #expect(!fake.isAdvertising)
        host.sync(remoteOn: true, cardOn: true);   #expect(fake.isAdvertising)
        host.sync(remoteOn: false, cardOn: true);  #expect(!fake.isAdvertising)
        #expect(fake.startCount == 2 && fake.stopCount == 2)
    }

    @Test func syncIsIdempotentAndNamesTheMac() {
        let fake = FakeAdvertiser(); let host = make(fake)
        host.sync(remoteOn: true, cardOn: true); host.sync(remoteOn: true, cardOn: true)
        #expect(fake.startCount == 1)
        #expect(fake.lastName == "True · the user's MacBook")
        #expect(fake.addressProvider?() == "mac.ts.net:8444")
        host.sync(remoteOn: false, cardOn: false); host.sync(remoteOn: false, cardOn: false)
        #expect(fake.stopCount == 1)
    }

    @Test func helloReachesTheHandler() {
        let fake = FakeAdvertiser(); var got: NearbyPairing.Hello?
        let host = make(fake) { got = $0 }
        host.sync(remoteOn: true, cardOn: true)
        fake.phoneSays("YOSHII iPhone", id: "abc")
        #expect(got == .init(name: "YOSHII iPhone", id: "abc"))
    }

    @Test func remoteAccessSyncHonoursItsOwnState() {
        let remote = RemoteAccess(); let fake = FakeAdvertiser()
        remote.nearby = make(fake)
        remote.syncNearby()   // Remote Access is off in a fresh instance's defaults
        #expect(remote.enabled || !fake.isAdvertising)
    }

    @Test func notifyPairedIsForwarded() {
        let fake = FakeAdvertiser(); make(fake).notifyPaired()
        #expect(fake.pairedCount == 1)
    }
}
