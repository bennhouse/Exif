import AppKit
import SwiftUI

struct ExifApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("Exif", id: "main") {
            ContentView()
                // No scroll bars anywhere: with "Always show" they took space and lists changed width.
                .scrollIndicators(.never)
        }
        .defaultSize(width: 900, height: 580)
        .windowToolbarStyle(.unified(showsTitle: true))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("Open…") { Intake.chooseFiles() }.keyboardShortcut("o")
                Button("Open Folder…") { Intake.chooseFolder() }.keyboardShortcut("o", modifiers: [.command, .shift])
            }
            CommandGroup(replacing: .help) {
                Link("ExifCleaner Website", destination: URL(string: "https://exifcleaner.com")!)
                Link("Source Code", destination: URL(string: "https://github.com/bennhouse/Exif")!)
            }
        }

        // Exif › Settings… (⌘,): a window of its own, as in the other apps of the suite.
        Settings {
            SettingsView()
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        LaunchTrace.mark("didFinishLaunching")
        MainActor.assumeIsolated {
            Snapshots.startIfRequested()
            // ExifTool (Perl) is started once the window is up, so launching never waits for it.
            DispatchQueue.main.async { AppModel.shared.warmUp() }
            if let p = ProcessInfo.processInfo.environment["EXIF_OPEN"] {
                AppModel.shared.add(p.split(separator: ":").map { URL(fileURLWithPath: String($0)) })
            }
        }
    }

    /// Files dropped on the Dock icon or opened with "Open With › Exif".
    func application(_ application: NSApplication, open urls: [URL]) {
        MainActor.assumeIsolated { AppModel.shared.add(urls) }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.shutdown() }
    }
}

LaunchTrace.mark("main")
if CommandLine.arguments.count > 1, CommandLine.arguments[1] == "--clean" {
    MainActor.assumeIsolated { CLI.clean(Array(CommandLine.arguments.dropFirst(2))) }
} else {
    ExifApp.main()
}

/// Command-line test mode, no window: `Exif --clean FILE...` cleans with the saved settings and
/// prints, for each file, the counts before and after and the outcome, then the total time.
@MainActor
enum CLI {
    static func clean(_ paths: [String]) {
        _ = NSApplication.shared
        let t0 = Date()
        let model = AppModel.shared
        model.add(paths.map { URL(fileURLWithPath: $0) })
        Timer.scheduledTimer(withTimeInterval: 0.02, repeats: true) { timer in
            MainActor.assumeIsolated {
                let files = model.allFiles
                guard !files.isEmpty, files.allSatisfy(\.isDone), !model.isProcessing else { return }
                timer.invalidate()
                for f in files {
                    print("\(f.name)\t\(f.before.count) → \(f.after.count)\t\(f.outcome.map { "\($0)" } ?? "-")\t\(f.output?.lastPathComponent ?? "")\t\(f.error ?? "")\t\(f.note ?? "")")
                }
                print(String(format: "%d files in %.2f s", files.count, Date().timeIntervalSince(t0)))
                model.shutdown()
                exit(0)
            }
        }
        RunLoop.main.run()
    }
}
