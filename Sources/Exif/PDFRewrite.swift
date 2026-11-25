import Foundation
import PDFKit

/// ExifTool writes a PDF's changes as an update appended to the file: the old Info dictionary and
/// XMP stay in it and `exiftool -PDF-update:all=` brings them back. After ExifTool, Exif writes the
/// PDF again from scratch with PDFKit, so only what the pages use is kept and the earlier versions
/// are gone. Then, in the new file and without moving a byte (offsets stay valid):
///   - the Info dictionary Quartz writes (Producer with the macOS build, the cleaning time) is
///     blanked to an empty dictionary;
///   - JPEG images inside the PDF (DCTDecode streams, copied as they are) lose their Exif, XMP,
///     Photoshop/IPTC and comment segments; the JFIF, Adobe and ICC colour segments stay.
/// Pages, sizes, links, form fields and bookmarks are compared before the original is replaced;
/// signed PDFs aren't rewritten. On any doubt nothing is replaced and
/// the ExifTool result stays.
enum PDFRewrite {
    enum Failure: Error { case unreadable, locked, signed, writeFailed, check }

    /// What must come through the rewrite unchanged: per page, its size, annotations (links,
    /// notes), form fields; and the bookmarks.
    struct Shape: Equatable {
        var pages: [String] = []
        var outline = 0

        init(_ d: PDFDocument) {
            for i in 0..<d.pageCount {
                guard let p = d.page(at: i) else { pages.append("missing"); continue }
                let b = p.bounds(for: .mediaBox)
                let widgets = p.annotations.filter { $0.type == "Widget" }.count
                pages.append("\(Int(b.width.rounded()))x\(Int(b.height.rounded())) r\(p.rotation) a\(p.annotations.count) w\(widgets)")
            }
            outline = Self.count(d.outlineRoot)
        }

        private static func count(_ o: PDFOutline?) -> Int {
            guard let o else { return 0 }
            return (0..<o.numberOfChildren).reduce(o.numberOfChildren) { $0 + count(o.child(at: $1)) }
        }
    }

    @discardableResult
    static func run(_ url: URL, keepDate: Bool) throws -> Result {
        guard let doc = PDFDocument(url: url) else { throw Failure.unreadable }
        guard !doc.isLocked else { throw Failure.locked }
        // Writing a signed PDF again would break its signature: left as ExifTool made it.
        for i in 0..<doc.pageCount {
            if doc.page(at: i)?.annotations.contains(where: { $0.widgetFieldType == .signature }) == true { throw Failure.signed }
        }
        let shape = Shape(doc)
        doc.documentAttributes = [:]
        let dir = url.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(url.lastPathComponent).exif-\(UUID().uuidString.prefix(8)).pdf")
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard doc.write(to: tmp) else { throw Failure.writeFailed }

        var bytes = [UInt8](try Data(contentsOf: tmp))
        blankInfo(&bytes)
        blankJPEGMetadata(&bytes)
        try Data(bytes).write(to: tmp)
        guard let check = PDFDocument(url: tmp), Shape(check) == shape,
              !Self.find(Array("xpacket begin".utf8), in: bytes, from: 0).isValid else { throw Failure.check }
        // The text layer: the same characters on every page. Where it differs (a font whose
        // character map didn't come through), the page must still look the same.
        var textChanged = false
        for i in 0..<doc.pageCount {
            guard let a = doc.page(at: i), let b = check.page(at: i) else { throw Failure.check }
            if letters(a) != letters(b) {
                guard looksSame(a, b) else { throw Failure.check }
                textChanged = true
            }
        }

        // Same permissions, extended attributes (cleared later if the setting says so) and, when
        // asked, modification date as the file it replaces.
        let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
        _ = copyfile(url.path, tmp.path, nil, copyfile_flags_t(COPYFILE_XATTR))
        var set: [FileAttributeKey: Any] = [:]
        if let p = attrs[.posixPermissions] { set[.posixPermissions] = p }
        if keepDate, let d = attrs[.modificationDate] { set[.modificationDate] = d }
        try FileManager.default.setAttributes(set, ofItemAtPath: tmp.path)
        // rename(2) in the same folder: the original is replaced in one step, never half-written.
        guard rename(tmp.path, url.path) == 0 else { throw Failure.writeFailed }
        return textChanged ? .textChanged : .done
    }

    enum Result { case done, textChanged }

    private static func letters(_ p: PDFPage) -> [Character] { (p.string ?? "").filter { !$0.isWhitespace }.sorted() }

    /// Both pages drawn at about 800 px: at most 0.2% of the pixels may differ (anti-aliasing).
    private static func looksSame(_ a: PDFPage, _ b: PDFPage) -> Bool {
        let box = a.bounds(for: .mediaBox)
        guard box.width > 0, box.height > 0 else { return false }
        let scale = 800 / max(box.width, box.height)
        let w = Int(box.width * scale), h = Int(box.height * scale)
        func draw(_ p: PDFPage) -> [UInt8]? {
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
                ctx.setFillColor(CGColor(gray: 1, alpha: 1)); ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
                ctx.scaleBy(x: scale, y: scale)
                p.draw(with: .mediaBox, to: ctx)
                return true
            }
            return ok ? px : nil
        }
        guard let x = draw(a), let y = draw(b) else { return false }
        var differing = 0
        for i in stride(from: 0, to: x.count, by: 4) {
            if abs(Int(x[i]) - Int(y[i])) > 24 || abs(Int(x[i + 1]) - Int(y[i + 1])) > 24 || abs(Int(x[i + 2]) - Int(y[i + 2])) > 24 { differing += 1 }
        }
        return differing <= (w * h) / 500
    }

    // MARK: Info dictionary

    /// The trailer's /Info object, its dictionary's contents overwritten with spaces.
    static func blankInfo(_ b: inout [UInt8]) {
        let trailer = lastIndex(of: Array("trailer".utf8), in: b)
        guard trailer >= 0, let info = firstRange(of: Array("/Info".utf8), in: b, from: trailer) else { return }
        // "/Info 7 0 R"
        var i = info.upperBound
        func skipSpace() { while i < b.count, isSpace(b[i]) { i += 1 } }
        func number() -> String { var s = ""; while i < b.count, (48...57).contains(b[i]) { s.append(Character(UnicodeScalar(b[i]))); i += 1 }; return s }
        skipSpace(); let num = number(); skipSpace(); let gen = number()
        guard !num.isEmpty, !gen.isEmpty else { return }
        let header = Array("\(num) \(gen) obj".utf8)
        var from = 0
        var objStart = -1
        while let r = firstRange(of: header, in: b, from: from) {
            if r.lowerBound == 0 || isSpace(b[r.lowerBound - 1]) { objStart = r.upperBound; break }
            from = r.upperBound
        }
        guard objStart >= 0, let open = firstRange(of: [0x3C, 0x3C], in: b, from: objStart) else { return }
        // Find the matching ">>", skipping (strings) with escapes and <hex> strings.
        var j = open.upperBound, depth = 1
        while j < b.count, depth > 0 {
            switch b[j] {
            case 0x28: // (
                var paren = 1; j += 1
                while j < b.count, paren > 0 {
                    if b[j] == 0x5C { j += 2; continue }
                    if b[j] == 0x28 { paren += 1 } else if b[j] == 0x29 { paren -= 1 }
                    j += 1
                }
                continue
            case 0x3C:
                if j + 1 < b.count, b[j + 1] == 0x3C { depth += 1; j += 2; continue }
                while j < b.count, b[j] != 0x3E { j += 1 }
                j += 1; continue
            case 0x3E:
                if j + 1 < b.count, b[j + 1] == 0x3E { depth -= 1; if depth == 0 { break }; j += 2; continue }
            default: break
            }
            if depth == 0 { break }
            j += 1
        }
        guard depth == 0, j < b.count else { return }
        for k in open.upperBound..<j { b[k] = 0x20 }
    }

    // MARK: JPEG streams

    /// Every JPEG that starts a stream: APP1 (Exif, XMP), APP3–APP13 (Photoshop/IPTC…), APP15 and
    /// COM segments have their contents zeroed, so no reader recognises them; their lengths stay.
    static func blankJPEGMetadata(_ b: inout [UInt8]) {
        let keyword = Array("stream".utf8)
        var from = 0
        while let r = firstRange(of: keyword, in: b, from: from) {
            from = r.upperBound
            var i = r.upperBound
            if i < b.count, b[i] == 0x0D { i += 1 }
            guard i < b.count, b[i] == 0x0A else { continue }
            i += 1
            guard i + 3 < b.count, b[i] == 0xFF, b[i + 1] == 0xD8 else { continue }
            i += 2
            while i + 3 < b.count, b[i] == 0xFF {
                let m = b[i + 1]
                if m == 0xFF { i += 1; continue }
                if m == 0xDA || m == 0xD9 { break }     // image data follows
                if m == 0x01 || (0xD0...0xD7).contains(m) { i += 2; continue }
                let len = Int(b[i + 2]) << 8 | Int(b[i + 3])
                guard len >= 2, i + 2 + len <= b.count else { break }
                let strip = m == 0xFE || m == 0xE1 || (0xE3...0xED).contains(m) || m == 0xEF
                if strip { for k in (i + 4)..<(i + 2 + len) { b[k] = 0 } }
                i += 2 + len
            }
            from = i
        }
    }

    // MARK: Byte search

    private static func isSpace(_ c: UInt8) -> Bool { c == 0x20 || c == 0x0A || c == 0x0D || c == 0x09 || c == 0x0C || c == 0x00 }

    private static func firstRange(of n: [UInt8], in h: [UInt8], from: Int) -> Range<Int>? {
        let r = find(n, in: h, from: from)
        return r.isValid ? r.index..<(r.index + n.count) : nil
    }

    struct Hit { let index: Int; var isValid: Bool { index >= 0 } }

    static func find(_ n: [UInt8], in h: [UInt8], from: Int) -> Hit {
        guard !n.isEmpty, h.count >= n.count, from <= h.count - n.count else { return Hit(index: -1) }
        let first = n[0]
        var i = from
        let last = h.count - n.count
        while i <= last {
            if h[i] == first {
                var k = 1
                while k < n.count, h[i + k] == n[k] { k += 1 }
                if k == n.count { return Hit(index: i) }
            }
            i += 1
        }
        return Hit(index: -1)
    }

    private static func lastIndex(of n: [UInt8], in h: [UInt8]) -> Int {
        guard h.count >= n.count else { return -1 }
        var i = h.count - n.count
        while i >= 0 {
            if h[i] == n[0], Array(h[i..<(i + n.count)]) == n { return i }
            i -= 1
        }
        return -1
    }
}
