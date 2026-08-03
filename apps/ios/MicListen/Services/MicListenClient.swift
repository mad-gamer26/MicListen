import Foundation

enum MicListenError: LocalizedError {
    case invalidURL
    case unsupportedScheme(String)
    case authenticationRequired(String)
    case badPassword
    case notMicListen(String)
    case server(status: Int, message: String)
    case network(String)
    case malformedResponse(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Enter a valid MicListen URL."
        case .unsupportedScheme(let scheme):
            return "\(scheme) is not supported. Use http, https, ws, or wss."
        case .authenticationRequired(let message):
            return message
        case .badPassword:
            return "The password was rejected."
        case .notMicListen(let message):
            return message
        case .server(_, let message):
            return message
        case .network(let message):
            return message
        case .malformedResponse(let message):
            return message
        }
    }
}

final class MicListenClient {
    private let session: URLSession
    private let cookieStorage: HTTPCookieStorage
    private let decoder = JSONDecoder()

    init(cookieStorage: HTTPCookieStorage = .shared) {
        self.cookieStorage = cookieStorage

        let configuration = URLSessionConfiguration.default
        configuration.httpCookieAcceptPolicy = .always
        configuration.httpCookieStorage = cookieStorage
        configuration.httpShouldSetCookies = true
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 12
        configuration.timeoutIntervalForResource = 20
        self.session = URLSession(configuration: configuration)
    }

    func normalizedURL(from text: String) throws -> URL {
        var raw = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else {
            throw MicListenError.invalidURL
        }

        if raw.lowercased().hasPrefix("ws://") {
            raw.replaceSubrange(raw.startIndex..<raw.index(raw.startIndex, offsetBy: 5), with: "http://")
        } else if raw.lowercased().hasPrefix("wss://") {
            raw.replaceSubrange(raw.startIndex..<raw.index(raw.startIndex, offsetBy: 6), with: "https://")
        } else if !raw.contains("://") {
            raw = "\(defaultScheme(for: raw))://\(raw)"
        }

        guard var components = URLComponents(string: raw),
              let scheme = components.scheme?.lowercased(),
              let host = components.host,
              !host.isEmpty else {
            throw MicListenError.invalidURL
        }

        guard scheme == "http" || scheme == "https" else {
            throw MicListenError.unsupportedScheme(scheme)
        }

        components.scheme = scheme
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }

        guard let url = components.url else {
            throw MicListenError.invalidURL
        }
        return url
    }

    func fetchHealth(baseURL: URL) async throws -> HealthPayload {
        let url = baseURL.miclistenAppending("api/health")
        let data = try await requestData(url: url, method: "GET", accept: "application/json")
        do {
            return try decoder.decode(HealthPayload.self, from: data)
        } catch {
            throw MicListenError.malformedResponse("The server did not return MicListen health data.")
        }
    }

    func fetchDevices(baseURL: URL) async throws -> [AudioDevice] {
        let url = baseURL.miclistenAppending("api/devices")
        let data = try await requestData(url: url, method: "GET", accept: "application/json")
        do {
            return try decoder.decode(DeviceListResponse.self, from: data).devices
        } catch {
            throw MicListenError.malformedResponse("The server did not return a MicListen device list.")
        }
    }

    func login(baseURL: URL, password: String) async throws {
        let trimmed = password.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw MicListenError.authenticationRequired("Password required.")
        }

        let destination = baseURL.path.isEmpty ? "/" : baseURL.path
        let form = "password=\(trimmed.formURLEncoded)&next=\(destination.formURLEncoded)"
        var request = URLRequest(url: baseURL.miclistenAppending("login"))
        request.httpMethod = "POST"
        request.httpBody = Data(form.utf8)
        request.setValue("application/x-www-form-urlencoded; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.setValue("text/html,application/json", forHTTPHeaderField: "Accept")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MicListenError.network("The server did not return an HTTP response.")
            }
            if http.statusCode == 401 {
                throw MicListenError.badPassword
            }
            guard (200..<400).contains(http.statusCode) else {
                throw MicListenError.server(
                    status: http.statusCode,
                    message: errorMessage(from: data) ?? "Login failed with HTTP \(http.statusCode)."
                )
            }
        } catch let error as MicListenError {
            throw error
        } catch {
            throw MicListenError.network(error.localizedDescription)
        }
    }

    func fetchRelayStreamers(baseURL: URL) async throws -> [RelayStreamerLink] {
        let data = try await requestData(url: baseURL, method: "GET", accept: "text/html")
        guard let html = String(data: data, encoding: .utf8) else {
            throw MicListenError.malformedResponse("The relay home page could not be read.")
        }
        return parseRelayLinks(html: html, baseURL: baseURL)
    }

    func streamURL(baseURL: URL, deviceID: Int) -> URL {
        baseURL.miclistenAppending("stream/audio/\(deviceID).mp3")
    }

    func cookieHeader(for url: URL) -> String? {
        guard let cookies = cookieStorage.cookies(for: url), !cookies.isEmpty else {
            return nil
        }
        return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
    }

    private func requestData(url: URL, method: String, accept: String) async throws -> Data {
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.setValue(accept, forHTTPHeaderField: "Accept")
        request.setValue("no-store", forHTTPHeaderField: "Cache-Control")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw MicListenError.network("The server did not return an HTTP response.")
            }
            if http.statusCode == 401 {
                throw MicListenError.authenticationRequired(errorMessage(from: data) ?? "Password required.")
            }
            if http.statusCode == 404 {
                throw MicListenError.notMicListen("No MicListen service was found at this URL.")
            }
            guard (200..<300).contains(http.statusCode) else {
                throw MicListenError.server(
                    status: http.statusCode,
                    message: errorMessage(from: data) ?? "The server returned HTTP \(http.statusCode)."
                )
            }
            if let finalURL = http.url,
               finalURL.miclistenNormalizedPath.hasSuffix("/login") {
                throw MicListenError.authenticationRequired("Password required.")
            }
            return data
        } catch let error as MicListenError {
            throw error
        } catch let error as URLError {
            throw MicListenError.network(networkMessage(for: error))
        } catch {
            throw MicListenError.network(error.localizedDescription)
        }
    }

    private func parseRelayLinks(html: String, baseURL: URL) -> [RelayStreamerLink] {
        let pattern = #"href\s*=\s*["']([^"']+)["']"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return []
        }
        let range = NSRange(html.startIndex..<html.endIndex, in: html)
        let matches = regex.matches(in: html, range: range)
        var seen = Set<String>()
        var links: [RelayStreamerLink] = []

        for match in matches {
            guard match.numberOfRanges > 1,
                  let hrefRange = Range(match.range(at: 1), in: html) else {
                continue
            }
            let href = String(html[hrefRange])
            guard let resolved = URL(string: href, relativeTo: baseURL)?.absoluteURL,
                  let name = resolved.miclistenSinglePathComponent,
                  name.range(of: #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#, options: .regularExpression) != nil,
                  !seen.contains(name) else {
                continue
            }
            seen.insert(name)
            links.append(RelayStreamerLink(name: name, baseURL: resolved.miclistenDirectoryURL))
        }

        return links.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    private func errorMessage(from data: Data) -> String? {
        if let detail = try? decoder.decode(ErrorDetail.self, from: data).detail {
            return detail
        }
        if let text = String(data: data, encoding: .utf8) {
            let compact = text
                .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
                .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !compact.isEmpty, compact.count < 180 {
                return compact
            }
        }
        return nil
    }

    private func defaultScheme(for raw: String) -> String {
        let host = raw
            .split(separator: "/")
            .first?
            .split(separator: ":")
            .first
            .map(String.init)?
            .lowercased() ?? ""

        if host == "localhost" || host.hasSuffix(".local") || isPrivateIPv4(host) {
            return "http"
        }
        return "https"
    }

    private func isPrivateIPv4(_ host: String) -> Bool {
        let parts = host.split(separator: ".").compactMap { Int($0) }
        guard parts.count ==  4 else {
            return false
        }
        if parts[0] == 10 || parts[0] == 127 {
            return true
        }
        if parts[0] == 192 && parts[1] == 168 {
            return true
        }
        if parts[0] == 172 && (16...31).contains(parts[1]) {
            return true
        }
        return false
    }

    private func networkMessage(for error: URLError) -> String {
        switch error.code {
        case .cannotFindHost:
            return "The host could not be found."
        case .cannotConnectToHost:
            return "The host refused the connection."
        case .notConnectedToInternet:
            return "The network is unavailable."
        case .timedOut:
            return "The connection timed out."
        case .appTransportSecurityRequiresSecureConnection:
            return "iOS blocked the connection. Use HTTPS or a trusted local address."
        default:
            return error.localizedDescription
        }
    }
}

private struct ErrorDetail: Decodable {
    let detail: String?
}

private extension String {
    var formURLEncoded: String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._* ")
        return addingPercentEncoding(withAllowedCharacters: allowed)?
            .replacingOccurrences(of: " ", with: "+") ?? self
    }
}

private extension URL {
    var miclistenDirectoryURL: URL {
        guard var components = URLComponents(url: self, resolvingAgainstBaseURL: false) else {
            return self
        }
        components.query = nil
        components.fragment = nil
        if components.path.isEmpty {
            components.path = "/"
        }
        if !components.path.hasSuffix("/") {
            components.path += "/"
        }
        return components.url ?? self
    }

    var miclistenNormalizedPath: String {
        let value = path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        return "/\(value)"
    }

    var miclistenSinglePathComponent: String? {
        let components = path
            .split(separator: "/")
            .map(String.init)
        guard components.count == 1 else {
            return nil
        }
        return components[0]
    }

    func miclistenAppending(_ relativePath: String) -> URL {
        URL(string: relativePath, relativeTo: miclistenDirectoryURL)?.absoluteURL ?? self
    }
}
