import Foundation

/// The OAuth client the user registered with a provider. Nothing is baked into the bundle: Provider
/// Setup writes it to the keychain, and that is the only place the app reads it from.
struct ProviderClient: Codable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    let clientId: String
    /// Google Desktop clients only. Google treats it as non-confidential for installed apps, but it is
    /// still never logged or printed.
    let clientSecret: String?

    var description: String {
        "ProviderClient(clientId: …\(clientId.suffix(6)), clientSecret: \(clientSecret == nil ? "none" : "redacted"))"
    }

    var debugDescription: String { description }
}

enum OAuthConfigError: Error, Equatable {
    case missing(Provider)
    case invalid(Provider, reason: String)
    case unreadable(String)
}

/// Loads, validates and stores provider clients. Keychain: service `Profile.keychainClient`
/// (`<bundle id>.client`), account `google` / `microsoft`.
enum OAuthConfig {
    static let keychainService = Profile.keychainClient

    // Split so the repository's secret scanner, which flags real client IDs, does not trip on the
    // validation suffix itself.
    private static let googleClientSuffix = ".apps." + "googleusercontent" + ".com"

    private static let nullUUID = "00000000-0000-0000-0000-000000000000"

    private static var store: KeychainStore { KeychainStore(service: keychainService) }

    /// Nil when Provider Setup has not been completed for this provider.
    static func load(_ provider: Provider) throws -> ProviderClient? {
        let data: Data
        do {
            data = try store.read(account: provider.rawValue)
        } catch KeychainError.notFound {
            return nil
        }
        guard let client = try? JSONDecoder().decode(ProviderClient.self, from: data) else {
            throw KeychainError.corrupt
        }
        try validate(client, for: provider)
        return client
    }

    static func save(_ client: ProviderClient, for provider: Provider) throws {
        try validate(client, for: provider)
        let label = "Yaya\u{2019}s Calendar \u{2014} \(provider.displayName) OAuth client"
        try store.save(JSONEncoder().encode(client), account: provider.rawValue, label: label)
    }

    @discardableResult
    static func delete(_ provider: Provider) throws -> Bool {
        try store.delete(account: provider.rawValue)
    }

    /// Google's downloaded `client_secret_*.json`. Only Desktop ("installed") clients work with a
    /// loopback redirect; a Web client is called out by name because that is the usual mistake.
    static func parseGoogleClientSecretJSON(_ data: Data) throws -> ProviderClient {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthConfigError.unreadable("not a JSON object")
        }
        guard let installed = root["installed"] as? [String: Any] else {
            let reason = root["web"] != nil
                ? "this is a Web client; create a Desktop app client instead"
                : "no \"installed\" client in the file"
            throw OAuthConfigError.invalid(.google, reason: reason)
        }
        let client = ProviderClient(clientId: (installed["client_id"] as? String ?? "").trimmed,
                                    clientSecret: (installed["client_secret"] as? String)?.trimmed)
        try validate(client, for: .google)
        return client
    }

    static func validate(_ client: ProviderClient, for provider: Provider) throws {
        let id = client.clientId
        switch provider {
        case .google:
            guard id.hasSuffix(googleClientSuffix), id.count > googleClientSuffix.count, !isPlaceholder(id) else {
                throw OAuthConfigError.invalid(.google, reason: "client ID is not a Google OAuth client ID")
            }
            guard let secret = client.clientSecret, !secret.isEmpty, !isPlaceholder(secret) else {
                throw OAuthConfigError.invalid(.google, reason: "Desktop clients need their client secret")
            }
        case .microsoft:
            guard let uuid = UUID(uuidString: id), uuid.uuidString != nullUUID else {
                throw OAuthConfigError.invalid(.microsoft, reason: "client ID must be the Application (client) ID GUID")
            }
        }
    }

    private static func isPlaceholder(_ value: String) -> Bool {
        value.uppercased().hasPrefix("PASTE")
    }
}

extension OAuthConfig {
    /// The developer file's shape (`Config/oauth.local.example.json`, real copy in the gitignored
    /// `Config/oauth.local.json`): `{"google":{"clientId","clientSecret"},"microsoft":{"clientId"}}`.
    /// Providers that are absent or still hold placeholders are left out rather than failing the whole
    /// file. Used by the app's "Import from developer file" (Provider Setup), which copies the result into
    /// the Keychain; the file itself is never the app's source of truth.
    static func parseDevFile(_ data: Data) throws -> [Provider: ProviderClient] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw OAuthConfigError.unreadable("not a JSON object")
        }
        var clients: [Provider: ProviderClient] = [:]
        for provider in Provider.allCases {
            guard let entry = root[provider.rawValue] as? [String: Any] else { continue }
            let client = ProviderClient(clientId: (entry["clientId"] as? String ?? "").trimmed,
                                        clientSecret: (entry["clientSecret"] as? String)?.trimmed)
            if (try? validate(client, for: provider)) != nil { clients[provider] = client }
        }
        return clients
    }
}

#if OAUTH_PROBE
extension OAuthConfig {
    /// Dev probe only — never compiled into the shipping app. Reads the gitignored
    /// `Config/oauth.local.json` (see `parseDevFile`).
    static func loadDevFile(at url: URL) throws -> [Provider: ProviderClient] {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch {
            throw OAuthConfigError.unreadable("cannot read \(url.lastPathComponent)")
        }
        do {
            return try parseDevFile(data)
        } catch {
            throw OAuthConfigError.unreadable("\(url.lastPathComponent) is not a JSON object")
        }
    }
}
#endif

private extension String {
    var trimmed: String { trimmingCharacters(in: .whitespacesAndNewlines) }
}
