import SwiftUI
import AppKit

// Groups (1.32, Hosam's call): several tasks — an event's, say — that go to ONE Modhesh task with
// their hours added up. A group is a `TaskItem` with `isGroup` and no timer of its own; its tasks
// point to it with `groupID` and show inside its card, each with its own timer and tools. Link the
// group to a Modhesh task (Modhesh window) and press Done on the group: its tasks' hours, added up
// (rounded at Done like any task), go to that Modhesh task, and its open tasks are finished too.
// In the database a group's own `seconds` stay 0 (so team hours never count it twice); the total
// is in `group_seconds`, which the Chrome extension sends.

// MARK: - Group card in the list

struct GroupRow: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud = CloudSync.shared
    var group: TaskItem
    var labelsAbove = false
    @Local var editing = false
    @Local var confirmDelete = false
    @Local var folded = false

    var body: some View {
        let members = store.members(of: group.id)
        let running = members.contains { m in m.isRunning || store.subtasks(of: m.id).contains(where: { $0.isRunning }) }
        VStack(alignment: .leading, spacing: 8) {
            header(count: members.count)
            if !folded {
                if members.isEmpty {
                    Text("No tasks in this group yet. Right-click a task → Add to Group, or press the pencil.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 46)
                } else {
                    VStack(spacing: 6) {
                        ForEach(members) { m in
                            TaskRow(task: m, labelsAbove: labelsAbove && m.id == members.last?.id, nested: true)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard(radius: 18, highlight: running)
        .sheet(isPresented: $editing) {
            GroupSheet(groupID: group.id).environmentObject(store)
        }
        .confirmationDialog("Delete the group “\(group.name)”?", isPresented: $confirmDelete) {
            Button("Delete Group", role: .destructive) { store.delete(group.id) }
        } message: {
            Text("Its \(members.count) task\(members.count == 1 ? "" : "s") stay, out of the group.")
        }
    }

    private func header(count: Int) -> some View {
        let secs = store.seconds(of: group)
        return HStack(spacing: 12) {
            Button {
                withAnimation(.easeOut(duration: 0.18)) { folded.toggle() }
            } label: {
                Image(systemName: folded ? "square.stack.3d.up" : "square.stack.3d.up.fill")
            }
            .buttonStyle(CircleIconButtonStyle(size: 34))
            .help(folded ? "Show the group's tasks" : "Fold the group")

            VStack(alignment: .leading, spacing: 4) {
                Text(group.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                ViewThatFits(in: .horizontal) {
                    meta(count: count, status: true, client: true)
                    meta(count: count, status: false, client: true)
                    meta(count: count, status: false, client: false)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            VStack(alignment: .trailing, spacing: 2) {
                Text(group.status == .complete ? "\(Fmt.hoursColumn(secs)) h" : Fmt.clock(secs))
                    .font(.system(size: 13.5, weight: .semibold, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                Text("All its tasks")
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.tertiary)
                    .fixedSize()
            }
            .frame(minWidth: TaskRow.timeColumn, alignment: .trailing)
            .help("The group's tasks and their amends, added up — what goes to Modhesh")

            Button { editing = true } label: { Image(systemName: "pencil") }
                .buttonStyle(CircleIconButtonStyle(size: 27))
                .help("Edit Group: its name and its tasks")
            Button { store.requestDone(group.id) } label: {
                Text(doneLabel(group)).lineLimit(1).fixedSize().foregroundStyle(Theme.coral).fontWeight(.semibold)
                    .frame(minWidth: TaskRow.doneWidth)
            }
            .buttonStyle(GlassButtonStyle(compact: true))
            .help("Finish the group: its tasks' hours, added up, go to the Modhesh task it's linked to")
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button("Done…") { store.requestDone(group.id) }
            Button("Edit Group…") { editing = true }
            ModheshManualButton(task: group)
            Menu("Mark as") {
                ForEach(TaskStatus.choices) { s in
                    Button(s.title) { store.update(group.id) { $0.status = s } }
                }
            }
            Divider()
            Button("Delete Group (keep its tasks)", role: .destructive) { confirmDelete = true }
        }
    }

    private func meta(count: Int, status: Bool, client: Bool) -> some View {
        HStack(spacing: 6) {
            if status { StatusPill(status: group.status).fixedSize() }
            Text("Group · \(count) task\(count == 1 ? "" : "s")").fixedSize()
            if client, !store.clientName(group.clientID).isEmpty {
                Text(store.clientName(group.clientID)).lineLimit(1)
            }
            ModheshBadge(task: group)
            if cloud.missingGroupColumns {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(Theme.orange)
                    .help("Run the latest schema.sql in Supabase (SQL Editor) so the group's hours can go to Modhesh.")
            }
        }
    }
}

// MARK: - New / Edit Group

/// Name the group and tick its tasks. A task can be in one group: ticking a task of another
/// group moves it here.
struct GroupSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let groupID: UUID?
    var preselect: [UUID] = []

    @Local var name = ""
    @Local var picked: Set<UUID> = []
    @Local var search = ""
    @Local var showDone = false
    @Local var loaded = false

    private var group: TaskItem? { groupID.flatMap { store.task($0) } }

    /// Tasks that can go in: top-level tasks (not groups), unfinished first, then the newest.
    private var candidates: [TaskItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        return store.tasks
            .filter { t in
                guard t.parentID == nil, !t.isGroupItem else { return false }
                if picked.contains(t.id) { return true }
                if !showDone && t.status == .complete { return false }
                if q.isEmpty { return true }
                return t.name.localizedCaseInsensitiveContains(q)
                    || store.clientName(t.clientID).localizedCaseInsensitiveContains(q)
            }
            .sorted { a, b in
                let pa = picked.contains(a.id), pb = picked.contains(b.id)
                if pa != pb { return pa }
                return a.createdAt > b.createdAt
            }
            .prefix(300)
            .map { $0 }
    }

    private var total: TimeInterval {
        picked.compactMap { store.task($0) }.reduce(0) { $0 + store.groupSeconds($1.id) }
    }

    var body: some View {
        SheetFrame(title: group == nil ? "New Group" : "Edit Group",
                   subtitle: "Tasks that go to one Modhesh task, with their hours added up",
                   icon: "square.stack.3d.up", scrolls: false) {
            FieldRow(label: "Group name") {
                TextField("e.g. the event's name", text: $name)
                    .textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").foregroundStyle(Theme.teal)
                    TextField("Search tasks or clients", text: $search).textFieldStyle(.plain)
                }
                .font(.system(size: 12))
                .padding(.horizontal, 12).padding(.vertical, 7)
                .glassChip()
                Toggle("Show completed", isOn: $showDone)
                    .font(.system(size: 12))
                    .fixedSize()
            }
            ScrollView {
                VStack(spacing: 6) {
                    ForEach(candidates) { t in row(t) }
                    if candidates.isEmpty {
                        Text("No tasks here.").font(.system(size: 12)).foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity).padding(20)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 200, maxHeight: 340)
            HStack {
                Text("\(picked.count) task\(picked.count == 1 ? "" : "s") · \(Fmt.hours(total)) h")
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { save() } label: {
                    Label(group == nil ? "Make Group" : "Save", systemImage: "square.stack.3d.up")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || picked.isEmpty)
            }
            Text("Link the group to its Modhesh task in the Modhesh window, then press Done on the group: the hours of all its tasks go there together.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(width: 560)
        .onAppear(perform: load)
    }

    private func row(_ t: TaskItem) -> some View {
        let on = picked.contains(t.id)
        let other = store.group(of: t).flatMap { $0.id == groupID ? nil : $0 }
        return Button {
            if on { picked.remove(t.id) } else { picked.insert(t.id) }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: on ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 16))
                    .foregroundStyle(on ? AnyShapeStyle(Theme.teal) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(t.name).font(.system(size: 12, weight: .semibold)).lineLimit(1)
                    HStack(spacing: 6) {
                        Text(t.status.title)
                        if !store.clientName(t.clientID).isEmpty { Text("· " + store.clientName(t.clientID)) }
                        if let o = other { Text("· in “\(o.name)”").foregroundStyle(Theme.orange) }
                    }
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                Text("\(Fmt.hoursColumn(store.groupSeconds(t.id))) h")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6).padding(.horizontal, 10)
            .background(on ? Theme.teal.opacity(0.10) : Color.primary.opacity(0.035),
                        in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func load() {
        guard !loaded else { return }
        loaded = true
        if let g = group {
            name = g.name
            picked = Set(store.members(of: g.id).map(\.id))
        } else {
            picked = Set(preselect)
        }
    }

    private func save() {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, !picked.isEmpty else { return }
        if let g = group {
            store.update(g.id) { $0.name = n }
            store.setMembers(g.id, Array(picked))
            store.flash("“\(n)” · \(picked.count) task\(picked.count == 1 ? "" : "s")")
        } else {
            store.makeGroup(name: n, members: Array(picked))
            store.flash("Group “\(n)” made — link it to its Modhesh task in Modhesh")
        }
        dismiss()
    }
}
