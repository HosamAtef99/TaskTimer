import SwiftUI
import AppKit
import UniformTypeIdentifiers

/// Team leader's view: who is working on what right now, and every task of the team by month.
struct TeamView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared

    @Local var month: Date = Calendar.current.dateInterval(of: .month, for: Date())?.start ?? Date()
    @Local var members: [TeamProfile] = []
    @Local var tasks: [TeamTask] = []
    @Local var loading = false
    @Local var error: String? = nil
    @Local var memberFilter: String = ""      // "" = everyone
    @Local var statusFilter: String = ""      // "" = all
    @Local var search = ""
    @Local var showAssign = false
    @Local var showAddMember = false
    @Local var resetFor: TeamProfile? = nil
    @Local var removeTarget: TeamProfile? = nil
    @Local var section = "tasks"           // "tasks" | "summary"
    @Local var period = "month"
    @Local var loadedAt: Date? = nil
    @Local var cursor: Date? = nil

    var body: some View {
        SheetFrame(title: cloud.teamName ?? "Team",
                   subtitle: "Everyone's tasks and live timers", icon: "person.3.fill") {
            controls
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }
            if section == "summary" {
                TeamSummaryView(month: month, monthTasks: tasks, members: members, period: $period)
                    .environmentObject(store)
            } else {
                nowStrip
                taskTable
            }
            HStack {
                Text(loadedAt.map { "Updated \(Fmt.relative($0)) · refreshes every minute" } ?? "")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 900, height: 700)
        .onAppear {
            if store.teamReportRequest {
                store.teamReportRequest = false
                section = "summary"
                period = "lastWeek"
            }
        }
        .task(id: month) {
            await load()
            // Then only what changed, once a minute (keeps the free database allowance).
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                if Task.isCancelled { break }
                await refresh()
            }
        }
        .sheet(isPresented: $showAssign) {
            AssignTaskSheet(members: members) { await load() }
                .environmentObject(store)
        }
        .sheet(isPresented: $showAddMember) {
            AddMemberSheet { await load() }
                .environmentObject(store)
        }
        .sheet(item: $resetFor) { m in
            ResetPasswordSheet(member: m)
                .environmentObject(store)
        }
        .confirmationDialog("Remove \(removeTarget?.name ?? "") from the team?",
                            isPresented: Binding(get: { removeTarget != nil },
                                                 set: { if !$0 { removeTarget = nil } })) {
            Button("Remove", role: .destructive) {
                if let m = removeTarget { remove(m) }
            }
        } message: {
            Text("Their account and their past tasks stay — the tasks remain in your team's history. Another team leader can add them to their team.")
        }
    }

    // MARK: Controls

    private var monthChoices: [Date] {
        let cal = Calendar.current
        let now = cal.dateInterval(of: .month, for: Date())?.start ?? Date()
        return (0..<12).compactMap { cal.date(byAdding: .month, value: -$0, to: now) }
    }

    private var controls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $section) {
                Text("Tasks").tag("tasks")
                Text("Summary").tag("summary")
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Picker("", selection: $month) {
                ForEach(monthChoices, id: \.self) { m in
                    Text(Fmt.monthYear.string(from: m)).tag(m)
                }
            }
            .labelsHidden().frame(width: 160)

            Picker("", selection: $memberFilter) {
                Text("Everyone").tag("")
                ForEach(members) { m in Text(m.name).tag(m.id) }
            }
            .labelsHidden().frame(width: 170)

            Picker("", selection: $statusFilter) {
                Text("All statuses").tag("")
                Text("Incoming").tag("incoming")
                Text("In Progress").tag("active")
                Text("Completed").tag("complete")
            }
            .labelsHidden().frame(width: 130)

            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Task or account", text: $search).textFieldStyle(.plain)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())

            Spacer()

            Button { Task { @MainActor in await load() } } label: {
                if loading { ProgressView().controlSize(.small) } else { Image(systemName: "arrow.clockwise") }
            }
            .buttonStyle(CircleIconButtonStyle(size: 30))
            .help("Refresh")
            Button { exportCSV() } label: { Image(systemName: "square.and.arrow.up") }
                .buttonStyle(CircleIconButtonStyle(size: 30))
                .help("Export these tasks as a CSV file (opens in Excel / Google Sheets)")
            Button { showAddMember = true } label: { Label("Add Member", systemImage: "person.badge.plus") }
                .buttonStyle(GlassButtonStyle(compact: true))
                .help("Create an account for someone in your team")
            Button { showAssign = true } label: { Label("Assign Task", systemImage: "plus") }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(members.isEmpty)
        }
    }

    // MARK: Now

    private var nowStrip: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 10) {
                ForEach(members) { m in
                    memberCard(m)
                }
            }
            .padding(2)
        }
        .frame(height: 96)
    }

    private func memberCard(_ m: TeamProfile) -> some View {
        let mine = tasks.filter { $0.userID == m.id }
        let running = mine.first { $0.isRunning }
        let monthSecs = mine.filter { Calendar.current.isDate($0.createdAt, equalTo: month, toGranularity: .month) }
            .reduce(0) { $0 + $1.liveSeconds(at: store.now) }
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle().fill(running != nil ? Theme.green : Color.secondary.opacity(0.4)).frame(width: 8, height: 8)
                Text(m.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                if m.isLeader {
                    Text("Leader").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.purple)
                }
            }
            if let r = running {
                Text(displayName(r)).font(.system(size: 11)).lineLimit(1)
                Text(Fmt.clock(r.liveSeconds(at: store.now)))
                    .font(.system(size: 15, weight: .semibold, design: .rounded).monospacedDigit())
                    .gradientText()
            } else {
                Text("Idle").font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
            Text("\(Fmt.hours(monthSecs)) h this month · \(mine.filter { $0.status == "incoming" }.count) incoming")
                .font(.system(size: 10)).foregroundStyle(.tertiary)
        }
        .padding(10)
        .frame(width: 190, height: 88, alignment: .topLeading)
        .glassCard(radius: 12, highlight: running != nil)
        .onTapGesture { memberFilter = memberFilter == m.id ? "" : m.id }
        .help("Click to show only \(m.name)'s tasks · right-click for account options")
        .contextMenu {
            if m.id != CloudAuth.shared.session?.userID {
                Button("Reset Password…") { resetFor = m }
                Button("Remove from Team…", role: .destructive) { removeTarget = m }
            }
            Button("Copy Email") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(m.email, forType: .string)
            }
        }
    }

    // MARK: Table

    private var filtered: [TeamTask] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        return tasks.filter { t in
            guard cal.isDate(t.createdAt, equalTo: month, toGranularity: .month) || t.isRunning else { return false }
            if !memberFilter.isEmpty && t.userID != memberFilter { return false }
            if !statusFilter.isEmpty && t.status != statusFilter { return false }
            if !q.isEmpty && !displayName(t).localizedCaseInsensitiveContains(q)
                && !t.client.localizedCaseInsensitiveContains(q) { return false }
            return true
        }
    }

    private var taskTable: some View {
        let rows = filtered
        let total = rows.reduce(0) { $0 + $1.liveSeconds(at: store.now) }
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(text: "\(rows.count) tasks · \(Fmt.hours(total)) h")
                Spacer()
            }
            HStack(spacing: 0) {
                header("Date", 70)
                header("Member", 130)
                header("Task", nil)
                header("Account", 150)
                header("Status", 90)
                header("Hours", 60)
            }
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { t in
                        HStack(spacing: 0) {
                            cell(Fmt.nice.string(from: t.workDate ?? t.createdAt), 70, secondary: true)
                            cell(memberName(t.userID), 130)
                            HStack(spacing: 6) {
                                if t.isRunning {
                                    Image(systemName: "record.circle").foregroundStyle(Theme.green).font(.system(size: 10))
                                }
                                Text(displayName(t)).lineLimit(1)
                                if t.assignedBy != nil {
                                    Image(systemName: "arrow.down.circle").font(.system(size: 10)).foregroundStyle(.tertiary)
                                        .help("Assigned by the leader")
                                }
                            }
                            .font(.system(size: 12))
                            .frame(maxWidth: .infinity, alignment: .leading)
                            cell(t.client.isEmpty ? "—" : t.client, 150, secondary: true)
                            Text(t.statusTitle)
                                .font(.system(size: 10, weight: .semibold))
                                .foregroundStyle(statusColor(t.status))
                                .frame(width: 90, alignment: .leading)
                            Text(Fmt.hours(t.liveSeconds(at: store.now)))
                                .font(.system(size: 12, weight: .medium).monospacedDigit())
                                .frame(width: 60, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(t.isRunning ? 0.08 : 0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                }
            }
            .overlay {
                if rows.isEmpty && !loading {
                    Text(members.isEmpty ? "No team members yet." : "No tasks for this filter.")
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func header(_ s: String, _ width: CGFloat?) -> some View {
        Text(s.uppercased())
            .font(.system(size: 9, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(.secondary)
            .frame(width: width, alignment: s == "Hours" ? .trailing : .leading)
            .frame(maxWidth: width == nil ? .infinity : nil, alignment: .leading)
            .padding(.horizontal, width == nil ? 0 : 0)
            .padding(.leading, s == "Date" ? 10 : 0)
            .padding(.trailing, s == "Hours" ? 10 : 0)
    }

    private func cell(_ s: String, _ width: CGFloat, secondary: Bool = false) -> some View {
        Text(s)
            .font(.system(size: 12))
            .foregroundStyle(secondary ? AnyShapeStyle(HierarchicalShapeStyle.secondary) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .lineLimit(1)
            .frame(width: width, alignment: .leading)
    }

    private func statusColor(_ s: String) -> Color {
        switch s {
        case "incoming": return Theme.purple
        case "complete": return Theme.green
        default: return Theme.blue
        }
    }

    private func memberName(_ id: String) -> String {
        if let m = members.first(where: { $0.id == id }) { return m.name }
        // Someone who has left the team: the name saved on their tasks.
        if let n = tasks.first(where: { $0.userID == id && !($0.ownerName ?? "").isEmpty })?.ownerName { return n + " (left)" }
        return "—"
    }

    private func displayName(_ t: TeamTask) -> String {
        if let p = t.parentID, let parent = tasks.first(where: { $0.id == p }) { return "\(parent.name) - \(t.name)" }
        return t.name
    }

    // MARK: Actions

    private func load() async {
        loading = true
        defer { loading = false }
        do {
            let r = try await cloud.loadTeam(month: month)
            members = r.members
            tasks = r.tasks
            cursor = r.tasks.compactMap(\.updatedAt).max() ?? Date().addingTimeInterval(-60)
            error = nil
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    /// Merges the tasks that changed since the last look.
    private func refresh() async {
        guard let since = cursor else { return await load() }
        do {
            let changed = try await cloud.teamChanges(since: since)
            guard !changed.isEmpty else { loadedAt = Date(); return }
            var byID = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
            for t in changed {
                if t.deleted { byID.removeValue(forKey: t.id) } else { byID[t.id] = t }
            }
            tasks = byID.values.sorted { $0.createdAt > $1.createdAt }
            cursor = max(since, changed.compactMap(\.updatedAt).max() ?? since)
            if changed.contains(where: { t in !members.contains(where: { $0.id == t.userID }) }) {
                members = (try? await cloud.loadTeam(month: month).members) ?? members
            }
            error = nil
            loadedAt = Date()
        } catch {
            self.error = error.localizedDescription
        }
    }

    private func remove(_ m: TeamProfile) {
        removeTarget = nil
        Task { @MainActor in
            do {
                try await cloud.teamAdmin(["action": "remove", "id": m.id])
                store.flash("Removed \(m.name) from the team")
                await load()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }

    private func exportCSV() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.commaSeparatedText]
        panel.nameFieldStringValue = "\(cloud.teamName ?? "Team") - \(Fmt.monthYear.string(from: month)).csv"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        var lines = ["Date,Member,Task,Account,Status,Hours,Deliverables,Stars"]
        for t in filtered.sorted(by: { ($0.workDate ?? $0.createdAt) < ($1.workDate ?? $1.createdAt) }) {
            lines.append([
                Fmt.isoDay.string(from: t.workDate ?? t.createdAt),
                q(memberName(t.userID)), q(displayName(t)), q(t.client), t.statusTitle,
                Fmt.hours(t.liveSeconds(at: Date())),
                t.deliverables.map { String($0) } ?? "",
                t.rating.map { String($0) } ?? "",
            ].joined(separator: ","))
        }
        // The BOM lets Excel read Arabic names correctly.
        let text = "\u{FEFF}" + lines.joined(separator: "\n")
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
            store.flash("Exported \(filtered.count) tasks")
        } catch {
            store.flash("Export failed: \(error.localizedDescription)")
        }
    }
}

// MARK: - Assign a task

struct AssignTaskSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let members: [TeamProfile]
    let onDone: () async -> Void

    @Local var memberID: String = ""
    @Local var name = ""
    @Local var client = ""
    @Local var sending = false
    @Local var error: String? = nil

    var body: some View {
        SheetFrame(title: "Assign Task", subtitle: "It goes to their Incoming within a minute", icon: "tray.and.arrow.down.fill") {
            FieldRow(label: "To") {
                Picker("", selection: $memberID) {
                    Text("— Choose —").tag("")
                    ForEach(members) { m in Text(m.name).tag(m.id) }
                }
                .labelsHidden()
            }
            FieldRow(label: "Task name") {
                TextField("e.g. Ramadan Promo 15s", text: $name).textFieldStyle(.roundedBorder)
            }
            FieldRow(label: "Client / Account") {
                HStack(spacing: 8) {
                    TextField("Account", text: $client).textFieldStyle(.roundedBorder)
                    if !store.clients.isEmpty {
                        Menu {
                            ForEach(store.clients) { c in Button(c.name) { client = c.name } }
                        } label: { Text("Pick") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                    }
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small).tint(.white) }
                        Text("Assign")
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(sending || memberID.isEmpty || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 460)
    }

    private func send() {
        sending = true
        error = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        let c = client.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            defer { sending = false }
            do {
                try await CloudSync.shared.assign(to: memberID, name: n, client: c)
                await onDone()
                store.flash("Assigned “\(n)”")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Team accounts (leader)

/// A readable starting password the leader can pass on; the member changes it after signing in.
func suggestedPassword() -> String {
    let words = ["tiger", "river", "pixel", "cloud", "frame", "orbit", "lemon", "comet", "maple", "storm"]
    let w = words.randomElement() ?? "frame"
    return "\(w.prefix(1).uppercased())\(w.dropFirst())-\(Int.random(in: 1000...9999))"
}

/// name@company.com — the same check the server does.
func isValidEmail(_ s: String) -> Bool {
    let e = s.trimmingCharacters(in: .whitespaces)
    return e.range(of: #"^[^\s@]+@[^\s@]+\.[^\s@]{2,}$"#, options: .regularExpression) != nil
}

/// Shows "That email isn't valid" under an email field once something was typed.
struct EmailHint: View {
    let email: String
    var body: some View {
        if !email.trimmingCharacters(in: .whitespaces).isEmpty && !isValidEmail(email) {
            Label("That email isn't valid — it should look like name@company.com", systemImage: "exclamationmark.circle")
                .font(.system(size: 11)).foregroundStyle(Theme.pink)
        }
    }
}

struct AddMemberSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let onDone: () async -> Void

    enum Mode: String, CaseIterable, Identifiable {
        case new = "New account", existing = "Existing account"
        var id: String { rawValue }
    }

    @Local var mode: Mode = .new
    @Local var name = ""
    @Local var email = ""
    @Local var password = suggestedPassword()
    @Local var sending = false
    @Local var error: String? = nil
    @Local var created: String? = nil

    private var canSend: Bool {
        guard !sending, isValidEmail(email) else { return false }
        if mode == .existing { return true }
        return !name.trimmingCharacters(in: .whitespaces).isEmpty && password.count >= 6
    }

    var body: some View {
        SheetFrame(title: "Add Member", subtitle: mode == .new ? "Creates their TaskTimer account in your team"
                                                               : "Someone who already has a TaskTimer account", icon: "person.badge.plus") {
            if let created {
                VStack(alignment: .leading, spacing: 8) {
                    Label(mode == .new ? "Done ✓" : "Added to your team ✓", systemImage: "checkmark.circle.fill")
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
                }
            } else {
                Picker("", selection: $mode) {
                    ForEach(Mode.allCases) { m in Text(m.rawValue).tag(m) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .onChange(of: mode) { _ in error = nil }

                if mode == .new {
                    FieldRow(label: "Name") {
                        TextField("e.g. Mosab", text: $name).textFieldStyle(.roundedBorder)
                    }
                }
                FieldRow(label: "Email") {
                    TextField("name@company.com", text: $email).textFieldStyle(.roundedBorder)
                        .font(.system(size: 15)).controlSize(.large)
                    EmailHint(email: email)
                }
                if mode == .new {
                    FieldRow(label: "Starting password") {
                        HStack {
                            TextField("", text: $password)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                            Button { password = suggestedPassword() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                                .buttonStyle(CircleIconButtonStyle(size: 26))
                                .help("Another password")
                        }
                        Text("They can change it after signing in.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                } else {
                    Text("For someone who was removed from another team (or never had one). They keep their password and their past tasks. If they're still in another team, that team's leader has to remove them first.")
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
                            if sending { ProgressView().controlSize(.small).tint(.white) }
                            Text(mode == .new ? "Create Account" : "Add to Team")
                        }
                    }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSend)
                }
            }
        }
        .frame(width: 460)
    }

    private func send() {
        sending = true
        error = nil
        let n = name.trimmingCharacters(in: .whitespaces)
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        let p = password
        let m = mode
        Task { @MainActor in
            defer { sending = false }
            do {
                if m == .existing {
                    let r = try await CloudSync.shared.teamAdmin(["action": "add_existing", "email": e])
                    let who = (r["name"] as? String).map { "\($0) (\(e))" } ?? e
                    created = "\(who) is now in your team.\nThey sign in with their current password."
                } else {
                    let r = try await CloudSync.shared.teamAdmin(["action": "create", "name": n, "email": e, "password": p])
                    if (r["existing"] as? Bool) == true {
                        created = "\(e) already had a TaskTimer account and is now in your team.\nThey sign in with their current password."
                    } else {
                        created = "TaskTimer account\nEmail: \(e)\nPassword: \(p)"
                    }
                }
                await onDone()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

struct ResetPasswordSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let member: TeamProfile
    /// Admins reset anyone's password; leaders only their team's.
    var asAdmin = false

    @Local var password = suggestedPassword()
    @Local var sending = false
    @Local var error: String? = nil

    var body: some View {
        SheetFrame(title: "Reset Password", subtitle: "\(member.name) · \(member.email)", icon: "key.fill") {
            FieldRow(label: "New password") {
                HStack {
                    TextField("", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 12, design: .monospaced))
                    Button { password = suggestedPassword() } label: { Image(systemName: "arrow.triangle.2.circlepath") }
                        .buttonStyle(CircleIconButtonStyle(size: 26))
                }
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small).tint(.white) }
                        Text("Reset & Copy")
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(sending || password.count < 6)
            }
        }
        .frame(width: 440)
    }

    private func send() {
        sending = true
        error = nil
        let p = password
        Task { @MainActor in
            defer { sending = false }
            do {
                try await CloudSync.shared.teamAdmin(["action": asAdmin ? "admin_reset" : "reset", "id": member.id, "password": p])
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString("TaskTimer\nEmail: \(member.email)\nNew password: \(p)", forType: .string)
                store.flash("Password reset — copied to send to \(member.name)")
                dismiss()
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}

// MARK: - Summary (month / week)

struct TeamSummaryView: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud = CloudSync.shared
    let month: Date
    let monthTasks: [TeamTask]
    let members: [TeamProfile]
    @Binding var period: String          // "month" | "thisWeek" | "lastWeek"

    @Local var weekTasks: [TeamTask] = []
    @Local var weekMembers: [TeamProfile] = []
    @Local var loading = false
    @Local var error: String? = nil

    struct Row: Identifiable {
        let id: String
        let name: String
        let count: Int
        let completed: Int
        let seconds: Double
    }

    private var range: (from: Date, to: Date)? {
        guard let thisWeek = CloudSync.weekStart(of: Date()) else { return nil }
        let cal = Calendar.current
        switch period {
        case "thisWeek":
            return (thisWeek, cal.date(byAdding: .day, value: 7, to: thisWeek) ?? Date())
        case "lastWeek":
            return (cal.date(byAdding: .day, value: -7, to: thisWeek) ?? thisWeek, thisWeek)
        default:
            return nil
        }
    }

    private var tasks: [TeamTask] {
        if period == "month" {
            return monthTasks.filter { Calendar.current.isDate($0.createdAt, equalTo: month, toGranularity: .month) }
        }
        return weekTasks
    }

    private var allMembers: [TeamProfile] { period == "month" || weekMembers.isEmpty ? members : weekMembers }

    private var title: String {
        if period == "month" { return Fmt.monthYear.string(from: month) }
        guard let r = range else { return "" }
        let end = Calendar.current.date(byAdding: .day, value: -1, to: r.to) ?? r.to
        return "Week of \(Fmt.nice.string(from: r.from)) – \(Fmt.nice.string(from: end))"
    }

    var body: some View {
        let rows = tasks
        let now = store.now
        let total = rows.reduce(0) { $0 + $1.liveSeconds(at: now) }
        let byAccount = Self.group(rows, now: now, key: { $0.client.isEmpty ? "No account" : $0.client }, name: { $0 })
        let byMember = Self.group(rows, now: now, key: { $0.userID }, name: { memberName($0) })

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Picker("", selection: $period) {
                    Text(Fmt.monthYear.string(from: month)).tag("month")
                    Text("This week").tag("thisWeek")
                    Text("Last week").tag("lastWeek")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 360)
                if loading { ProgressView().controlSize(.small) }
                Spacer()
                Button {
                    let text = Self.reportText(title: "\(cloud.teamName ?? "Team") — \(title)", tasks: rows, now: now,
                                               byMember: byMember, byAccount: byAccount)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(text, forType: .string)
                    store.flash("Report copied — paste it in WhatsApp or email")
                } label: { Label("Copy Report", systemImage: "doc.on.doc") }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }

            HStack(spacing: 10) {
                stat("Hours", Fmt.hours(total))
                stat("Tasks", "\(rows.count)")
                stat("Completed", "\(rows.filter { $0.status == "complete" }.count)")
                stat("In Progress", "\(rows.filter { $0.status == "active" }.count)")
                stat("Incoming", "\(rows.filter { $0.status == "incoming" }.count)")
            }

            HStack(alignment: .top, spacing: 14) {
                table("By account", byAccount, total: total)
                table("By member", byMember, total: total)
            }
        }
        .task(id: period) { await loadWeek() }
    }

    private func stat(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionLabel(text: label)
            Text(value).font(.system(size: 22, weight: .semibold, design: .rounded).monospacedDigit())
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12)
    }

    private func table(_ title: String, _ rows: [Row], total: Double) -> some View {
        let maxSecs = rows.map(\.seconds).max() ?? 1
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: title)
            ScrollView {
                VStack(spacing: 4) {
                    ForEach(rows) { r in
                        HStack(spacing: 8) {
                            Text(r.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                .frame(width: 150, alignment: .leading)
                            GeometryReader { g in
                                Capsule().fill(Theme.linear)
                                    .frame(width: max(3, g.size.width * CGFloat(r.seconds / max(maxSecs, 1))))
                            }
                            .frame(height: 6)
                            Text("\(r.count)").font(.system(size: 11)).foregroundStyle(.secondary)
                                .frame(width: 28, alignment: .trailing)
                            Text(Fmt.hours(r.seconds)).font(.system(size: 12, weight: .semibold).monospacedDigit())
                                .frame(width: 44, alignment: .trailing)
                        }
                        .padding(.horizontal, 10).padding(.vertical, 6)
                        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 8))
                    }
                    if rows.isEmpty {
                        Text("Nothing yet.").font(.system(size: 12)).foregroundStyle(.secondary).padding(.vertical, 20)
                    }
                }
            }
            HStack {
                Text("tasks · hours").font(.system(size: 9)).foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private func memberName(_ id: String) -> String {
        if let m = allMembers.first(where: { $0.id == id }) { return m.name }
        if let n = tasks.first(where: { $0.userID == id })?.ownerName, !n.isEmpty { return n + " (left)" }
        return "—"
    }

    private func loadWeek() async {
        guard let r = range else { return }
        loading = true
        defer { loading = false }
        do {
            let res = try await cloud.loadTasks(from: r.from, to: r.to)
            weekTasks = res.tasks
            weekMembers = res.members
            error = nil
        } catch {
            self.error = error.localizedDescription
        }
    }

    static func group(_ tasks: [TeamTask], now: Date, key: (TeamTask) -> String, name: (String) -> String) -> [Row] {
        var buckets: [String: [TeamTask]] = [:]
        for t in tasks { buckets[key(t), default: []].append(t) }
        return buckets.map { k, list in
            Row(id: k, name: name(k), count: list.count,
                completed: list.filter { $0.status == "complete" }.count,
                seconds: list.reduce(0) { $0 + $1.liveSeconds(at: now) })
        }
        .sorted { $0.seconds > $1.seconds }
    }

    /// Plain text to paste in WhatsApp or an email.
    static func reportText(title: String, tasks: [TeamTask], now: Date, byMember: [Row], byAccount: [Row]) -> String {
        let total = tasks.reduce(0) { $0 + $1.liveSeconds(at: now) }
        var lines = [title,
                     "\(tasks.count) tasks · \(Fmt.hours(total)) h · \(tasks.filter { $0.status == "complete" }.count) completed",
                     "",
                     "By member:"]
        lines += byMember.map { "• \($0.name): \(Fmt.hours($0.seconds)) h (\($0.count) tasks, \($0.completed) completed)" }
        lines += ["", "By account:"]
        lines += byAccount.map { "• \($0.name): \(Fmt.hours($0.seconds)) h (\($0.count) tasks)" }
        return lines.joined(separator: "\n")
    }
}
