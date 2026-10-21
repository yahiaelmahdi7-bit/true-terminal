import Foundation
import TrueRemoteClient
@testable import True

@MainActor
final class FakeAdvertiser: NearbyAdvertising {
    var isAdvertising = false
    var onHello: ((NearbyPairing.Hello) -> Void)?
    var startCount = 0, stopCount = 0, pairedCount = 0
    var lastName: String?
    var addressProvider: (() -> String?)?

    func start(localName: String, address: @escaping () -> String?) {
        isAdvertising = true; startCount += 1; lastName = localName; addressProvider = address
    }
    func stop() { isAdvertising = false; stopCount += 1 }
    func notifyPaired() { pairedCount += 1 }

    /// What a phone writing its hello looks like to the Mac.
    func phoneSays(_ name: String, id: String) { onHello?(.init(name: name, id: id)) }
}
