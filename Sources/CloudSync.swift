import Foundation
import SwiftUI
import UserNotifications

struct TeamProfile: Identifiable, Hashable {
    let id: String
    var email: String
    var name: String
    var role: String
    var teamID: String?

    var isLeader: Bool { role == "leader" }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String else { return nil }
        self.id = id.lowercased()
        email = row["email"] as? String ?? ""
        let n = (row["full_name"] as? String ?? "").trimmingCharacters(in: .whitespaces)
        name = n.isEmpty ? email : n
        role = row["role"] as? String ?? "member"
        teamID = (row["team_id"] as? String)?.lowercased()
    }
}

struct TeamTask: Identifiable, Hashable {
    let id: String
    var userID: String
    var parentID: String?
    var name: String
    var client: String
    var status: String
    var seconds: Double
    var runningSince: Date?
    var workDate: Date?
    var createdAt: Date
    var assignedBy: String?
    var ownerName: String?
    var updatedAt: Date?
    var deleted: Bool
    var deliverables: Int?
    var rating: Int?

    var isRunning: Bool { runningSince != nil }

    func liveSeconds(at now: Date) -> Double {
        max(0, seconds + (runningSince.map { max(0, now.timeIntervalSince($0)) } ?? 0))
    }

    var statusTitle: String {
        switch status {
        case "incoming": return "Incoming"
        case "complete": return "Completed"
        default: return "In Progress"
        }
    }

    init?(_ row: [String: Any]) {
        guard let id = row["id"] as? String, let user = row["user_id"] as? String else { return nil }
        self.id = id.lowercased()
        userID = user.lowercased()
        parentID = (row["parent_id"] as? String)?.lowercased()
        name = row["name"] as? String ?? ""
        client = row["client"] as? String ?? ""
        status = row["status"] as? String ?? "active"
        seconds = (row["seconds"] as? Double) ?? Double(row["seconds"] as? Int ?? 0)
        runningSince = Cloud.date(row["running_since"])
        workDate = Cloud.date(row["work_date"])
        createdAt = Cloud.date(row["created_at"]) ?? Date()
        assignedBy = (row["assigned_by"] as? String)?.lowercased()
        ownerName = row["owner_name"] as? String
        updatedAt = Cloud.date(row["updated_at"])
        deleted = (row["deleted"] as? Bool) ?? false
        deliverables = row["deliverables"] as? Int
        rating = row["rating"] as? Int
    }
}

/// Keeps this Mac's tasks in the team database, and brings in tasks a leader added for you.
/// The app stays the source of truth for your own tasks; the database is a copy the leader can see.
@MainActor
final class CloudSync: ObservableObject {
    static let shared = CloudSync()

    @Published private(set) var profile: TeamProfile?
    @Published private(set) var teamName: String?
    @Published private(set) var lastSync: Date?
    @Published var error: String?

    var isLeader: Bool { profile?.isLeader ?? false }

    /// id → fingerprint of the row last sent, so only changed tasks are sent again.
    private var pushed: [String: String] = [:]
    private var lastPull: Date?
    private var pushWork: DispatchWorkItem?
    private var timer: Timer?
    private var pushing = false
    private var ticks = 0
    private var pulling = false

    /// The account the pushed / lastPull state belongs to (kept per account).
    private var stateUser: String?
    private var pushedKey: String { "cloudPushed-\(stateUser ?? "none")" }
    private var lastPullKey: String { "cloudLastPull-\(stateUser ?? "none")" }

    private init() {}

    /// Loads the sync state of the signed-in account. False when it isn't the account
    /// whose tasks are loaded in the app (never send one person's tasks as another's).
    private func ensureState() -> Bool {
        guard let uid = CloudAuth.shared.session?.userID, Store.shared.account == uid else { return false }
        if stateUser != uid {
            stateUser = uid
            pushed = (UserDefaults.standard.dictionary(forKey: pushedKey) as? [String: String]) ?? [:]
            lastPull = UserDefaults.standard.object(forKey: lastPullKey) as? Date
        }
        return true
    }

    // MARK: - Lifecycle

    func start() async {
        guard CloudAuth.shared.signedIn, ensureState() else { return }
        await loadProfile()
        await restoreIfEmpty()
        await saveSettings()
        await loadSettings()
        await loadModheshLinks()
        await pushNow()
        await pull()
        await checkWeeklyReport()
        if timer == nil {
            // Every 2 minutes, kept light (the free database has a monthly download allowance).
            timer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self else { return }
                    self.ticks += 1
                    await self.pull()
                    await self.pushNow()
                    await self.loadModhesh()
                    if self.ticks % 3 == 0 { await self.loadModheshLinks() }
                    if self.ticks % 5 == 0 {
                        await self.checkWeeklyReport()
                        await self.loadSettings()
                    }
                }
            }
        }
    }

    /// Called on sign-out: forget everything about the account.
    func reset() {
        timer?.invalidate()
        timer = nil
        profile = nil
        teamName = nil
        lastSync = nil
        error = nil
        pushed = [:]
        lastPull = nil
        stateUser = nil
        modheshTasks = []
        modheshLinks = [:]
        newModheshCount = 0
        extensionSeen = nil
        extensionVersion = nil
        modheshSeenName = nil
        modheshConfirmedName = nil
        modheshMismatch = false
        modheshStatus = nil
        modheshReadAt = nil
    }

    /// First sign-in on this Mac for an account that already has tasks: bring them back.
    private func restoreIfEmpty() async {
        guard let uid = CloudAuth.shared.session?.userID, Store.shared.account == uid,
              Store.shared.tasks.isEmpty else { return }
        do {
            let rows = try await CloudAPI.select("tasks", [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "deleted", value: "eq.false"),
            ])
            let list = rows.compactMap { TeamTask($0) }
            Store.shared.restore(from: list)
            // These rows are already in the database as they are.
            for t in Store.shared.tasks {
                let id = t.id.uuidString.lowercased()
                pushed[id] = fingerprint(row(for: t, userID: uid))
            }
            UserDefaults.standard.set(pushed, forKey: pushedKey)
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Called whenever tasks change; sends them a moment later.
    func scheduleSync() {
        guard CloudAuth.shared.signedIn else { return }
        pushWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.pushNow() }
        }
        pushWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    // MARK: - Profile

    func loadProfile() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            let rows = try await CloudAPI.select("profiles", [
                URLQueryItem(name: "select", value: "id,email,full_name,role,team_id"),
                URLQueryItem(name: "id", value: "eq.\(uid)"),
            ])
            profile = rows.first.flatMap { TeamProfile($0) }
            teamName = nil
            if let team = profile?.teamID {
                let t = try await CloudAPI.select("teams", [
                    URLQueryItem(name: "select", value: "name"),
                    URLQueryItem(name: "id", value: "eq.\(team)"),
                ])
                teamName = t.first?["name"] as? String
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    func rename(_ name: String) async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            try await CloudAPI.update("profiles", [URLQueryItem(name: "id", value: "eq.\(uid)")], ["full_name": name])
            await loadProfile()
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Sending my tasks

    private func row(for t: TaskItem, userID: String) -> [String: Any] {
        var secs = t.manualAdjust
        for s in t.sessions {
            if let e = s.end { secs += max(0, e.timeIntervalSince(s.start)) }
        }
        let status: String
        switch t.status {
        case .incoming: status = "incoming"
        case .complete: status = "complete"
        default: status = "active"
        }
        let runningSince: Any = t.isRunning ? Cloud.iso(t.sessions[t.sessions.count - 1].start) : NSNull()
        return [
            "id": t.id.uuidString.lowercased(),
            "user_id": userID,
            "parent_id": t.parentID.map { $0.uuidString.lowercased() as Any } ?? NSNull(),
            "name": t.name,
            "client": Store.shared.clientName(t.clientID),
            "status": status,
            "seconds": (secs * 10).rounded() / 10,
            "running_since": runningSince,
            "work_date": t.workDate.map { Fmt.isoDay.string(from: $0) as Any } ?? NSNull(),
            "created_at": Cloud.iso(t.createdAt),
            "deleted": false,
            "deliverables": t.deliverables.map { $0 as Any } ?? NSNull(),
            "rating": t.rating.map { $0 as Any } ?? NSNull(),
            "challenge": t.challenge.map { $0 as Any } ?? NSNull(),
            "started_at": t.sessions.first.map { Cloud.iso($0.start) as Any } ?? NSNull(),
        ]
    }

    private static let newColumns = ["deliverables", "rating", "started_at", "challenge"]

    /// Set when the database doesn't have the deliverables / rating columns yet
    /// (schema.sql not re-run), so syncing keeps working without them.
    private var skipNewColumns = false

    private func fingerprint(_ row: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return UUID().uuidString }
        return String(data: data, encoding: .utf8) ?? UUID().uuidString
    }

    func pushNow() async {
        guard let uid = CloudAuth.shared.session?.userID, !pushing, ensureState() else { return }
        pushing = true
        defer { pushing = false }

        var rows: [[String: Any]] = []
        var prints: [String: String] = [:]
        for t in Store.shared.tasks {
            let r = row(for: t, userID: uid)
            let id = t.id.uuidString.lowercased()
            let fp = fingerprint(r)
            prints[id] = fp
            if pushed[id] != fp { rows.append(r) }
        }
        let gone = pushed.keys.filter { prints[$0] == nil }
        guard !rows.isEmpty || !gone.isEmpty else { return }

        do {
            if !rows.isEmpty {
                var send = rows
                func stripped(_ rows: [[String: Any]]) -> [[String: Any]] {
                    rows.map { r in r.filter { !Self.newColumns.contains($0.key) } }
                }
                if skipNewColumns { send = stripped(rows) }
                do {
                    try await CloudAPI.upsert("tasks", send)
                } catch let e as Cloud.CloudError where !skipNewColumns
                            && Self.newColumns.contains(where: { e.message.contains($0) }) {
                    skipNewColumns = true
                    send = stripped(rows)
                    try await CloudAPI.upsert("tasks", send)
                }
                for r in rows {
                    if let id = r["id"] as? String { pushed[id] = prints[id] }
                }
            }
            for id in gone {
                try await CloudAPI.update("tasks", [URLQueryItem(name: "id", value: "eq.\(id)")],
                                          ["deleted": true, "running_since": NSNull()])
                pushed.removeValue(forKey: id)
            }
            UserDefaults.standard.set(pushed, forKey: pushedKey)
            lastSync = Date()
            error = nil
        } catch {
            UserDefaults.standard.set(pushed, forKey: pushedKey)
            self.error = error.localizedDescription
        }
    }

    // MARK: - Tasks a leader added for me

    func pull() async {
        guard let uid = CloudAuth.shared.session?.userID, !pulling, ensureState() else { return }
        pulling = true
        defer { pulling = false }
        var query = [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "user_id", value: "eq.\(uid)"),
            URLQueryItem(name: "assigned_by", value: "not.is.null"),
            URLQueryItem(name: "order", value: "updated_at.asc"),
        ]
        if let since = lastPull {
            query.append(URLQueryItem(name: "updated_at", value: "gt.\(Cloud.iso(since))"))
        }
        do {
            let rows = try await CloudAPI.select("tasks", query)
            var newest = lastPull
            var added: [String] = []
            for r in rows {
                if let u = Cloud.date(r["updated_at"]), newest.map({ u > $0 }) ?? true { newest = u }
                guard let tt = TeamTask(r), (r["deleted"] as? Bool) != true,
                      let id = UUID(uuidString: tt.id),
                      Store.shared.task(id) == nil, pushed[tt.id] == nil else { continue }
                Store.shared.adoptAssigned(id: id, name: tt.name, client: tt.client, createdAt: tt.createdAt)
                added.append(tt.name)
            }
            lastPull = newest
            if let newest { UserDefaults.standard.set(newest, forKey: lastPullKey) }
            if !added.isEmpty {
                let names = added.joined(separator: ", ")
                Store.shared.notify(title: "New task from your team leader", body: names)
                Store.shared.flash("New in Incoming: \(names)")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: - Modhesh

    struct ModheshTask: Identifiable, Hashable {
        var id: String { code }
        let code: String
        var title: String
        var client: String
        var status: Int?
        var statusTitle: String
        var loggedSeconds: Double?
        var taskID: UUID?
        var updatedAt: Date?
        var submittedSeconds: Double?
        var submittedAt: Date?
        var submitNote: String?
        var autoLinked: Bool
    }

    @Published private(set) var modheshTasks: [ModheshTask] = []
    @Published private(set) var modheshError: String?

    func loadModhesh() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            let rows = try await CloudAPI.select("modhesh_tasks", [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "status", value: "in.(1,6)"),   // only what still needs work
                URLQueryItem(name: "order", value: "updated_at.desc"),
            ])
            modheshTasks = rows.compactMap { r in
                guard let code = r["code"] as? String else { return nil }
                let status = r["status"] as? Int
                return ModheshTask(code: code,
                                   title: r["title"] as? String ?? "",
                                   client: r["client"] as? String ?? "",
                                   status: status,
                                   statusTitle: (r["status_title"] as? String) ?? Self.modheshStatusTitle(status),
                                   loggedSeconds: (r["logged_seconds"] as? Double) ?? (r["logged_seconds"] as? Int).map(Double.init),
                                   taskID: (r["task_id"] as? String).flatMap { UUID(uuidString: $0) },
                                   updatedAt: Cloud.date(r["updated_at"]),
                                   submittedSeconds: (r["submitted_seconds"] as? Double) ?? (r["submitted_seconds"] as? Int).map(Double.init),
                                   submittedAt: Cloud.date(r["submitted_at"]),
                                   submitNote: r["submit_note"] as? String,
                                   autoLinked: (r["auto_linked"] as? Bool) ?? false)
            }
            modheshError = nil
            announceNewModhesh(uid)
        } catch {
            let m = error.localizedDescription
            modheshError = m.contains("modhesh_tasks")
                ? "Run the latest schema.sql in Supabase first (it adds the Modhesh table)."
                : m
        }
    }

    // MARK: - Modhesh settings (shared with the Chrome extension)

    /// When the Chrome extension last checked in (nil = never seen for this account).
    @Published private(set) var extensionSeen: Date?
    @Published private(set) var extensionVersion: String?
    /// The person whose Modhesh is open in Chrome, and whether that isn't this account.
    @Published private(set) var modheshSeenName: String?
    @Published private(set) var modheshConfirmedName: String?
    @Published private(set) var modheshMismatch = false
    /// What the extension's last read of Modhesh found, in words, and when.
    @Published private(set) var modheshStatus: String?
    @Published private(set) var modheshReadAt: Date?
    private var settingsWork: DispatchWorkItem?

    var extensionConnected: Bool {
        guard let d = extensionSeen else { return false }
        return Date().timeIntervalSince(d) < 24 * 3600
    }

    /// Sends Settings → Modhesh to the database a moment after a change.
    func scheduleSettingsSave() {
        settingsWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in await self?.saveSettings() }
        }
        settingsWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
    }

    func saveSettings() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            try await CloudAPI.upsert("user_settings", [[
                "user_id": uid,
                "challenge": min(4, max(1, Pref.int(Pref.defaultChallenge))),
                "default_rating": min(5, max(1, Pref.int(Pref.defaultRating))),
                "default_deliverables": max(0, Pref.int(Pref.defaultDeliverables)),
                "auto_link": false,   // automatic linking was removed (it linked the wrong tasks)
                "auto_submit": Pref.bool(Pref.modheshAutoSubmit),
                "updated_at": Cloud.iso(Date()),
            ]])
        } catch {
            let m = error.localizedDescription
            if !m.contains("user_settings") { self.error = m }
        }
    }

    func loadSettings() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            let rows = try await CloudAPI.select("user_settings", [
                URLQueryItem(name: "select", value: "*"),
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
            ])
            let r = rows.first
            extensionSeen = Cloud.date(r?["extension_seen_at"])
            extensionVersion = r?["extension_version"] as? String
            modheshSeenName = r?["modhesh_seen_name"] as? String
            modheshConfirmedName = r?["modhesh_name"] as? String
            modheshMismatch = (r?["modhesh_mismatch"] as? Bool) ?? false
            modheshStatus = r?["modhesh_status"] as? String
            modheshReadAt = Cloud.date(r?["modhesh_read_at"])
        } catch {
            // Table not created yet: treated as "extension not added".
        }
    }

    /// Removes every Modhesh task on this account that wasn't sent yet, forgets whose Modhesh it
    /// was, and asks the extension to read Modhesh again from scratch.
    func resetModhesh() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            _ = try await CloudAPI.delete("modhesh_tasks", [
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "submitted_at", value: "is.null"),
            ])
            try await CloudAPI.upsert("user_settings", [[
                "user_id": uid,
                "modhesh_name": NSNull(), "modhesh_seen_name": NSNull(), "modhesh_mismatch": false,
                "modhesh_reset_at": Cloud.iso(Date()),
            ]])
            UserDefaults.standard.removeObject(forKey: "modheshSeen-\(uid)")
            modheshTasks = []
            modheshLinks = [:]
            newModheshCount = 0
            modheshError = nil
            await loadSettings()
            await loadModhesh()
            await loadModheshLinks()
            Store.shared.flash("Modhesh cleared — your tasks come back within 5 minutes")
        } catch {
            modheshError = error.localizedDescription
        }
    }

    /// "This Modhesh is mine": take tasks from the Modhesh account that's open in Chrome.
    func confirmModheshOwner() async {
        guard let uid = CloudAuth.shared.session?.userID, let name = modheshSeenName else { return }
        do {
            try await CloudAPI.upsert("user_settings", [[
                "user_id": uid, "modhesh_name": name, "modhesh_mismatch": false,
            ]])
            await loadSettings()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// New tasks on Modhesh (pending / in progress, not linked) since the last look.
    @Published private(set) var newModheshCount = 0

    private func announceNewModhesh(_ uid: String) {
        let key = "modheshSeen-\(uid)"
        let open = modheshTasks.filter { $0.taskID == nil && Self.modheshActive($0.status) }
        let known = UserDefaults.standard.stringArray(forKey: key)
        let fresh = open.filter { !(known ?? []).contains($0.code) }
        UserDefaults.standard.set(Array(Set((known ?? []) + open.map(\.code))), forKey: key)
        guard known != nil else { return }   // first look: don't announce everything
        newModheshCount += fresh.count
        guard !fresh.isEmpty else { return }
        let names = fresh.prefix(3).map(\.title).joined(separator: ", ")
        Store.shared.notify(title: fresh.count == 1 ? "New task on Modhesh" : "\(fresh.count) new tasks on Modhesh",
                            body: names + " — open Modhesh in TaskTimer to link it.")
        Store.shared.flash("New on Modhesh: \(names)")
    }

    func clearNewModhesh() { newModheshCount = 0 }

    /// Links a Modhesh task to a TaskTimer task (nil = unlink). The Chrome extension reads this link.
    /// TaskTimer tasks linked to a Modhesh task (any Modhesh status), and whether their time
    /// was sent there. Used to mark linked tasks in the lists.
    struct ModheshLink: Hashable {
        var status: Int?
        var sent: Bool
    }
    @Published private(set) var modheshLinks: [UUID: ModheshLink] = [:]

    func loadModheshLinks() async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        let since = Calendar.current.date(byAdding: .day, value: -120, to: Date()) ?? Date()
        do {
            let rows = try await CloudAPI.select("modhesh_tasks", [
                URLQueryItem(name: "select", value: "task_id,status,submitted_at"),
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "task_id", value: "not.is.null"),
                URLQueryItem(name: "updated_at", value: "gt.\(Cloud.iso(since))"),
            ])
            var map: [UUID: ModheshLink] = [:]
            for r in rows {
                guard let s = r["task_id"] as? String, let id = UUID(uuidString: s) else { continue }
                let status = r["status"] as? Int
                let sent = r["submitted_at"] is String || status == 4 || status == 5
                map[id] = ModheshLink(status: status, sent: sent)
            }
            if map != modheshLinks { modheshLinks = map }
        } catch {
            // Older database without these columns: nothing to mark.
        }
    }

    func linkModhesh(_ code: String, to taskID: UUID?) async {
        guard let uid = CloudAuth.shared.session?.userID else { return }
        do {
            await pushNow()   // make sure the TaskTimer task exists in the database
            try await CloudAPI.update("modhesh_tasks", [
                URLQueryItem(name: "user_id", value: "eq.\(uid)"),
                URLQueryItem(name: "code", value: "eq.\(code)"),
            ], ["task_id": taskID.map { $0.uuidString.lowercased() as Any } ?? NSNull()])
            await loadModhesh()
            await loadModheshLinks()
        } catch {
            modheshError = error.localizedDescription
        }
    }

    /// Pending to Start (1) or In Progress (6).
    static func modheshActive(_ s: Int?) -> Bool { s == 1 || s == 6 }

    static func modheshStatusTitle(_ s: Int?) -> String {
        switch s {
        case 1: return "Pending to Start"
        case 6: return "In Progress"
        case 4: return "Completed"
        case 5: return "Pending Approver"
        default: return "—"
        }
    }

    // MARK: - Leader

    func loadTeam(month: Date) async throws -> (members: [TeamProfile], tasks: [TeamTask]) {
        guard let team = profile?.teamID else { throw Cloud.CloudError("You're not in a team yet.") }
        let members = try await CloudAPI.select("profiles", [
            URLQueryItem(name: "select", value: "id,email,full_name,role,team_id"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "order", value: "full_name.asc"),
        ]).compactMap { TeamProfile($0) }

        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? month
        let inMonth = try await CloudAPI.select("tasks", [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "deleted", value: "eq.false"),
            URLQueryItem(name: "created_at", value: "gte.\(Cloud.iso(start))"),
            URLQueryItem(name: "created_at", value: "lt.\(Cloud.iso(end))"),
            URLQueryItem(name: "order", value: "created_at.desc"),
        ])
        let running = try await CloudAPI.select("tasks", [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "deleted", value: "eq.false"),
            URLQueryItem(name: "running_since", value: "not.is.null"),
        ])
        var byID: [String: TeamTask] = [:]
        for r in inMonth + running {
            if let t = TeamTask(r) { byID[t.id] = t }
        }
        let tasks = byID.values.sorted { $0.createdAt > $1.createdAt }
        return (members, tasks)
    }

    /// Team tasks changed since `since` (deleted ones included, so they can be removed).
    /// Used by the Team window to refresh without downloading the whole month again.
    func teamChanges(since: Date) async throws -> [TeamTask] {
        guard let team = profile?.teamID else { return [] }
        return try await CloudAPI.select("tasks", [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "updated_at", value: "gt.\(Cloud.iso(since))"),
        ]).compactMap { TeamTask($0) }
    }

    /// Team tasks done (by day) or created in [from, to).
    func loadTasks(from: Date, to: Date) async throws -> (members: [TeamProfile], tasks: [TeamTask]) {
        guard let team = profile?.teamID else { throw Cloud.CloudError("You're not in a team yet.") }
        let members = try await CloudAPI.select("profiles", [
            URLQueryItem(name: "select", value: "id,email,full_name,role,team_id"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "order", value: "full_name.asc"),
        ]).compactMap { TeamProfile($0) }
        let d1 = Fmt.isoDay.string(from: from), d2 = Fmt.isoDay.string(from: to)
        let t1 = Cloud.iso(from), t2 = Cloud.iso(to)
        let rows = try await CloudAPI.select("tasks", [
            URLQueryItem(name: "select", value: "*"),
            URLQueryItem(name: "team_id", value: "eq.\(team)"),
            URLQueryItem(name: "deleted", value: "eq.false"),
            URLQueryItem(name: "or", value: "(and(work_date.gte.\(d1),work_date.lt.\(d2)),and(work_date.is.null,created_at.gte.\(t1),created_at.lt.\(t2)))"),
        ])
        return (members, rows.compactMap { TeamTask($0) })
    }

    // MARK: - Weekly report (leaders)

    private var weeklyChecking = false
    private let weeklyKey = "weeklyReportWeek"

    /// Once a week (from Monday 9:00), sends the leader a notification with last week's numbers.
    func checkWeeklyReport() async {
        guard isLeader, !weeklyChecking else { return }
        let cal = Calendar.current
        let now = Date()
        guard let thisWeek = Self.weekStart(of: now),
              let lastWeek = cal.date(byAdding: .day, value: -7, to: thisWeek),
              now >= thisWeek.addingTimeInterval(9 * 3600) else { return }
        let mark = Fmt.isoDay.string(from: thisWeek)
        if UserDefaults.standard.string(forKey: weeklyKey) == mark { return }
        weeklyChecking = true
        defer { weeklyChecking = false }
        do {
            let r = try await loadTasks(from: lastWeek, to: thisWeek)
            let total = r.tasks.reduce(0) { $0 + $1.liveSeconds(at: now) }
            var lines: [String] = []
            for m in r.members {
                let mine = r.tasks.filter { $0.userID == m.id }
                guard !mine.isEmpty else { continue }
                let h = mine.reduce(0) { $0 + $1.liveSeconds(at: now) }
                lines.append("\(m.name): \(Fmt.hours(h)) h")
            }
            let c = UNMutableNotificationContent()
            c.title = "Weekly report — \(teamName ?? "your team")"
            c.body = "\(r.tasks.count) tasks · \(Fmt.hours(total)) h\n" + lines.prefix(6).joined(separator: " · ")
            c.sound = .default
            c.userInfo = ["kind": "weekly"]
            try await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "weekly-\(mark)", content: c, trigger: nil))
            UserDefaults.standard.set(mark, forKey: weeklyKey)
        } catch {
            // Try again on the next check.
        }
    }

    /// Monday of the week that contains `d`.
    static func weekStart(of d: Date) -> Date? {
        var cal = Calendar(identifier: .gregorian)
        cal.firstWeekday = 2
        cal.timeZone = .current
        return cal.dateInterval(of: .weekOfYear, for: d)?.start
    }

    /// Leader only: create / reset / remove team accounts through the team-admin Edge Function.
    @discardableResult
    func teamAdmin(_ body: [String: Any]) async throws -> [String: Any] {
        let token = try await CloudAuth.shared.token()
        guard let url = URL(string: "\(Cloud.url)/functions/v1/team-admin") else { throw Cloud.CloudError("Bad URL") }
        var req = URLRequest(url: url, timeoutInterval: 30)
        req.httpMethod = "POST"
        req.setValue(Cloud.anonKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        if status == 404 {
            throw Cloud.CloudError("The team-admin function isn't set up in Supabase yet.")
        }
        guard (200..<300).contains(status) else { throw Cloud.CloudError(Cloud.message(from: data, status: status)) }
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Adds an Incoming task for a team member. It shows up in their app within a minute.
    func assign(to memberID: String, name: String, client: String) async throws {
        guard let me = CloudAuth.shared.session?.userID else { throw Cloud.CloudError("Not signed in.") }
        try await CloudAPI.insert("tasks", [[
            "id": UUID().uuidString.lowercased(),
            "user_id": memberID,
            "name": name,
            "client": client,
            "status": "incoming",
            "seconds": 0,
            "assigned_by": me,
            "created_at": Cloud.iso(Date()),
        ]])
    }
}
