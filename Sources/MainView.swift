import SwiftUI
import AppKit

enum TaskFilter: String, CaseIterable, Identifiable {
    case incoming = "Incoming", inProgress = "In Progress", complete = "Completed", all = "All"
    var id: String { rawValue }
}

/// Where each task stands on Modhesh.
enum ModheshFilter: String, CaseIterable, Identifiable {
    case any = "Modhesh: All"
    case closed = "Closed on Modhesh"
    case open = "Not closed yet"
    case unlinked = "Not linked"
    var id: String { rawValue }

    func matches(_ link: CloudSync.ModheshLink?) -> Bool {
        switch self {
        case .any: return true
        case .closed: return link?.sent == true
        case .open: return link != nil && link?.sent != true
        case .unlinked: return link == nil
        }
    }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @Local var filter: TaskFilter = .inProgress
    @Local var month: Date? = nil      // nil = all months
    @Local var modhesh: ModheshFilter = .any
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
        // The width comes from the window itself (not from the content, which could be wider
        // than the window and keep the wide layout on).
        GeometryReader { g in
            content
                .frame(width: g.size.width, height: g.size.height)
                .clipped()
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = $0 }
        }
        .frame(minWidth: 470, minHeight: 560)
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            GlowBackground()

            VStack(spacing: narrow ? 12 : 16) {
                header
                UpdateBanner()
                if cloud.isAdmin {
                    // Admins don't time tasks: their main window is the Admin panel.
                    AdminView(embedded: true)
                } else {
                    HeroCard(compact: compact)
                    listControls
                    taskList
                }
            }
            .padding(.horizontal, narrow ? 12 : (compact ? 16 : 22))
            .padding(.top, 30)
            .padding(.bottom, 12)
            .frame(maxWidth: .infinity)

            if let t = store.toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCard(radius: 20, highlight: true)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
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
                Text(cloud.isAdmin ? "Admin" : "Today · \(Fmt.short(store.todaySeconds()))")
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
            if !cloud.isAdmin {
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
            }
            Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Settings")
            if !cloud.isAdmin {
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
        .frame(minWidth: 90, maxWidth: 150)
        .help("Show tasks created in this month")
    }

    private var modheshPicker: some View {
        Picker("", selection: $modhesh) {
            ForEach(ModheshFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .labelsHidden()
        .frame(minWidth: 90, maxWidth: 160)
        .help("Closed on Modhesh = time sent there. Not closed yet = linked, waiting for Done.")
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
        let hasCloud = cloud.profile != nil
        if width < 640 {
            VStack(spacing: 8) {
                filterPicker
                HStack(spacing: 8) {
                    monthPicker.frame(maxWidth: .infinity)
                    if hasCloud { modheshPicker.frame(maxWidth: .infinity) }
                }
                searchField
            }
        } else if width < 900 {
            VStack(spacing: 8) {
                filterPicker
                HStack(spacing: 8) {
                    monthPicker
                    if hasCloud { modheshPicker }
                    searchField.frame(maxWidth: .infinity)
                }
            }
        } else {
            HStack(spacing: 10) {
                filterPicker.frame(maxWidth: 400)
                monthPicker
                if hasCloud { modheshPicker }
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
            if modhesh != .any && cloud.profile != nil {
                guard group.contains(where: { modhesh.matches(cloud.modheshLinks[$0.id]) }) else { return false }
            }
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

// MARK: - Modhesh badge

/// Green "Modhesh" tag on tasks linked to a Modhesh task; ✓ once the time was sent there.
struct ModheshBadge: View {
    @ObservedObject var cloud = CloudSync.shared
    let taskID: UUID

    var body: some View {
        if let link = cloud.modheshLinks[taskID] {
            HStack(spacing: 3) {
                Image(systemName: link.sent ? "checkmark.seal.fill" : "link")
                    .font(.system(size: 9, weight: .bold))
                Text(link.sent ? "Modhesh ✓" : "Modhesh")
                    .font(.system(size: 10, weight: .semibold))
            }
            .padding(.horizontal, 7).padding(.vertical, 3)
            .foregroundStyle(Theme.green)
            .background(Theme.green.opacity(0.15), in: Capsule())
            .overlay(Capsule().strokeBorder(Theme.green.opacity(link.sent ? 0.5 : 0.25)))
            .fixedSize()
            .help(link.sent ? "Linked to Modhesh — time sent there" + (link.status == 5 ? " (waiting for approval)" : "")
                            : "Linked to a Modhesh task")
        }
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
    @Local var dropped: [URL] = []
    @Local var askDrop = false

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
            guard task.folderURL != nil else {
                store.flash("This task has no folder to sort files into.")
                return false
            }
            // Copy or move (and maybe import into After Effects) is asked next.
            dropped = urls
            askDrop = true
            return true
        } isTargeted: { dropping = $0 }
        .sheet(isPresented: $askDrop) {
            if let f = task.folderURL {
                DropFilesSheet(files: dropped, project: f, taskName: task.name).environmentObject(store)
            }
        }
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
                    ModheshBadge(taskID: task.id)
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

            if let f = task.folderURL { RenderThumb(folder: f) }

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
                            Button("Open AE Project") { NSWorkspace.shared.open(ae); AERenderHelper.ensure() }
                        }
                        if let r = FolderService.folder(in: f, matching: ["render"]) {
                            Button("Open Render Folder") { NSWorkspace.shared.open(r) }
                        }
                        Button("Check Render Folder…") { checkRender() }
                        if let ae = FolderService.aeFile(in: f) {
                            Divider()
                            Button("Organize AE Project") { AEProjectTools.organize(ae) }
                            Button("Collect AE Project") {
                                AEProjectTools.collect(ae, taskFolder: f, taskName: task.name)
                            }
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

    private func checkRender() {
        let t = task
        Task { @MainActor in
            let text = await RenderWatcher.shared.diagnose(t)
            let a = NSAlert()
            a.messageText = "Render folder check — \(t.name)"
            a.informativeText = text
            a.addButton(withTitle: "OK")
            a.addButton(withTitle: "Copy")
            if a.runModal() == .alertSecondButtonReturn {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
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
            ModheshBadge(taskID: task.id)
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

// MARK: - Files dropped on a task

/// Asked when files are dropped on a task: copy or move them into the task's folders, and
/// (when After Effects is open) whether to import them into the open project.
struct DropFilesSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let files: [URL]
    let project: URL
    let taskName: String

    @Local var copy = UserDefaults.standard.bool(forKey: "dropCopies")
    @Local var importAE = UserDefaults.standard.object(forKey: "dropImportsAE") as? Bool ?? true
    @Local var kind: AfterEffects.LayeredKind = AfterEffects.LayeredKind.last

    var body: some View {
        let aeOpen = AfterEffects.isRunning && AfterEffects.canImport(files)
        let layered = AfterEffects.hasLayered(files)
        SheetFrame(title: "Add to “\(taskName)”", subtitle: "\(files.count) item\(files.count == 1 ? "" : "s") into the task folder", icon: "tray.and.arrow.down") {
            VStack(alignment: .leading, spacing: 4) {
                ForEach(files.prefix(8), id: \.self) { f in
                    HStack(spacing: 6) {
                        Image(systemName: f.hasDirectoryPath ? "folder" : "doc").foregroundStyle(.secondary)
                        Text(f.lastPathComponent).lineLimit(1).truncationMode(.middle)
                        Text("→ \(FolderService.target(for: f, in: project).lastPathComponent)")
                            .foregroundStyle(.secondary).lineLimit(1)
                    }
                    .font(.system(size: 12))
                }
                if files.count > 8 {
                    Text("+ \(files.count - 8) more").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Picker("", selection: $copy) {
                Text("Move").tag(false)
                Text("Copy").tag(true)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 220)
            Text(copy ? "The originals stay where they are." : "The files leave where they are now (e.g. Downloads).")
                .font(.system(size: 11)).foregroundStyle(.secondary)

            if aeOpen {
                Divider()
                Toggle("Import into the After Effects project that's open", isOn: $importAE)
                    .font(.system(size: 12, weight: .medium))
                if importAE && layered {
                    VStack(alignment: .leading, spacing: 6) {
                        SectionLabel(text: "PSD / AI import kind")
                        Picker("", selection: $kind) {
                            ForEach(AfterEffects.LayeredKind.allCases) { k in Text(k.title).tag(k) }
                        }
                        .labelsHidden()
                        .frame(maxWidth: 300, alignment: .leading)
                        Text("If After Effects shows its own import window for a PSD, choose there — the other files wait for it.")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button(copy ? "Copy" : "Move") { run(importing: aeOpen && importAE) }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 480)
    }

    private func run(importing: Bool) {
        UserDefaults.standard.set(copy, forKey: "dropCopies")
        UserDefaults.standard.set(importAE, forKey: "dropImportsAE")
        AfterEffects.LayeredKind.last = kind
        let store = self.store
        let moved = FolderService.sort(files, into: project, copy: copy)
        dismiss()
        guard !moved.isEmpty else { store.flash("Nothing was added."); return }
        let summary = Dictionary(grouping: moved, by: { $0.folder })
            .map { "\($0.value.count) → \($0.key)" }
            .sorted()
            .joined(separator: ",  ")
        store.flash("\(copy ? "Copied" : "Moved") \(moved.count): \(summary)")
        guard importing else { return }

        let groups = Dictionary(grouping: moved, by: { $0.folder })
            .sorted { $0.key < $1.key }
            .map { (bin: $0.key, urls: $0.value.map(\.url)) }
        AfterEffects.importFiles(groups, layered: kind) { result in
            switch result {
            case .success(let n):
                store.flash(n == 0 ? "Nothing was imported into After Effects."
                                   : "Imported \(n) item\(n == 1 ? "" : "s") into After Effects")
            case .failure(let e):
                let a = NSAlert()
                a.messageText = "Some files didn't go into After Effects"
                a.informativeText = e.localizedDescription
                a.runModal()
            }
        }
    }
}
