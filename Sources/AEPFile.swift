import Foundation

/// Reads and rewrites the footage paths inside an After Effects project file (.aep), so
/// TaskTimer can collect a project without After Effects.
///
/// An .aep is a RIFX file: chunks of `id (4 bytes) · size (4 bytes, big-endian) · data`,
/// padded to an even length; `LIST` chunks hold a 4-byte type and more chunks, and their size
/// includes their children's padding. Each footage file's path is in
/// `LIST:"Pin " → LIST:"Als2" → "alas"`: compact JSON with sorted keys, e.g.
/// `{"ascendcount_base":3,"ascendcount_target":2,"fullpath":"/Users/me/a.png","platform":2,
///   "server_name":"","server_volume_name":"","target_is_folder":false}`
/// (for an image sequence `fullpath` is its folder and `target_is_folder` is true). The
/// `ascendcount_*` pair is After Effects' fallback relative path from the project file.
/// Render output paths use the same record under `LIST:"LOm "`; those are left alone.
/// Format notes: https://github.com/forticheprod/aep_parser (docs/file_format.md).
/// Everything not changed is written back byte for byte.
struct AEPFile {
    indirect enum Node {
        case leaf(id: String, data: [UInt8])
        case list(type: String, children: [Node])   // id is "LIST" (or "RIFX" for the root)
    }

    struct Footage: Hashable {
        let path: String
        let isFolder: Bool
    }

    private var children: [Node]
    private let rootType: String
    private let trailing: [UInt8]

    // MARK: Reading

    init?(data: Data) {
        let b = [UInt8](data)
        guard b.count >= 12, Self.fourCC(b, 0) == "RIFX" else { return nil }
        let end = min(b.count, 8 + Self.u32(b, 4))
        guard let kids = Self.parse(b, from: 12, to: end) else { return nil }
        children = kids
        rootType = Self.fourCC(b, 8)
        trailing = end < b.count ? Array(b[end...]) : []
    }

    private static func fourCC(_ b: [UInt8], _ i: Int) -> String {
        String(bytes: b[i..<(i + 4)], encoding: .isoLatin1) ?? "????"
    }

    private static func u32(_ b: [UInt8], _ i: Int) -> Int {
        Int(b[i]) << 24 | Int(b[i + 1]) << 16 | Int(b[i + 2]) << 8 | Int(b[i + 3])
    }

    private static func parse(_ b: [UInt8], from start: Int, to end: Int) -> [Node]? {
        var out: [Node] = []
        var pos = start
        while pos < end {
            guard pos + 8 <= end else { return nil }
            let id = fourCC(b, pos)
            let size = u32(b, pos + 4)
            let dataStart = pos + 8
            let dataEnd = dataStart + size
            guard dataEnd <= end else { return nil }
            if id == "LIST", size >= 4 {
                let type = fourCC(b, dataStart)
                // "btdk" lists hold raw data; a list that doesn't parse is kept as raw bytes.
                if type != "btdk", let kids = parse(b, from: dataStart + 4, to: dataEnd) {
                    out.append(.list(type: type, children: kids))
                } else {
                    out.append(.leaf(id: id, data: Array(b[dataStart..<dataEnd])))
                }
            } else {
                out.append(.leaf(id: id, data: Array(b[dataStart..<dataEnd])))
            }
            pos = dataEnd + (size % 2)
        }
        return pos == end ? out : nil
    }

    // MARK: Footage records

    private static func record(_ data: [UInt8]) -> [String: Any]? {
        var bytes = data
        while bytes.last == 0 { bytes.removeLast() }
        guard let obj = try? JSONSerialization.jsonObject(with: Data(bytes)) as? [String: Any] else { return nil }
        return obj
    }

    /// Calls `body` with each footage `alas` record (inside a "Pin " list), in file order.
    private static func eachFootageRecord(_ nodes: [Node], inPin: Bool, _ body: ([UInt8]) -> Void) {
        for n in nodes {
            switch n {
            case .leaf(let id, let data):
                if inPin && id == "alas" { body(data) }
            case .list(let type, let kids):
                eachFootageRecord(kids, inPin: inPin || type == "Pin ", body)
            }
        }
    }

    /// Every footage file / sequence folder the project uses (each once). `unreadable` counts
    /// records that aren't the JSON kind (very old projects).
    func footage() -> (items: [Footage], unreadable: Int) {
        var items: [Footage] = []
        var seen = Set<String>()
        var unreadable = 0
        Self.eachFootageRecord(children, inPin: false) { data in
            guard let r = Self.record(data), let p = r["fullpath"] as? String, !p.isEmpty else {
                unreadable += 1
                return
            }
            let f = Footage(path: p, isFolder: (r["target_is_folder"] as? Bool) ?? false)
            if seen.insert(f.path).inserted { items.append(f) }
        }
        return (items, unreadable)
    }

    /// After Effects' relative-path counts for `target` seen from the project file `project`.
    static func relativeCounts(project: String, target: String, targetIsFolder: Bool) -> (Int, Int) {
        guard project.hasPrefix("/"), target.hasPrefix("/") else { return (0, 0) }
        let a = URL(fileURLWithPath: project).pathComponents
        var b = URL(fileURLWithPath: target).pathComponents
        if targetIsFolder { b.append("_") }
        func volume(_ p: [String]) -> Int { p.count > 2 && p[1] == "Volumes" ? 3 : 1 }
        guard Array(a.prefix(volume(a))) == Array(b.prefix(volume(b))) else { return (0, 0) }
        var common = 0
        while common < min(a.count, b.count) && a[common] == b[common] { common += 1 }
        return (a.count - common, b.count - common)
    }

    private static func jsonString(_ s: String) -> String {
        var out = "\""
        for ch in s.unicodeScalars {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if ch.value < 0x20 { out += String(format: "\\u%04x", ch.value) } else { out.unicodeScalars.append(ch) }
            }
        }
        return out + "\""
    }

    /// A copy of the project with footage moved: `map` is old path → new path, and the project
    /// copy will be saved at `projectPath` (for the relative-path counts). Only the values that
    /// change are edited; the rest of each record is kept as After Effects wrote it.
    func relinked(_ map: [String: String], projectPath: String) -> (file: AEPFile, changed: Int) {
        var changed = 0
        func fix(_ nodes: [Node], inPin: Bool) -> [Node] {
            nodes.map { n in
                switch n {
                case .leaf(let id, let data):
                    guard inPin, id == "alas", let r = Self.record(data),
                          let old = r["fullpath"] as? String, let new = map[old],
                          var text = String(bytes: data, encoding: .utf8) else { return n }
                    let isFolder = (r["target_is_folder"] as? Bool) ?? false
                    let (base, target) = Self.relativeCounts(project: projectPath, target: new, targetIsFolder: isFolder)
                    func set(_ key: String, _ value: String) {
                        // "key":value — a JSON string or a number.
                        let pattern = "\"\(key)\"\\s*:\\s*(\"(?:[^\"\\\\]|\\\\.)*\"|-?\\d+)"
                        guard let re = try? NSRegularExpression(pattern: pattern) else { return }
                        let ns = text as NSString
                        if let m = re.firstMatch(in: text, range: NSRange(location: 0, length: ns.length)) {
                            text = ns.replacingCharacters(in: m.range(at: 1), with: value)
                        }
                    }
                    set("fullpath", Self.jsonString(new))
                    set("ascendcount_base", String(base))
                    set("ascendcount_target", String(target))
                    // Keep any NUL bytes After Effects had after the JSON.
                    var zeros = 0
                    for byte in data.reversed() { if byte == 0 { zeros += 1 } else { break } }
                    changed += 1
                    return .leaf(id: id, data: Array(text.utf8) + Array(repeating: 0, count: zeros))
                case .list(let type, let kids):
                    return .list(type: type, children: fix(kids, inPin: inPin || type == "Pin "))
                }
            }
        }
        var copy = self
        copy.children = fix(children, inPin: false)
        return (copy, changed)
    }

    // MARK: Writing

    func data() -> Data {
        var out: [UInt8] = []
        out.reserveCapacity(1 << 20)
        func id(_ s: String) {
            var b = Array(s.utf8.prefix(4))
            while b.count < 4 { b.append(0x20) }
            out += b
        }
        func size(_ n: Int, at i: Int) {
            out[i] = UInt8(n >> 24 & 0xFF); out[i + 1] = UInt8(n >> 16 & 0xFF)
            out[i + 2] = UInt8(n >> 8 & 0xFF); out[i + 3] = UInt8(n & 0xFF)
        }
        func write(_ n: Node) {
            switch n {
            case .leaf(let cid, let data):
                id(cid)
                let at = out.count
                out += [0, 0, 0, 0]
                size(data.count, at: at)
                out += data
                if data.count % 2 == 1 { out.append(0) }
            case .list(let type, let kids):
                id("LIST")
                let at = out.count
                out += [0, 0, 0, 0]
                id(type)
                kids.forEach(write)
                let n = out.count - at - 4
                size(n, at: at)
                if n % 2 == 1 { out.append(0) }
            }
        }
        id("RIFX")
        let at = out.count
        out += [0, 0, 0, 0]
        id(rootType)
        children.forEach(write)
        size(out.count - at - 4, at: at)
        out += trailing
        return Data(out)
    }
}
