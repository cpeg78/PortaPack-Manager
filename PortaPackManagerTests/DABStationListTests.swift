import Foundation
import Testing
@testable import PortaPackManager

@Suite("DAB-Senderliste")
@MainActor
struct DABStationListTests {
    private func ensemble(_ channel: String, snr: Double?, _ services: [(UInt32, String)]) -> DABStoredEnsemble {
        var entry = DABStoredEnsemble(channel: channel, ensemble: DABEnsemble(), snr: snr)
        entry.services = services.map { .init(id: $0.0, label: $0.1, kind: .dabPlus, bitrate: 104, programmeType: 0) }
        return entry
    }

    @Test("Mehrfach gesendete Dienste erscheinen nur beim besten Störabstand")
    func bestSignalWins() {
        let list = DABModel.deduplicated([
            ensemble("9B", snr: 6, [(0xD385, "N-JOY"), (0xD581, "NDR 1 NDS LG")]),
            ensemble("10A", snr: 11, [(0xD385, "N-JOY"), (0xD451, "NDR 90,3")]),
            ensemble("10C", snr: 8, [(0xD385, "N-JOY")]),
        ])
        #expect(list.map(\.ensemble.channel) == ["9B", "10A"])   // 10C bleibt leer und entfällt
        #expect(list[0].services.map(\.label) == ["NDR 1 NDS LG"])
        #expect(list[1].services.map(\.label) == ["N-JOY", "NDR 90,3"])
    }

    @Test("Ohne Störabstand gewinnt das erste Ensemble")
    func firstWithoutSNR() {
        let list = DABModel.deduplicated([
            ensemble("9B", snr: nil, [(0xD385, "N-JOY")]),
            ensemble("10A", snr: nil, [(0xD385, "N-JOY"), (0xD451, "NDR 90,3")]),
        ])
        #expect(list[0].services.map(\.id) == [0xD385])
        #expect(list[1].services.map(\.id) == [0xD451])
    }
}
