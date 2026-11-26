import Foundation

enum OddChannel: String {
    case mono, dual, skip
}

struct SplitError: LocalizedError {
    let message: String
    init(_ message: String) { self.message = message }
    var errorDescription: String? { message }
}

/// The parts of a WAV header needed to split it.
struct WavInfo {
    var formatTag: UInt16        // 1 PCM, 3 float, 6 A-law, 7 mu-law, 0xFFFE extensible
    var channels: Int
    var sampleRate: UInt32
    var bitsPerSample: UInt16
    var blockAlign: Int
    var extensible: Data?        // cbSize + validBits + mask + GUID, when formatTag is 0xFFFE
    var dataOffset: UInt64
    var dataSize: UInt64

    var bytesPerSample: Int { blockAlign / channels }
    var frames: UInt64 { dataSize / UInt64(blockAlign) }
}

private extension Data {
    func u16(_ at: Int) -> UInt16 {
        UInt16(self[startIndex + at]) | UInt16(self[startIndex + at + 1]) << 8
    }
    func u32(_ at: Int) -> UInt32 {
        (0..<4).reduce(UInt32(0)) { $0 | UInt32(self[startIndex + at + $1]) << (8 * $1) }
    }
    func u64(_ at: Int) -> UInt64 {
        (0..<8).reduce(UInt64(0)) { $0 | UInt64(self[startIndex + at + $1]) << (8 * $1) }
    }
    func tag(_ at: Int) -> String {
        String(decoding: self[(startIndex + at)..<(startIndex + at + 4)], as: UTF8.self)
    }
    mutating func put16(_ v: UInt16) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func put32(_ v: UInt32) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func put64(_ v: UInt64) { Swift.withUnsafeBytes(of: v.littleEndian) { append(contentsOf: $0) } }
    mutating func putTag(_ s: String) { append(contentsOf: Array(s.utf8)) }
}

enum Splitter {
    static func readInfo(_ url: URL) throws -> WavInfo {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw SplitError("CANNOT READ FILE") }
        defer { try? fh.close() }
        let fileSize = (try? fh.seekToEnd()) ?? 0
        try fh.seek(toOffset: 0)

        guard let head = try fh.read(upToCount: 12), head.count == 12 else { throw SplitError("NOT A WAV FILE") }
        let riff = head.tag(0)
        guard ["RIFF", "RF64", "BW64"].contains(riff), head.tag(8) == "WAVE" else { throw SplitError("NOT A WAV FILE") }

        var ds64DataSize: UInt64?
        var fmt: Data?
        var pos: UInt64 = 12
        while pos + 8 <= fileSize {
            try fh.seek(toOffset: pos)
            guard let ch = try fh.read(upToCount: 8), ch.count == 8 else { break }
            let id = ch.tag(0)
            var size = UInt64(ch.u32(4))
            let body = pos + 8
            switch id {
            case "ds64":
                if let d = try fh.read(upToCount: Int(min(size, 64))), d.count >= 16 { ds64DataSize = d.u64(8) }
            case "fmt ":
                fmt = try fh.read(upToCount: Int(min(size, 1024)))
            case "data":
                if size == 0xFFFF_FFFF, let s = ds64DataSize { size = s }
                // Recorders that stopped mid-take can leave a size past the end of the file.
                size = min(size, fileSize - body)
                guard let f = fmt, f.count >= 16 else { throw SplitError("NO FORMAT CHUNK BEFORE AUDIO DATA") }
                return try parseFormat(f, dataOffset: body, dataSize: size)
            default:
                break
            }
            pos = body + size + (size & 1)
        }
        throw SplitError("NO AUDIO DATA FOUND")
    }

    private static func parseFormat(_ f: Data, dataOffset: UInt64, dataSize: UInt64) throws -> WavInfo {
        let tag = f.u16(0)
        let channels = Int(f.u16(2))
        let blockAlign = Int(f.u16(12))
        var base = tag
        var ext: Data?
        if tag == 0xFFFE {
            guard f.count >= 40 else { throw SplitError("BROKEN EXTENSIBLE FORMAT CHUNK") }
            ext = f[(f.startIndex + 16)..<(f.startIndex + 40)]
            base = f.u16(24)
        }
        guard [1, 3, 6, 7].contains(base) else { throw SplitError("COMPRESSED WAV (FORMAT \(base)) IS NOT SUPPORTED") }
        guard channels > 0, blockAlign > 0, blockAlign % channels == 0 else { throw SplitError("UNREADABLE CHANNEL LAYOUT") }
        return WavInfo(formatTag: tag, channels: channels, sampleRate: f.u32(4), bitsPerSample: f.u16(14),
                       blockAlign: blockAlign, extensible: ext, dataOffset: dataOffset, dataSize: dataSize)
    }

    /// A WAV header for `channels` channels of the source's format. Writes RF64 when the data passes 4 GB.
    static func header(_ src: WavInfo, channels: Int, frames: UInt64) -> Data {
        let bps = src.bytesPerSample
        let blockAlign = bps * channels
        let dataSize = frames * UInt64(blockAlign)
        var fmt = Data()
        fmt.put16(src.formatTag)
        fmt.put16(UInt16(channels))
        fmt.put32(src.sampleRate)
        fmt.put32(src.sampleRate * UInt32(blockAlign))
        fmt.put16(UInt16(blockAlign))
        fmt.put16(src.bitsPerSample)
        if var ext = src.extensible {
            // Keep valid bits and subformat; set the speaker mask to front left/right or front centre.
            let mask: UInt32 = channels == 2 ? 0x3 : 0x4
            withUnsafeBytes(of: mask.littleEndian) { ext.replaceSubrange((ext.startIndex + 4)..<(ext.startIndex + 8), with: $0) }
            fmt.append(ext)
        }
        let pad = dataSize & 1
        let big = dataSize + 200 > 0xFFFF_FFFF
        var h = Data()
        let riffSize = 4 + (big ? 36 : 0) + 8 + UInt64(fmt.count) + 8 + dataSize + pad
        h.putTag(big ? "RF64" : "RIFF")
        h.put32(big ? 0xFFFF_FFFF : UInt32(riffSize))
        h.putTag("WAVE")
        if big {
            h.putTag("ds64"); h.put32(28)
            h.put64(riffSize); h.put64(dataSize); h.put64(frames); h.put32(0)
        }
        h.putTag("fmt "); h.put32(UInt32(fmt.count)); h.append(fmt)
        h.putTag("data"); h.put32(big ? 0xFFFF_FFFF : UInt32(dataSize))
        return h
    }

    /// Splits `url` into a folder beside it and returns that folder.
    static func split(_ url: URL, odd: OddChannel, progress: (Double) -> Void) throws -> URL {
        let info = try readInfo(url)
        if info.channels <= 2 {
            throw SplitError(info.channels == 1 ? "FILE IS MONO. NOTHING TO SPLIT" : "FILE IS ALREADY STEREO. NOTHING TO SPLIT")
        }

        // Each output: the source channels it takes (one or two) and how many channels it writes.
        var outs: [(src: [Int], channels: Int, name: String)] = []
        let width = String(info.channels).count
        func num(_ n: Int) -> String { String(repeating: "0", count: width - String(n).count) + String(n) }
        let stem = url.deletingPathExtension().lastPathComponent
        var c = 0
        while c + 1 < info.channels {
            outs.append(([c, c + 1], 2, "\(stem) \(num(c + 1))-\(num(c + 2)).wav"))
            c += 2
        }
        if c < info.channels {
            switch odd {
            case .mono: outs.append(([c], 1, "\(stem) \(num(c + 1)).wav"))
            case .dual: outs.append(([c, c], 2, "\(stem) \(num(c + 1)).wav"))
            case .skip: break
            }
        }

        let fm = FileManager.default
        let parent = url.deletingLastPathComponent()
        var folder = parent.appendingPathComponent(stem, isDirectory: true)
        var n = 2
        while fm.fileExists(atPath: folder.path) {
            folder = parent.appendingPathComponent("\(stem) \(n)", isDirectory: true)
            n += 1
        }
        do {
            try fm.createDirectory(at: folder, withIntermediateDirectories: false)
        } catch {
            throw SplitError("CANNOT CREATE A FOLDER HERE. CHECK THE DISK IS WRITABLE")
        }

        do {
            try write(url, info: info, outs: outs, folder: folder, progress: progress)
        } catch {
            try? fm.removeItem(at: folder)
            throw error
        }
        return folder
    }

    private static func write(_ url: URL, info: WavInfo, outs: [(src: [Int], channels: Int, name: String)],
                              folder: URL, progress: (Double) -> Void) throws {
        let fm = FileManager.default
        let frames = info.frames
        var handles: [FileHandle] = []
        defer { handles.forEach { try? $0.close() } }
        for o in outs {
            let u = folder.appendingPathComponent(o.name)
            guard fm.createFile(atPath: u.path, contents: header(info, channels: o.channels, frames: frames)),
                  let h = try? FileHandle(forWritingTo: u) else { throw SplitError("CANNOT WRITE \(o.name.uppercased())") }
            try h.seekToEnd()
            handles.append(h)
        }

        guard let input = try? FileHandle(forReadingFrom: url) else { throw SplitError("CANNOT READ FILE") }
        defer { try? input.close() }
        try input.seek(toOffset: info.dataOffset)

        let bps = info.bytesPerSample
        let srcAlign = info.blockAlign
        let chunkFrames = max(1, (8 << 20) / srcAlign)
        var buffers = outs.map { o in [UInt8](repeating: 0, count: chunkFrames * bps * o.channels) }
        var done: UInt64 = 0
        var lastReport = -1.0

        while done < frames {
            let want = Int(min(UInt64(chunkFrames), frames - done))
            guard let chunk = try input.read(upToCount: want * srcAlign), chunk.count >= srcAlign else { break }
            let got = chunk.count / srcAlign
            chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
                let src = raw.baseAddress!
                for (i, o) in outs.enumerated() {
                    let outAlign = bps * o.channels
                    buffers[i].withUnsafeMutableBytes { dstRaw in
                        let dst = dstRaw.baseAddress!
                        for (k, ch) in o.src.enumerated() {
                            var s = src + ch * bps
                            var d = dst + k * bps
                            for _ in 0..<got {
                                d.copyMemory(from: s, byteCount: bps)
                                s += srcAlign
                                d += outAlign
                            }
                        }
                    }
                }
            }
            for (i, o) in outs.enumerated() {
                try handles[i].write(contentsOf: Data(buffers[i][0..<(got * bps * o.channels)]))
            }
            done += UInt64(got)
            let p = Double(done) / Double(max(frames, 1))
            if p - lastReport >= 0.01 { progress(p); lastReport = p }
        }
        for (i, o) in outs.enumerated() where (frames * UInt64(bps * o.channels)) & 1 == 1 {
            try handles[i].write(contentsOf: Data([0]))
        }
    }
}
