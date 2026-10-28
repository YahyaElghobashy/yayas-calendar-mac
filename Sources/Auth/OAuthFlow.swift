import AppKit
import Foundation

/// One token-endpoint response. Access tokens are only ever held in memory.
struct TokenGrant: Sendable, CustomStringConvertible {
    let accessToken: String
    let expiresAt: Date
    /// Always present after sign-in; on refresh, present when the provider rotated it (Microsoft).
    let refreshToken: String?
    let idToken: String?
    let grantedScopes: [String]

    var description: String {
        "TokenGrant(expiresAt: \(expiresAt), refreshToken: \(refreshToken == nil ? "none" : "redacted"), scopes: \(grantedScopes.count))"
    }
}

/// Identity claims from an id_token, decoded **without** signature verification: they label the
/// account and nothing else. The token arrives straight from the token endpoint over TLS.
struct IDTokenClaims: Equatable, Sendable {
    static let microsoftPersonalTenant = "9188040d-6c67-4c5b-b112-36a304b66dad"

    let subject: String?
    /// Microsoft: object id, stable per user per tenant.
    let objectId: String?
    let tenantId: String?
    let email: String?
    let preferredUsername: String?
    let name: String?
    let nonce: String?
    /// Google Workspace domain.
    let hostedDomain: String?

    /// Personal Microsoft accounts often carry no `email` claim; `preferred_username` is the address.
    var displayEmail: String? { email ?? preferredUsername.flatMap { $0.contains("@") ? $0 : nil } }

    /// What makes an account unique: Google `sub`, Microsoft `oid` + `tid`.
    var stableIdentity: String? {
        if let objectId, let tenantId { return "\(tenantId)/\(objectId)" }
        return subject
    }

    var isMicrosoftPersonal: Bool { tenantId == Self.microsoftPersonalTenant }

    static func decodeUnverified(_ jwt: String) -> IDTokenClaims? {
        let segments = jwt.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count == 3,
              let payload = Data(base64URLEncoded: String(segments[1])),
              let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any]
        else { return nil }
        func string(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        return IDTokenClaims(subject: string("sub"), objectId: string("oid"), tenantId: string("tid"),
                             email: string("email"), preferredUsername: string("preferred_username"),
                             name: string("name"), nonce: string("nonce"), hostedDomain: string("hd"))
    }
}

/// Failures mapped to what the app does about them. Associated values carry provider error codes only,
/// never descriptions (Microsoft's can contain the user's address).
enum AuthError: Error, Equatable, Sendable, CustomStringConvertible {
    case notConfigured(Provider)
    case browserUnavailable
    case loopbackUnavailable
    case cancelled
    case timedOut
    /// The refresh token is dead: sign in again.
    case reauthNeeded(code: String)
    /// An administrator (or the consent policy) blocks the app; or the user declined consent.
    case adminBlocked(code: String)
    /// The client ID or secret is wrong, or the redirect is not registered.
    case clientRejected(code: String)
    case offline
    case server(status: Int)
    case provider(code: String)
    case invalidResponse(String)
    case missingRefreshToken
    case nonceMismatch

    var description: String {
        switch self {
        case .notConfigured(let provider): return "notConfigured(\(provider.rawValue))"
        case .browserUnavailable: return "browserUnavailable"
        case .loopbackUnavailable: return "loopbackUnavailable"
        case .cancelled: return "cancelled"
        case .timedOut: return "timedOut"
        case .reauthNeeded(let code): return "reauthNeeded(\(code))"
        case .adminBlocked(let code): return "adminBlocked(\(code))"
        case .clientRejected(let code): return "clientRejected(\(code))"
        case .offline: return "offline"
        case .server(let status): return "server(\(status))"
        case .provider(let code): return "provider(\(code))"
        case .invalidResponse(let reason): return "invalidResponse(\(reason))"
        case .missingRefreshToken: return "missingRefreshToken"
        case .nonceMismatch: return "nonceMismatch"
        }
    }
}

struct AuthorizationResult: Sendable {
    let grant: TokenGrant
    let claims: IDTokenClaims?
}

/// Authorization-code flow with PKCE over a loopback redirect (RFC 8252), plus refresh and revoke.
struct OAuthFlow: Sendable {
    typealias BrowserOpener = @Sendable (URL) async -> Bool

    static let openInDefaultBrowser: BrowserOpener = { url in
        await MainActor.run { NSWorkspace.shared.open(url) }
    }

    let provider: Provider
    let client: ProviderClient
    private let http: HTTP
    private let openBrowser: BrowserOpener
    private let now: @Sendable () -> Date

    init(provider: Provider, client: ProviderClient, http: HTTP = .shared,
         openBrowser: @escaping BrowserOpener = OAuthFlow.openInDefaultBrowser,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.provider = provider
        self.client = client
        self.http = http
        self.openBrowser = openBrowser
        self.now = now
    }

    /// Opens the provider's consent page in the default browser and waits for the redirect.
    /// `onListening` receives the redirect URI once the browser has been asked to open.
    func authorize(loginHint: String? = nil, timeout: TimeInterval = LoopbackServer.defaultTimeout,
                   onListening: (@Sendable (URL) -> Void)? = nil) async throws -> AuthorizationResult {
        try requireUsableClient()
        let pkce = try PKCE()
        let state = try SecureRandom.state()
        let nonce = try SecureRandom.nonce()

        let server = LoopbackServer(binding: provider.loopbackBinding, expectedState: state, timeout: timeout)
        let redirectURI: URL
        do {
            redirectURI = try await server.start()
        } catch {
            throw Self.map(loopback: error)
        }

        let url = Self.authorizeURL(provider: provider, clientId: client.clientId, redirectURI: redirectURI,
                                    pkce: pkce, state: state, nonce: nonce, loginHint: loginHint)
        guard await openBrowser(url) else {
            server.cancel()
            throw AuthError.browserUnavailable
        }
        onListening?(redirectURI)

        let outcome: LoopbackServer.Outcome
        do {
            outcome = try await server.waitForCallback()
        } catch {
            throw Self.map(loopback: error)
        }

        switch outcome {
        case .providerError(let code, let description, let subcode):
            throw Self.classify(code: code, description: description, subcode: subcode)
        case .code(let code):
            let grant = try await exchange(code: code, verifier: pkce.verifier, redirectURI: redirectURI)
            guard grant.refreshToken != nil else { throw AuthError.missingRefreshToken }
            let claims = grant.idToken.flatMap(IDTokenClaims.decodeUnverified)
            if let echoed = claims?.nonce, !LoopbackRoute.constantTimeEquals(echoed, nonce) {
                throw AuthError.nonceMismatch
            }
            return AuthorizationResult(grant: grant, claims: claims)
        }
    }

    func exchange(code: String, verifier: String, redirectURI: URL) async throws -> TokenGrant {
        var fields = [("grant_type", "authorization_code"), ("code", code),
                      ("redirect_uri", redirectURI.absoluteString), ("client_id", client.clientId),
                      ("code_verifier", verifier)]
        appendClientFields(to: &fields)
        return try await tokenRequest(fields)
    }

    /// Redeems a refresh token. For Microsoft the grant carries the rotated refresh token, which the
    /// caller must persist before using the access token.
    func refresh(using refreshToken: String) async throws -> TokenGrant {
        var fields = [("grant_type", "refresh_token"), ("refresh_token", refreshToken),
                      ("client_id", client.clientId)]
        appendClientFields(to: &fields)
        return try await tokenRequest(fields)
    }

    /// Best effort (Google only); returns whether the provider confirmed it.
    @discardableResult
    func revoke(_ token: String) async -> Bool {
        guard let url = provider.revokeURL,
              let response = try? await http.postForm(url, fields: [("token", token)])
        else { return false }
        return response.isSuccess
    }

    static func authorizeURL(provider: Provider, clientId: String, redirectURI: URL, pkce: PKCE,
                             state: String, nonce: String, loginHint: String? = nil) -> URL {
        var parameters: [(String, String)] = [
            ("client_id", clientId),
            ("response_type", "code"),
            ("redirect_uri", redirectURI.absoluteString),
            ("scope", provider.scope),
            ("state", state),
            ("nonce", nonce),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", PKCE.method),
        ]
        parameters += provider.extraAuthorizeParameters.map { ($0.name, $0.value) }
        if let loginHint { parameters.append(("login_hint", loginHint)) }

        var components = URLComponents(url: provider.authorizeURL, resolvingAgainstBaseURL: false)!
        components.percentEncodedQueryItems = parameters.map {
            URLQueryItem(name: FormURLEncoding.escape($0.0), value: FormURLEncoding.escape($0.1))
        }
        return components.url!
    }

    // MARK: - Token endpoint

    private func requireUsableClient() throws {
        guard !client.clientId.isEmpty,
              !provider.requiresClientSecret || !(client.clientSecret ?? "").isEmpty
        else { throw AuthError.notConfigured(provider) }
    }

    private func appendClientFields(to fields: inout [(String, String)]) {
        if provider.requiresClientSecret, let secret = client.clientSecret { fields.append(("client_secret", secret)) }
        if let scope = provider.tokenRequestScope { fields.append(("scope", scope)) }
    }

    private func tokenRequest(_ fields: [(String, String)]) async throws -> TokenGrant {
        try requireUsableClient()
        let response: HTTPResponse
        do {
            response = try await http.postForm(provider.tokenURL, fields: fields)
        } catch {
            throw Self.classify(transport: error)
        }
        guard response.isSuccess else { throw Self.tokenError(from: response) }
        return try Self.parseTokenResponse(response.body, now: now())
    }

    static func parseTokenResponse(_ data: Data, now: Date) throws -> TokenGrant {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw AuthError.invalidResponse("token response is not a JSON object")
        }
        guard let accessToken = json["access_token"] as? String, !accessToken.isEmpty else {
            throw AuthError.invalidResponse("no access_token")
        }
        if let type = json["token_type"] as? String, type.lowercased() != "bearer" {
            throw AuthError.invalidResponse("token_type \(type)")
        }
        func nonEmpty(_ key: String) -> String? {
            guard let value = json[key] as? String, !value.isEmpty else { return nil }
            return value
        }
        let lifetime = seconds(json["expires_in"]) ?? 3600
        let scopes = (json["scope"] as? String)?.split(separator: " ").map(String.init) ?? []
        return TokenGrant(accessToken: accessToken, expiresAt: now.addingTimeInterval(max(0, lifetime)),
                          refreshToken: nonEmpty("refresh_token"), idToken: nonEmpty("id_token"),
                          grantedScopes: scopes)
    }

    private static func seconds(_ value: Any?) -> TimeInterval? {
        switch value {
        case let number as NSNumber: return number.doubleValue
        case let text as String: return TimeInterval(text)
        default: return nil
        }
    }

    static func tokenError(from response: HTTPResponse) -> AuthError {
        let json = (try? response.jsonObject()) ?? [:]
        guard let code = json["error"] as? String, !code.isEmpty else {
            return response.status >= 500 ? .server(status: response.status) : .provider(code: "http_\(response.status)")
        }
        if code == "server_error" || code == "temporarily_unavailable" { return .server(status: response.status) }
        let codes = (json["error_codes"] as? [NSNumber])?.map(\.intValue) ?? []
        return classify(code: code, description: json["error_description"] as? String, errorCodes: codes)
    }

    // MARK: - Error classification

    /// Entra codes that mean consent or policy stands in the way.
    static let adminBlockedAADSTS: Set<Int> = [65001, 90094, 90095, 50105, 53003]
    /// Entra codes that mean the refresh token or session is gone.
    static let reauthAADSTS: Set<Int> = [70000, 70008, 700082, 700084, 50173, 50132, 50076, 50079]

    static func classify(code: String, description: String?, subcode: String? = nil, errorCodes: [Int] = []) -> AuthError {
        let aadsts = Set(errorCodes).union(aadstsCodes(in: description))
        if subcode == "cancel" || aadsts.contains(65004) { return .cancelled }
        if let blocked = aadsts.intersection(adminBlockedAADSTS).min() { return .adminBlocked(code: "AADSTS\(blocked)") }
        switch code {
        case "admin_policy_enforced", "org_internal", "access_denied", "consent_required":
            return .adminBlocked(code: code)
        case "invalid_grant", "interaction_required", "login_required":
            let specific = aadsts.intersection(reauthAADSTS).min().map { "AADSTS\($0)" }
            return .reauthNeeded(code: specific ?? code)
        case "deleted_client":
            return .clientRejected(code: code)
        case "invalid_client" where (description ?? "").lowercased().contains("deleted")
                                   || (description ?? "").lowercased().contains("not found"):
            // Google deletes OAuth clients unused for 6 months ("The OAuth client was deleted." / "…not found.").
            return .clientRejected(code: "deleted_client")
        case "invalid_client", "unauthorized_client", "redirect_uri_mismatch", "unsupported_response_type":
            return .clientRejected(code: code)
        default:
            if let expired = aadsts.intersection(reauthAADSTS).min() { return .reauthNeeded(code: "AADSTS\(expired)") }
            return .provider(code: code)
        }
    }

    static func classify(transport error: Error) -> AuthError {
        if let auth = error as? AuthError { return auth }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost, .timedOut, .cannotFindHost,
                 .cannotConnectToHost, .dnsLookupFailed, .internationalRoamingOff, .dataNotAllowed,
                 .callIsActive:
                return .offline
            default:
                return .provider(code: "url_\(urlError.code.rawValue)")
            }
        }
        if let httpError = error as? HTTPError { return .invalidResponse("\(httpError)") }
        return .provider(code: "transport")
    }

    static func map(loopback error: Error) -> AuthError {
        switch error as? LoopbackServer.Failure {
        case .timedOut?: return .timedOut
        case .cancelled?: return .cancelled
        default: return .loopbackUnavailable
        }
    }

    /// Every `AADSTS<digits>` in a description.
    static func aadstsCodes(in text: String?) -> Set<Int> {
        guard let text else { return [] }
        var codes: Set<Int> = []
        var rest = Substring(text)
        while let marker = rest.range(of: "AADSTS") {
            let digits = rest[marker.upperBound...].prefix { $0.isASCII && $0.isNumber }
            if let value = Int(digits) { codes.insert(value) }
            rest = rest[marker.upperBound...]
        }
        return codes
    }
}
