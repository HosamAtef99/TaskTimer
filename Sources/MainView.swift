import SwiftUI
import AppKit

enum TaskFilter: String, CaseIterable, Identifiable {
    case incoming = "Incoming", inProgress = "In Progress", complete = "Completed", all = "All"
    var id: String { rawValue }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @Local var filter: TaskFilter = .inProgress
    @Local var month: Date? = nil      // nil = all months
    @Local var search = ""
    @Local var showClients = false
    @Local var showTeam = false
    @Local var showModhesh = false
    @Local var width: CGFloat = 900
    @ObservedObject var cloud = CloudSync.shared

    /// Layout follows the window width so nothing gets cut off when it's made smaller.
    private var compact: Bool { width < 780 }
    private var narrow: Bool { width < 640 }

    var body: some View {
        ZStack(alignment: .bottom) {
            GlowBackground()

            VStack(spacing: narrow ? 12 : 16) {
                header
                UpdateBanner()
                HeroCard(compact: compact)
                listControls
                taskList
            }
            .padding(.horizontal, narrow ? 12 : (compact ? 16 : 22))
            .padding(.top, 30)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)
            .background(GeometryReader { g in
                Color.clear
                    .onAppear { width = g.size.width }
                    .onChange(of: g.size.width) { width = $0 }
            })

            if let t = store.toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCard(radius: 20, highlight: true)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 470, minHeight: 560)
        .sheet(item: $store.doneTarget) { target in
            if Features.sheet {
                SheetDoneSheet(taskID: target.id).environmentObject(store)
            } else {
                DoneSheet(taskID: target.id).environmentObject(store)
            }
        }
        .sheet(isPresented: $store.showNewTask) {
            NewTaskSheet().environmentObject(store)
        }
        .sheet(isPresented: $store.showSettings) {
            SettingsView(inSheet: true).environmentObject(store)
        }
        .sheet(isPresented: $showClients) {
            ClientsView(inSheet: true).environmentObject(store)
        }
        .sheet(isPresented: $showTeam) {
            TeamView().environmentObject(store)
        }
        .sheet(isPresented: $showModhesh) {
            ModheshView().environmentObject(store)
        }
        .onChange(of: store.teamReportRequest) { want in
            if want && cloud.isLeader { showTeam = true }
        }
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: compact ? 6 : 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TaskTimer Dev")
                    .font(.system(size: narrow ? 20 : (compact ? 22 : 26), weight: .bold, design: .rounded))
                    .gradientText()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("Today · \(Fmt.short(store.todaySeconds()))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .layoutPriority(1)
            Spacer(minLength: 4)
            if Features.sheet && store.pendingCount > 0 {
                Button {
                    Task { await store.retryPending(silent: false) }
                } label: {
                    if compact {
                        Image(systemName: "arrow.clockwise").foregroundStyle(Theme.pink)
                    } else {
                        Label("\(store.pendingCount) not sent · Retry", systemImage: "arrow.clockwise")
                            .foregroundStyle(Theme.pink)
                    }
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                .help("These logs failed to reach the sheet. Click to try again.")
            }
            if cloud.profile != nil { modheshButton }
            if cloud.isLeader {
                if compact {
                    Button { showTeam = true } label: { Image(systemName: "person.3.fill") }
                        .buttonStyle(CircleIconButtonStyle())
                        .help("Your team's tasks and live timers")
                } else {
                    Button { showTeam = true } label: { Label("Team", systemImage: "person.3.fill") }
                        .buttonStyle(GlassButtonStyle(compact: true))
                        .help("Your team's tasks and live timers")
                }
            }
            Button { showClients = true } label: { Image(systemName: "person.2") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Clients")
            Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Settings")
            if !narrow {
                Button {
                    if let url = FolderService.chooseExistingFolder() {
                        _ = store.importFolder(url)
                        filter = .inProgress
                    }
                } label: { Image(systemName: "folder.badge.plus") }
                    .buttonStyle(CircleIconButtonStyle())
                    .help("Import an existing task folder")
            }
            if compact {
                Button { store.showNewTask = true } label: { Image(systemName: "plus") }
                    .buttonStyle(CircleIconButtonStyle(filled: true))
                    .help("New Task (⌘N)")
            } else {
                Button { store.showNewTask = true } label: {
                    Label("New Task", systemImage: "plus")
                }
                .buttonStyle(GradientButtonStyle())
            }
        }
    }

    @ViewBuilder
    private var modheshButton: some View {
        let open = cloud.modheshTasks.filter { $0.taskID == nil && CloudSync.modheshActive($0.status) }.count
        let fresh = cloud.newModheshCount
        if compact {
            Button { showModhesh = true; cloud.clearNewModhesh() } label: {
                Image(systemName: fresh > 0 ? "bell.badge.fill" : "link")
            }
            .buttonStyle(CircleIconButtonStyle(filled: fresh > 0))
            .overlay(alignment: .topTrailing) {
                if fresh + open > 0 {
                    Text("\(fresh > 0 ? fresh : open)")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 4).padding(.vertical, 1)
                        .background(Theme.pink, in: Capsule())
                        .offset(x: 4, y: -4)
                }
            }
            .help(fresh > 0 ? "New tasks arrived on Modhesh" : "Modhesh")
        } else if fresh > 0 {
            Button { showModhesh = true; cloud.clearNewModhesh() } label: {
                Label("Modhesh · \(fresh) new", systemImage: "bell.badge.fill")
            }
            .buttonStyle(GradientButtonStyle(compact: true))
            .help("New tasks arrived on Modhesh")
        } else {
            Button { showModhesh = true } label: {
                Label(open > 0 ? "Modhesh (\(open))" : "Modhesh", systemImage: "link")
            }
            .buttonStyle(GlassButtonStyle(compact: true))
            .help("Link Modhesh tasks to your TaskTimer tasks")
        }
    }

    // MARK: List

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(TaskFilter.allCases) { f in
                Text(f == .incoming && incomingCount > 0 ? "Incoming (\(incomingCount))" : f.rawValue).tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
    }

    private var monthPicker: some View {
        Picker("", selection: $month) {
            Text("All months").tag(Date?.none)
            ForEach(monthChoices, id: \.self) { m in
                Text(Fmt.monthYear.string(from: m)).tag(Date?.some(m))
            }
        }
        .labelsHidden()
        .frame(minWidth: 110, maxWidth: 150)
        .help("Show tasks created in this month")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search tasks or clients", text: $search)
                .textFieldStyle(.plain)
        }
        .padding(.horizontal, 10).padding(.vertical, 6)
        .background(.thinMaterial, in: Capsule())
    }

    @ViewBuilder
    private var listControls: some View {
        if width < 820 {
            VStack(spacing: 8) {
                filterPicker
                HStack(spacing: 8) {
                    monthPicker
                    searchField.frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: 10) {
                filterPicker.frame(maxWidth: 400)
                monthPicker
                Spacer(minLength: 8)
                searchField.frame(minWidth: 140, maxWidth: 220)
            }
        }
    }

    private var incomingCount: Int { store.tasks.filter { $0.status == .incoming }.count }

    /// Months that have tasks, plus this month, newest first.
    private var monthChoices: [Date] {
        var list = store.taskMonths
        if let now = Calendar.current.dateInterval(of: .month, for: Date())?.start, !list.contains(now) {
            list.insert(now, at: 0)
        }
        return list
    }

    /// Top-level tasks; a task shows when it or any of its amends matches.
    private var filtered: [TaskItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        let cal = Calendar.current
        return store.tasks.filter { $0.parentID == nil }.filter { t in
            let group = [t] + store.subtasks(of: t.id)
            if let m = month {
                guard group.contains(where: { cal.isDate($0.createdAt, equalTo: m, toGranularity: .month) }) else { return false }
            }
            let passFilter = group.contains { s in
                switch filter {
                case .incoming: return s.status == .incoming
                case .inProgress: return s.status.isInProgress
                case .complete: return s.status == .complete
                case .all: return true
                }
            }
            guard passFilter else { return false }
            if q.isEmpty { return true }
            return group.contains { s in
                s.name.localizedCaseInsensitiveContains(q)
                    || store.clientName(s.clientID).localizedCaseInsensitiveContains(q)
            }
        }
    }

    private var taskList: some View {
        Group {
            if filtered.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.system(size: 30, weight: .light))
                        .foregroundStyle(Theme.cool)
                    Text(store.tasks.isEmpty ? "No tasks yet — press New Task to start." : "Nothing here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 10) {
                        ForEach(filtered) { t in
                            TaskRow(task: t)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
        }
    }
}

// MARK: - Hero (running task)

struct HeroCard: View {
    @EnvironmentObject var store: Store
    var compact = false

    var body: some View {
        let running = store.running
        HStack(spacing: compact ? 14 : 22) {
            let secs = running?.totalSeconds(at: store.now) ?? 0
            ZStack {
                TimerRing(running: running != nil,
                          progress: running == nil ? 0 : (secs.truncatingRemainder(dividingBy: 3600)) / 3600,
                          size: compact ? 76 : 112)
                Image(systemName: running == nil ? "moon.zzz" : "bolt.fill")
                    .font(.system(size: compact ? 20 : 26, weight: .semibold))
                    .foregroundStyle(Theme.cool)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let t = running {
                    SectionLabel(text: "Now working on")
                    Text(store.displayName(t))
                        .font(.system(size: compact ? 16 : 20, weight: .semibold))
                        .lineLimit(2)
                    if !store.clientName(t.clientID).isEmpty {
                        Text(store.clientName(t.clientID))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.clock(secs))
                        .font(.system(size: compact ? 26 : 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .gradientText()
                        .lineLimit(1)
                    HStack(spacing: 10) {
                        Button { store.pause(t.id) } label: { Image(systemName: "pause.fill") }
                            .buttonStyle(CircleIconButtonStyle(size: compact ? 34 : 40))
                            .help("Pause (⌘⇧P)")
                        Button { store.requestDone(t.id) } label: { Image(systemName: "checkmark") }
                            .buttonStyle(CircleIconButtonStyle(filled: true, size: compact ? 34 : 40))
                            .keyboardShortcut(.return, modifiers: .command)
                            .help("Done (⌘↩)")
                    }
                } else {
                    SectionLabel(text: "Idle")
                    Text("No timer running")
                        .font(.system(size: compact ? 17 : 20, weight: .semibold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.8)
                    Text("Start a task below, or create a new one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            MonthStats(compact: compact)
        }
        .padding(compact ? 14 : 20)
        .glassCard(radius: 24, highlight: running != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: running?.id)
    }
}

// MARK: - This month (completed)

/// Completed tasks and hours this month. It only changes when a task is completed
/// (or edited), not with the running timer.
struct MonthStats: View {
    @EnvironmentObject var store: Store
    var compact = false

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let done = store.tasks.filter { t in
            t.status == .complete && cal.isDate(t.workDate ?? t.createdAt, equalTo: now, toGranularity: .month)
        }
        let seconds = done.reduce(0) { $0 + $1.totalSeconds(at: $1.sessions.last?.end ?? $1.createdAt) }
        let month = DateFormatter()
        month.dateFormat = "MMMM"
        return VStack(alignment: .leading, spacing: compact ? 6 : 10) {
            SectionLabel(text: month.string(from: now))
            stat(value: "\(done.count)", label: done.count == 1 ? "task done" : "tasks done", icon: "checkmark.circle.fill")
            stat(value: Fmt.hours(seconds), label: "hours", icon: "clock.fill")
        }
        .padding(compact ? 10 : 14)
        .frame(minWidth: compact ? 96 : 130, alignment: .leading)
        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
        .help("Completed this month (by the day you finished them)")
    }

    private func stat(value: String, label: String, icon: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: compact ? 11 : 13))
                .foregroundStyle(Theme.cool)
            Text(value)
                .font(.system(size: compact ? 20 : 26, weight: .semibold, design: .rounded).monospacedDigit())
                .gradientText()
                .lineLimit(1)
                .fixedSize()
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .fixedSize()
        }
    }
}

// MARK: - Task row

struct TaskRow: View {
    @EnvironmentObject var store: Store
    var task: TaskItem
    @Local var hovering = false
    @Local var dropping = false
    @Local var confirmDelete = false

    var body: some View {
        let subs = store.subtasks(of: task.id)
        VStack(alignment: .leading, spacing: 8) {
            mainRow(hasSubs: !subs.isEmpty)
            if !subs.isEmpty {
                VStack(spacing: 6) {
                    ForEach(subs) { s in SubtaskRow(task: s) }
                }
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassCard(radius: 16, highlight: task.isRunning || subs.contains(where: { $0.isRunning }) || dropping)
        .scaleEffect(hovering ? 1.005 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .confirmationDialog("Delete “\(task.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(task.id) }
        } message: {
            Text(subs.isEmpty
                 ? "This only removes it from TaskTimer. The folder and the sheet row stay."
                 : "This also removes its \(subs.count) amend\(subs.count == 1 ? "" : "s") from TaskTimer. The folder and the sheet rows stay.")
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard let f = task.folderURL else {
                store.flash("This task has no folder to sort files into.")
                return false
            }
            let moved = FolderService.sort(urls, into: f)
            if moved.isEmpty {
                store.flash("Nothing moved.")
            } else {
                let summary = Dictionary(grouping: moved, by: { $0.1 })
                    .map { "\($0.value.count) → \($0.key)" }
                    .sorted()
                    .joined(separator: ",  ")
                store.flash("Sorted \(moved.count) file\(moved.count == 1 ? "" : "s"): \(summary)")
            }
            return true
        } isTargeted: { dropping = $0 }
    }

    private func mainRow(hasSubs: Bool) -> some View {
        HStack(spacing: 14) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(CircleIconButtonStyle(filled: task.isRunning, size: 36))
            .help(task.isRunning ? "Pause" : "Start")

            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 8) {
                    Text(task.name)
                        .font(.system(size: 14, weight: .semibold))
                        .lineLimit(1)
                        .truncationMode(.tail)
                    StatusPill(status: task.status).fixedSize()
                    if task.pendingLog != nil {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(Theme.pink)
                            .help(task.pendingLog?.error ?? "Waiting to be sent")
                    }
                }
                // Drops the date (then the row number) when there's no room, instead of wrapping.
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 6) {
                        clientMenu
                        Text("·").foregroundStyle(.tertiary)
                        Text(Fmt.nice.string(from: task.createdAt)).fixedSize()
                        if let r = task.sheetRow {
                            Text("·").foregroundStyle(.tertiary)
                            Text("Row \(r)").fixedSize()
                        }
                    }
                    clientMenu
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            VStack(alignment: .trailing, spacing: 2) {
                Text(task.status == .complete ? "\(Fmt.hours(task.totalSeconds(at: store.now))) h" : Fmt.clock(task.totalSeconds(at: store.now)))
                    .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.linear) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                if hasSubs {
                    Text("Total \(Fmt.hours(store.groupSeconds(task.id))) h")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.tertiary)
                        .help("This task plus all its amends")
                }
            }

            HStack(spacing: 6) {
                if let f = task.folderURL {
                    Menu {
                        Button("Open Folder") { NSWorkspace.shared.open(f) }
                        if let ae = FolderService.aeFile(in: f) {
                            Button("Open AE Project") { NSWorkspace.shared.open(ae) }
                        }
                        if let r = FolderService.folder(in: f, matching: ["render"]) {
                            Button("Open Render Folder") { NSWorkspace.shared.open(r) }
                        }
                    } label: {
                        Image(systemName: "folder")
                    }
                    .menuStyle(.borderlessButton)
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Task folder")
                }
                Button { addAmend() } label: { Image(systemName: "plus.square.on.square") }
                    .buttonStyle(CircleIconButtonStyle(size: 28))
                    .help("Add an amend (subtask). It gets its own timer and its own row in the sheet.")
                Button { store.requestDone(task.id) } label: {
                    Text(doneLabel(task)).lineLimit(1).fixedSize()
                }
                .buttonStyle(GradientButtonStyle(compact: true))
            }
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(task.isRunning ? "Pause" : "Start") { store.toggle(task.id) }
            Button(Features.sheet ? "Done / Log to Sheet…" : "Done…") { store.requestDone(task.id) }
            Button("Add Amend") { addAmend() }
            Divider()
            Button("Copy Task Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.name, forType: .string)
            }
            if let f = task.folderURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
            Menu("Mark as") {
                ForEach(TaskStatus.choices) { s in
                    Button(s.title) { store.update(task.id) { $0.status = s } }
                }
            }
            Divider()
            Button("Delete Task", role: .destructive) { confirmDelete = true }
        }
    }

    private func addAmend() {
        if let id = store.addAmend(to: task.id), let s = store.task(id) {
            store.flash("“\(store.displayName(s))” — timer running")
        }
    }

    private var clientMenu: some View {
        Menu {
            ForEach(store.clients) { c in
                Button(c.missingFromSheet == true ? "\(c.name)  (not in sheet)" : c.name) { store.setClient(task.id, c.id) }
            }
            if !store.clients.isEmpty { Divider() }
            Button("No client") { store.setClient(task.id, nil) }
        } label: {
            Text(store.clientName(task.clientID).isEmpty ? "Choose client" : store.clientName(task.clientID))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
    }
}

// MARK: - Amend row (inside its task's card)

struct SubtaskRow: View {
    @EnvironmentObject var store: Store
    var task: TaskItem
    @Local var confirmDelete = false

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.turn.down.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.tertiary)
                .padding(.leading, 12)
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(CircleIconButtonStyle(filled: task.isRunning, size: 26))
            .help(task.isRunning ? "Pause" : "Start")

            Text(task.name)
                .font(.system(size: 12, weight: .semibold))
                .lineLimit(1)
            StatusPill(status: task.status)
            if task.pendingLog != nil {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(Theme.pink)
                    .help(task.pendingLog?.error ?? "Waiting to be sent")
            }
            if let r = task.sheetRow {
                Text("Row \(r)")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(task.status == .complete ? "\(Fmt.hours(task.totalSeconds(at: store.now))) h" : Fmt.clock(task.totalSeconds(at: store.now)))
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.linear) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
            Button { store.requestDone(task.id) } label: {
                Text(doneLabel(task)).lineLimit(1).fixedSize()
            }
            .buttonStyle(GradientButtonStyle(compact: true))
        }
        .padding(.vertical, 6).padding(.trailing, 6)
        .background(Color.primary.opacity(task.isRunning ? 0.08 : 0.04), in: RoundedRectangle(cornerRadius: 10))
        .contentShape(Rectangle())
        .contextMenu {
            Button(task.isRunning ? "Pause" : "Start") { store.toggle(task.id) }
            Button(Features.sheet ? "Done / Log to Sheet…" : "Done…") { store.requestDone(task.id) }
            Divider()
            Button("Copy Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(store.displayName(task), forType: .string)
            }
            Menu("Mark as") {
                ForEach(TaskStatus.choices) { s in
                    Button(s.title) { store.update(task.id) { $0.status = s } }
                }
            }
            Divider()
            Button("Delete Amend", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(store.displayName(task))”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(task.id) }
        } message: {
            Text("This only removes it from TaskTimer. Its sheet row stays.")
        }
    }
}

/// "Done" while working, "Edit" once completed (to fix the hours or the day).
func doneLabel(_ t: TaskItem) -> String {
    if t.status == .complete { return Features.sheet ? "Log again" : "Edit" }
    return "Done"
}
