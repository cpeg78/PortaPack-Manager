import Foundation
import IOKit
import IOKit.serial
import IOKit.usb

/// Kennungen, unter denen sich das Gerät am USB meldet.
enum USBIdentity {
    static let greatScottGadgets: Int = 0x1D50
    static let portaPackMayhem: Int = 0x6018   // Mayhem-Modus (CDC-Konsole)
    static let hackRFOne: Int = 0x6089         // HackRF-Modus (Vendor-Interface)
    static let jawbreaker: Int = 0x604B
    static let nxp: Int = 0x1FC9
    static let lpcDFU: Int = 0x000C            // DFU-Bootloader des LPC43xx
    static let sanDisk: Int = 0x0781           // SD-over-USB-Modus gibt sich als SanDisk aus
    static let sdOverUSB: Int = 0xA7A8
}

/// Eine gefundene serielle Schnittstelle samt USB-Herkunft.
struct SerialDevice: Hashable, Sendable {
    let path: String
    let vendorID: Int
    let productID: Int
    let productName: String
    let serialNumber: String
}

/// Sucht über die IORegistry nach seriellen Schnittstellen und ordnet sie
/// ihrem USB-Gerät zu. Namen wie `cu.usbmodemTransceiver1` sind nicht stabil
/// (Mayhem setzt die Seriennummer auf den Namen der laufenden App), deshalb
/// zählt die Vendor-/Product-ID des Elterngeräts.
enum SerialDeviceFinder {
    /// Alle seriellen Schnittstellen von Great Scott Gadgets (Vendor-ID des
    /// Elterngeräts – der Name wechselt mit der laufenden Mayhem-App).
    static func portaPackSerialDevices() -> [SerialDevice] {
        allSerialDevices().filter {
            $0.vendorID == USBIdentity.greatScottGadgets
        }
    }

    /// Nur Mayhem-Konsolen (`1d50:6018`). Andere GSG-Geräte mit serieller
    /// Schnittstelle (etwa ein GreatFET) sollen keine Mayhem-Befehle bekommen.
    static func mayhemConsoles() -> [SerialDevice] {
        isMayhemConsole(portaPackSerialDevices())
    }

    static func isMayhemConsole(_ devices: [SerialDevice]) -> [SerialDevice] {
        devices.filter { $0.vendorID == USBIdentity.greatScottGadgets && $0.productID == USBIdentity.portaPackMayhem }
    }

    static func allSerialDevices() -> [SerialDevice] {
        guard let matching = IOServiceMatching(kIOSerialBSDServiceValue) else { return [] }
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }

        var result: [SerialDevice] = []
        while case let service = IOIteratorNext(iterator), service != 0 {
            defer { IOObjectRelease(service) }
            guard let path = property(service, kIOCalloutDeviceKey) as? String else { continue }
            guard let usb = usbParent(of: service) else { continue }
            defer { IOObjectRelease(usb) }
            let vendor = property(usb, "idVendor") as? Int ?? 0
            let product = property(usb, "idProduct") as? Int ?? 0
            let name = property(usb, "USB Product Name") as? String ?? ""
            let serial = property(usb, "USB Serial Number") as? String ?? ""
            result.append(SerialDevice(path: path, vendorID: vendor, productID: product, productName: name, serialNumber: serial))
        }
        return result.sorted { $0.path < $1.path }
    }

    /// Findet USB-Geräte (nicht serielle) mit Vendor/Product-ID.
    static func usbDevicePresent(vendorID: Int, productID: Int) -> Bool {
        usbDeviceService(vendorID: vendorID, productID: productID).map { service in
            IOObjectRelease(service)
            return true
        } ?? false
    }

    static func usbDeviceService(vendorID: Int, productID: Int) -> io_service_t? {
        guard let matching = IOServiceMatching("IOUSBHostDevice") else { return nil }
        let dict = matching as NSMutableDictionary
        dict["idVendor"] = vendorID
        dict["idProduct"] = productID
        let service = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        return service == 0 ? nil : service
    }

    private static func property(_ service: io_object_t, _ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
    }

    private static func usbParent(of service: io_object_t) -> io_object_t? {
        var current = service
        IOObjectRetain(current)
        while true {
            var parent: io_object_t = 0
            let status = IORegistryEntryGetParentEntry(current, kIOServicePlane, &parent)
            IOObjectRelease(current)
            guard status == KERN_SUCCESS, parent != 0 else { return nil }
            if IOObjectConformsTo(parent, "IOUSBHostDevice") != 0 {
                return parent
            }
            current = parent
        }
    }
}
