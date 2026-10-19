import Foundation

/// Finds (or creates) the folder for a month inside a parent folder, reading how the
/// existing month folders are named ("Oct 2026", "10 - October 2026", "2026-10", "أكتوبر 2026"…)
/// and naming a new one the same way.
enum MonthFolder {

    enum LetterCase { case lower, upper, title }

    enum Piece: Equatable {
        case text(String)
        case monthFull(LetterCase)   // October
        case monthShort(LetterCase)  // Oct
        case monthArabic             // أكتوبر
        case monthNumber(padded: Bool) // 10 / 09 or 9
        case year4                   // 2026
        case year2                   // 26
    }

    struct Parsed {
        var month: Int      // 1...12
        var year: Int?
        var pieces: [Piece]
    }

    static let fullNames = ["january", "february", "march", "april", "may", "june",
                            "july", "august", "september", "october", "november", "december"]
    static let shortNames = ["jan", "feb", "mar", "apr", "may", "jun",
                             "jul", "aug", "sep", "oct", "nov", "dec"]
    static let arabicNames = ["يناير", "فبراير", "مارس", "أبريل", "مايو", "يونيو",
                              "يوليو", "أغسطس", "سبتمبر", "أكتوبر", "نوفمبر", "ديسمبر"]

    /// Used when there is no month folder yet to copy the style from: "Oct 2026".
    static let defaultPieces: [Piece] = [.monthShort(.title), .text(" "), .year4]

    // MARK: - Public

    /// The folder for `date` inside `base`, created if needed.
    static func folder(in base: URL, for date: Date = Date()) throws -> URL {
        let (existing, name) = resolve(in: base, for: date)
        if let existing { return existing }
        let url = base.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// Name of the month folder that `folder(in:for:)` would use, and whether it exists already.
    static func preview(in base: URL, for date: Date = Date()) -> (name: String, exists: Bool) {
        let (existing, name) = resolve(in: base, for: date)
        return (existing?.lastPathComponent ?? name, existing != nil)
    }

    // MARK: - Matching

    private static func resolve(in base: URL, for date: Date) -> (URL?, String) {
        let cal = Calendar(identifier: .gregorian)
        let month = cal.component(.month, from: date)
        let year = cal.component(.year, from: date)

        let dirs = subfolders(of: base)
        var parsed: [(url: URL, p: Parsed)] = []
        for d in dirs {
            if let p = parse(d.lastPathComponent) { parsed.append((d, p)) }
        }

        // Same month and year first, then same month with no year in the name.
        if let hit = parsed.first(where: { $0.p.month == month && $0.p.year == year }) {
            return (hit.url, hit.url.lastPathComponent)
        }
        if let hit = parsed.first(where: { $0.p.month == month && $0.p.year == nil }) {
            return (hit.url, hit.url.lastPathComponent)
        }

        // New folder: copy the style of the latest month folder.
        let latest = parsed.max { a, b in
            let ka = (a.p.year ?? 0) * 100 + a.p.month
            let kb = (b.p.year ?? 0) * 100 + b.p.month
            return ka < kb
        }
        let pieces = latest?.p.pieces ?? defaultPieces
        let name = render(pieces, month: month, year: year)
        return (nil, name.isEmpty ? render(defaultPieces, month: month, year: year) : name)
    }

    private static func subfolders(of base: URL) -> [URL] {
        let items = (try? FileManager.default.contentsOfDirectory(
            at: base, includingPropertiesForKeys: [.isDirectoryKey], options: [.skipsHiddenFiles])) ?? []
        return items.filter { (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true }
    }

    // MARK: - Parsing a folder name

    private enum Kind { case letters, digits, other }

    private static func kind(of c: Character) -> Kind {
        if c.isLetter { return .letters }
        if c.isNumber { return .digits }
        return .other
    }

    /// Splits "10 - October 2026" into ["10", " - ", "October", " ", "2026"].
    private static func tokens(_ s: String) -> [(text: String, kind: Kind)] {
        var out: [(text: String, kind: Kind)] = []
        var current = ""
        var currentKind: Kind?
        for c in s {
            let k = kind(of: c)
            if k == currentKind {
                current.append(c)
            } else {
                if let ck = currentKind { out.append((text: current, kind: ck)) }
                current = String(c)
                currentKind = k
            }
        }
        if let ck = currentKind { out.append((text: current, kind: ck)) }
        return out
    }

    static func normalizeArabic(_ s: String) -> String {
        s.lowercased()
            .replacingOccurrences(of: "أ", with: "ا")
            .replacingOccurrences(of: "إ", with: "ا")
            .replacingOccurrences(of: "آ", with: "ا")
    }

    private static func letterCase(_ s: String) -> LetterCase {
        if s == s.uppercased() && s != s.lowercased() { return .upper }
        if let f = s.first, String(f) == String(f).uppercased(), String(f) != String(f).lowercased() { return .title }
        return .lower
    }

    static func parse(_ name: String) -> Parsed? {
        let toks = tokens(name)
        var pieces: [Piece] = toks.map { .text($0.text) }
        var month: Int?
        var year: Int?

        // 1) A month written as a word.
        for (i, t) in toks.enumerated() where t.kind == .letters && month == nil {
            let w = normalizeArabic(t.text)
            if let m = fullNames.firstIndex(of: w) {
                month = m + 1; pieces[i] = .monthFull(letterCase(t.text))
            } else if let m = shortNames.firstIndex(of: w) {
                month = m + 1; pieces[i] = .monthShort(letterCase(t.text))
            } else if w == "sept" {
                month = 9; pieces[i] = .monthShort(letterCase(t.text))
            } else if let m = arabicNames.map(normalizeArabic).firstIndex(of: w) {
                month = m + 1; pieces[i] = .monthArabic
            }
        }

        // 2) A four-digit year.
        for (i, t) in toks.enumerated() where t.kind == .digits && year == nil {
            if t.text.count == 4, let y = Int(t.text), (2000...2100).contains(y) {
                year = y; pieces[i] = .year4
            }
        }

        let numbers = toks.enumerated().filter { $0.element.kind == .digits }

        if let m = month {
            // A number equal to the month next to the name ("10 - October") follows the month too.
            for (i, t) in numbers {
                if case .text = pieces[i], let v = Int(t.text), v == m, t.text.count <= 2 {
                    pieces[i] = .monthNumber(padded: t.text.count == 2)
                    break
                }
            }
            // "Oct 26": a two-digit year.
            if year == nil {
                let twos = numbers.filter { (i, t) in
                    if case .text = pieces[i] { return t.text.count == 2 && (Int(t.text) ?? 0) >= 20 }
                    return false
                }
                if twos.count == 1, let v = Int(twos[0].element.text) {
                    year = 2000 + v; pieces[twos[0].offset] = .year2
                }
            }
        } else {
            // 3) A numeric month next to a year: "10-2026", "2026-10", "10-26".
            let list = numbers.map { (index: $0.offset, text: $0.element.text) }
            for k in 0..<max(0, list.count - 1) {
                let a = list[k], b = list[k + 1]
                guard let va = Int(a.text), let vb = Int(b.text) else { continue }
                if pieces[b.index] == .year4, (1...12).contains(va), a.text.count <= 2 {
                    month = va; pieces[a.index] = .monthNumber(padded: a.text.count == 2); break
                }
                if pieces[a.index] == .year4, (1...12).contains(vb), b.text.count <= 2 {
                    month = vb; pieces[b.index] = .monthNumber(padded: b.text.count == 2); break
                }
                if year == nil, (1...12).contains(va), a.text.count <= 2, b.text.count == 2, vb >= 20 {
                    month = va; year = 2000 + vb
                    pieces[a.index] = .monthNumber(padded: a.text.count == 2)
                    pieces[b.index] = .year2
                    break
                }
            }
        }

        guard let m = month else { return nil }
        return Parsed(month: m, year: year, pieces: pieces)
    }

    // MARK: - Naming a new folder

    static func render(_ pieces: [Piece], month: Int, year: Int) -> String {
        func cased(_ s: String, _ c: LetterCase) -> String {
            switch c {
            case .lower: return s.lowercased()
            case .upper: return s.uppercased()
            case .title: return s.prefix(1).uppercased() + String(s.dropFirst())
            }
        }
        var out = ""
        for p in pieces {
            switch p {
            case .text(let t): out += t
            case .monthFull(let c): out += cased(fullNames[month - 1], c)
            case .monthShort(let c): out += cased(shortNames[month - 1], c)
            case .monthArabic: out += arabicNames[month - 1]
            case .monthNumber(let padded): out += padded ? String(format: "%02d", month) : "\(month)"
            case .year4: out += "\(year)"
            case .year2: out += String(format: "%02d", year % 100)
            }
        }
        return out
    }
}
