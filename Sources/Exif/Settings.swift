import AppKit
import SwiftUI

/// ExifCleaner's settings (settings_schema.ts), same defaults, kept in UserDefaults.
@MainActor
final class AppSettings: ObservableObject {
    static let shared = AppSettings()

    @Published var preserveOrientation: Bool { didSet { save("preserveOrientation", preserveOrientation) } }
    @Published var preserveColorProfile: Bool { didSet { save("preserveColorProfile", preserveColorProfile) } }
    @Published var preserveResolution: Bool { didSet { save("preserveResolution", preserveResolution) } }
    @Published var saveAsCopy: Bool { didSet { save("saveAsCopy", saveAsCopy) } }
    @Published var preserveTimestamps: Bool { didSet { save("preserveTimestamps", preserveTimestamps) } }
    @Published var removeXattrs: Bool { didSet { save("removeXattrs", removeXattrs) } }
    /// Empty: the system's language.
    @Published var language: String { didSet { save("language", language); I18n.shared.language = language } }
    /// light, system, dark
    @Published var themeMode: String { didSet { save("themeMode", themeMode); applyTheme() } }

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        preserveOrientation = b("preserveOrientation", true)
        preserveColorProfile = b("preserveColorProfile", true)
        preserveResolution = b("preserveResolution", true)
        saveAsCopy = b("saveAsCopy", true)
        preserveTimestamps = b("preserveTimestamps", false)
        removeXattrs = b("removeXattrs", false)
        language = d.string(forKey: "language") ?? ""
        themeMode = d.string(forKey: "themeMode") ?? "system"
        I18n.shared.language = language
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    var options: CleanArgs.Options {
        CleanArgs.Options(preserveOrientation: preserveOrientation, preserveColorProfile: preserveColorProfile,
                          preserveResolution: preserveResolution, preserveTimestamps: preserveTimestamps)
    }

    func applyTheme() {
        switch themeMode {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

/// The translations ExifCleaner ships (strings.json, 26 languages), looked up the same way:
/// the chosen language, then its base ("pt-BR" → "pt"), then English.
final class I18n: @unchecked Sendable {
    static let shared = I18n()

    static let languages: [(code: String, name: String)] = [
        ("ca", "Català"), ("cs", "Čeština"), ("da", "Dansk"), ("de", "Deutsch"), ("en", "English"), ("es", "Español"),
        ("fr", "Français"), ("hr", "Hrvatski"), ("it", "Italiano"), ("hu", "Magyar"), ("nl", "Nederlands"), ("pl", "Polski"),
        ("pt", "Português"), ("pt-BR", "Português (Brasil)"), ("ro", "Română"), ("sk", "Slovenčina"), ("sv", "Svenska"),
        ("vi", "Tiếng Việt"), ("tr", "Türkçe"), ("ru", "Русский"), ("uk", "Українська"), ("ar", "العربية"), ("fa", "فارسی"),
        ("ml", "മലയാളം"), ("zh", "中文"), ("ja", "日本語"),
    ]

    private let strings: [String: [String: String]]
    var language = "" { didSet { resolved = Self.resolve(language) } }
    private(set) var resolved = "en"

    private init() {
        var table: [String: [String: String]] = [:]
        if let url = Bundle.main.url(forResource: "strings", withExtension: "json") ?? Self.devStrings,
           let data = try? Data(contentsOf: url),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: [String: String]] {
            table = json
        }
        strings = table
        resolved = Self.resolve("")
    }

    private static var devStrings: URL? {
        ProcessInfo.processInfo.environment["EXIF_TOOLS"].map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/strings.json") }
    }

    private static func resolve(_ chosen: String) -> String {
        let codes = Set(languages.map(\.code))
        let candidates = chosen.isEmpty ? Locale.preferredLanguages : [chosen]
        for c in candidates {
            if codes.contains(c) { return c }
            let parts = c.split(separator: "-")
            if parts.count >= 2, codes.contains("\(parts[0])-\(parts.last!)") { return "\(parts[0])-\(parts.last!)" }
            if let base = parts.first, codes.contains(String(base)) { return String(base) }
        }
        return "en"
    }

    var isRightToLeft: Bool { ["ar", "fa"].contains(resolved) }

    func t(_ key: String, _ params: [String: Any] = [:]) -> String {
        let set = strings[key] ?? [:]
        var s = set[resolved] ?? set[String(resolved.split(separator: "-").first ?? "")] ?? set["en"] ?? key
        if s.isEmpty { s = set["en"] ?? key }
        for (k, v) in params { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
        return s
    }
}

func t(_ key: String, _ params: [String: Any] = [:]) -> String { I18n.shared.t(key, params) }

/// ExifCleaner's settings drawer, as a native inspector beside the file list: appearance,
/// language and the cleaning options, each saved at once.
struct SettingsPanel: View {
    @ObservedObject private var settings = AppSettings.shared
    var onClose: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(t("menu.app.settings")).font(.title3.weight(.semibold))
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark").font(.system(size: 12, weight: .semibold)) }
                        .buttonStyle(.borderless)
                        .help(t("settings.close"))
                        .keyboardShortcut(.cancelAction)
                }
                section(t("appearance")) {
                    Picker(t("appearance"), selection: $settings.themeMode) {
                        Label(t("themeLight"), systemImage: "sun.max").tag("light")
                        Label(t("themeAuto"), systemImage: "display").tag("system")
                        Label(t("themeDark"), systemImage: "moon").tag("dark")
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                }
                section(t("language")) {
                    Picker(t("language"), selection: $settings.language) {
                        Text(t("languageSystem")).tag("")
                        Divider()
                        ForEach(I18n.languages, id: \.code) { Text($0.name).tag($0.code) }
                    }
                    .labelsHidden()
                }
                VStack(alignment: .leading, spacing: 14) {
                    toggle($settings.preserveOrientation, "preserveOrientation")
                    toggle($settings.preserveColorProfile, "preserveColorProfile")
                    toggle($settings.preserveResolution, "preserveResolution")
                    toggle($settings.saveAsCopy, "saveAsCopy")
                    toggle($settings.preserveTimestamps, "preserveTimestamps")
                    toggle($settings.removeXattrs, "removeXattrs")
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
            .padding(Layout.gutter)
        }
        .frame(minWidth: 280)
    }

    private func section<C: View>(_ title: String, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.caption.weight(.semibold)).tone(.secondary)
            content()
        }
    }

    private func toggle(_ value: Binding<Bool>, _ key: String) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(t("settings.\(key).label"))
                Text(t("settings.\(key).description")).font(.caption).tone(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Toggle(t("settings.\(key).label"), isOn: value)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}
