import AppKit
import Combine

enum FileStatus { case pending, reading, processing, complete, noMetadata, error }
enum Outcome { case alreadyClean, unchanged, cleaned, refused, failed }

/// One file in the list (ExifCleaner's FileEntry).
@MainActor
final class FileEntry: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    let name: String
    let ext: String
    let size: Int64
    @Published var status = FileStatus.pending
    @Published var before = Metadata()
    @Published var after = Metadata()
    @Published var outcome: Outcome?
    @Published var removed = 0
    @Published var output: URL?
    @Published var outputSize: Int64?
    @Published var error: String?
    @Published var failureSummary: String?
    /// Shown under the name when the file was cleaned with a reservation (a PDF ExifTool cleaned
    /// but Exif couldn't write again from scratch).
    @Published var note: String?

    init(url: URL) {
        self.url = url
        name = url.lastPathComponent
        ext = url.pathExtension.uppercased()
        size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) } ?? 0
    }

    var isDone: Bool { status == .complete || status == .noMetadata || status == .error }
    var isExpandable: Bool { isDone }
    var wroteCopy: Bool { status == .complete && output != nil && output != url }
}

/// A dropped folder: its supported files, shown under one collapsible row.
@MainActor
final class FolderGroup: ObservableObject, Identifiable {
    let id = UUID()
    let url: URL
    @Published var files: [FileEntry] = []
    @Published var expanded = true
    @Published var scanning = true
    @Published var found = 0
    init(url: URL) { self.url = url }
    var name: String { url.lastPathComponent }
}

enum ListItem: Identifiable {
    case file(FileEntry)
    case folder(FolderGroup)
    var id: UUID { switch self { case .file(let f): f.id; case .folder(let g): g.id } }
}

/// The list and the processing queue. Files are cleaned by a few ExifTool processes at once
/// (ExifCleaner 3.4's "multi-core speed boost"), each kept open between files.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var items: [ListItem] = []
    @Published private(set) var elapsed = 0
    @Published var toast: String?
    @Published var dragActive = false

    private var queue: [FileEntry] = []
    private var running = 0
    private var startedAt: Date?
    private var timer: Timer?
    private let pool = ToolPool()

    var allFiles: [FileEntry] {
        items.flatMap { item -> [FileEntry] in
            switch item { case .file(let f): [f]; case .folder(let g): g.files }
        }
    }

    var hasFiles: Bool { !items.isEmpty }
    var totalCount: Int { allFiles.count }
    var cleanedCount: Int { allFiles.filter { $0.outcome == .cleaned }.count }
    var tagsRemoved: Int { allFiles.reduce(0) { $0 + $1.removed } }
    var isProcessing: Bool { running > 0 || !queue.isEmpty }

    /// Starts one ExifTool right after launch so the first file doesn't wait for Perl.
    func warmUp() { pool.warmUp() }
    func shutdown() { pool.shutdown() }

    func clear() {
        guard !isProcessing else { return }
        items.removeAll()
        elapsed = 0
        startedAt = nil
    }

    // MARK: Intake

    func add(_ urls: [URL]) {
        var files: [FileEntry] = []
        var skipped = 0
        for url in urls {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                let group = FolderGroup(url: url)
                items.append(.folder(group))
                scan(group)
            } else if FileTypes.isSupported(url) {
                let f = FileEntry(url: url)
                items.append(.file(f))
                files.append(f)
            } else {
                skipped += 1
            }
        }
        if skipped > 0 { show(t("intake.unsupportedSkipped", ["count": skipped])) }
        enqueue(files)
    }

    /// Folder recursion: every supported file inside, found on a background thread.
    private func scan(_ group: FolderGroup) {
        let root = group.url
        DispatchQueue.global(qos: .userInitiated).async {
            var found: [URL] = []
            let keys: [URLResourceKey] = [.isRegularFileKey]
            if let e = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles, .skipsPackageDescendants]) {
                for case let u as URL in e where FileTypes.isSupported(u) {
                    if (try? u.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true { found.append(u) }
                }
            }
            found.sort { $0.path.localizedStandardCompare($1.path) == .orderedAscending }
            DispatchQueue.main.async {
                let files = found.map { FileEntry(url: $0) }
                group.files = files
                group.found = files.count
                group.scanning = false
                if files.isEmpty, let i = self.items.firstIndex(where: { $0.id == group.id }) {
                    self.items.remove(at: i)
                    self.show(t("folder.supportedFiles", ["count": 0]))
                }
                self.objectWillChange.send()
                self.enqueue(files)
            }
        }
    }

    func show(_ message: String) {
        toast = message
        let m = message
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { if self.toast == m { self.toast = nil } }
    }

    // MARK: Processing

    private func enqueue(_ files: [FileEntry]) {
        guard !files.isEmpty else { return }
        if timer == nil {
            // A new batch keeps counting from where the last one stopped, until Clear.
            startedAt = Date().addingTimeInterval(-Double(elapsed))
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
                MainActor.assumeIsolated { self.tick() }
            }
        }
        queue += files
        pump()
    }

    private func tick() {
        if let s = startedAt { elapsed = Int(Date().timeIntervalSince(s)) }
        updateBadge()
    }

    private func updateBadge() {
        let left = queue.count + running
        NSApp.dockTile.badgeLabel = left > 0 ? "\(left)" : nil
    }

    private func pump() {
        let settings = AppSettings.shared
        while !queue.isEmpty, running < pool.size {
            let f = queue.removeFirst()
            running += 1
            f.status = .reading
            let job = Job(url: f.url, options: settings.options, copy: settings.saveAsCopy, removeXattrs: settings.removeXattrs)
            pool.run(job) { [weak self] step in
                DispatchQueue.main.async { MainActor.assumeIsolated { self?.apply(step, to: f) } }
            }
        }
        updateBadge()
        if queue.isEmpty && running == 0 {
            timer?.invalidate(); timer = nil
            if let s = startedAt { elapsed = Int(Date().timeIntervalSince(s)) }
            startedAt = nil
            NSApp.dockTile.badgeLabel = nil
            if !NSApp.isActive { NSApp.requestUserAttention(.informationalRequest) }
        }
    }

    private func apply(_ step: Job.Step, to f: FileEntry) {
        switch step {
        case .processing:
            f.status = .processing
        case .done(let r):
            f.before = r.before
            f.after = r.after
            f.output = r.output
            f.outputSize = r.outputSize
            f.error = r.error
            f.failureSummary = r.failureSummary
            f.note = r.note
            f.outcome = r.outcome
            f.removed = r.removed
            switch r.outcome {
            case .alreadyClean: f.status = .noMetadata
            case .refused, .failed: f.status = .error
            default: f.status = .complete
            }
            running -= 1
            objectWillChange.send()
            pump()
        }
    }
}

/// What one file goes through, on a pool thread (use_process_files.ts + exif_handlers.ts):
/// read, refuse RAF, clean (in place or to "_cleaned"), read again, clear the xattrs.
struct Job: Sendable {
    let url: URL
    let options: CleanArgs.Options
    let copy: Bool
    let removeXattrs: Bool

    struct Result: Sendable {
        var before = Metadata()
        var after = Metadata()
        var output: URL?
        var outputSize: Int64?
        var outcome = Outcome.failed
        var removed = 0
        var error: String?
        var failureSummary: String?
        var note: String?
    }
    enum Step: Sendable { case processing, done(Result) }

    func run(_ tool: ExifTool, reserve: (URL) -> URL, report: (Step) -> Void) {
        var r = Result()
        let path = url.path
        guard let read = tool.run(CleanArgs.read + [path]) else {
            r.error = "ExifTool could not be started"; report(.done(r)); return
        }
        r.before = Metadata.parse(read.stdout)
        if let e = r.before.error {
            r.outcome = .failed; r.error = e; report(.done(r)); return
        }
        if r.before.count == 0 && !removeXattrs {
            r.outcome = .alreadyClean; r.after = r.before; r.output = url
            report(.done(r)); return
        }
        if FileTypes.ext(url) == ".raf" {
            r.outcome = .refused; r.failureSummary = t("outcome.refusedRaf"); r.error = r.failureSummary
            report(.done(r)); return
        }
        report(.processing)
        let destination = copy ? reserve(url) : url
        var outPath = destination
        if r.before.count > 0 {
            let w = tool.run(CleanArgs.sanitize(source: path, destination: copy ? destination.path : nil, s: options))
            let err = w?.stderr.split(separator: "\n").first(where: { $0.hasPrefix("Error") }).map(String.init)
            // "copied": saving as a copy with nothing ExifTool could change; the copy is still made.
            let updated = ["1 image files updated", "1 image files created", "1 image files copied"].contains { w?.stdout.contains($0) == true }
            if w == nil || err != nil || !updated {
                if copy { try? FileManager.default.removeItem(at: destination) }
                // Nothing to change is not a failure: the file stays as it was.
                if let w, w.stdout.contains("1 image files unchanged") {
                    outPath = url
                } else {
                    r.outcome = .failed
                    r.failureSummary = t("writeFailedSummary")
                    r.error = err ?? w?.stderr.trimmingCharacters(in: .whitespacesAndNewlines) ?? "ExifTool stopped"
                    report(.done(r)); return
                }
            }
            // PDFs: written again from scratch, so ExifTool's appended update can't be undone. Also
            // when ExifTool found nothing to change: the file may hold an earlier ExifTool update.
            if FileTypes.ext(url) == ".pdf" {
                var target: URL? = outPath
                if outPath != destination {
                    // Unchanged, saving as a copy: the copy is the original's bytes, then rewritten.
                    target = (try? FileManager.default.copyItem(at: url, to: destination)).map { destination }
                }
                if let target {
                    do {
                        if try PDFRewrite.run(target, keepDate: options.preserveTimestamps) == .textChanged {
                            r.note = t("pdf.textChanged")
                        }
                        outPath = target
                    } catch {
                        if target != outPath { try? FileManager.default.removeItem(at: target) }
                        r.note = t(error as? PDFRewrite.Failure == .signed ? "pdf.signed" : "pdf.rewriteFailed")
                    }
                } else {
                    r.note = t("pdf.rewriteFailed")
                }
            }
        } else if copy {
            // Only the attributes to clear: the copy is the original's bytes.
            do { try FileManager.default.copyItem(at: url, to: destination) } catch {
                r.outcome = .failed; r.failureSummary = t("writeFailedSummary"); r.error = error.localizedDescription
                report(.done(r)); return
            }
        }
        var failed = false
        if removeXattrs, !Xattr.removeAll(outPath.path) {
            failed = true; r.outcome = .failed; r.failureSummary = t("xattrFailedSummary"); r.error = t("xattrFailedSummary")
        }
        r.output = outPath
        r.outputSize = (try? outPath.resourceValues(forKeys: [.fileSizeKey]).fileSize).map { Int64($0 ?? 0) }
        if let a = tool.run(CleanArgs.read + [outPath.path]) {
            r.after = Metadata.parse(a.stdout)
            // A PDF written by PDFKit gets a standard sRGB colour space, which ExifTool lists as an
            // ICC profile: colour data, not the file's metadata, so it isn't counted.
            if FileTypes.ext(url) == ".pdf", r.before.icc.isEmpty {
                let icc = r.after.icc
                r.after.fields.removeAll { icc.contains($0.key) }
                r.after.icc = []
            }
        }
        let afterKeys = Set(r.after.fields.map(\.key))
        r.removed = r.before.fields.filter { !afterKeys.contains($0.key) }.count
        if !failed {
            // Only the attributes were cleared on a file with no metadata: "unchanged".
            r.outcome = r.before.count == 0 ? .unchanged : (r.removed == 0 ? .unchanged : .cleaned)
        }
        report(.done(r))
    }
}

enum Xattr {
    /// Removes every extended attribute (quarantine, where-from, Finder tags…).
    static func removeAll(_ path: String) -> Bool {
        let size = listxattr(path, nil, 0, XATTR_NOFOLLOW)
        if size <= 0 { return size == 0 }
        var buf = [CChar](repeating: 0, count: size)
        guard listxattr(path, &buf, size, XATTR_NOFOLLOW) == size else { return false }
        var ok = true
        var start = 0
        for i in 0..<size where buf[i] == 0 {
            let name = buf[start..<i].withUnsafeBufferPointer { String(decoding: UnsafeRawBufferPointer($0), as: UTF8.self) }
            // com.apple.provenance is kept by macOS itself and can't be removed: not the user's data.
            if name != "com.apple.provenance", removexattr(path, name, XATTR_NOFOLLOW) != 0 { ok = false }
            start = i + 1
        }
        return ok
    }
}

/// A few ExifTool processes, each on its own thread.
final class ToolPool: @unchecked Sendable {
    let size = max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2))
    private var tools: [ExifTool] = []
    private var free: [Int] = []
    private let lock = NSLock()
    private var reserved = Set<String>()
    private let queues: [DispatchQueue]

    init() {
        tools = (0..<size).map { _ in ExifTool() }
        free = Array(0..<size)
        queues = (0..<size).map { DispatchQueue(label: "exif.tool.\($0)", qos: .userInitiated) }
    }

    func warmUp() { queues[0].async { [tools] in tools[0].start() } }

    func shutdown() { for (i, q) in queues.enumerated() { q.sync { tools[i].stop() } } }

    func run(_ job: Job, report: @escaping @Sendable (Job.Step) -> Void) {
        lock.lock()
        let i = free.isEmpty ? 0 : free.removeFirst()
        lock.unlock()
        let tool = tools[i]
        queues[i].async { [self] in
            job.run(tool, reserve: reserve, report: report)
            lock.lock(); free.append(i); lock.unlock()
        }
    }

    /// A "_cleaned" name no other file in flight has taken.
    private func reserve(_ url: URL) -> URL {
        lock.lock(); defer { lock.unlock() }
        var u = FileTypes.cleanedPath(for: url)
        var n = 2
        while reserved.contains(u.path) {
            let base = url.deletingPathExtension().lastPathComponent
            let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
            u = url.deletingLastPathComponent().appendingPathComponent("\(base)_cleaned_\(n)\(ext)")
            if !FileManager.default.fileExists(atPath: u.path) && !reserved.contains(u.path) { break }
            n += 1
        }
        reserved.insert(u.path)
        return u
    }
}
