import Foundation
import SwiftUI

/// Switches for whole features.
enum Features {
    /// Logging to the team Google Sheet. Off: TaskTimer keeps everything in the app.
    /// The sheet code (SheetService, SheetSync, TaskTimer.gs, SheetDoneSheet) stays in the
    /// project so it can be switched back on.
    static let sheet = false
}

/// All user settings live in UserDefaults under these keys (used with @AppStorage).
enum Pref {
    static let memberName = "memberName"
    static let webAppURL = "webAppURL"
    static let token = "sheetToken"
    static let templatePath = "templatePath"
    static let subfolders = "subfolders"
    static let lastLocation = "lastLocation"
    static let timeFormat = "timeFormat"       // "hm" | "decimal" | "minutes"
    static let rounding = "roundingMinutes"    // 0, 5, 10, 15, 30
    static let updateSameRow = "updateSameRow"
    static let hideDock = "hideDock"
    static let pauseOnSleep = "pauseOnSleep"
    static let menuBarStyle = "menuBarStyle"
    static let renderNotify = "renderNotify"   // "time" (1:05) | "seconds" (01:05:12) | "icon"
    static let openFinderOnCreate = "openFinderOnCreate"
    static let openAEOnCreate = "openAEOnCreate"

    // Read from the sheet (Settings → Sheet → Sync from Sheet)
    static let tabMode = "tabMode"                     // "auto" | "manual"
    static let tabName = "tabName"                     // used when tabMode == "manual"
    static let statusComplete = "statusCompleteLabel"  // what "Complete" is written as in the sheet
    static let statusInProcess = "statusInProcessLabel"
    static let timeFormatFromSheet = "timeFormatFromSheet"
    static let sheetConfig = "sheetConfig"

    // Where new task folders go
    static let folderMode = "folderMode"   // "location" | "client" | "months"
    static let monthsRoot = "monthsRoot"   // folder that holds the month folders ("months" mode)

    static let defaultSubfolders = """
    00 - Render
    01 - AE
    02 - PSD
    03 - For AI
    04 - From AI
    05 - Sound
    06 - Images
    07 - Videos
    08 - Others
    """

    /// No template until each person picks their own (the path below is only shown as an example).
    static let defaultTemplate = ""
    static let templateExample = "/Users/you/Templates/new.aep"

    static let oldDefaultSubfolders = """
    00 - Render
    01 - AE
    02 - PSD
    03 - For AI
    04 - From AI
    05 - Sound
    06 - Assets and others
    """

    static func registerDefaults() {
        // The template path used to default to one person's Mac; forget it if it isn't there.
        if let t = UserDefaults.standard.string(forKey: templatePath),
           t.hasPrefix("/Users/mousab.hassan/"), !FileManager.default.fileExists(atPath: t) {
            UserDefaults.standard.removeObject(forKey: templatePath)
        }
        // If the old folder tree was saved untouched, switch to the new one.
        if let saved = UserDefaults.standard.string(forKey: subfolders),
           saved.trimmingCharacters(in: .whitespacesAndNewlines) == oldDefaultSubfolders.trimmingCharacters(in: .whitespacesAndNewlines) {
            UserDefaults.standard.removeObject(forKey: subfolders)
        }
        UserDefaults.standard.register(defaults: [
            subfolders: defaultSubfolders,
            templatePath: defaultTemplate,
            timeFormat: "hm",
            rounding: 0,
            updateSameRow: true,
            hideDock: false,
            pauseOnSleep: true,
            menuBarStyle: "time",
            renderNotify: true,
            openFinderOnCreate: true,
            openAEOnCreate: false,
            tabMode: "auto",
            folderMode: "location",
            timeFormatFromSheet: true,
        ])
    }

    static var d: UserDefaults { .standard }
    static func string(_ k: String) -> String { d.string(forKey: k) ?? "" }
    static func bool(_ k: String) -> Bool { d.bool(forKey: k) }
    static func int(_ k: String) -> Int { d.integer(forKey: k) }

    /// Which tab new rows go to: the current month's tab, or the one picked in Settings.
    static func tabTarget() -> (mode: String, tab: String) {
        let t = string(tabName).trimmingCharacters(in: .whitespaces)
        if string(tabMode) == "manual", !t.isEmpty { return ("manual", t) }
        return ("auto", "")
    }

    static var subfolderList: [String] {
        string(subfolders)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
}

// MARK: - Formatting

enum Fmt {
    static func clock(_ s: TimeInterval) -> String {
        let t = Int(max(0, s))
        return String(format: "%02d:%02d:%02d", t / 3600, (t % 3600) / 60, t % 60)
    }

    /// "1:05" — hours and minutes, for the menu bar.
    static func menuClock(_ s: TimeInterval) -> String {
        let m = Int(max(0, s)) / 60
        return String(format: "%d:%02d", m / 60, m % 60)
    }

    static func short(_ s: TimeInterval) -> String {
        let m = Int(max(0, s)) / 60
        let h = m / 60, mm = m % 60
        if h == 0 { return "\(mm)m" }
        return mm == 0 ? "\(h)h" : "\(h)h \(mm)m"
    }

    static func rounded(_ s: TimeInterval) -> TimeInterval {
        let step = Pref.int(Pref.rounding)
        guard step > 0 else { return s }
        let stepSec = Double(step * 60)
        let r = (s / stepSec).rounded() * stepSec
        return (s > 0 && r == 0) ? stepSec : r
    }

    /// The text written into the Time column of the sheet.
    static func sheetTime(_ s: TimeInterval) -> String {
        let secs = rounded(s)
        let totalMin = Int((secs / 60).rounded())
        switch Pref.string(Pref.timeFormat) {
        case "decimal":
            let h = Double(totalMin) / 60.0
            var str = String(format: "%.2f", h)
            while str.hasSuffix("0") { str.removeLast() }
            if str.hasSuffix(".") { str.removeLast() }
            return str
        case "minutes":
            return "\(totalMin)"
        default:
            return String(format: "%d:%02d", totalMin / 60, totalMin % 60)
        }
    }

    static let isoDay: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()

    /// Hours as a decimal, e.g. 3, 3.5, 0.75.
    static func hours(_ s: TimeInterval) -> String {
        let h = (max(0, s) / 3600 * 100).rounded() / 100
        var str = String(format: "%.2f", h)
        while str.hasSuffix("0") { str.removeLast() }
        if str.hasSuffix(".") { str.removeLast() }
        return str
    }

    static let monthYear: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MMMM yyyy"
        return f
    }()

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static let nice: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "d MMM"
        return f
    }()
}
