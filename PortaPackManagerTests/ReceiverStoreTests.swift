import Foundation
import Testing
@testable import PortaPackManager

/// Empfang läuft beim Seitenwechsel weiter; Umschalten erst nach Rückfrage
/// (Umbau 29.10.2026). Nur reine Logik – kein Gerät, keine UserDefaults schreiben.
@MainActor
@Suite("Empfänger-Halter und Rückfrage beim Umschalten")
struct ReceiverStoreTests {
    @Test("Zwei Seiten bekommen dasselbe Model – auch dasselbe wie Fernzugriff und Plan")
    func sameInstance() {
        let store = ReceiverStore.shared
        #expect(store.ble === store.ble)
        #expect(store.pager === store.pager)
        #expect(store.adsb === RemoteHub.shared.adsb)
        #expect(store.acars === RemoteHub.shared.acars)
        #expect(store.sonde === ReceptionPlanner.shared.sonde)
        #expect(store.dsc === DSCModel.shared)
        #expect(store.createdModels.contains { $0 === store.ble })
        // Geteilte Models gehören nicht dem Halter (kein zweites Exemplar).
        #expect(!store.createdModels.contains { $0 === store.adsb })
    }

    @Test("Seite eines Empfängers nach Typ")
    func itemOfOwner() {
        #expect(ReceiverStore.item(of: ReceiverStore.shared.ble) == .ble)
        #expect(ReceiverStore.item(of: RemoteHub.shared.adsb) == .adsb)
        #expect(ReceiverStore.item(of: RemoteHub.shared.spectrum) == .spectrum)
        #expect(ReceiverStore.item(of: NSObject()) == nil)
        #expect(ReceiverStore.item(of: nil) == nil)
    }

    /// Kurzform eines Ergebnisses – vergleichbar ohne `Equatable` am Enum.
    private func describe(_ conflict: ReceiverConflict?) -> String {
        switch conflict {
        case nil: "keine"
        case .plan(let title)?: "plan:\(title)"
        case .remote(let mode)?: "remote:\(mode.rawValue)"
        case .local(_, let name)?: "local:\(name)"
        }
    }

    @Test("Kein anderer Besitzer → keine Rückfrage")
    func noConflict() {
        let me = NSObject()
        #expect(describe(ReceiverConflict.classify(requester: me, occupant: nil, plan: nil, remote: nil)) == "keine")
        #expect(describe(ReceiverConflict.classify(requester: me, occupant: me, plan: nil, remote: nil)) == "keine")
        // Der Plan-Termin selbst (gleiches Model) fragt nicht.
        #expect(describe(ReceiverConflict.classify(requester: me, occupant: me, plan: ("ISS", me), remote: nil)) == "keine")
    }

    @Test("Andere Seite am Mac → Name der Seite in der Rückfrage")
    func localConflict() {
        let ble = ReceiverStore.shared.ble
        let conflict = ReceiverConflict.classify(requester: NSObject(), occupant: ble, plan: nil, remote: nil)
        #expect(describe(conflict) == "local:" + SidebarItem.ble.title)
        if case .local(let owner, _)? = conflict { #expect(ObjectIdentifier(owner) == ObjectIdentifier(ble)) }
        guard let conflict else { return }
        let prompt = SwitchPrompt(conflict: conflict, newTitle: "Radio")
        #expect(prompt.message.contains(SidebarItem.ble.title))
        #expect(prompt.message.contains("Radio"))
    }

    @Test("Unbekannter Besitzer → neutraler Name")
    func unknownOwner() {
        let conflict = ReceiverConflict.classify(requester: NSObject(), occupant: NSObject(), plan: nil, remote: nil)
        #expect(describe(conflict).hasPrefix("local:"))
        #expect(describe(conflict) != "local:")
    }

    @Test("Termin des Empfangsplans hat Vorrang – auch zwischen zwei Starts")
    func planConflict() {
        let planModel = NSObject()
        let conflict = ReceiverConflict.classify(requester: NSObject(), occupant: nil,
                                                 plan: ("METEOR-M2 3", planModel), remote: nil)
        #expect(describe(conflict) == "plan:METEOR-M2 3")
        guard let conflict else { return }
        let prompt = SwitchPrompt(conflict: conflict, newTitle: "Radio")
        #expect(prompt.message.contains("METEOR-M2 3"))
        #expect(prompt.message != SwitchPrompt(conflict: .local(owner: planModel, name: "X"), newTitle: "Radio").message)
    }

    @Test("Fernzugriff belegt das Gerät → Text nennt das Handy")
    func remoteConflict() {
        let remoteModel = NSObject()
        let conflict = ReceiverConflict.classify(requester: NSObject(), occupant: remoteModel,
                                                 plan: nil, remote: (.adsb, remoteModel))
        #expect(describe(conflict) == "remote:adsb")
        if let conflict {
            #expect(SwitchPrompt(conflict: conflict, newTitle: "Radio").message.contains(RemoteHub.Mode.adsb.title))
        }
        // Fernmodus gewählt, das Gerät gehört aber jemand anderem → gewöhnlicher Wechsel.
        let other = ReceiverConflict.classify(requester: NSObject(), occupant: NSObject(),
                                              plan: nil, remote: (.adsb, remoteModel))
        #expect(describe(other).hasPrefix("local:"))
    }

    @Test("Alle Empfänger-Models lassen sich einheitlich stoppen")
    func everyStoreModelStops() {
        let store = ReceiverStore.shared
        let models: [AnyObject] = [store.spectrum, store.aprs, store.pager, store.flarm, store.ble,
                                   store.drones, store.meshtastic, store.lorawan, store.dcf77, store.gps,
                                   store.recorder, store.antennaCheck, store.adsb, store.ais, store.acars]
        for model in models {
            #expect(model is ReceiverStopping, "\(type(of: model)) fehlt ReceiverStopping")
            #expect(ReceiverStore.item(of: model) != nil, "\(type(of: model)) ohne Seite")
        }
    }
}
