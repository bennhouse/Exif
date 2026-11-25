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

    private init() {
        let d = UserDefaults.standard
        func b(_ k: String, _ def: Bool) -> Bool { d.object(forKey: k) as? Bool ?? def }
        preserveOrientation = b("preserveOrientation", true)
        preserveColorProfile = b("preserveColorProfile", true)
        preserveResolution = b("preserveResolution", true)
        saveAsCopy = b("saveAsCopy", true)
        preserveTimestamps = b("preserveTimestamps", false)
        removeXattrs = b("removeXattrs", false)
    }

    private func save(_ key: String, _ value: Any) { UserDefaults.standard.set(value, forKey: key) }

    var options: CleanArgs.Options {
        CleanArgs.Options(preserveOrientation: preserveOrientation, preserveColorProfile: preserveColorProfile,
                          preserveResolution: preserveResolution, preserveTimestamps: preserveTimestamps)
    }
}

/// ExifCleaner's texts (its strings.json, English only), looked up by key with {param} filled in.
final class Strings: Sendable {
    static let shared = Strings()
    private let table: [String: String]

    private init() {
        let url = Bundle.main.url(forResource: "strings", withExtension: "json") ?? Self.devStrings
        table = url.flatMap { try? Data(contentsOf: $0) }
            .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
    }

    private static var devStrings: URL? {
        ProcessInfo.processInfo.environment["EXIF_TOOLS"].map { URL(fileURLWithPath: $0).deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Resources/strings.json") }
    }

    func t(_ key: String, _ params: [String: Any] = [:]) -> String {
        var s = table[key] ?? key
        for (k, v) in params { s = s.replacingOccurrences(of: "{\(k)}", with: "\(v)") }
        return s
    }
}

func t(_ key: String, _ params: [String: Any] = [:]) -> String { Strings.shared.t(key, params) }

/// The settings window (Exif › Settings…, ⌘,): ExifCleaner's cleaning options, each saved at once.
/// The appearance follows the system.
struct SettingsView: View {
    @ObservedObject private var settings = AppSettings.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            toggle($settings.preserveOrientation, "preserveOrientation")
            toggle($settings.preserveColorProfile, "preserveColorProfile")
            toggle($settings.preserveResolution, "preserveResolution")
            toggle($settings.saveAsCopy, "saveAsCopy")
            toggle($settings.preserveTimestamps, "preserveTimestamps")
            toggle($settings.removeXattrs, "removeXattrs")
        }
        .padding(Layout.gutter)
        .frame(width: 440)
        .fixedSize(horizontal: false, vertical: true)
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
