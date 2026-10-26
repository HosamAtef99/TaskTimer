// Checks AEPFile (the .aep reader/writer Collect uses). Run in CI before the build:
//   swiftc Sources/AEPFile.swift Tests/AEPFileTest/main.swift -o aeptest && ./aeptest samples/*.aep
import Foundation

var failures = 0
func check(_ ok: Bool, _ what: String) {
    print((ok ? "ok   " : "FAIL ") + what)
    if !ok { failures += 1 }
}

// 1. Real project files are written back byte for byte.
for path in CommandLine.arguments.dropFirst() {
    guard let d = FileManager.default.contents(atPath: path) else { check(false, "read \(path)"); continue }
    guard let f = AEPFile(data: d) else { check(false, "parse \(path)"); continue }
    check(f.data() == d, "round trip \((path as NSString).lastPathComponent)")
}

// 2. A made-up project: one footage file, one sequence folder, one render output.
func chunk(_ id: String, _ body: [UInt8]) -> [UInt8] {
    var out = Array(id.utf8)
    let n = body.count
    out += [UInt8(n >> 24 & 255), UInt8(n >> 16 & 255), UInt8(n >> 8 & 255), UInt8(n & 255)] + body
    if n % 2 == 1 { out.append(0) }
    return out
}
func list(_ type: String, _ kids: [[UInt8]]) -> [UInt8] { chunk("LIST", Array(type.utf8) + kids.flatMap { $0 }) }
func alas(_ path: String, folder: Bool) -> [UInt8] {
    let json = #"{"ascendcount_base":3,"ascendcount_target":2,"fullpath":"\#(path)","platform":2,"server_name":"","server_volume_name":"","target_is_folder":\#(folder)}"#
    return list("Als2", [chunk("alas", Array(json.utf8))])
}
let body = Array("Egg!".utf8)
    + chunk("head", [0, 1, 2])
    + list("Fold", [
        chunk("fdta", [0, 0]),
        // A folder "Images" holding a subfolder "Stills" holding the footage item.
        list("Item", [chunk("idta", [0, 1] + [UInt8](repeating: 0, count: 82)), chunk("Utf8", Array("Images".utf8)),
                      chunk("sfdt", [0, 0, 0, 0]),
                      list("Sfdr", [
                        list("Item", [chunk("idta", [0, 1] + [UInt8](repeating: 0, count: 82)), chunk("Utf8", Array("Stills".utf8)),
                                      list("Sfdr", [
                                        list("Item", [chunk("idta", [0, 7] + [UInt8](repeating: 0, count: 82)), chunk("Utf8", []),
                                                      list("Pin ", [chunk("sspc", [1]), alas("/Users/me/Task/06 - Images/a b.png", folder: false)])]),
                                        chunk("fvdv", [0, 0, 0, 3]),
                                      ])]),
                      ])]),
        // A sequence at the top level.
        list("Item", [chunk("idta", [0, 7] + [UInt8](repeating: 0, count: 82)), chunk("Utf8", []),
                      list("Pin ", [alas("/Users/me/Task/seq", folder: true)])]),
    ])
    + list("LRdr", [list("LOm ", [alas("/Users/me/Task/00 - Render", folder: true)])])
let fake = Array("RIFX".utf8) + [UInt8(body.count >> 24 & 255), UInt8(body.count >> 16 & 255), UInt8(body.count >> 8 & 255), UInt8(body.count & 255)] + body
    + Array("<?xpacket trailing?>".utf8)

if let f = AEPFile(data: Data(fake)) {
    check(f.data() == Data(fake), "made-up project round trip")
    let found = f.footage()
    check(found.items.map(\.path) == ["/Users/me/Task/06 - Images/a b.png", "/Users/me/Task/seq"], "footage found, render output skipped")
    check(found.items.map(\.isFolder) == [false, true], "sequence is a folder")
    check(found.items.map(\.bins) == [["Images", "Stills"], []], "project-panel folders")
    let project = "/Users/me/Task/Collect/Task 1/01 - AE/Task.aep"
    let map = ["/Users/me/Task/06 - Images/a b.png": "/Users/me/Task/Collect/Task 1/(Footage)/06 - Images/a b.png",
               "/Users/me/Task/seq": "/Users/me/Task/Collect/Task 1/(Footage)/seq"]
    let (moved, changed) = f.relinked(map, projectPath: project)
    check(changed == 2, "two records changed")
    let out = moved.data()
    if let again = AEPFile(data: out) {
        check(again.footage().items.map(\.path) == Array(map.values).sorted(), "new paths read back")
        let text = String(decoding: out, as: UTF8.self)
        check(text.contains(#""ascendcount_base":2,"ascendcount_target":3,"fullpath":"/Users/me/Task/Collect/Task 1/(Footage)/06 - Images/a b.png""#), "file counts")
        check(text.contains(#""ascendcount_base":2,"ascendcount_target":3,"fullpath":"/Users/me/Task/Collect/Task 1/(Footage)/seq""#), "folder counts")
        check(text.contains(#""fullpath":"/Users/me/Task/00 - Render""#), "render output untouched")
        check(text.hasSuffix("<?xpacket trailing?>"), "trailing data kept")
    } else {
        check(false, "re-parse after relink")
    }
} else {
    check(false, "parse made-up project")
}

print(failures == 0 ? "All AEPFile checks passed" : "\(failures) AEPFile check(s) failed")
exit(failures == 0 ? 0 : 1)
