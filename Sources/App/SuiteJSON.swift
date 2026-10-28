import Foundation
import UserNotifications

/// Pure formatting for the installer flags (docs/CONTRACTS.md, installer flags).
/// Kept free of AppKit so the test binary checks the exact bytes the installer parses.
enum SuiteJSON {
    static let appKey = "yayascalendar"

    /// `{"app":"yayascalendar","loginItem":true,"notifications":"granted"}`: one line, this key order.
    static func permissions(loginItem: Bool, notifications: String) -> String {
        let state = ["granted", "denied", "undetermined"].contains(notifications) ? notifications : "undetermined"
        return "{\"app\":\"\(appKey)\",\"loginItem\":\(loginItem ? "true" : "false"),\"notifications\":\"\(state)\"}"
    }

    static func notificationState(_ status: UNAuthorizationStatus) -> String {
        switch status {
        case .authorized, .provisional: return "granted"
        case .denied: return "denied"
        default: return "undetermined"
        }
    }

    /// `--selftest` result line. `failures` maps a check name to a short code (never a secret).
    static func selftest(checks: [(name: String, ok: Bool)], failures: [String: String], millis: Int) -> String {
        let pass = checks.allSatisfy(\.ok)
        var parts = ["\"app\":\"\(appKey)\"", "\"selftest\":\"\(pass ? "pass" : "fail")\""]
        parts += checks.map { "\"\($0.name)\":\($0.ok ? "true" : "false")" }
        if !failures.isEmpty {
            let errors = failures.keys.sorted().map { "\"\($0)\":\"\(failures[$0]!)\"" }.joined(separator: ",")
            parts.append("\"errors\":{\(errors)}")
        }
        parts.append("\"ms\":\(millis)")
        return "{" + parts.joined(separator: ",") + "}"
    }
}
