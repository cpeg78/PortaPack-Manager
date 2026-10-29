import Foundation
import Security

/// Ein Datenblock im Anmelde-Schlüsselbund (Zigbee-, Thread-, LoRaWAN-Schlüssel).
/// Gespeichert wird per `SecItemUpdate` mit Rückfall auf `SecItemAdd` – das
/// frühere „erst löschen, dann anlegen“ verlor alle Schlüssel, sobald das
/// Anlegen scheiterte.
enum KeychainBlob {
    /// `query`: Klasse, Dienst, Konto – ohne Daten und Rückgabeschlüssel.
    static func save(_ data: Data, query: [String: Any]) -> OSStatus {
        let attributes: [String: Any] = [kSecValueData as String: data,
                                         kSecAttrAccessible as String: kSecAttrAccessibleWhenUnlocked]
        let status = SecItemUpdate(query as CFDictionary, attributes as CFDictionary)
        guard status == errSecItemNotFound else { return status }
        var add = query
        add.merge(attributes) { _, new in new }
        return SecItemAdd(add as CFDictionary, nil)
    }
}
