import Foundation

extension URLSession {
    /// Wie `data(for:)`, bricht aber ab, sobald die Antwort `limit` Bytes
    /// übersteigt. Antworten von Fremddiensten (SondeHub, hexdb, Wikimedia …)
    /// landen ganz im Speicher – eine fehlerhafte oder manipulierte Antwort
    /// sollte die App nicht volllaufen lassen (Review 27.10.2026).
    func limitedData(for request: URLRequest, limit: Int = 20_000_000) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await self.bytes(for: request)
        if response.expectedContentLength > Int64(limit) { throw URLError(.dataLengthExceedsMaximum) }
        var data = Data()
        var chunk = [UInt8]()
        chunk.reserveCapacity(65_536)
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count == 65_536 {
                data.append(contentsOf: chunk)
                chunk.removeAll(keepingCapacity: true)
                if data.count > limit { throw URLError(.dataLengthExceedsMaximum) }
            }
        }
        data.append(contentsOf: chunk)
        guard data.count <= limit else { throw URLError(.dataLengthExceedsMaximum) }
        return (data, response)
    }
}
