import Foundation
import UserNotifications

enum SuiteTests {
    static func run() {
        T.section("installer flags: --permissions-json line")
        T.equal(SuiteJSON.permissions(loginItem: true, notifications: "granted"),
                #"{"app":"yayascalendar","loginItem":true,"notifications":"granted"}"#, "exact bytes, contract key order")
        T.equal(SuiteJSON.permissions(loginItem: false, notifications: "denied"),
                #"{"app":"yayascalendar","loginItem":false,"notifications":"denied"}"#, "false + denied")
        T.equal(SuiteJSON.permissions(loginItem: false, notifications: "maybe"),
                #"{"app":"yayascalendar","loginItem":false,"notifications":"undetermined"}"#, "unknown state → undetermined")
        for state in ["granted", "denied", "undetermined"] {
            for login in [true, false] {
                let line = SuiteJSON.permissions(loginItem: login, notifications: state)
                T.check(!line.contains("\n"), "one line")
                guard let object = (try? JSONSerialization.jsonObject(with: Data(line.utf8))) as? [String: Any] else {
                    T.check(false, "valid JSON: \(line)"); continue
                }
                T.equal(Set(object.keys), ["app", "loginItem", "notifications"], "keys")
                T.equal(object["app"] as? String, "yayascalendar", "app")
                T.equal(object["loginItem"] as? Bool, login, "loginItem is a JSON bool")
                T.equal(object["notifications"] as? String, state, "notifications")
            }
        }

        T.section("installer flags: notification states")
        T.equal(SuiteJSON.notificationState(.authorized), "granted", "authorized")
        T.equal(SuiteJSON.notificationState(.provisional), "granted", "provisional")
        T.equal(SuiteJSON.notificationState(.denied), "denied", "denied")
        T.equal(SuiteJSON.notificationState(.notDetermined), "undetermined", "notDetermined")

        T.section("installer flags: --selftest line")
        let pass = SuiteJSON.selftest(checks: [("dirs", true), ("keychain", true), ("widgetFile", true)], failures: [:], millis: 42)
        T.equal(pass, #"{"app":"yayascalendar","selftest":"pass","dirs":true,"keychain":true,"widgetFile":true,"ms":42}"#, "pass line")
        let fail = SuiteJSON.selftest(checks: [("dirs", true), ("keychain", false)], failures: ["keychain": "add:-25308"], millis: 7)
        let object = (try? JSONSerialization.jsonObject(with: Data(fail.utf8))) as? [String: Any]
        T.equal(object?["selftest"] as? String, "fail", "fail line says fail")
        T.equal((object?["errors"] as? [String: String])?["keychain"], "add:-25308", "fail line carries the code")
    }
}
