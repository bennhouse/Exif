import Foundation

/// One ExifTool process kept open (-stay_open), as ExifCleaner's ExiftoolProcess: commands go
/// in on stdin, each ends with -execute<N>, and the answer is read up to {ready<N>}. Starting
/// Perl and loading ExifTool takes about 0.1–0.2 s, so it happens once, not per file.
final class ExifTool: @unchecked Sendable {
    struct Output { var stdout: String; var stderr: String }

    static var script: URL {
        if let dir = ProcessInfo.processInfo.environment["EXIF_TOOLS"] {
            return URL(fileURLWithPath: dir).appendingPathComponent("exiftool")
        }
        return Bundle.main.resourceURL!.appendingPathComponent("exiftool/exiftool")
    }

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stderr: FileHandle?
    private var outBuffer = Data()
    private var errBuffer = Data()
    private var counter = 0

    /// Starts the process if needed. Returns false when Perl or the script can't be run.
    @discardableResult
    func start() -> Bool {
        if let p = process, p.isRunning { return true }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/perl")
        // -config "" (first argument): never load a ~/.ExifTool_config.
        p.arguments = [Self.script.path, "-config", "", "-stay_open", "True", "-@", "-"]
        var env = ProcessInfo.processInfo.environment
        env["LANG"] = "en_US.UTF-8"
        p.environment = env
        let i = Pipe(), o = Pipe(), e = Pipe()
        p.standardInput = i
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return false }
        process = p
        stdin = i.fileHandleForWriting
        stdout = o.fileHandleForReading
        stderr = e.fileHandleForReading
        outBuffer.removeAll(); errBuffer.removeAll()
        return true
    }

    func stop() {
        guard let p = process, p.isRunning else { return }
        try? stdin?.write(contentsOf: Data("-stay_open\nFalse\n".utf8))
        DispatchQueue.global().asyncAfter(deadline: .now() + 1) { if p.isRunning { p.terminate() } }
        process = nil
    }

    /// Runs one command and waits for its output. Not thread-safe: one caller at a time.
    func run(_ args: [String]) -> Output? {
        guard start(), let stdin, let stdout, let stderr else { return nil }
        counter += 1
        let marker = "{ready\(counter)}"
        // Arguments go one per line; a newline inside one would split it, so those are refused.
        guard !args.contains(where: { $0.contains("\n") }) else { return Output(stdout: "", stderr: "Error: unsupported file name") }
        // -echo4 writes the same marker on stderr once the command is done, so both streams can be read to it.
        let text = (args + ["-echo4", marker, "-execute\(counter)"]).joined(separator: "\n") + "\n"
        do { try stdin.write(contentsOf: Data(text.utf8)) } catch { process = nil; return nil }
        guard let out = read(stdout, &outBuffer, until: marker), let err = read(stderr, &errBuffer, until: marker) else {
            process?.terminate(); process = nil
            return nil
        }
        return Output(stdout: out, stderr: err)
    }

    private func read(_ handle: FileHandle, _ buffer: inout Data, until marker: String) -> String? {
        let m = Data(marker.utf8)
        while true {
            if let r = buffer.range(of: m) {
                let text = String(decoding: buffer[buffer.startIndex..<r.lowerBound], as: UTF8.self)
                var end = r.upperBound
                if end < buffer.endIndex, buffer[end] == UInt8(ascii: "\n") { end += 1 }
                buffer.removeSubrange(buffer.startIndex..<end)
                return text
            }
            let chunk = handle.availableData
            if chunk.isEmpty { return nil }   // process ended
            buffer.append(chunk)
        }
    }
}

/// Metadata as ExifTool lists it with -args -G1:2:4: ordered "Group1:Group2:Tag" → value.
struct Metadata {
    var fields: [(key: String, value: String)] = []
    var error: String?
    /// Keys read from an ICC profile (family-1 group ICC_Profile, ICC-header…).
    var icc: Set<String> = []

    var count: Int { fields.count }
    func has(_ key: String) -> Bool { fields.contains { $0.key == key } }

    /// Parses `-args` output and keeps what ExifCleaner counts (its cleanExifData): computed
    /// values and structural groups (System, JFIF, ExifTool, Composite, most of File) are
    /// left out, and keys lose their family-1 group ("IFD0:Camera:Make" → "Camera:Make").
    static func parse(_ text: String) -> Metadata {
        var m = Metadata()
        var index: [String: Int] = [:]
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard line.hasPrefix("-"), let eq = line.firstIndex(of: "=") else { continue }
            let rawKey = String(line[line.index(after: line.startIndex)..<eq])
            let value = String(line[line.index(after: eq)...])
            let parts = rawKey.split(separator: ":").map(String.init).filter { !isInstance($0) }
            guard let tag = parts.last else { continue }
            // ExifCleaner's display check: an Error, or a Warning that isn't "[minor]", makes the read fail.
            if parts.first == "ExifTool", tag == "Error" { m.error = value; continue }
            if parts.first == "ExifTool", tag == "Warning" {
                // Except an unreadable XMP packet (seen in encrypted PDFs made by TCPDF): `-all=`
                // drops it with the rest, so the file can still be cleaned.
                if m.error == nil, !value.lowercased().hasPrefix("[minor]"), !value.hasPrefix("XMP format error") { m.error = value }
                continue
            }
            if isComputed(parts) { continue }
            let key = parts.count >= 3 ? parts.dropFirst().joined(separator: ":") : parts.joined(separator: ":")
            if parts.first?.hasPrefix("ICC") == true { m.icc.insert(key) }
            if let i = index[key] { m.fields[i].value = value } else { index[key] = m.fields.count; m.fields.append((key, value)) }
        }
        return m
    }

    private static func isInstance(_ s: String) -> Bool {
        s.hasPrefix("Copy") && s.count > 4 && s.dropFirst(4).allSatisfy(\.isNumber)
    }

    private static let computed: Set<String> = ["SourceFile", "ImageSize", "Megapixels"]
    private static let structural: Set<String> = ["System", "JFIF", "ExifTool", "Composite"]
    // Writable File tags that are user content (ExifCleaner's FILE_GROUP_WRITABLE_TAGS minus the overrides).
    private static let removableFile: Set<String> = ["Comment"]

    private static func isComputed(_ parts: [String]) -> Bool {
        guard let g = parts.first, let tag = parts.last else { return true }
        if computed.contains(tag) { return true }
        if structural.contains(g) { return true }
        if g == "File" { return !removableFile.contains(tag) }
        return false
    }
}

/// The ExifTool arguments ExifCleaner uses (exiftool_adapter.ts / exif.ts).
enum CleanArgs {
    // -a: every duplicate too (shown with -G4 as "Copy1"…), as ExifCleaner's -json output has them.
    static let read = ["-a", "-args", "-G1:2:4", "-charset", "filename=utf8"]

    static let quickTimeDates = ["-QuickTime:CreateDate=", "-QuickTime:ModifyDate=", "-TrackCreateDate=",
                                 "-TrackModifyDate=", "-MediaCreateDate=", "-MediaModifyDate="]
    static let rawIdentifying = [
        "-IFD0:Artist=", "-IFD0:Software=", "-IFD0:ImageDescription=", "-IFD0:Copyright=", "-IFD0:XPComment=",
        "-IFD0:XPAuthor=", "-IFD0:XPTitle=", "-IFD0:XPSubject=", "-IFD0:XPKeywords=", "-ExifIFD:UserComment=",
        "-ExifIFD:SerialNumber=", "-ExifIFD:LensSerialNumber=", "-ExifIFD:OwnerName=", "-IFD0:CameraSerialNumber=",
        "-IFD0:OriginalRawFileName=", "-IFD0:RawDataUniqueID=", "-MakerNotes:OwnerName=",
        "-MakerNotes:InternalSerialNumber=", "-ExifIFD:DateTimeOriginal=", "-ExifIFD:CreateDate=", "-IFD0:ModifyDate=",
        "-ExifIFD:OffsetTime=", "-ExifIFD:OffsetTimeOriginal=", "-ExifIFD:OffsetTimeDigitized=", "-ExifIFD:SubSecTime=",
        "-ExifIFD:SubSecTimeOriginal=", "-ExifIFD:SubSecTimeDigitized=",
    ]
    static let resolution = [
        "-JFIF:XResolution>JFIF:XResolution", "-JFIF:YResolution>JFIF:YResolution", "-JFIF:ResolutionUnit>JFIF:ResolutionUnit",
        "-IFD0:XResolution>IFD0:XResolution", "-IFD0:YResolution>IFD0:YResolution", "-IFD0:ResolutionUnit>IFD0:ResolutionUnit",
        "-PNG:PixelsPerUnitX>PNG:PixelsPerUnitX", "-PNG:PixelsPerUnitY>PNG:PixelsPerUnitY", "-PNG:PixelUnits>PNG:PixelUnits",
    ]

    static func sanitize(source: String, destination: String?, s: Options) -> [String] {
        let ext = "." + (source as NSString).pathExtension.lowercased()
        var a = ["-charset", "filename=utf8", "-all="]
        if FileTypes.media.contains(ext) { a += quickTimeDates }
        // -all= can't clear IFD0 on a TIFF (it is the image directory).
        if FileTypes.tiff.contains(ext) { a.append("-CommonIFD0=") }
        if FileTypes.raw.contains(ext) { a += rawIdentifying + quickTimeDates }
        var keep: [String] = []
        if s.preserveOrientation { keep.append("-Orientation") }
        if s.preserveColorProfile { keep.append("-ICC_Profile") }
        if s.preserveResolution { keep += resolution }
        if !keep.isEmpty { a += ["-TagsFromFile", "@"] + keep }
        if s.preserveTimestamps { a.append("-P") }
        if let destination { a += ["-o", destination] } else { a.append("-overwrite_original") }
        a.append(source)
        return a
    }

    struct Options {
        var preserveOrientation = true
        var preserveColorProfile = true
        var preserveResolution = true
        var preserveTimestamps = false
    }
}

enum FileTypes {
    static let supported: Set<String> = [".jpg", ".jpeg", ".png", ".gif", ".tiff", ".tif", ".webp", ".heic", ".heif", ".bmp",
                                         ".avif", ".svg", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".raf", ".dng", ".pef",
                                         ".srw", ".mp4", ".mov", ".avi", ".m4a", ".m4v", ".3gp", ".wmv", ".wav", ".pdf"]
    static let raw: Set<String> = [".raf", ".cr2", ".cr3", ".nef", ".arw", ".orf", ".rw2", ".dng", ".pef", ".srw"]
    static let media: Set<String> = [".mp4", ".mov", ".avi", ".m4a", ".m4v", ".3gp", ".wmv"]
    static let tiff: Set<String> = [".tif", ".tiff"]

    static func ext(_ url: URL) -> String { "." + url.pathExtension.lowercased() }
    static func isSupported(_ url: URL) -> Bool { supported.contains(ext(url)) }

    /// "<name>_cleaned.<ext>", then "_cleaned_2", "_cleaned_3"… (generateCleanedPath).
    static func cleanedPath(for url: URL) -> URL {
        let dir = url.deletingLastPathComponent()
        let base = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.isEmpty ? "" : "." + url.pathExtension
        var candidate = dir.appendingPathComponent("\(base)_cleaned\(ext)")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = dir.appendingPathComponent("\(base)_cleaned_\(n)\(ext)")
            n += 1
        }
        return candidate
    }
}
