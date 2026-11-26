import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// ExifCleaner's window: the drop zone (empty state, then the file table) and the status bar with
/// the summary and Clear. Settings are in their own window (⌘,).
struct ContentView: View {
    @ObservedObject var model = AppModel.shared
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                if model.hasFiles { FileTable(model: model) } else { EmptyState(model: model) }
                if model.dragActive {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(Color.accentColor, style: StrokeStyle(lineWidth: 2, dash: [7, 5]))
                        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.accentColor.opacity(0.06)))
                        .padding(10)
                        .allowsHitTesting(false)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .onDrop(of: [.fileURL], isTargeted: $model.dragActive) { providers in
                Intake.load(providers) { model.add($0) }
                return true
            }
            Divider()
            StatusBar(model: model)
        }
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                Text(toast)
                    .font(.callout)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(.regularMaterial, in: Capsule())
                    .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
                    .padding(.bottom, Layout.footerHeight + 12)
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .task {
            // Development aid: EXIF_SNAPSHOT_SETTINGS=1 opens the settings window 1.5 s after launch.
            guard ProcessInfo.processInfo.environment["EXIF_SNAPSHOT_SETTINGS"] != nil else { return }
            try? await Task.sleep(for: .milliseconds(1500))
            openSettings()
        }
        .frame(minWidth: 560, minHeight: 360)
        .navigationTitle("Exif")
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                Button { Intake.chooseFiles() } label: { Image(systemName: "plus").toolbarIcon() }
                    .help(t("intake.chooseFiles"))
                Button { Intake.chooseFolder() } label: { Image(systemName: "folder.badge.plus").toolbarIcon() }
                    .help(t("intake.chooseFolder"))
            }
        }
        .onAppear { LaunchTrace.mark("window content appeared"); DispatchQueue.main.async { LaunchTrace.mark("first frame done") } }
    }
}

@MainActor
enum Intake {
    static func chooseFiles() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = false
        p.allowedContentTypes = FileTypes.supported.compactMap { UTType(filenameExtension: String($0.dropFirst())) }
        guard p.runModal() == .OK else { return }
        AppModel.shared.add(p.urls)
    }

    static func chooseFolder() {
        let p = NSOpenPanel()
        p.allowsMultipleSelection = true
        p.canChooseDirectories = true
        p.canChooseFiles = false
        guard p.runModal() == .OK else { return }
        AppModel.shared.add(p.urls)
    }

    static func load(_ providers: [NSItemProvider], _ done: @escaping @MainActor ([URL]) -> Void) {
        let group = DispatchGroup()
        let lock = NSLock()
        var urls: [(Int, URL)] = []
        for (i, p) in providers.enumerated() {
            group.enter()
            _ = p.loadObject(ofClass: URL.self) { url, _ in
                if let url { lock.lock(); urls.append((i, url)); lock.unlock() }
                group.leave()
            }
        }
        group.notify(queue: .main) {
            let sorted = urls.sorted { $0.0 < $1.0 }.map(\.1)
            MainActor.assumeIsolated { done(sorted) }
        }
    }
}

// MARK: Empty state

struct EmptyState: View {
    @ObservedObject var model: AppModel
    @ObservedObject var settings = AppSettings.shared

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable().frame(width: 96, height: 96)
                .opacity(model.dragActive ? 1 : 0.92)
            Text(t("empty.title")).font(.title2.weight(.semibold)).tone(.primary)
            Text(model.dragActive ? t("empty.dropActive") : t("empty.subtitle"))
                .multilineTextAlignment(.center).tone(.secondary)
            HStack(spacing: 10) {
                Button(t("intake.chooseFiles")) { Intake.chooseFiles() }
                    .buttonStyle(.borderedProminent).keyboardShortcut("o")
                Button(t("intake.chooseFolder")) { Intake.chooseFolder() }
                    .buttonStyle(.bordered)
            }
            .controlSize(.large)
            .padding(.top, 4)
            Text(settings.saveAsCopy ? t("intake.outputCopy") : t("intake.outputOverwrite"))
                .font(.caption).tone(.secondary)
        }
        .padding(Layout.gutter * 2)
        .frame(maxWidth: 460)
    }
}

// MARK: Table

enum Col {
    static let status: CGFloat = 26
    static let type: CGFloat = 70
    static let size: CGFloat = 112
    static let before: CGFloat = 64
    static let after: CGFloat = 92
}

struct FileTable: View {
    @ObservedObject var model: AppModel
    @State private var expanded: Set<UUID> = []

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0, pinnedViews: [.sectionHeaders]) {
                Section {
                    ForEach(model.items) { item in
                        switch item {
                        case .file(let f):
                            FileRowView(file: f, expanded: binding(f.id), indent: 0)
                        case .folder(let g):
                            FolderRowView(group: g, expanded: $expanded)
                        }
                    }
                } header: {
                    header
                }
            }
        }
        .task {
            // Development aid: EXIF_SNAPSHOT_EXPAND=<n> opens the n-th file's details once it is done.
            guard let v = ProcessInfo.processInfo.environment["EXIF_SNAPSHOT_EXPAND"], let n = Int(v) else { return }
            while !Task.isCancelled {
                let files = model.allFiles
                if n < files.count, files[n].isDone { expanded.insert(files[n].id); return }
                try? await Task.sleep(for: .milliseconds(100))
            }
        }
    }

    private func binding(_ id: UUID) -> Binding<Bool> {
        Binding(get: { expanded.contains(id) }, set: { if $0 { expanded.insert(id) } else { expanded.remove(id) } })
    }

    private var header: some View {
        HStack(spacing: 8) {
            Color.clear.frame(width: Col.status)
            h(t("table.header.name")).frame(maxWidth: .infinity, alignment: .leading)
            h(t("table.header.type")).frame(width: Col.type)
            h(t("table.header.size")).frame(width: Col.size)
            h(t("table.header.before")).frame(width: Col.before)
            h(t("table.header.after")).frame(width: Col.after)
        }
        .padding(.horizontal, 14)
        .frame(height: 30)
        .background(.bar)
        .overlay(alignment: .bottom) { Divider() }
    }

    private func h(_ s: String) -> some View {
        Text(s.uppercased()).font(.system(size: 10.5, weight: .semibold)).kerning(0.6).tone(.secondary)
    }
}

struct FolderRowView: View {
    @ObservedObject var group: FolderGroup
    // Redrawn when any file finishes, for the progress indicator.
    @ObservedObject private var model = AppModel.shared
    @Binding var expanded: Set<UUID>

    var body: some View {
        VStack(spacing: 0) {
            Button { withAnimation(.easeOut(duration: 0.15)) { group.expanded.toggle() } } label: {
                HStack(spacing: 8) {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .rotationEffect(.degrees(group.expanded ? 90 : 0))
                        .frame(width: Col.status)
                        .tone(.secondary)
                    Image(systemName: "folder.fill").foregroundStyle(Color.accentColor.opacity(0.85))
                    Text(group.name).fontWeight(.medium).lineLimit(1).truncationMode(.middle).tone(.primary)
                    Text(group.scanning ? t("folder.scanning") : t("folder.supportedFiles", ["count": group.files.count]))
                        .font(.callout).tone(.secondary)
                    Spacer()
                    if !group.scanning, group.files.contains(where: { !$0.isDone }) { ProgressView().controlSize(.small) }
                }
                .padding(.horizontal, 14)
                .frame(height: 38)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(group.expanded ? t("folder.collapse", ["folder": group.name]) : t("folder.expand", ["folder": group.name]))
            Divider().padding(.leading, 14)
            if group.expanded {
                ForEach(group.files) { f in
                    FileRowView(file: f, expanded: Binding(get: { expanded.contains(f.id) },
                                                           set: { if $0 { expanded.insert(f.id) } else { expanded.remove(f.id) } }),
                                indent: 22)
                }
            }
        }
    }
}

struct FileRowView: View {
    @ObservedObject var file: FileEntry
    @Binding var expanded: Bool
    let indent: CGFloat
    @State private var hover = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                statusCell.frame(width: Col.status)
                nameCell.frame(maxWidth: .infinity, alignment: .leading)
                // Type, size, before and after: fixed widths on the right, centred; the name takes the rest.
                TypePill(ext: file.ext).frame(width: Col.type)
                sizeCell.frame(width: Col.size)
                Text(file.status == .pending || file.status == .reading ? "–" : "\(file.before.count)")
                    .monospacedDigit().tone(.primary)
                    .frame(width: Col.before)
                afterCell.frame(width: Col.after)
            }
            .padding(.leading, 14 + indent).padding(.trailing, 14)
            .frame(minHeight: 40)
            .background(hover && file.isExpandable ? Color.primary.opacity(0.04) : .clear)
            .contentShape(Rectangle())
            .onHover { hover = $0 }
            .onTapGesture { if file.isExpandable { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } } }
            .help(file.status == .error ? (file.error ?? "") : "")
            if expanded && file.isExpandable {
                MetadataExpansion(file: file)
                    .padding(.leading, 14 + indent + Col.status + 8).padding(.trailing, 14).padding(.bottom, 12)
            }
            Divider().padding(.leading, 14 + indent)
        }
    }

    @ViewBuilder private var statusCell: some View {
        if file.status == .error {
            Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.red)
        } else if file.isExpandable {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .semibold))
                .rotationEffect(.degrees(expanded ? 90 : 0))
                .tone(.secondary)
        } else {
            ProgressView().controlSize(.mini)
        }
    }

    private var nameCell: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(file.name).lineLimit(1).truncationMode(.middle).tone(.primary)
            if file.wroteCopy {
                Text(t("writtenToCopy")).font(.caption).tone(.secondary).lineLimit(1)
            }
            if let n = file.note { Text(n).font(.caption).foregroundStyle(.orange).lineLimit(2) }
            if let s = summary { Text(s).font(.caption).foregroundStyle(file.status == .error ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary)).lineLimit(2) }
        }
        .padding(.vertical, 6)
    }

    private var summary: String? {
        switch file.outcome {
        case .alreadyClean: return t("outcome.alreadyClean")
        case .unchanged: return t("outcome.unchanged")
        case .refused, .failed: return file.failureSummary ?? file.error
        default: return nil
        }
    }

    private var sizeCell: some View {
        let a = ByteCountFormatter.string(fromByteCount: file.size, countStyle: .file)
        var s = a
        if let o = file.outputSize, o != file.size { s += " → " + ByteCountFormatter.string(fromByteCount: o, countStyle: .file) }
        return Text(s).monospacedDigit().lineLimit(1).minimumScaleFactor(0.8).tone(.primary)
    }

    /// The count and ✓ centred in the column; the reveal arrow at its right edge on hover.
    private var afterCell: some View {
        HStack(spacing: 5) {
            switch file.status {
            case .pending, .reading, .processing:
                Text("–").tone(.secondary)
            case .error:
                Text(t("status.error")).foregroundStyle(.red)
            case .complete, .noMetadata:
                Text("\(file.after.count)").monospacedDigit().tone(.primary)
                Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    .foregroundStyle(file.outcome == .cleaned ? Color.green : Color.secondary)
                    .transition(.scale.combined(with: .opacity))
            }
        }
        .frame(maxWidth: .infinity)
        .overlay(alignment: .trailing) {
            if file.isDone, file.status != .error, hover {
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([file.output ?? file.url])
                } label: { Image(systemName: "arrow.up.forward.square") }
                    .buttonStyle(.borderless)
                    .help(file.wroteCopy ? t("reveal.cleanedCopy") : t("reveal.original"))
            }
        }
    }
}

struct TypePill: View {
    let ext: String
    var body: some View {
        Text(ext.isEmpty ? "?" : ext)
            .font(.system(size: 11, weight: .semibold, design: .rounded))
            .foregroundStyle(color)
            .padding(.horizontal, 7).padding(.vertical, 2.5)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(color.opacity(0.13)))
            .lineLimit(1)
    }
    private var color: Color {
        switch ext.lowercased() {
        case "jpg", "jpeg": .blue
        case "png": .green
        case "pdf": .red
        case "heic", "heif", "avif": .orange
        case "mp4", "mov", "m4v", "avi", "3gp", "wmv", "m4a", "wav": .purple
        case "gif", "webp", "svg", "bmp": .teal
        case "tif", "tiff": .indigo
        default: .gray
        }
    }
}

// MARK: Metadata diff (MetadataExpansion)

struct MetadataExpansion: View {
    @ObservedObject var file: FileEntry
    @ObservedObject private var model = AppModel.shared

    struct Field { let name: String; let value: String; let removed: Bool }
    struct Group { let raw: String; let fields: [Field]; var removed: Int { fields.filter(\.removed).count } }

    private static let friendly: [String: String] = [
        "Camera": "metaGroupCamera", "GPS": "metaGroupLocation", "Location": "metaGroupLocation", "Time": "metaGroupTime",
        "Author": "metaGroupAuthor", "Image": "metaGroupImage", "Video": "metaGroupVideo", "XMP": "metaGroupDocument",
        "Document": "metaGroupDocument", "IPTC": "metaGroupPublishing", "ICC_Profile": "metaGroupColorProfile",
        "MakerNotes": "metaGroupCameraInternals",
    ]

    private var groups: [Group] {
        let afterKeys = Set(file.after.fields.map(\.key))
        let beforeKeys = Set(file.before.fields.map(\.key))
        var order: [String] = []
        var map: [String: [Field]] = [:]
        func add(_ key: String, _ value: String, _ removed: Bool) {
            let (g, f): (String, String) = key.firstIndex(of: ":").map { (String(key[..<$0]), String(key[key.index(after: $0)...])) } ?? ("Other", key)
            if map[g] == nil { order.append(g); map[g] = [] }
            map[g]!.append(Field(name: f, value: value, removed: removed))
        }
        for (k, v) in file.before.fields { add(k, v, !afterKeys.contains(k)) }
        for (k, v) in file.after.fields where !beforeKeys.contains(k) { add(k, v, false) }
        return order.map { Group(raw: $0, fields: map[$0]!) }
    }

    var body: some View {
        let gs = groups
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                if gs.isEmpty {
                    Text(t("noMetadataFound")).font(.callout).tone(.secondary)
                } else {
                    let present = file.before.count - file.removed
                    Text(t("metadata.summary", ["removed": file.removed, "present": present])).font(.callout).tone(.secondary)
                }
                Spacer()
                if !gs.isEmpty {
                    Button(t("copyAll")) { copy(gs) }.buttonStyle(.link).font(.callout)
                }
            }
            ForEach(gs, id: \.raw) { g in
                VStack(alignment: .leading, spacing: 6) {
                    Text(t("metadataGroupHeader", ["groupName": t(Self.friendly[g.raw] ?? "metaGroupOther") + (Self.friendly[g.raw] == nil && g.raw != "Other" ? " · \(g.raw)" : ""),
                                                   "removed": g.removed, "total": g.fields.count]))
                        .font(.caption.weight(.semibold)).tone(.secondary)
                    Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 3) {
                        ForEach(Array(g.fields.enumerated()), id: \.offset) { _, f in
                            GridRow {
                                Text(f.name).font(.system(size: 11.5, design: .monospaced))
                                    .foregroundStyle(f.removed ? .secondary : .primary)
                                    .lineLimit(1)
                                Text(f.value).font(.system(size: 11.5))
                                    .strikethrough(f.removed, color: .secondary)
                                    .foregroundStyle(f.removed ? .secondary : .primary)
                                    .lineLimit(2).truncationMode(.middle)
                                    .textSelection(.enabled)
                                Text(f.removed ? t("metadata.field.removed") : t("metadata.field.preserved"))
                                    .font(.caption2.weight(.medium))
                                    .foregroundStyle(f.removed ? Color.green : Color.orange)
                            }
                        }
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(.quaternary.opacity(0.5)))
            }
        }
    }

    private func copy(_ gs: [Group]) {
        let text = gs.map { g in
            g.raw + "\n" + g.fields.map { "  \($0.name): \($0.value)\($0.removed ? " (\(t("metadata.field.removed")))" : "")" }.joined(separator: "\n")
        }.joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        model.show(t("toast.copied"))
    }
}

// MARK: Status bar

struct StatusBar: View {
    @ObservedObject var model: AppModel

    var body: some View {
        HStack(spacing: 12) {
            Spacer()
            if model.hasFiles {
                Text([t("statusBar.xOfYCleaned", ["completed": model.cleanedCount, "total": model.totalCount]),
                      t("statusBar.tagsRemoved", ["count": model.tagsRemoved]),
                      t("statusBar.elapsed", ["seconds": model.elapsed])].joined(separator: " — "))
                    .font(.callout).monospacedDigit().tone(.secondary)
                Button(t("statusBar.clear")) { model.clear() }
                    .buttonStyle(.link)
                    .disabled(model.isProcessing)
                    .keyboardShortcut(.delete, modifiers: .command)
            }
        }
        .padding(.horizontal, 14)
        .frame(height: Layout.footerHeight)
    }
}
