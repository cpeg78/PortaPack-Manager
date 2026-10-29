import Foundation
import Testing
@testable import PortaPackManager

@Suite("Spektrum-Vorlagen")
struct SpectrumPresetsTests {
    @Test("Zigbee-Kanäle 11–26 im 5-MHz-Raster ab 2405 MHz")
    func zigbeeRaster() {
        let channels = SpectrumPresets.zigbee
        #expect(channels.map(\.number) == Array(11...26))
        #expect(channels.first?.mhz == 2405)
        #expect(channels.last?.mhz == 2480)
        #expect(channels.first { $0.number == 15 }?.mhz == 2425)
    }

    @Test("Die Zigbee-Vorlage bietet das Kanalraster an")
    func zigbeePresetHasChannels() {
        let presets = SpectrumPresets.groups.flatMap(\.presets).filter { $0.channels == .zigbee }
        #expect(presets.count == 1)
    }

    @Test("WLAN-Vorlagen bieten je ihr Kanalraster an")
    func wifiPresetsHaveChannels() {
        let plans = SpectrumPresets.groups.flatMap(\.presets).compactMap(\.channels)
        #expect(Set(plans).isSuperset(of: [.wifi24, .wifi5, .wifi6]))
        #expect(SpectrumPresets.wifi24.first { $0.number == 6 }?.mhz == 2437)
        #expect(SpectrumPresets.wifi5.first { $0.number == 36 }?.mhz == 5180)
        #expect(SpectrumPresets.wifi6.allSatisfy { $0.mhz <= 6000 })
    }
}
