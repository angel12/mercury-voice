import Foundation

/// Low-level policy shared by Hermes REST and native auth requests.
/// Credential attachment, refresh/retry, and password-login interpretation
/// belong to their callers, not this transport.
enum HermesHTTP {
    /// Native auth uses headers/tickets, never stored or replayed SPA cookies.
    static func cookieFreeConfig() -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 30
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        return config
    }

    static func performJSON(
        _ request: URLRequest, on session: URLSession
    ) async throws -> JSONValue {
        let (data, response) = try await HTTPErrorDetail.load(request, on: session)
        guard let http = response as? HTTPURLResponse else {
            throw HermesError.malformedResponse("not an HTTP response")
        }
        switch http.statusCode {
        case 200..<300:
            break
        case 401:
            // Only 401 can trigger credential recovery. A 403 is an access
            // refusal that rotation cannot fix; preserve its server detail.
            throw HermesError.unauthorized
        default:
            let detail =
                HTTPErrorDetail.restJSONDetail(data)
                ?? HTTPErrorDetail.displayed(String(decoding: data, as: UTF8.self))
            throw HermesError.httpError(status: http.statusCode, detail: detail)
        }
        guard let json = try? JSONDecoder().decode(JSONValue.self, from: data) else {
            throw HermesError.malformedResponse("invalid JSON body")
        }
        return json
    }
}
