import SwiftUI
import AppKit

/// Admin window: every account and team. Admins add leaders and members, move people between
/// teams, change roles and passwords, and manage teams — no need to edit the database by hand.
/// Everything goes through the team-admin Edge Function (actions starting with admin_).
struct AdminView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared

    struct Team: Identifiable, Hashable {
        let id: String
        var name: String
    }

    enum Tab: String, CaseIterable, Identifiable {
        case people = "People", teams = "Teams"
        var id: String { rawValue }
    }

    @Local var tab: Tab = .people
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

    var body: some View {
        SheetFrame(title: "Admin", subtitle: "Accounts, teams and roles for everyone", icon: "shield.lefthalf.filled") {
            HStack(spacing: 10) {
                Picker("", selection: $tab) {
                    ForEach(Tab.allCases) { t in Text(t.rawValue).tag(t) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(maxWidth: 220)
                Spacer()
                if loading { ProgressView().controlSize(.small) }
                Button { Task { await load() } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(CircleIconButtonStyle(size: 28))
                    .help("Refresh")
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if tab == .people { peopleTab } else { teamsTab }
            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 640, idealWidth: 820, maxWidth: 1000, minHeight: 520, idealHeight: 660)
        .task { await load() }
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
    }

    // MARK: People

    private var shownPeople: [TeamProfile] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return people.filter { p in
            if let f = teamFilter {
                if f.isEmpty ? p.teamID != nil : p.teamID != f { return false }
            }
            if q.isEmpty { return true }
            return p.name.localizedCaseInsensitiveContains(q) || p.email.localizedCaseInsensitiveContains(q)
                || teamName(p.teamID).localizedCaseInsensitiveContains(q)
        }
        .sorted { a, b in
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
                    .disabled(teams.isEmpty && people.isEmpty)
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
                    if p.isAdmin { tag("Admin", Theme.purple) }
                    if isMe { tag("You", Theme.blue) }
                }
                Text(p.email).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
                    .textSelection(.enabled)
                Text(lastSignIn[p.id].map { "Last sign-in \(Fmt.relative($0))" } ?? "Never signed in")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
            }
            Spacer(minLength: 8)

            // Team
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

            // Role
            Menu {
                Button("Member") { update(p, ["role": "member"], done: "\(p.name) is a member") }
                    .disabled(!p.isLeader)
                Button("Leader") { update(p, ["role": "leader"], done: "\(p.name) is a leader") }
                    .disabled(p.isLeader)
                Divider()
                Button(p.isAdmin ? "Remove Admin" : "Make Admin") {
                    update(p, ["is_admin": !p.isAdmin], done: p.isAdmin ? "\(p.name) is no longer an admin" : "\(p.name) is an admin")
                }
            } label: {
                Text(p.isLeader ? "Leader" : "Member")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 90)

            Menu {
                Button("Reset Password…") { resetFor = p }
                Button("Copy Email") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(p.email, forType: .string)
                    store.flash("Copied")
                }
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
                    let loose = people.filter { $0.teamID == nil }.count
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
                await cloud.loadProfile()   // in case admins changed their own team or role
            } catch {
                self.error = error.localizedDescription
            }
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
    @Local var makeAdmin = false
    @Local var sending = false
    @Local var error: String? = nil
    @Local var created: String? = nil

    private var canSend: Bool {
        !sending && isValidEmail(email) && password.count >= 6
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        SheetFrame(title: "Add Account", subtitle: "A leader or member, in any team", icon: "person.badge.plus") {
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
                        name = ""; email = ""; password = suggestedPassword(); makeAdmin = false
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
                    FieldRow(label: "Team") {
                        Picker("", selection: $teamID) {
                            Text("No team").tag(String?.none)
                            ForEach(teams) { t in Text(t.name).tag(String?.some(t.id)) }
                        }
                        .labelsHidden()
                    }
                    FieldRow(label: "Role") {
                        Picker("", selection: $role) {
                            Text("Member").tag("member")
                            Text("Leader").tag("leader")
                        }
                        .labelsHidden()
                    }
                }
                Toggle("Admin too (can open this Admin window)", isOn: $makeAdmin)
                    .font(.system(size: 12))
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
                            if sending { ProgressView().controlSize(.small).tint(.white) }
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
            "is_admin": makeAdmin,
        ]
        if let teamID { body["team_id"] = teamID }
        Task { @MainActor in
            defer { sending = false }
            do {
                try await CloudSync.shared.teamAdmin(body)
                created = "TaskTimer account\nEmail: \(e)\nPassword: \(p)"
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
