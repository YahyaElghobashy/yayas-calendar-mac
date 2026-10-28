import AppKit

extension AccountDirectory {
    /// The live directory: the accounts store, in the user's order, with their logos.
    static func live() -> AccountDirectory {
        let model = AccountsModel.shared
        let logos = model.logos
        return AccountDirectory(accounts: model.accounts.map { r in
            DirectoryAccount(id: r.id, tag: r.tag, name: r.displayName, email: r.email, color: r.color,
                             logo: logos[r.id], includeInAll: r.includeInAll, calendarEnabled: r.calendarEnabled,
                             mailEnabled: r.mailEnabled)
        })
    }
}
