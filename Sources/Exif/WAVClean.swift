import Foundation

/// WAV files, which ExifTool can read but not write ("Can't currently write RIFF WAVE files"):
/// the file is written again with only the chunks that make up the sound. Everything else goes:
/// LIST/INFO (title, artist, dates, software), bext (Broadcast WAV: description, originator,
/// recording time), iXML, _PMX (XMP), id3/ID3, axml, cart, JUNK/PAD… The audio bytes are copied
/// unchanged.
enum WAVClean {
    enum Failure: Error, LocalizedError {
        case notWAV, rf64, malformed, writeFailed
        var errorDescription: String? {
            switch self {
            case .notWAV: "Not a RIFF WAVE file"
            case .rf64: "RF64/BW64 WAV files (over 4 GB) can’t be cleaned yet"
            case .malformed: "The WAV file is damaged: no format or audio chunk found"
            case .writeFailed: "Couldn’t write the cleaned WAV file"
            }
        }
    }

    /// Chunks kept: the format, the audio, and sample/loop/cue data a sampler needs to play it.
    static let kept: Set<String> = ["fmt ", "fact", "data", "cue ", "smpl", "inst"]

    /// Writes the cleaned `source` to `destination` (may be the same file: replaced in one step).
    /// Same permissions and extended attributes as `source`; its modification date too with `keepDate`.
    static func run(source: URL, destination: URL, keepDate: Bool) throws {
        guard let input = try? FileHandle(forReadingFrom: source) else { throw Failure.writeFailed }
        defer { try? input.close() }
        let fileSize = (try? input.seekToEnd()) ?? 0
        try input.seek(toOffset: 0)
        guard let header = try input.read(upToCount: 12), header.count == 12 else { throw Failure.notWAV }
        let magic = String(decoding: header[0..<4], as: UTF8.self)
        if magic == "RF64" || magic == "BW64" { throw Failure.rf64 }
        guard magic == "RIFF", String(decoding: header[8..<12], as: UTF8.self) == "WAVE" else { throw Failure.notWAV }

        // The chunks to copy: (id, offset of the body, body size).
        var chunks: [(id: Data, offset: UInt64, size: UInt64)] = []
        var pos: UInt64 = 12
        while pos + 8 <= fileSize {
            try input.seek(toOffset: pos)
            guard let h = try input.read(upToCount: 8), h.count == 8 else { break }
            let id = String(decoding: h[0..<4], as: UTF8.self)
            var size = UInt64(h[4]) | UInt64(h[5]) << 8 | UInt64(h[6]) << 16 | UInt64(h[7]) << 24
            let body = pos + 8
            // A recorder that stopped before closing the file leaves a size past the end (often
            // 0xFFFFFFFF): the chunk is then everything up to the end.
            if body + size > fileSize { size = fileSize - body }
            if kept.contains(id) { chunks.append((h[0..<4], body, size)) }
            pos = body + size + (size & 1)
        }
        guard chunks.contains(where: { $0.id == Data("fmt ".utf8) }),
              chunks.contains(where: { $0.id == Data("data".utf8) }) else { throw Failure.malformed }
        var total: UInt64 = 4
        for c in chunks { total += 8 + c.size + (c.size & 1) }
        guard total <= UInt64(UInt32.max) else { throw Failure.rf64 }

        let dir = destination.deletingLastPathComponent()
        let tmp = dir.appendingPathComponent(".\(destination.lastPathComponent).exif-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: tmp.path, contents: nil),
              let out = try? FileHandle(forWritingTo: tmp) else { throw Failure.writeFailed }
        do {
            func le32(_ v: UInt64) -> Data { withUnsafeBytes(of: UInt32(v).littleEndian) { Data($0) } }
            try out.write(contentsOf: Data("RIFF".utf8) + le32(total) + Data("WAVE".utf8))
            for c in chunks {
                try out.write(contentsOf: c.id + le32(c.size))
                try input.seek(toOffset: c.offset)
                var left = c.size
                while left > 0 {
                    let n = Int(min(left, 4 << 20))
                    guard let block = try input.read(upToCount: n), block.count == n else { throw Failure.writeFailed }
                    try out.write(contentsOf: block)
                    left -= UInt64(n)
                }
                if c.size & 1 == 1 { try out.write(contentsOf: Data([0])) }
            }
            try out.synchronize()
            try out.close()

            let attrs = try FileManager.default.attributesOfItem(atPath: source.path)
            _ = copyfile(source.path, tmp.path, nil, copyfile_flags_t(COPYFILE_XATTR))
            var set: [FileAttributeKey: Any] = [:]
            if let p = attrs[.posixPermissions] { set[.posixPermissions] = p }
            if keepDate, let d = attrs[.modificationDate] { set[.modificationDate] = d }
            try FileManager.default.setAttributes(set, ofItemAtPath: tmp.path)
            // rename(2) in the same folder: the file is replaced in one step, never half-written.
            guard rename(tmp.path, destination.path) == 0 else { throw Failure.writeFailed }
        } catch {
            try? out.close()
            try? FileManager.default.removeItem(at: tmp)
            throw error
        }
    }
}
