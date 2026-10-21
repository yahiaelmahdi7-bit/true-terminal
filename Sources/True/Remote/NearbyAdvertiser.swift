@preconcurrency import CoreBluetooth
import Foundation
import TrueRemoteClient

/// What the Mac needs from Bluetooth, and nothing more. The real one is `CoreBluetoothAdvertiser`; tests drive a fake.
@MainActor
protocol NearbyAdvertising: AnyObject {
    var isAdvertising: Bool { get }
    /// Called on the main actor when a phone writes its hello.
    var onHello: ((NearbyPairing.Hello) -> Void)? { get set }
    /// `address` is asked every time a phone reads, because the tailnet name can arrive after Bluetooth starts.
    func start(localName: String, address: @escaping () -> String?)
    func stop()
    /// Tell subscribed phones a phone paired, so their card can collapse.
    func notifyPaired()
}

/// Owns "should we be advertising right now": Remote Access on AND the Bluetooth card setting on.
@MainActor
final class NearbyHost {
    static let cardKey = "remote.nearbyCard"

    private let advertiser: NearbyAdvertising
    private let computerName: () -> String
    private let address: () -> String?

    init(advertiser: NearbyAdvertising, computerName: @escaping () -> String, address: @escaping () -> String?,
         onHello: @escaping (NearbyPairing.Hello) -> Void) {
        self.advertiser = advertiser; self.computerName = computerName; self.address = address
        advertiser.onHello = onHello
    }

    var isAdvertising: Bool { advertiser.isAdvertising }

    /// Idempotent: call after any change to Remote Access or the card toggle.
    func sync(remoteOn: Bool, cardOn: Bool) {
        if remoteOn && cardOn {
            if !advertiser.isAdvertising { advertiser.start(localName: "True · \(computerName())", address: address) }
        } else if advertiser.isAdvertising {
            advertiser.stop()
        }
    }

    func notifyPaired() { advertiser.notifyPaired() }
}

/// Real transport: a `CBPeripheralManager` serving the three characteristics of `NearbyPairing`.
/// Never constructed in tests; nothing here runs until Remote Access and the card toggle are both on.
@MainActor
final class CoreBluetoothAdvertiser: NSObject, NearbyAdvertising, @preconcurrency CBPeripheralManagerDelegate {
    private var manager: CBPeripheralManager?
    private var pending: (name: String, address: () -> String?)?
    private var pairedChar: CBMutableCharacteristic?
    private(set) var isAdvertising = false
    var onHello: ((NearbyPairing.Hello) -> Void)?

    func start(localName: String, address: @escaping () -> String?) {
        pending = (localName, address)
        isAdvertising = true
        // Creating the manager is what triggers the system Bluetooth permission prompt.
        if manager == nil { manager = CBPeripheralManager(delegate: self, queue: .main) } else { publishIfReady() }
    }

    func stop() {
        pending = nil; isAdvertising = false
        manager?.stopAdvertising(); manager?.removeAllServices()
        pairedChar = nil
    }

    func notifyPaired() {
        guard let manager, let pairedChar else { return }
        _ = manager.updateValue(Data([1]), for: pairedChar, onSubscribedCentrals: nil)
    }

    private func publishIfReady() {
        guard let manager, manager.state == .poweredOn, let pending, !manager.isAdvertising else { return }
        let address = CBMutableCharacteristic(type: CBUUID(string: NearbyPairing.addressUUID), properties: [.read],
                                              value: nil, permissions: [.readable])
        let hello = CBMutableCharacteristic(type: CBUUID(string: NearbyPairing.helloUUID),
                                            properties: [.writeWithoutResponse], value: nil, permissions: [.writeable])
        let paired = CBMutableCharacteristic(type: CBUUID(string: NearbyPairing.pairedUUID), properties: [.notify],
                                             value: nil, permissions: [.readable])
        pairedChar = paired
        let service = CBMutableService(type: CBUUID(string: NearbyPairing.serviceUUID), primary: true)
        service.characteristics = [address, hello, paired]
        manager.removeAllServices()
        manager.add(service)
        manager.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [service.uuid],
                                  CBAdvertisementDataLocalNameKey: pending.name])
    }

    // MARK: CBPeripheralManagerDelegate (queue is .main)

    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        if peripheral.state == .poweredOn { publishIfReady() }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveRead request: CBATTRequest) {
        guard request.characteristic.uuid == CBUUID(string: NearbyPairing.addressUUID),
              let addr = pending?.address() else {
            peripheral.respond(to: request, withResult: .attributeNotFound); return
        }
        let data = NearbyPairing.encodeAddress(addr)
        guard request.offset <= data.count else { peripheral.respond(to: request, withResult: .invalidOffset); return }
        request.value = data.subdata(in: request.offset..<data.count)
        peripheral.respond(to: request, withResult: .success)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didReceiveWrite requests: [CBATTRequest]) {
        for r in requests where r.characteristic.uuid == CBUUID(string: NearbyPairing.helloUUID) {
            if let value = r.value, let hello = NearbyPairing.decodeHello(value) { onHello?(hello) }
        }
    }
}
