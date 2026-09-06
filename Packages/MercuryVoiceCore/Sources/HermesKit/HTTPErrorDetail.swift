import Foundation

/// Caps and redacts HTTP error text shown in UI notices, and bounds how much
/// of a non-2xx body is retained while it is received.
///
/// Success bodies (TTS audio, profiles JSON) stay unbounded — a transport-wide
/// cap would truncate valid speech.
package enum HTTPErrorDetail {
    /// Existing plain-body policy; JSON error strings must match.
    package static let displayLimit = 300
    /// Non-2xx bodies only. 64 KiB is enough to parse typical provider JSON
    /// errors; hostile multi-megabyte dumps stop here.
    package static let errorReadLimit = 64 * 1024

    package static func displayed(_ text: String) -> String {
        cap(redact(text))
    }

    /// REST/auth `detail` field, already capped and redacted. `nil` when the
    /// body is not JSON or has no string `detail` (login keeps that optional).
    package static func restJSONDetail(_ data: Data) -> String? {
        (try? JSONDecoder().decode(JSONValue.self, from: data))?["detail"]?
            .stringValue.map(displayed)
    }

    package static func load(
        _ request: URLRequest, on session: URLSession
    ) async throws -> (Data, URLResponse) {
        let (bytes, response) = try await session.bytes(for: request)
        let http = response as? HTTPURLResponse
        let success = http.map { (200..<300).contains($0.statusCode) } ?? false
        let expected = http?.expectedContentLength ?? -1
        let data = try await collect(
            bytes,
            limit: success ? nil : errorReadLimit,
            hint: expected > 0 ? Int(expected) : nil)
        return (data, response)
    }

    private static func collect(
        _ bytes: URLSession.AsyncBytes, limit: Int?, hint: Int?
    ) async throws -> Data {
        var data = Data()
        data.reserveCapacity(limit ?? hint ?? 65_536)
        for try await byte in bytes {
            data.append(byte)
            if let limit, data.count >= limit { break }
        }
        return data
    }

    private static func cap(_ text: String) -> String {
        let utf8 = text.utf8
        guard utf8.count > displayLimit else { return text }
        return String(decoding: Data(utf8.prefix(displayLimit)), as: UTF8.self)
    }

    private static func redact(_ text: String) -> String {
        var result = text
        result = result.replacingOccurrences(
            of: #"(?i)\bBearer\s+\S+"#,
            with: "Bearer «redacted»",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)\bsk-[A-Za-z0-9_-]{8,}"#,
            with: "sk-«redacted»",
            options: .regularExpression)
        result = result.replacingOccurrences(
            of: #"(?i)\bxai-[A-Za-z0-9_-]{8,}"#,
            with: "xai-«redacted»",
            options: .regularExpression)
        return result
    }
}
