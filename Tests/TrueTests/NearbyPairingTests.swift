import Testing
import Foundation
import TrueRemoteClient

@Suite struct NearbyPairingTests {
    @Test func helloRoundTrips() throws {
        let h = NearbyPairing.Hello(name: "YOSHII iPhone", id: "8F2A-11")
        let back = try #require(NearbyPairing.decodeHello(NearbyPairing.encodeHello(h)))
        #expect(back == h)
    }

    @Test func barInNameCannotBreakTheSplit() throws {
        let data = NearbyPairing.encodeHello(.init(name: "A|B", id: "x|y"))
        let back = try #require(NearbyPairing.decodeHello(data))
        #expect(back.name == "A B")
        #expect(back.id == "x-y")
    }

    @Test func rejectsMalformedHello() {
        #expect(NearbyPairing.decodeHello(Data("nobar".utf8)) == nil)
        #expect(NearbyPairing.decodeHello(Data("|id".utf8)) == nil)
        #expect(NearbyPairing.decodeHello(Data("name|".utf8)) == nil)
        #expect(NearbyPairing.decodeHello(Data([0xFF, 0xFE, 0x7C, 0x41])) == nil)
        #expect(NearbyPairing.decodeHello(Data("na\nme|id".utf8)) == nil)
        #expect(NearbyPairing.decodeHello(Data(String(repeating: "a", count: 300).utf8 + Data("|i".utf8))) == nil)
    }

    @Test func thresholdIsMinusSeventy() {
        #expect(NearbyPairing.isNearby(rssi: -55))
        #expect(NearbyPairing.isNearby(rssi: -70))
        #expect(!NearbyPairing.isNearby(rssi: -71))
    }

    @Test func addressMustBeBareHostPort() {
        #expect(NearbyPairing.decodeAddress(Data("mac.tail1.ts.net:8444".utf8)) == "mac.tail1.ts.net:8444")
        #expect(NearbyPairing.decodeAddress(Data("https://evil".utf8)) == nil)
        #expect(NearbyPairing.decodeAddress(Data("a.b/x".utf8)) == nil)
        #expect(NearbyPairing.decodeAddress(Data()) == nil)
    }

    @Test func macNameStripsAdvertisedPrefix() {
        #expect(NearbyPairing.macName(fromLocalName: "True · the user's MacBook") == "the user's MacBook")
        #expect(NearbyPairing.macName(fromLocalName: "Other") == "Other")
    }

    @Test func uuidsAreValidAndDistinct() {
        let all = [NearbyPairing.serviceUUID, NearbyPairing.addressUUID, NearbyPairing.helloUUID, NearbyPairing.pairedUUID]
        #expect(all.allSatisfy { UUID(uuidString: $0) != nil })
        #expect(Set(all).count == 4)
    }
}
