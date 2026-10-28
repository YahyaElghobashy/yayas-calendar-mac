import Foundation

/// Defaults for a freshly connected account. Everything here is a first guess the user can edit.
enum AccountNaming {
    /// Consumer Google domains: these accounts are "Personal" and get no company logo.
    static let personalDomains: Set<String> = ["gmail.com", "googlemail.com"]

    static func domain(of email: String) -> String? {
        guard let at = email.lastIndex(of: "@") else { return nil }
        let domain = email[email.index(after: at)...]
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            .lowercased()
        return domain.isEmpty ? nil : domain
    }

    static func isPersonal(email: String) -> Bool {
        domain(of: email).map(personalDomains.contains) ?? false
    }

    /// The domain's first label, title-cased: orbitalpickle.example → "Orbitalpickle",
    /// quietcomets.example → "Quietcomets", gmail.com → "Gmail", moon-toast-bakery.example → "Moon Toast Bakery".
    static func displayName(for email: String) -> String {
        guard let label = firstLabel(of: email) else { return "Account" }
        let words = label.split(whereSeparator: { $0 == "-" || $0 == "_" }).map { word in
            word.prefix(1).uppercased() + word.dropFirst().lowercased()
        }
        let name = words.joined(separator: " ")
        return name.isEmpty ? "Account" : name
    }

    /// "Personal" for consumer Google accounts, else the first three letters of the domain's first label
    /// (ORB, QUI, MOO…). A tag already taken gets a digit (QUI2) so chips stay distinguishable.
    static func tag(for email: String, taken: Set<String> = []) -> String {
        let base: String
        if isPersonal(email: email) {
            base = "Personal"
        } else {
            let letters = (firstLabel(of: email) ?? "").filter { $0.isASCII && ($0.isLetter || $0.isNumber) }
            let prefix = String(letters.prefix(3)).uppercased()
            base = prefix.isEmpty ? "ACC" : prefix
        }
        let used = Set(taken.map { $0.lowercased() })
        guard used.contains(base.lowercased()) else { return base }
        var n = 2
        while used.contains("\(base)\(n)".lowercased()) { n += 1 }
        return "\(base)\(n)"
    }

    /// The first swatch no account uses yet; once all eight are taken, they repeat in order.
    static func nextColor(used: [UInt32], palette: [UInt32] = AppTheme.accountSwatches) -> UInt32 {
        guard !palette.isEmpty else { return 0x8FB4C4 }
        if let free = palette.first(where: { !used.contains($0) }) { return free }
        return palette[used.count % palette.count]
    }

    private static func firstLabel(of email: String) -> String? {
        guard let domain = domain(of: email), let label = domain.split(separator: ".").first else { return nil }
        return String(label)
    }
}
