import Foundation

// Settings → Mail → Writing (D-042) and the other rich-mail keys. Everything lives in
// `MailLocalStore` (UserDefaults in the app, memory in tests and renders), never under `labs.*`. Values are stored
// as strings (the store's one type); anything unknown or malformed reads as the default.

struct RichMailSettings: Equatable {
    static let fontFamilyKey = "mail.compose.fontFamily"
    static let fontSizeKey = "mail.compose.fontSize"
    static let plainTextOnlyKey = "mail.compose.plainTextOnly"
    static let quoteStyleKey = "mail.compose.quoteStyle"
    /// One key with the reader's Save (`AttachmentSaveFolder.key`).
    static let saveFolderKey = AttachmentSaveFolder.key
    static let imagesFromCorrespondentsKey = "mail.images.fromCorrespondents"

    /// Key → default, for the Settings tests and the CONTRACTS section.
    static let defaults: [(key: String, value: String)] = [
        (fontFamilyKey, FontChoice.sans.rawValue), (fontSizeKey, "\(SizeChoice.normal.rawValue)"), (plainTextOnlyKey, "false"),
        (quoteStyleKey, MailQuoteRequest.Style.bar.rawValue), (saveFolderKey, ""), (imagesFromCorrespondentsKey, "false"),
    ]

    var font: FontChoice = .sans
    var size: SizeChoice = .normal
    var plainTextOnly = false
    var quoteStyle: MailQuoteRequest.Style = .bar
    /// "" = Downloads.
    var saveFolder = ""
    var imagesFromCorrespondents = false

    init() {}

    init(local: MailLocalStore) {
        font = local.string(Self.fontFamilyKey).flatMap(FontChoice.init(rawValue:)) ?? .sans
        size = local.string(Self.fontSizeKey).flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }.flatMap(SizeChoice.init(rawValue:)) ?? .normal
        plainTextOnly = Self.bool(local.string(Self.plainTextOnlyKey))
        quoteStyle = local.string(Self.quoteStyleKey).flatMap(MailQuoteRequest.Style.init(rawValue:)) ?? .bar
        saveFolder = local.string(Self.saveFolderKey) ?? ""
        imagesFromCorrespondents = Self.bool(local.string(Self.imagesFromCorrespondentsKey))
    }

    func save(to local: MailLocalStore) {
        local.setString(font.rawValue, Self.fontFamilyKey)
        local.setString("\(size.rawValue)", Self.fontSizeKey)
        local.setString(plainTextOnly ? "true" : "false", Self.plainTextOnlyKey)
        local.setString(quoteStyle.rawValue, Self.quoteStyleKey)
        local.setString(saveFolder, Self.saveFolderKey)
        local.setString(imagesFromCorrespondents ? "true" : "false", Self.imagesFromCorrespondentsKey)
    }

    private static func bool(_ value: String?) -> Bool {
        guard let v = value?.trimmingCharacters(in: .whitespaces).lowercased() else { return false }
        return v == "true" || v == "1" || v == "yes"
    }

    var documentDefaults: ComposerDocument.Defaults { ComposerDocument.Defaults(font: font, size: size) }

    // MARK: Save folder

    /// Where Save puts files: the chosen folder when it exists and is writable, else Downloads with a note. The one
    /// rule lives in `AttachmentSaveFolder.resolve` (the reader's Save, Save All and Settings use it too).
    func saveFolder(downloads: URL = AttachmentSaveFolder.downloads, usable: (URL) -> Bool = AttachmentSaveFolder.isUsable) -> AttachmentSaveFolder {
        AttachmentSaveFolder.resolve(stored: saveFolder, downloads: downloads, usable: usable)
    }

    // MARK: Labels (Settings)

    static let plainTextLine = "No formatting, no inline images. Attachments still work."

    static func quoteStyleTitle(_ style: MailQuoteRequest.Style) -> String {
        style == .bar ? "Bar, like Gmail" : "Header above the quote"
    }
}
