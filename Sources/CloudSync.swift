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
    private var pulling = false

    private let pushedKey = "cloudPushed"
    private let lastPullKey = "cloudLastPull"

    private init() {
        pushed = (UserDefaults.standard.dictionary(forKey: pushedKey) as? [String: String]) ?? [:]
        lastPull = UserDefaults.standard.object(forKey: lastPullKey) as? Date
    }

    // MARK: - Lifecycle

    func start() async {
        guard CloudAuth.shared.signedIn else { return }
        await loadProfile()
        await pushNow()
        await pull()
        await checkWeeklyReport()
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    await self?.pull()
                    await self?.pushNow()
                    await self?.checkWeeklyReport()
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
        UserDefaults.standard.removeObject(forKey: pushedKey)
        UserDefaults.standard.removeObject(forKey: lastPullKey)
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
        ]
    }

    private func fingerprint(_ row: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: row, options: [.sortedKeys]) else { return UUID().uuidString }
        return String(data: data, encoding: .utf8) ?? UUID().uuidString
    }

    func pushNow() async {
        guard let uid = CloudAuth.shared.session?.userID, !pushing else { return }
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
                try await CloudAPI.upsert("tasks", rows)
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
        guard let uid = CloudAuth.shared.session?.userID, !pulling else { return }
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
