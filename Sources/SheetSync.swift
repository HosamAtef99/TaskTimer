import Foundation
import SwiftUI

struct SheetTab: Codable, Hashable {
    var name: String
    var hidden: Bool?
}

/// What the last "Sync from Sheet" read: tabs, column titles and the dropdown lists.
struct SheetConfig: Codable {
    var spreadsheet: String?
    var tabs: [SheetTab] = []
    var autoTab: String?
    var sheet: String?
    var columns: [String: String] = [:]
    var headers: [String: String] = [:]
    var lists: [String: [String]] = [:]
    var timeFormat: String?
    var version: Int?
    var syncedAt: Date?

    var clients: [String] { lists["client"] ?? [] }
    var statuses: [String] { lists["status"] ?? [] }
    var members: [String] { lists["member"] ?? [] }
    var visibleTabs: [String] { tabs.filter { !($0.hidden ?? false) }.map(\.name) }
}

/// Keeps TaskTimer in step with the team sheet. Nothing about the sheet is hard-coded:
/// on Sync the script reports the sheet as it is now, and TaskTimer adopts it.
@MainActor
final class SheetSync: ObservableObject {
    static let shared = SheetSync()

    @Published private(set) var config: SheetConfig?
    @Published private(set) var syncing = false
    @Published var lastError: String?

    private var timer: Timer?

    private init() {
        if let data = UserDefaults.standard.data(forKey: Pref.sheetConfig),
           let c = try? JSONDecoder().decode(SheetConfig.self, from: data) {
            config = c
        }
    }

    /// Sync on launch, then every hour.
    func start() {
        Task { @MainActor in await sync(silent: true) }
        timer = Timer.scheduledTimer(withTimeInterval: 60 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.sync(silent: true) }
        }
    }

    @discardableResult
    func sync(silent: Bool) async -> Bool {
        guard !Pref.string(Pref.webAppURL).trimmingCharacters(in: .whitespaces).isEmpty else {
            if !silent { lastError = SheetService.SheetError.notConfigured.localizedDescription }
            return false
        }
        guard !syncing else { return false }
        syncing = true
        defer { syncing = false }

        do {
            let r = try await SheetService.config()
            var c = SheetConfig()
            c.spreadsheet = r.spreadsheet
            c.tabs = r.tabs ?? []
            c.autoTab = r.autoTab
            c.sheet = r.sheet
            c.columns = r.columns ?? [:]
            c.headers = r.headers ?? [:]
            c.lists = r.lists ?? [:]
            c.timeFormat = r.timeFormat
            c.version = r.version
            c.syncedAt = Date()
            config = c
            if let data = try? JSONEncoder().encode(c) {
                UserDefaults.standard.set(data, forKey: Pref.sheetConfig)
            }
            apply(c)
            lastError = r.warning.flatMap { $0.isEmpty ? nil : $0 }
            if !silent {
                Store.shared.flash("Synced “\(c.sheet ?? "sheet")” · \(c.clients.count) accounts ✓")
            }
            return true
        } catch {
            var msg = error.localizedDescription
            if msg.contains("Unknown action") {
                msg = "The script on the sheet is the old version. Paste the new TaskTimer.gs into Apps Script, then Deploy → Manage deployments → Edit → New version."
            }
            lastError = msg
            if !silent { Store.shared.flash("Sync failed: \(msg)") }
            return false
        }
    }

    /// Adopts what the sheet says: accounts, status words, the member's exact name, time format.
    private func apply(_ c: SheetConfig) {
        Store.shared.syncClients(c.clients)

        let st = c.statuses
        if !st.isEmpty {
            let d = UserDefaults.standard
            var complete = Pref.string(Pref.statusComplete)
            if complete.isEmpty || !st.contains(complete) {
                complete = Self.guess(st, ["complete", "done", "finish", "deliver", "مكتمل", "تم", "خلص"]) ?? st[0]
                d.set(complete, forKey: Pref.statusComplete)
            }
            let inProcess = Pref.string(Pref.statusInProcess)
            if inProcess.isEmpty || !st.contains(inProcess) {
                let g = Self.guess(st, ["process", "progress", "working", "doing", "wip", "pending", "ongoing", "جاري", "شغال"])
                    ?? st.first(where: { $0 != complete }) ?? complete
                d.set(g, forKey: Pref.statusInProcess)
            }
        }

        // Match the saved name to the sheet's spelling ("hossam atef" → "Hossam atef").
        let me = Pref.string(Pref.memberName).trimmingCharacters(in: .whitespaces)
        if !me.isEmpty, let exact = c.members.first(where: { $0.caseInsensitiveCompare(me) == .orderedSame }), exact != me {
            UserDefaults.standard.set(exact, forKey: Pref.memberName)
        }

        if Pref.bool(Pref.timeFormatFromSheet), let tf = c.timeFormat, ["hm", "decimal", "minutes"].contains(tf) {
            UserDefaults.standard.set(tf, forKey: Pref.timeFormat)
        }
    }

    private static func guess(_ options: [String], _ words: [String]) -> String? {
        for w in words {
            if let o = options.first(where: { $0.lowercased().contains(w) }) { return o }
        }
        return nil
    }
}
