import Foundation
import SQLite3

/// Fehler aus SQLite: erweiterter Code und Klartext der Bibliothek.
struct SQLiteError: Error, CustomStringConvertible, LocalizedError {
    var code: Int32
    var message: String

    var description: String { "SQLite \(code): \(message)" }
    var errorDescription: String? { description }

    /// Datei beschädigt oder gar keine Datenbank.
    var isCorrupt: Bool {
        let primary = code & 0xFF
        return primary == SQLITE_CORRUPT || primary == SQLITE_NOTADB
    }

    /// Platte voll.
    var isFull: Bool { code & 0xFF == SQLITE_FULL }
}

/// Wert, der an einen Platzhalter `?` gebunden werden kann.
protocol SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32
}

/// `SQLITE_TRANSIENT`: SQLite kopiert Text und BLOB sofort.
private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

extension Int: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, Int64(self)) }
}

extension Int64: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_int64(statement, index, self) }
}

extension Double: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(statement, index, self) }
}

extension Float: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_double(statement, index, Double(self)) }
}

extension String: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 { sqlite3_bind_text(statement, index, self, -1, transient) }
}

extension Data: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        withUnsafeBytes { buffer in
            // Ein leerer Puffer hat keine Adresse – als leeres BLOB binden, nicht als NULL.
            guard let base = buffer.baseAddress else { return sqlite3_bind_zeroblob(statement, index, 0) }
            return sqlite3_bind_blob(statement, index, base, Int32(buffer.count), transient)
        }
    }
}

extension Optional: SQLiteBindable where Wrapped: SQLiteBindable {
    func bind(to statement: OpaquePointer, at index: Int32) -> Int32 {
        switch self {
        case .some(let value): value.bind(to: statement, at: index)
        case .none: sqlite3_bind_null(statement, index)
        }
    }
}

/// Ein vorbereitetes Statement. Lebt im Cache der Verbindung und wird je Aufruf
/// zurückgesetzt – SQL wird nur einmal übersetzt.
final class SQLiteStatement {
    let handle: OpaquePointer
    private unowned let connection: SQLiteConnection

    fileprivate init(handle: OpaquePointer, connection: SQLiteConnection) {
        self.handle = handle
        self.connection = connection
    }

    deinit { sqlite3_finalize(handle) }

    func bind(_ values: [any SQLiteBindable]) throws {
        sqlite3_reset(handle)
        sqlite3_clear_bindings(handle)
        for (i, value) in values.enumerated() {
            let rc = value.bind(to: handle, at: Int32(i + 1))
            if rc != SQLITE_OK { throw connection.error(rc) }
        }
    }

    /// Nächste Zeile; `false` am Ende.
    func step() throws -> Bool {
        let rc = sqlite3_step(handle)
        if rc == SQLITE_ROW { return true }
        if rc == SQLITE_DONE { return false }
        let error = connection.error(rc)
        sqlite3_reset(handle)
        throw error
    }

    func isNull(_ column: Int32) -> Bool { sqlite3_column_type(handle, column) == SQLITE_NULL }
    func int(_ column: Int32) -> Int { Int(sqlite3_column_int64(handle, column)) }
    func optionalInt(_ column: Int32) -> Int? { isNull(column) ? nil : int(column) }
    func double(_ column: Int32) -> Double { sqlite3_column_double(handle, column) }
    func optionalDouble(_ column: Int32) -> Double? { isNull(column) ? nil : double(column) }

    func text(_ column: Int32) -> String? {
        guard let pointer = sqlite3_column_text(handle, column) else { return nil }
        return String(cString: pointer)
    }

    func blob(_ column: Int32) -> Data? {
        guard !isNull(column) else { return nil }
        let count = Int(sqlite3_column_bytes(handle, column))
        guard count > 0, let pointer = sqlite3_column_blob(handle, column) else { return Data() }
        return Data(bytes: pointer, count: count)
    }
}

/// Eine SQLite-Verbindung. Nicht threadsicher – `ArchiveDatabase` benutzt sie
/// nur auf ihrer seriellen Warteschlange.
final class SQLiteConnection {
    let handle: OpaquePointer
    private var cache: [String: SQLiteStatement] = [:]

    init(url: URL, readOnly: Bool = false) throws {
        var db: OpaquePointer?
        let flags = (readOnly ? SQLITE_OPEN_READONLY : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE) | SQLITE_OPEN_NOMUTEX
        let rc = sqlite3_open_v2(url.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let message = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2"
            sqlite3_close_v2(db)
            throw SQLiteError(code: rc, message: message)
        }
        handle = db
        sqlite3_extended_result_codes(db, 1)
    }

    deinit {
        cache.removeAll()
        sqlite3_close_v2(handle)
    }

    func error(_ rc: Int32) -> SQLiteError {
        SQLiteError(code: sqlite3_extended_errcode(handle) != 0 ? sqlite3_extended_errcode(handle) : rc,
                    message: String(cString: sqlite3_errmsg(handle)))
    }

    /// Führt ein oder mehrere Statements ohne Parameter aus (Schema, PRAGMA).
    func execute(_ sql: String) throws {
        var message: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &message)
        guard rc == SQLITE_OK else {
            let text = message.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(handle))
            sqlite3_free(message)
            throw SQLiteError(code: sqlite3_extended_errcode(handle), message: text)
        }
    }

    /// Vorbereitetes Statement aus dem Cache (bzw. neu übersetzt), Parameter gebunden.
    func prepare(_ sql: String, _ values: [any SQLiteBindable] = []) throws -> SQLiteStatement {
        let statement: SQLiteStatement
        if let cached = cache[sql] {
            statement = cached
        } else {
            var raw: OpaquePointer?
            let rc = sqlite3_prepare_v3(handle, sql, -1, UInt32(SQLITE_PREPARE_PERSISTENT), &raw, nil)
            guard rc == SQLITE_OK, let raw else { throw error(rc) }
            statement = SQLiteStatement(handle: raw, connection: self)
            cache[sql] = statement
        }
        try statement.bind(values)
        return statement
    }

    /// Statement ohne Ergebniszeilen; liefert die Zahl geänderter Zeilen.
    @discardableResult
    func run(_ sql: String, _ values: [any SQLiteBindable] = []) throws -> Int {
        let statement = try prepare(sql, values)
        while try statement.step() {}
        sqlite3_reset(statement.handle)
        return Int(sqlite3_changes(handle))
    }

    /// Alle Zeilen einer Abfrage.
    func query<T>(_ sql: String, _ values: [any SQLiteBindable] = [], row: (SQLiteStatement) throws -> T) throws -> [T] {
        let statement = try prepare(sql, values)
        defer { sqlite3_reset(statement.handle) }
        var result: [T] = []
        while try statement.step() { result.append(try row(statement)) }
        return result
    }

    /// Erste Spalte der ersten Zeile als Zahl (COUNT, MAX …); `nil` ohne Zeile oder bei NULL.
    func scalar(_ sql: String, _ values: [any SQLiteBindable] = []) throws -> Int? {
        try query(sql, values) { $0.optionalInt(0) }.first ?? nil
    }

    func scalarDouble(_ sql: String, _ values: [any SQLiteBindable] = []) throws -> Double? {
        try query(sql, values) { $0.optionalDouble(0) }.first ?? nil
    }

    var lastInsertID: Int { Int(sqlite3_last_insert_rowid(handle)) }

    var isInTransaction: Bool { sqlite3_get_autocommit(handle) == 0 }

    /// Alles in `body` als eine Transaktion; bei einem Fehler wird zurückgerollt.
    /// Verschachtelt läuft `body` in der äußeren Transaktion mit.
    func transaction<T>(_ body: () throws -> T) throws -> T {
        guard !isInTransaction else { return try body() }
        try execute("BEGIN IMMEDIATE")
        do {
            let result = try body()
            try execute("COMMIT")
            return result
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    var userVersion: Int {
        get { (try? scalar("PRAGMA user_version")) ?? 0 }
    }

    func setUserVersion(_ version: Int) throws {
        try execute("PRAGMA user_version = \(version)")
    }

    /// Vergisst alle vorbereiteten Statements (vor ATTACH/DETACH oder Schließen).
    func clearCache() { cache.removeAll() }
}
