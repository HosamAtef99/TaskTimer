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
    @Local var loadedAt: Date? = nil

    var body: some View {
        SheetFrame(title: cloud.teamName ?? "Team",
                   subtitle: "Everyone's tasks and live timers", icon: "person.3.fill") {
            controls
            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
            }
            nowStrip
            taskTable
            HStack {
                Text(loadedAt.map { "Updated \(Fmt.relative($0)) · refreshes every 30 seconds" } ?? "")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 900, height: 700)
        .task(id: month) {
            while !Task.isCancelled {
                await load()
                try? await Task.sleep(nanoseconds: 30_000_000_000)
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
        var lines = ["Date,Member,Task,Account,Status,Hours"]
        for t in filtered.sorted(by: { ($0.workDate ?? $0.createdAt) < ($1.workDate ?? $1.createdAt) }) {
            lines.append([
                Fmt.isoDay.string(from: t.workDate ?? t.createdAt),
                q(memberName(t.userID)), q(displayName(t)), q(t.client), t.statusTitle,
                Fmt.hours(t.liveSeconds(at: Date())),
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

struct AddMemberSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let onDone: () async -> Void

    @Local var name = ""
    @Local var email = ""
    @Local var password = suggestedPassword()
    @Local var sending = false
    @Local var error: String? = nil
    @Local var created: String? = nil

    var body: some View {
        SheetFrame(title: "Add Member", subtitle: "Creates their TaskTimer account in your team", icon: "person.badge.plus") {
            if let created {
                VStack(alignment: .leading, spacing: 8) {
                    Label("Account created ✓", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.green)
                    Text("Send them this, they sign in from Settings → Team:")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
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
                FieldRow(label: "Name") {
                    TextField("e.g. Mosab", text: $name).textFieldStyle(.roundedBorder)
                }
                FieldRow(label: "Email") {
                    TextField("name@company.com", text: $email).textFieldStyle(.roundedBorder)
                }
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
                    .disabled(sending || name.trimmingCharacters(in: .whitespaces).isEmpty
                              || !email.contains("@") || password.count < 6)
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
        Task { @MainActor in
            defer { sending = false }
            do {
                let r = try await CloudSync.shared.teamAdmin(["action": "create", "name": n, "email": e, "password": p])
                if (r["existing"] as? Bool) == true {
                    created = "\(e) already had a TaskTimer account and is now in your team.\nThey sign in with their current password."
                } else {
                    created = "TaskTimer account\nEmail: \(e)\nPassword: \(p)"
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
                try await CloudSync.shared.teamAdmin(["action": "reset", "id": member.id, "password": p])
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
