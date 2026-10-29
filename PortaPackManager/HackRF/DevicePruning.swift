import Foundation

/// Ausdünnen von Gerätetabellen, deren Schlüssel aus der Luft kommen (MMSI,
/// Knotennummern, MAC-Adressen, DevAddr). Zufällige oder gefälschte Kennungen
/// blähten sie sonst unbegrenzt auf – und sie werden alle 500 ms sortiert.
/// Wie bei ADS-B/BLE: erst Einträge ohne Meldung seit `maxAge` weg, reicht
/// das nicht, bleiben die zuletzt gehörten 90 % der Obergrenze.
enum DevicePruning {
    static func prune<Key: Hashable, Value>(_ table: inout [Key: Value], limit: Int, maxAge: TimeInterval,
                                            now: Date, lastSeen: (Value) -> Date) {
        guard table.count > limit else { return }
        table = table.filter { now.timeIntervalSince(lastSeen($0.value)) <= maxAge }
        let target = limit * 9 / 10
        guard table.count > target else { return }
        let keep = table.sorted { lastSeen($0.value) > lastSeen($1.value) }.prefix(target)
        table = Dictionary(keep.map { ($0.key, $0.value) }, uniquingKeysWith: { first, _ in first })
    }
}
