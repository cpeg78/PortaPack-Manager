import CoreBluetooth
import Foundation

/// Bluetooth-LE-Werbung über das Bluetooth des Mac (CoreBluetooth): liefert
/// die Dienstdaten je Gerät. Der Mac hört alle drei Werbekanäle zugleich und
/// ist empfindlicher als der HackRF; Apples Stack empfängt aber keine
/// codierte PHY (Bluetooth 5 Long Range). CoreBluetooth kennt keine
/// Geräteadresse – als Kennung dienen die ersten sechs Bytes der
/// Peripherie-UUID (stabil je Gerät auf diesem Mac).
final class MacBluetoothScanner: NSObject, @unchecked Sendable {
    struct Advertisement: Sendable {
        var address: BLEAddress
        var rssiDB: Double
        var serviceData: [UInt16: [UInt8]]
        var name: String?
    }

    private var central: CBCentralManager?
    private let queue = DispatchQueue(label: "de.christiangolz.portapackmanager.macbluetooth")
    private let lock = NSLock()
    private var handler: (@Sendable (Advertisement) -> Void)?
    private var wanted: [CBUUID]?
    private(set) var state: CBManagerState = .unknown
    private var stateHandler: (@Sendable (CBManagerState) -> Void)?

    /// Startet die Suche; `services` schränkt auf Dienst-UUIDs ein (nil = alle).
    func start(services: [UInt16]?, state: @escaping @Sendable (CBManagerState) -> Void,
               handler: @escaping @Sendable (Advertisement) -> Void) {
        lock.withLock {
            self.handler = handler
            self.stateHandler = state
            wanted = services?.map { CBUUID(string: String(format: "%04X", $0)) }
        }
        queue.async { [self] in
            if central == nil { central = CBCentralManager(delegate: self, queue: queue) }
            else { beginScan() }
        }
    }

    func stop() {
        lock.withLock { handler = nil }
        queue.async { [self] in central?.stopScan() }
    }

    private func beginScan() {
        guard let central, central.state == .poweredOn else { return }
        let services = lock.withLock { wanted }
        central.scanForPeripherals(withServices: services, options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
    }

    static func stateDescription(_ state: CBManagerState) -> String? {
        switch state {
        case .poweredOn: nil
        case .poweredOff: String(localized: "Bluetooth des Mac ist ausgeschaltet.")
        case .unauthorized: String(localized: "Die App darf Bluetooth nicht nutzen – erlaube es in den Systemeinstellungen unter „Datenschutz & Sicherheit ▸ Bluetooth“.")
        case .unsupported: String(localized: "Dieser Mac hat kein Bluetooth LE.")
        default: String(localized: "Bluetooth des Mac wird vorbereitet …")
        }
    }
}

extension MacBluetoothScanner: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        state = central.state
        lock.withLock { stateHandler }?(central.state)
        beginScan()
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        guard let handler = lock.withLock({ self.handler }) else { return }
        var serviceData: [UInt16: [UInt8]] = [:]
        if let raw = advertisementData[CBAdvertisementDataServiceDataKey] as? [CBUUID: Data] {
            for (uuid, data) in raw where uuid.data.count == 2 {
                let bytes = [UInt8](uuid.data)
                serviceData[UInt16(bytes[0]) << 8 | UInt16(bytes[1])] = [UInt8](data)
            }
        }
        guard !serviceData.isEmpty else { return }
        var uuid = peripheral.identifier.uuid
        let bytes = withUnsafeBytes(of: &uuid) { Array($0.prefix(6)) }
        handler(Advertisement(address: BLEAddress(bytes: bytes, random: true), rssiDB: RSSI.doubleValue,
                              serviceData: serviceData,
                              name: advertisementData[CBAdvertisementDataLocalNameKey] as? String))
    }
}
