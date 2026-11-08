import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Admin: every account, team and hour. Admins are their own role — never in a team, no tasks of
/// their own — so for an admin account this is the main window (`embedded`). Changes go through
/// the team-admin Edge Function (actions starting with admin_); the stats read tasks directly
/// (admins can read every task through RLS).
struct AdminView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @Environment(\.mainWindowSize) var windowSize
    @ObservedObject var cloud = CloudSync.shared
    var embedded = false

    struct Team: Identifiable, Hashable {
        let id: String
        var name: String
    }

    enum Tab: String, CaseIterable, Identifiable {
        case stats = "Hours", clients = "Clients", people = "People", teams = "Teams"
        var id: String { rawValue }
    }

    // Clients and pitches
    @Local var clientRows: [Store.CloudClient] = []
    @Local var newClientName = ""
    @Local var newClientKind = "client"
    @Local var newClientTeam: String? = nil
    @Local var clientSearch = ""
    @Local var editingClient: String? = nil
    @Local var editClientText = ""
    @Local var deletingClient: Store.CloudClient? = nil
    @Local var showClosed = false
    @Local var confirmFresh = false

    @Local var tab: Tab = .stats
    @Local var people: [TeamProfile] = []
    @Local var lastSignIn: [String: Date] = [:]
    @Local var teams: [Team] = []
    @Local var search = ""
    @Local var teamFilter: String? = nil      // nil = all, "" = no team
    @Local var loading = false
    @Local var error: String? = nil
    @Local var showAdd = false
    @Local var resetFor: TeamProfile? = nil
    @Local var renaming: Team? = nil
    @Local var newTeamName = ""
    @Local var deleting: Team? = nil
    @Local var deletingPerson: TeamProfile? = nil

    // Hours
    @Local var month: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @Local var tasks: [TeamTask] = []
    @Local var running: [TeamTask] = []
    @Local var loadedAt: Date = Date()
    @Local var openTeams: Set<String> = []
    @Local var openPeople: Set<String> = []

    var body: some View {
        if embedded {
            VStack(alignment: .leading, spacing: 14) { inner }
        } else {
            SheetFrame(title: "Admin", subtitle: "Accounts, teams and hours for everyone", icon: "shield.lefthalf.filled", scrolls: false) {
                inner
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
            .frame(minWidth: 640, idealWidth: 860, maxWidth: 1100,
                   minHeight: min(540, Room.sheetHeight(windowSize)), idealHeight: min(700, Room.sheetHeight(windowSize)),
                   maxHeight: Room.sheetHeight(windowSize))
        }
    }

    @ViewBuilder
    private var inner: some View {
        HStack(spacing: 10) {
            Picker("", selection: $tab) {
                ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 380)
            Spacer()
            if loading { ProgressView().controlSize(.small) }
            Button { Task { await loadAll() } } label: { Image(systemName: "arrow.clockwise") }
                .buttonStyle(CircleIconButtonStyle(size: 28))
                .help("Refresh")
        }
        if let error {
            Label(error, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12)).foregroundStyle(Theme.pink)
                .fixedSize(horizontal: false, vertical: true)
        }
        Group {
            switch tab {
            case .stats: statsTab
            case .clients: clientsTab
            case .people: peopleTab
            case .teams: teamsTab
            }
        }
        .task { await loadAll() }
        .onChange(of: month) { _ in Task { await loadHours() } }
        .sheet(isPresented: $showAdd) {
            AdminAddAccountSheet(teams: teams) { await load() }.environmentObject(store)
        }
        .sheet(item: $resetFor) { p in
            ResetPasswordSheet(member: p, asAdmin: true).environmentObject(store)
        }
        .sheet(item: $renaming) { t in
            AdminTeamNameSheet(team: t) { await load() }.environmentObject(store)
        }
        .confirmationDialog("Delete the team “\(deleting?.name ?? "")”?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } })) {
            Button("Delete Team", role: .destructive) {
                if let t = deleting { run(["action": "admin_delete_team", "id": t.id], done: "Team deleted") }
            }
        } message: {
            Text("Only an empty team can be deleted. Its past tasks stay in the database, without a team.")
        }
        .confirmationDialog("Delete “\(deletingClient?.name ?? "")” from the list?", isPresented: Binding(
            get: { deletingClient != nil }, set: { if !$0 { deletingClient = nil } })) {
            Button("Delete", role: .destructive) {
                if let c = deletingClient { clientAction("Deleted “\(c.name)”") { try await cloud.deleteClient(c.id) } }
            }
        } message: {
            Text("Tasks already done for it keep the name and their hours. To only hide it from the pickers, use Remove / Close instead.")
        }
        .confirmationDialog("Delete “\(deletingPerson?.name ?? "")” for good?", isPresented: Binding(
            get: { deletingPerson != nil }, set: { if !$0 { deletingPerson = nil } })) {
            Button("Delete Account and All Their Tasks", role: .destructive) {
                if let p = deletingPerson {
                    run(["action": "admin_delete_user", "id": p.id], done: "\(p.name)'s account was deleted")
                }
            }
        } message: {
            Text("This can't be undone. \(deletingPerson?.email ?? "") can't sign in any more, and all their tasks and hours are deleted from every team's history. To keep their hours, take them out of their team instead.")
        }
    }

    // MARK: Hours

    private var monthChoices: [Date] {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        return (0..<12).compactMap { cal.date(byAdding: .month, value: -$0, to: start) }
    }

    private struct PersonStat: Identifiable {
        let id: String
        var name: String
        var seconds: Double = 0
        var done = 0
        var inProgress = 0
        var tasks: [TeamTask] = []
        var runningTask: TeamTask?
    }

    private struct TeamStat: Identifiable {
        let id: String          // team id, "" = no team
        var name: String
        var people: [PersonStat]
        var seconds: Double { people.reduce(0) { $0 + $1.seconds } }
        var done: Int { people.reduce(0) { $0 + $1.done } }
        var inProgress: Int { people.reduce(0) { $0 + $1.inProgress } }
        var workingNow: Int { people.filter { $0.runningTask != nil }.count }
    }

    private func personName(_ id: String, fallback: String?) -> String {
        people.first { $0.id == id }?.name ?? fallback ?? "Deleted account"
    }

    /// Hours go to the team the task was made in (a task stays with its team when someone moves).
    private var teamStats: [TeamStat] {
        let now = loadedAt
        var byTeam: [String: [String: PersonStat]] = [:]
        // Current members show even with no hours yet.
        for p in people where !p.isAdmin {
            let team = p.teamID ?? ""
            if team.isEmpty { continue }
            byTeam[team, default: [:]][p.id] = PersonStat(id: p.id, name: p.name)
        }
        for t in tasks {
            let team = t.teamID ?? ""
            var ps = byTeam[team, default: [:]][t.userID] ?? PersonStat(id: t.userID, name: personName(t.userID, fallback: t.ownerName))
            ps.seconds += t.liveSeconds(at: now)
            if t.status == "complete" { ps.done += 1 } else if t.status != "incoming" { ps.inProgress += 1 }
            ps.tasks.append(t)
            byTeam[team, default: [:]][t.userID] = ps
        }
        for t in running {
            let team = t.teamID ?? ""
            var ps = byTeam[team, default: [:]][t.userID] ?? PersonStat(id: t.userID, name: personName(t.userID, fallback: t.ownerName))
            ps.runningTask = t
            byTeam[team, default: [:]][t.userID] = ps
        }
        var out: [TeamStat] = []
        for t in teams {
            let list = (byTeam[t.id] ?? [:]).values.sorted { $0.seconds > $1.seconds }
            out.append(TeamStat(id: t.id, name: t.name, people: list))
        }
        if let loose = byTeam[""], !loose.isEmpty {
            out.append(TeamStat(id: "", name: "Without a team", people: loose.values.sorted { $0.seconds > $1.seconds }))
        }
        return out.sorted { $0.seconds > $1.seconds }
    }

    private var statsTab: some View {
        let stats = teamStats
        let total = stats.reduce(0.0) { $0 + $1.seconds }
        let done = stats.reduce(0) { $0 + $1.done }
        let now = stats.reduce(0) { $0 + $1.workingNow }
        let activePeople = stats.reduce(0) { $0 + $1.people.filter { $0.seconds > 0 }.count }
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Picker("", selection: $month) {
                    ForEach(monthChoices, id: \.self) { m in Text(Fmt.monthYear.string(from: m)).tag(m) }
                }
                .labelsHidden()
                .frame(maxWidth: 170)
                Spacer()
                Button { exportCSV(stats) } label: { Label("Export CSV", systemImage: "square.and.arrow.up") }
                    .buttonStyle(GlassButtonStyle(compact: true))
            }
            HStack(spacing: 10) {
                bigStat(Fmt.hours(total), "hours")
                bigStat("\(done)", "tasks done")
                bigStat("\(activePeople)", "people worked")
                bigStat("\(now)", "working now")
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(stats) { t in teamCard(t, of: total) }
                }
                .padding(2)
            }
        }
    }

    private func bigStat(_ value: String, _ label: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(value)
                .font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
                .gradientText()
                .lineLimit(1)
            Text(label).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
    }

    private func teamCard(_ t: TeamStat, of total: Double) -> some View {
        let open = openTeams.contains(t.id)
        return VStack(alignment: .leading, spacing: 8) {
            Button {
                if open { openTeams.remove(t.id) } else { openTeams.insert(t.id) }
            } label: {
                HStack(spacing: 10) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(t.name).font(.system(size: 14, weight: .semibold))
                        Text("\(t.people.count) people · \(t.done) done · \(t.inProgress) in progress" + (t.workingNow > 0 ? " · \(t.workingNow) working now" : ""))
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Spacer()
                    VStack(alignment: .trailing, spacing: 4) {
                        Text("\(Fmt.hours(t.seconds)) h")
                            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                        bar(total > 0 ? t.seconds / total : 0).frame(width: 120)
                    }
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(t.people) { p in personRowStats(p, teamID: t.id, teamSeconds: t.seconds) }
                if t.people.isEmpty {
                    Text("Nobody in this team yet.").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
        }
        .padding(12)
        .glassCard(radius: 14)
    }

    private func bar(_ fraction: Double) -> some View {
        GeometryReader { g in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.08))
                Capsule().fill(Theme.linear).frame(width: max(2, g.size.width * min(1, fraction)))
            }
        }
        .frame(height: 5)
    }

    private func personRowStats(_ p: PersonStat, teamID: String, teamSeconds: Double) -> some View {
        let key = teamID + "/" + p.id
        let open = openPeople.contains(key)
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                if open { openPeople.remove(key) } else { openPeople.insert(key) }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: open ? "chevron.down" : "chevron.right")
                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(.tertiary)
                    Circle().fill(p.runningTask != nil ? Theme.green : Color.primary.opacity(0.15)).frame(width: 7, height: 7)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(p.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                        if let r = p.runningTask {
                            Text("Working on “\(r.name)” · \(Fmt.clock(r.liveSeconds(at: loadedAt)))")
                                .font(.system(size: 10)).foregroundStyle(Theme.green).lineLimit(1)
                        } else {
                            Text("\(p.done) done · \(p.inProgress) in progress")
                                .font(.system(size: 10)).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text("\(Fmt.hours(p.seconds)) h")
                        .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    bar(teamSeconds > 0 ? p.seconds / teamSeconds : 0).frame(width: 80)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            if open {
                ForEach(p.tasks.sorted { ($0.workDate ?? $0.createdAt) > ($1.workDate ?? $1.createdAt) }) { t in
                    HStack(spacing: 8) {
                        Text(Fmt.nice.string(from: t.workDate ?? t.createdAt)).frame(width: 60, alignment: .leading)
                        Text((t.parentID == nil ? "" : "↳ ") + t.name).lineLimit(1)
                        if !t.client.isEmpty { Text("· \(t.client)").foregroundStyle(.secondary).lineLimit(1) }
                        Spacer()
                        Text(t.statusTitle).foregroundStyle(.secondary)
                        Text("\(Fmt.hours(t.liveSeconds(at: loadedAt))) h").monospacedDigit().frame(width: 60, alignment: .trailing)
                    }
                    .font(.system(size: 11))
                    .padding(.leading, 30)
                }
                if p.tasks.isEmpty {
                    Text("No tasks this month.").font(.system(size: 11)).foregroundStyle(.secondary).padding(.leading, 30)
                }
            }
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
    }

    private func exportCSV(_ stats: [TeamStat]) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "All teams - \(Fmt.monthYear.string(from: month)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Team,Person,Date,Task,Account,Status,Hours"]
        for t in stats {
            for p in t.people {
                for task in p.tasks.sorted(by: { ($0.workDate ?? $0.createdAt) < ($1.workDate ?? $1.createdAt) }) {
                    lines.append([q(t.name), q(p.name), Fmt.isoDay.string(from: task.workDate ?? task.createdAt),
                                  q(task.name), q(task.client), task.statusTitle,
                                  Fmt.hours(task.liveSeconds(at: loadedAt))].joined(separator: ","))
                }
            }
        }
        lines.append("")
        lines.append("Team,Person,Hours,Done,In progress")
        for t in stats {
            for p in t.people {
                lines.append([q(t.name), q(p.name), Fmt.hours(p.seconds), "\(p.done)", "\(p.inProgress)"].joined(separator: ","))
            }
            lines.append([q(t.name), q("Team total"), Fmt.hours(t.seconds), "\(t.done)", "\(t.inProgress)"].joined(separator: ","))
        }
        do {
            try ("\u{FEFF}" + lines.joined(separator: "\n")).write(to: url, atomically: true, encoding: .utf8)
            store.flash("Saved \(url.lastPathComponent)")
        } catch {
            self.error = error.localizedDescription
        }
    }

    // MARK: Clients and pitches

    private func hours(of c: Store.CloudClient) -> (seconds: Double, count: Int, support: Double) {
        let name = c.name.lowercased()
        let mine = tasks.filter { t in
            if let id = t.clientID { return id == c.id }
            return t.client.lowercased() == name
        }
        let secs = mine.reduce(0.0) { $0 + $1.liveSeconds(at: loadedAt) }
        let sup = mine.filter(\.support).reduce(0.0) { $0 + $1.liveSeconds(at: loadedAt) }
        return (secs, mine.count, sup)
    }

    private struct StrayName: Identifiable { var id: String { name }; let name: String; let seconds: Double }
    private struct ClientGroup: Identifiable { let id: String; let name: String; let list: [Store.CloudClient] }

    /// Client names used in this month's tasks that aren't in the list (old spellings).
    private var strayNames: [StrayName] {
        let known = Set(clientRows.map { $0.name.lowercased() })
        let ids = Set(clientRows.map(\.id))
        var out: [String: Double] = [:]
        for t in tasks where !t.client.isEmpty {
            if let id = t.clientID, ids.contains(id) { continue }
            if known.contains(t.client.lowercased()) { continue }
            out[t.client, default: 0] += t.liveSeconds(at: loadedAt)
        }
        return out.map { StrayName(name: $0.key, seconds: $0.value) }.sorted { $0.seconds > $1.seconds }
    }

    private var clientGroups: [ClientGroup] {
        let q = clientSearch.trimmingCharacters(in: .whitespaces)
        let shown = clientRows.filter { c in
            (showClosed || c.active) && (q.isEmpty || c.name.localizedCaseInsensitiveContains(q)
                                         || (c.teamName ?? "").localizedCaseInsensitiveContains(q))
        }
        let all = teams.map { (id: $0.id, name: $0.name) } + [(id: "", name: "Without a team")]
        return all.compactMap { g -> ClientGroup? in
            let list = shown.filter { ($0.teamID ?? "") == g.id }.sorted { a, b in
                if (a.kind == "pitch") != (b.kind == "pitch") { return a.kind != "pitch" }
                return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
            }
            return list.isEmpty ? nil : ClientGroup(id: g.id, name: g.name, list: list)
        }
    }

    private var clientsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            addClientBar
            Text("Only admins add clients, so everyone picks the same name. Each client and pitch belongs to the team that handles it; it shows in that team's New Task (pitches under Pitches), and anyone can pick it under Support.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            clientFilterBar
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    if clientRows.isEmpty {
                        Text("No clients yet. Add each team's clients above. (If adding fails, run the latest schema.sql in Supabase first.)")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(clientGroups) { g in groupCard(g) }
                    strayCard
                }
                .padding(2)
            }
        }
    }

    private var addClientBar: some View {
        HStack(spacing: 8) {
            TextField("New client or pitch", text: $newClientName)
                .textFieldStyle(.roundedBorder)
                .onSubmit(addClient)
            Picker("", selection: $newClientKind) {
                Text("Client").tag("client")
                Text("Pitch").tag("pitch")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 130)
            Picker("", selection: $newClientTeam) {
                Text("— Team —").tag(String?.none)
                ForEach(teams) { t in Text(t.name).tag(String?.some(t.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            Button { addClient() } label: { Label("Add", systemImage: "plus") }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(newClientName.trimmingCharacters(in: .whitespaces).isEmpty || newClientTeam == nil)
        }
    }

    private var clientFilterBar: some View {
        HStack(spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search clients or teams", text: $clientSearch).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
            Toggle("Show removed", isOn: $showClosed).font(.system(size: 12))
            Spacer()
            Picker("", selection: $month) {
                ForEach(monthChoices, id: \.self) { m in Text(Fmt.monthYear.string(from: m)).tag(m) }
            }
            .labelsHidden()
            .frame(maxWidth: 170)
            .help("Hours shown for this month")
        }
    }

    private func groupCard(_ g: ClientGroup) -> some View {
        let total = g.list.reduce(0.0) { $0 + hours(of: $1).seconds }
        let clients = g.list.filter { $0.kind != "pitch" }.count
        let pitches = g.list.count - clients
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(g.name).font(.system(size: 14, weight: .semibold))
                Text("\(clients) clients · \(pitches) pitches")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Text("\(Fmt.hours(total)) h").font(.system(size: 13, weight: .semibold, design: .rounded).monospacedDigit())
            }
            ForEach(g.list, id: \.id) { c in clientRow(c) }
        }
        .padding(12)
        .glassCard(radius: 14)
    }

    @ViewBuilder
    private var strayCard: some View {
        let stray = strayNames
        if !stray.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                Text("Names in this month's tasks that aren't in the list").font(.system(size: 13, weight: .semibold))
                Text("Old spellings from before clients came from here. Add the right client above; new tasks will use it.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                ForEach(stray) { s in
                    HStack {
                        Text(s.name).font(.system(size: 12))
                        Spacer()
                        Text("\(Fmt.hours(s.seconds)) h").font(.system(size: 12).monospacedDigit())
                        Button("Use this name") { newClientName = s.name }
                            .buttonStyle(GlassButtonStyle(compact: true))
                    }
                }
            }
            .padding(12)
            .glassCard(radius: 14)
        }
    }

    private func clientRow(_ c: Store.CloudClient) -> some View {
        let h = hours(of: c)
        let isPitch = c.kind == "pitch"
        return HStack(spacing: 8) {
            if editingClient == c.id {
                TextField("", text: $editClientText)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit {
                        let n = editClientText.trimmingCharacters(in: .whitespaces)
                        editingClient = nil
                        guard !n.isEmpty, n != c.name else { return }
                        clientAction("Renamed to “\(n)”") {
                            try await cloud.saveClient(id: c.id, name: n, teamID: c.teamID, kind: c.kind, active: c.active)
                        }
                    }
                    .frame(maxWidth: 240)
            } else {
                Text(c.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
            }
            if isPitch { tag("Pitch", Theme.pitch) }
            if !c.active { tag("Removed", Theme.orange) }
            Spacer(minLength: 8)
            Text("\(h.count) tasks").font(.system(size: 11)).foregroundStyle(.secondary)
            if h.support > 0 {
                Text("\(Fmt.hours(h.support)) h support").font(.system(size: 11)).foregroundStyle(Theme.blue)
                    .help("Hours other teams' people spent on it")
            }
            Text("\(Fmt.hours(h.seconds)) h")
                .font(.system(size: 12, weight: .medium, design: .rounded).monospacedDigit())
                .frame(width: 60, alignment: .trailing)
            Menu {
                Button("Rename…") { editingClient = c.id; editClientText = c.name }
                Menu("Move to Team") {
                    ForEach(teams) { t in
                        Button(t.name) {
                            clientAction("“\(c.name)” → \(t.name)") {
                                try await cloud.saveClient(id: c.id, name: c.name, teamID: t.id, kind: c.kind, active: c.active)
                            }
                        }
                        .disabled(c.teamID == t.id)
                    }
                }
                if !isPitch {
                    Divider()
                    if c.active {
                        Button("Remove from the lists (keep its hours)") {
                            clientAction("“\(c.name)” hidden") {
                                try await cloud.saveClient(id: c.id, name: c.name, teamID: c.teamID, kind: c.kind, active: false)
                            }
                        }
                    } else {
                        Button("Bring Back") {
                            clientAction("“\(c.name)” is back") {
                                try await cloud.saveClient(id: c.id, name: c.name, teamID: c.teamID, kind: c.kind, active: true)
                            }
                        }
                    }
                }
                Divider()
                Button("Delete…", role: .destructive) { deletingClient = c }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(.vertical, 6).padding(.horizontal, 8)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .opacity(c.active ? 1 : 0.6)
    }

    private func addClient() {
        let n = newClientName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, let team = newClientTeam else { return }
        let kind = newClientKind
        clientAction("Added “\(n)”") {
            try await cloud.saveClient(id: nil, name: n, teamID: team, kind: kind)
            newClientName = ""
        }
    }

    private func clientAction(_ done: String, _ work: @escaping () async throws -> Void) {
        error = nil
        Task { @MainActor in
            do {
                try await work()
                clientRows = await cloud.loadClients()
                store.flash(done)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    // MARK: People

    private var shownPeople: [TeamProfile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return people.filter { p in
            if let f = teamFilter {
                if f.isEmpty ? (p.teamID != nil || p.isAdmin) : p.teamID != f { return false }
            }
            if q.isEmpty { return true }
            return p.name.localizedCaseInsensitiveContains(q) || p.email.localizedCaseInsensitiveContains(q)
                || teamName(p.teamID).localizedCaseInsensitiveContains(q)
        }
        .sorted { a, b in
            if a.isAdmin != b.isAdmin { return a.isAdmin }
            let ta = teamName(a.teamID), tb = teamName(b.teamID)
            if ta != tb { return ta.isEmpty ? false : (tb.isEmpty ? true : ta < tb) }
            if a.isLeader != b.isLeader { return a.isLeader }
            return a.name.localizedCaseInsensitiveCompare(b.name) == .orderedAscending
        }
    }

    private var peopleTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                    TextField("Search name, email or team", text: $search).textFieldStyle(.plain)
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(.thinMaterial, in: Capsule())
                Picker("", selection: $teamFilter) {
                    Text("All teams").tag(String?.none)
                    Text("No team").tag(String?.some(""))
                    ForEach(teams) { t in Text(t.name).tag(String?.some(t.id)) }
                }
                .labelsHidden()
                .frame(minWidth: 120, maxWidth: 180)
                Button { showAdd = true } label: { Label("Add Account", systemImage: "person.badge.plus") }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
            Text("\(shownPeople.count) of \(people.count) accounts")
                .font(.system(size: 11)).foregroundStyle(.secondary)
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(shownPeople) { p in personRow(p) }
                }
                .padding(2)
            }
        }
    }

    private func personRow(_ p: TeamProfile) -> some View {
        let isMe = p.id == CloudAuth.shared.session?.userID.lowercased()
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(p.name).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                    if p.isAdmin { tag("Admin", Theme.coral) }
                    if p.banned { tag("Blocked", Theme.pink) }
                    if isMe { tag("You", Theme.blue) }
                    if !isValidEmail(p.email) { tag("Bad email", Theme.orange) }
                }
                Text(p.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .textSelection(.enabled)
                Text(lastSignIn[p.id].map { "Last sign-in \(Fmt.relative($0))" } ?? "Never signed in")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            // Team (admins are never in a team)
            if p.isAdmin {
                Text("—").foregroundStyle(.tertiary).frame(width: 150)
            } else {
                Menu {
                    ForEach(teams) { t in
                        Button(t.name) { update(p, ["team_id": t.id], done: "\(p.name) → \(t.name)") }
                            .disabled(p.teamID == t.id)
                    }
                    Divider()
                    Button("No team") { update(p, ["team_id": NSNull()], done: "\(p.name) is out of their team") }
                        .disabled(p.teamID == nil)
                } label: {
                    Text(p.teamID == nil ? "No team" : teamName(p.teamID)).lineLimit(1)
                }
                .menuStyle(.borderlessButton)
                .frame(width: 150)
                .help("Move to another team. Their past tasks stay with the old team.")
            }

            // Role
            Menu {
                Button("Member") { update(p, ["role": "member"], done: "\(p.name) is a member") }
                    .disabled(p.role == "member")
                Button("Leader") { update(p, ["role": "leader"], done: "\(p.name) is a leader") }
                    .disabled(p.role == "leader")
                Divider()
                Button("Admin (leaves their team)") { update(p, ["role": "admin"], done: "\(p.name) is an admin") }
                    .disabled(p.isAdmin)
            } label: {
                Text(p.isAdmin ? "Admin" : (p.isLeader ? "Leader" : "Member"))
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)

            Menu {
                Button("Reset Password…") { resetFor = p }
                if p.banned {
                    Button("Unblock (let them sign in)") {
                        run(["action": "admin_unban", "id": p.id], done: "\(p.name) can sign in again")
                    }
                }
                Button("Copy Email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.email, forType: .string)
                    store.flash("Copied")
                }
                Divider()
                Button("Delete Account…", role: .destructive) { deletingPerson = p }
                    .disabled(isMe)
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .padding(10)
        .glassCard(radius: 12)
    }

    private func tag(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .bold))
            .padding(.horizontal, 6).padding(.vertical, 2)
            .foregroundStyle(color)
            .background(color.opacity(0.15), in: Capsule())
    }

    // MARK: Teams

    private var teamsTab: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                TextField("New team name", text: $newTeamName)
                    .textFieldStyle(.roundedBorder)
                    .frame(maxWidth: 260)
                    .onSubmit(createTeam)
                Button { createTeam() } label: { Label("Create Team", systemImage: "plus") }
                    .buttonStyle(GradientButtonStyle(compact: true))
                    .disabled(newTeamName.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            ScrollView {
                LazyVStack(spacing: 8) {
                    ForEach(teams) { t in teamRow(t) }
                    freshStartCard
                    let loose = people.filter { $0.teamID == nil && !$0.isAdmin }.count
                    if loose > 0 {
                        Button {
                            teamFilter = ""; tab = .people
                        } label: {
                            Text("\(loose) account\(loose == 1 ? "" : "s") without a team →")
                                .font(.system(size: 12, weight: .medium))
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(Theme.orange)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, 4)
                    }
                }
                .padding(2)
            }
        }
    }

    private var freshStartCard: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text("Start Fresh").font(.system(size: 13, weight: .semibold))
                Text("Deletes every task and Modhesh link of every team. Accounts, teams and clients stay. Each person's Mongez drops its old tasks within 2 minutes and keeps a copy of them in its data folder.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("Start Fresh…") { confirmFresh = true }
                .buttonStyle(GlassButtonStyle(compact: true))
                .foregroundStyle(Theme.pink)
        }
        .padding(10)
        .glassCard(radius: 12)
        .confirmationDialog("Delete every task of every team?", isPresented: $confirmFresh) {
            Button("Delete All Tasks and Start Fresh", role: .destructive) {
                clientAction("All tasks deleted — fresh start") {
                    _ = try await CloudAPI.rpc("admin_start_fresh")
                    await loadHours()
                }
            }
        } message: {
            Text("This can't be undone in the database. Hours, Modhesh links and history go for everyone.")
        }
    }

    private func teamRow(_ t: Team) -> some View {
        let members = people.filter { $0.teamID == t.id }
        let leaders = members.filter { $0.isLeader }
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(t.name).font(.system(size: 13, weight: .semibold))
                Text("\(members.count) people · " + (leaders.isEmpty ? "no leader yet" : "leader: " + leaders.map(\.name).joined(separator: ", ")))
                    .font(.system(size: 11))
                    .foregroundStyle(leaders.isEmpty ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                    .lineLimit(2)
            }
            Spacer(minLength: 8)
            Button("Show People") { teamFilter = t.id; tab = .people }
                .buttonStyle(GlassButtonStyle(compact: true))
            Button("Rename…") { renaming = t }
                .buttonStyle(GlassButtonStyle(compact: true))
            Button { deleting = t } label: { Image(systemName: "trash") }
                .buttonStyle(CircleIconButtonStyle(size: 28))
                .disabled(!members.isEmpty)
                .help(members.isEmpty ? "Delete this team" : "Move everyone out of this team first")
        }
        .padding(10)
        .glassCard(radius: 12)
    }

    private func createTeam() {
        let n = newTeamName.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        newTeamName = ""
        run(["action": "admin_create_team", "name": n], done: "Team “\(n)” created")
    }

    // MARK: Data

    private func teamName(_ id: String?) -> String {
        guard let id else { return "" }
        return teams.first { $0.id == id }?.name ?? "Unknown team"
    }

    private func update(_ p: TeamProfile, _ fields: [String: Any], done: String) {
        var body = fields
        body["action"] = "admin_update_user"
        body["id"] = p.id
        run(body, done: done)
    }

    private func run(_ body: [String: Any], done: String) {
        error = nil
        Task { @MainActor in
            do {
                try await cloud.teamAdmin(body)
                store.flash(done)
                await load()
                await cloud.loadProfile()   // in case admins changed their own role
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    func loadAll() async {
        await load()
        await loadHours()
        clientRows = await cloud.loadClients()
    }

    func loadHours() async {
        let cal = Calendar.current
        let start = cal.dateInterval(of: .month, for: month)?.start ?? month
        let end = cal.date(byAdding: .month, value: 1, to: start) ?? start
        do {
            let r = try await cloud.loadAllTasks(from: start, to: end)
            tasks = r.inRange
            running = r.running
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await cloud.teamAdmin(["action": "admin_list"])
            let rows = r["profiles"] as? [[String: Any]] ?? []
            people = rows.compactMap { TeamProfile($0) }
            var signIns: [String: Date] = [:]
            for row in rows {
                if let id = (row["id"] as? String)?.lowercased(), let d = Cloud.date(row["last_sign_in_at"]) {
                    signIns[id] = d
                }
            }
            lastSignIn = signIns
            teams = (r["teams"] as? [[String: Any]] ?? []).compactMap { row in
                guard let id = row["id"] as? String else { return nil }
                return Team(id: id.lowercased(), name: row["name"] as? String ?? "")
            }
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }
}

// MARK: - Add account (admin)

struct AdminAddAccountSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let teams: [AdminView.Team]
    let onDone: () async -> Void

    @Local var name = ""
    @Local var email = ""
    @Local var password = suggestedPassword()
    @Local var teamID: String? = nil
    @Local var role = "member"
    @Local var sending = false
    @Local var error: String? = nil
    @Local var created: String? = nil

    private var canSend: Bool {
        !sending && isValidEmail(email) && password.count >= 6
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        SheetFrame(title: "Add Account", subtitle: "A member or leader in any team, or an admin", icon: "person.badge.plus") {
            if let created {
                Label("Account created ✓", systemImage: "checkmark.circle.fill")
                    .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
                Text(created)
                    .font(.system(size: 12, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                HStack {
                    Button("Copy") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(created, forType: .string)
                        store.flash("Copied")
                    }
                    .buttonStyle(GlassButtonStyle(compact: true))
                    Spacer()
                    Button("Add Another") {
                        self.created = nil
                        name = ""; email = ""; password = suggestedPassword()
                    }
                    .buttonStyle(GlassButtonStyle())
                    Button("Done") { dismiss() }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            } else {
                FieldRow(label: "Name") {
                    TextField("Full name", text: $name).textFieldStyle(.roundedBorder)
                }
                FieldRow(label: "Email") {
                    TextField("name@company.com", text: $email).textFieldStyle(.roundedBorder)
                        .font(.system(size: 15)).controlSize(.large)
                    EmailHint(email: email)
                }
                FieldRow(label: "Starting password") {
                    HStack {
                        TextField("", text: $password)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                        Button { password = suggestedPassword() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                            .buttonStyle(CircleIconButtonStyle(size: 26))
                    }
                }
                HStack(alignment: .top, spacing: 16) {
                    FieldRow(label: "Role") {
                        Picker("", selection: $role) {
                            Text("Member").tag("member")
                            Text("Leader").tag("leader")
                            Text("Admin").tag("admin")
                        }
                        .labelsHidden()
                    }
                    if role != "admin" {
                        FieldRow(label: "Team") {
                            Picker("", selection: $teamID) {
                                Text("No team").tag(String?.none)
                                ForEach(teams) { t in Text(t.name).tag(String?.some(t.id)) }
                            }
                            .labelsHidden()
                        }
                    }
                }
                if role == "admin" {
                    Text("Admins aren't in a team and don't time tasks: they manage accounts and teams and see everyone's hours.")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if let error {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.system(size: 12)).foregroundStyle(Theme.pink)
                        .fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Spacer()
                    Button("Cancel") { dismiss() }
                        .buttonStyle(GlassButtonStyle())
                        .keyboardShortcut(.cancelAction)
                    Button { send() } label: {
                        HStack(spacing: 6) {
                            if sending { ProgressView().controlSize(.small).tint(Theme.buttonInk) }
                            Text("Create Account")
                        }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                }
            }
        }
        .frame(width: 480)
    }

    private func send() {
        sending = true
        error = nil
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let p = password
        var body: [String: Any] = [
            "action": "admin_create_user",
            "name": name.trimmingCharacters(in: .whitespaces),
            "email": e,
            "password": p,
            "role": role,
        ]
        if let teamID, role != "admin" { body["team_id"] = teamID }
        Task { @MainActor in
            defer { sending = false }
            do {
                try await CloudSync.shared.teamAdmin(body)
                created = "Mongez account\nEmail: \(e)\nPassword: \(p)"
                await onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Rename team

struct AdminTeamNameSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let team: AdminView.Team
    let onDone: () async -> Void
    @Local var name = ""
    @Local var error: String? = nil

    var body: some View {
        SheetFrame(title: "Rename Team", subtitle: team.name, icon: "pencil") {
            TextField("Team name", text: $name)
                .textFieldStyle(.roundedBorder)
                .onAppear { name = team.name }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Rename") { save() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 400)
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            do {
                try await CloudSync.shared.teamAdmin(["action": "admin_rename_team", "id": team.id, "name": n])
                store.flash("Renamed to “\(n)”")
                await onDone()
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
