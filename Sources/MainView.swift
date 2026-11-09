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
    @Local var importTarget: ImportTarget? = nil
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
                .environment(\.mainWindowSize, g.size)
                .onAppear { width = g.size.width }
                .onChange(of: g.size.width) { width = $0 }
        }
        // One piece of glass: the content runs under the title bar, the window buttons sit on it.
        .ignoresSafeArea()
        .background(UnifiedWindow())
        .frame(minWidth: 600, minHeight: 560)   // narrower and text ran into other text
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            GlowBackground()

            VStack(spacing: narrow ? 10 : 14) {
                header
                UpdateBanner()
                if cloud.isAdmin {
                    // Admins don't time tasks: their main window is the Admin panel.
                    AdminView(embedded: true)
                } else {
                    StatsRow(narrow: narrow)
                    NowCard(compact: compact)
                        .zIndex(1)   // its tools' name labels show over the list
                    listControls
                    taskList
                }
            }
            // A safe margin all round, so buttons (and their glow) never touch the window's edge.
            .padding(.horizontal, narrow ? 18 : (compact ? 20 : 24))
            .padding(.top, 14)      // as much room above the top bar as below the list
            .padding(.bottom, 14)
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
        .sheet(item: $importTarget) { target in
            ImportFolderSheet(url: target.url) { filter = .inProgress }.environmentObject(store)
        }

        .onChange(of: store.teamReportRequest) { want in
            if want && cloud.isLeader { showTeam = true }
        }
    }

    // MARK: Header

    /// One bar with the window's own buttons (no separate title bar): the logo sits right after
    /// the red / yellow / green buttons.
    private var header: some View {
        HStack(alignment: .center, spacing: compact ? 6 : 8) {
            HStack(spacing: 8) {
                MongezLogo(lineWidth: 2.4)
                    .frame(width: 24, height: 24)
                Text(TestCopies.appTitle)
                    .font(.system(size: narrow ? 17 : 19, weight: .bold, design: .rounded))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
                if cloud.isAdmin {
                    Text("Admin")
                        .font(.system(size: 10, weight: .semibold))
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .foregroundStyle(Theme.coral)
                        .background(Theme.coral.opacity(0.14), in: Capsule())
                }
            }
            .padding(.leading, 70)   // room for the window buttons
            .layoutPriority(1)
            Spacer(minLength: 4)
            if Features.sheet && store.pendingCount > 0 {
                Button {
                    Task { await store.retryPending(silent: false) }
                } label: {
                    Image(systemName: "arrow.clockwise").foregroundStyle(Theme.pink)
                }
                .buttonStyle(CircleIconButtonStyle())
                .help("\(store.pendingCount) logs didn't reach the sheet. Click to try again.")
            }
            if !cloud.isAdmin {
                if cloud.profile != nil { modheshButton }
                if cloud.isLeader {
                    Button { showTeam = true } label: { Image(systemName: "person.3") }
                        .buttonStyle(CircleIconButtonStyle())
                        .help("Your team's tasks and live timers")
                }
                Button { showClients = true } label: { Image(systemName: "person.2") }
                    .buttonStyle(CircleIconButtonStyle())
                    .help("Clients")
                if !compact {
                    Button {
                        if let url = FolderService.chooseExistingFolder() {
                            importTarget = ImportTarget(url: url)
                        }
                    } label: { Image(systemName: "folder.badge.plus") }
                        .buttonStyle(CircleIconButtonStyle())
                        .help("Import an existing task folder")
                }
            }
            Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Settings")
            if !cloud.isAdmin {
                if compact {
                    Button { store.showNewTask = true } label: { Image(systemName: "plus") }
                        .buttonStyle(GradientButtonStyle())
                        .help("New Task (⌘N)")
                } else {
                    Button { store.showNewTask = true } label: {
                        Label("New Task", systemImage: "plus")
                    }
                    .buttonStyle(GradientButtonStyle())
                    .help("New Task (⌘N)")
                }
            }
        }
        .frame(minHeight: 34)
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
            .help("Link Modhesh tasks to your Mongez tasks")
        }
    }

    // MARK: List

    private func count(_ f: TaskFilter) -> Int {
        store.tasks.filter { $0.parentID == nil }.filter { t in
            ([t] + store.subtasks(of: t.id)).contains { s in
                switch f {
                case .incoming: return s.status == .incoming
                case .inProgress: return s.status.isInProgress
                case .complete: return s.status == .complete
                case .all: return true
                }
            }
        }.count
    }

    private var filterPicker: some View {
        Picker("", selection: $filter) {
            ForEach(TaskFilter.allCases) { f in
                Text(f == .all ? f.rawValue : "\(f.rawValue)  \(count(f))").tag(f)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var monthPicker: some View {
        Picker("", selection: $month) {
            Text("All months").tag(Date?.none)
            ForEach(monthChoices, id: \.self) { m in
                Text(Fmt.monthYear.string(from: m)).tag(Date?.some(m))
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Show tasks created in this month")
    }

    private var modheshPicker: some View {
        Picker("", selection: $modhesh) {
            ForEach(ModheshFilter.allCases) { f in
                Text(f.rawValue).tag(f)
            }
        }
        .labelsHidden()
        .fixedSize()
        .help("Closed on Modhesh = time sent there. Not closed yet = linked, waiting for Done.")
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(Theme.teal)
            TextField("Search", text: $search)
                .textFieldStyle(.plain)
            if !search.isEmpty {
                Button { search = "" } label: { Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary) }
                    .buttonStyle(.plain)
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12).padding(.vertical, 7)
        .glassChip()
    }

    /// Status tabs, search, month and Modhesh filters, in one bar above the list.
    @ViewBuilder
    private var listControls: some View {
        let hasCloud = cloud.profile != nil
        if width < 1000 {
            VStack(spacing: 8) {
                HStack(spacing: 8) {
                    filterPicker
                    if !narrow { searchField.frame(minWidth: 80, maxWidth: .infinity) }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 8) {
                    if narrow { searchField.frame(minWidth: 80, maxWidth: .infinity) }
                    monthPicker
                    if hasCloud { modheshPicker }
                    if !narrow { Spacer(minLength: 0) }
                }
            }
        } else {
            HStack(spacing: 8) {
                filterPicker
                searchField.frame(minWidth: 140, maxWidth: .infinity)
                monthPicker
                if hasCloud { modheshPicker }
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
        let list = filtered
        return Group {
            if list.isEmpty {
                VStack(spacing: 10) {
                    MongezLogo(lineWidth: 2)
                        .frame(width: 34, height: 34)
                        .opacity(0.6)
                    Text(store.tasks.isEmpty ? "No tasks yet — press New Task to start." : "Nothing here.")
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 8) {
                        ForEach(list) { t in
                            // The last row shows its tool names above the icons, so the list's
                            // bottom edge doesn't cut them.
                            TaskRow(task: t, labelsAbove: list.count > 1 && t.id == list.last?.id)
                        }
                    }
                    .padding(.vertical, 6)
                    .padding(.horizontal, 4)
                }
            }
        }
    }
}

// MARK: - Window without a separate title bar

/// Makes the main window one surface: transparent title bar, content under it, draggable
/// anywhere there's no control.
struct UnifiedWindow: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let v = NSView()
        DispatchQueue.main.async { configure(v.window) }
        return v
    }
    func updateNSView(_ v: NSView, context: Context) {
        DispatchQueue.main.async { configure(v.window) }
    }
    private func configure(_ w: NSWindow?) {
        guard let w else { return }
        w.titlebarAppearsTransparent = true
        w.titleVisibility = .hidden
        w.styleMask.insert(.fullSizeContentView)
        w.isMovableByWindowBackground = true
        w.backgroundColor = .clear
        w.isOpaque = false
        w.contentMinSize = NSSize(width: 600, height: 560)
    }
}

// MARK: - Now (running task)

/// The task that's timing, with its amends as chips, its tools as icons and a big Done.
/// Files dropped on it go into the task's folders.
struct NowCard: View {
    @EnvironmentObject var store: Store
    var compact = false
    @Local var dropping = false
    @Local var dropped: [URL] = []
    @Local var askDrop = false

    var body: some View {
        Group {
            if let r = store.running {
                running(r, parent: store.parent(of: r) ?? r)
            } else {
                idle
            }
        }
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: store.running?.id)
    }

    private var idle: some View {
        HStack(spacing: 14) {
            Image(systemName: "play.fill")
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(Theme.teal)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Theme.teal.opacity(0.12)))
            VStack(alignment: .leading, spacing: 3) {
                Text("No timer running")
                    .font(.system(size: 15, weight: .semibold))
                Text("Press ▶ on a task below, or New Task.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(14)
        .glassCard(radius: 22)
    }

    private func running(_ r: TaskItem, parent p: TaskItem) -> some View {
        let subs = store.subtasks(of: p.id)
        let secs = r.totalSeconds(at: store.now)
        return HStack(alignment: .center, spacing: compact ? 12 : 16) {
            Button { store.pause(r.id) } label: { Image(systemName: "pause.fill") }
                .buttonStyle(CircleIconButtonStyle(filled: true, size: compact ? 46 : 56))
                .help("Pause (⌘⇧P)")

            VStack(alignment: .leading, spacing: 7) {
                Text(p.name)
                    .font(.system(size: compact ? 15 : 17, weight: .bold))
                    .lineLimit(2)
                HStack(spacing: 6) {
                    StatusPill(status: r.status)
                    KindTag(task: p)
                    if !store.clientName(p.clientID).isEmpty {
                        Text(store.clientName(p.clientID))
                            .font(.system(size: 11.5))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    ModheshBadge(taskID: r.id)
                }
                // Main task and its amends: press one to time it.
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 5) {
                        amendChip(p, title: "Main", running: r.id == p.id)
                        ForEach(subs) { s in amendChip(s, title: s.name, running: r.id == s.id) }
                        Button {
                            if let id = store.addAmend(to: p.id), let s = store.task(id) {
                                store.flash("“\(store.displayName(s))” — timer running")
                            }
                        } label: {
                            Text("+ Amend").font(.system(size: 11, weight: .medium))
                                .padding(.horizontal, 9).padding(.vertical, 4)
                                .glassChip()
                        }
                        .buttonStyle(.plain)
                        .help("Add an amend. It gets its own timer and can be linked to its own Modhesh task.")
                    }
                }
                if p.folderURL != nil {
                    TaskTools(task: p, size: 28)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 10) {
                Text(Fmt.clock(secs))
                    .font(.system(size: compact ? 26 : 34, weight: .light, design: .rounded).monospacedDigit())
                    .foregroundStyle(Theme.linear)
                    .lineLimit(1)
                    .fixedSize()
                Button { store.requestDone(r.id) } label: {
                    Label("Done", systemImage: "checkmark")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.return, modifiers: .command)
                .help("Done (⌘↩)")
            }
        }
        .padding(compact ? 14 : 18)
        .glassCard(radius: 24, highlight: true)
        .overlay(alignment: .topTrailing) {
            if p.folderURL != nil {
                Label(dropping ? "Drop to add" : "Drop files here", systemImage: "arrow.down.to.line")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(Theme.buttonInk)
                    .padding(.horizontal, 9).padding(.vertical, 3)
                    .background(Theme.coralFill, in: Capsule())
                    .offset(x: -18, y: -9)
                    .opacity(dropping ? 1 : 0.85)
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            guard p.folderURL != nil else { return false }
            dropped = urls
            askDrop = true
            return true
        } isTargeted: { dropping = $0 }
        .sheet(isPresented: $askDrop) {
            if let f = p.folderURL {
                DropFilesSheet(files: dropped, project: f, taskName: p.name).environmentObject(store)
            }
        }
    }

    private func amendChip(_ t: TaskItem, title: String, running: Bool) -> some View {
        Button { if !running { store.start(t.id) } } label: {
            HStack(spacing: 4) {
                if running { Circle().fill(Theme.coral).frame(width: 6, height: 6) }
                Text(title).fontWeight(running ? .semibold : .regular)
                Text("· \(Fmt.short(t.totalSeconds(at: store.now)))").foregroundStyle(.secondary)
            }
            .font(.system(size: 11))
            .padding(.horizontal, 9).padding(.vertical, 4)
            .background(Capsule().fill(running ? Theme.coral.opacity(0.16) : Color.clear))
            .glassChip()
        }
        .buttonStyle(.plain)
        .help(running ? "Timing now" : "Switch the timer to \(title)")
    }
}

// MARK: - Task tools (After Effects + folders)

/// Open AE, Set Render Outputs, Organize, Collect and the folders, as small round icons. Each
/// shows its name on hover. In a narrow window they fold into one button (`grouped`) that opens a
/// glass panel with every tool in a grid.
struct TaskTools: View {
    var task: TaskItem
    var size: CGFloat = 27
    /// Narrow window: every tool in one button that opens them in a grid.
    var grouped = false
    /// Names show above the icons instead of below (the list's last row).
    var labelsAbove = false

    var body: some View {
        if let f = task.folderURL {
            let tools = TaskTool.all(for: task, folder: f)
            if grouped {
                ToolGroupButton(tools: tools, size: size, labelAbove: labelsAbove)
            } else {
                HStack(spacing: 4) {
                    ForEach(tools.filter { !$0.isFolder }) { t in
                        ToolIconButton(tool: t, size: size, labelAbove: labelsAbove)
                    }
                    FolderButton(tools: tools.filter { $0.isFolder }, size: size, labelAbove: labelsAbove)
                }
            }
        }
    }
}

/// One of a task's tools: its name (shown on hover and in the grid), its icon and what it does.
struct TaskTool: Identifiable {
    let id: String
    let name: String
    let symbol: String?          // nil = the "Ae" mark
    var isFolder = false
    let action: @MainActor () -> Void

    @MainActor
    static func all(for task: TaskItem, folder f: URL) -> [TaskTool] {
        var list: [TaskTool] = []
        if let ae = FolderService.aeFile(in: f) {
            list.append(TaskTool(id: "ae", name: "Open AE Project", symbol: nil) { NSWorkspace.shared.open(ae) })
            list.append(TaskTool(id: "outputs", name: "Set Render Outputs", symbol: "film.stack") {
                AEProjectTools.renderToTask(ae, taskFolder: f)
            })
            list.append(TaskTool(id: "organize", name: "Organize", symbol: "square.grid.2x2") { AEProjectTools.organize(ae) })
            list.append(TaskTool(id: "collect", name: "Collect", symbol: "shippingbox") {
                AEProjectTools.collect(ae, taskFolder: f, taskName: task.name)
            })
        }
        list.append(TaskTool(id: "folder", name: "Project Folder", symbol: "folder", isFolder: true) { NSWorkspace.shared.open(f) })
        if let r = FolderService.folder(in: f, matching: ["render"]) {
            list.append(TaskTool(id: "renderFolder", name: "Render Folder", symbol: "film", isFolder: true) { NSWorkspace.shared.open(r) })
        }
        return list
    }
}

/// A tool's icon, teal: an SF Symbol, or the "Ae" mark for After Effects.
private struct TaskToolIcon: View {
    var tool: TaskTool
    var size: CGFloat
    var body: some View {
        Group {
            if let s = tool.symbol {
                Image(systemName: s).font(.system(size: size * 0.45, weight: .semibold))
            } else {
                Text("Ae").font(.system(size: size * 0.36, weight: .heavy, design: .rounded))
            }
        }
        .foregroundStyle(Theme.teal)
    }
}

private struct ToolIconButton: View {
    var tool: TaskTool
    var size: CGFloat
    var labelAbove = false
    var body: some View {
        Button { tool.action() } label: {
            TaskToolIcon(tool: tool, size: size)
        }
        .buttonStyle(CircleIconButtonStyle(size: size))
        .hoverLabel(tool.name, above: labelAbove)
    }
}

/// The folder icon: opens the project folder, or (when there's a Render folder too) a small
/// panel to pick one. A plain round button, so its icon sits in the middle like the others.
private struct FolderButton: View {
    var tools: [TaskTool]
    var size: CGFloat
    var labelAbove = false
    @Local private var open = false

    var body: some View {
        Button {
            if tools.count == 1 { tools[0].action() } else { open.toggle() }
        } label: {
            Image(systemName: "folder")
                .font(.system(size: size * 0.45, weight: .semibold))
                .foregroundStyle(Theme.teal)
        }
        .buttonStyle(CircleIconButtonStyle(size: size))
        .hoverLabel(tools.count == 1 ? "Project Folder" : "Folders", above: labelAbove)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ToolGrid(tools: tools) { open = false }
        }
    }
}

/// Narrow window: all the tools behind one button.
private struct ToolGroupButton: View {
    var tools: [TaskTool]
    var size: CGFloat
    var labelAbove = false
    @Local private var open = false

    var body: some View {
        Button { open.toggle() } label: {
            Image(systemName: "wrench.and.screwdriver")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(Theme.teal)
        }
        .buttonStyle(CircleIconButtonStyle(size: size))
        .hoverLabel("Tools", above: labelAbove)
        .popover(isPresented: $open, arrowEdge: .bottom) {
            ToolGrid(tools: tools) { open = false }
        }
    }
}

/// The glass panel a folded tool button opens: every tool as an icon with its name, three to a
/// row. The icons pop in one after another with a little spring.
private struct ToolGrid: View {
    var tools: [TaskTool]
    var close: () -> Void
    @Local private var shown = false

    var body: some View {
        let items = Array(tools.enumerated())
        let rows = stride(from: 0, to: items.count, by: 3).map { Array(items[$0..<min($0 + 3, items.count)]) }
        VStack(spacing: 8) {
            ForEach(rows.indices, id: \.self) { r in
                HStack(spacing: 6) {
                    ForEach(rows[r], id: \.element.id) { item in
                        ToolGridCell(tool: item.element) {
                            close()
                            let run = item.element.action
                            Task { @MainActor in run() }
                        }
                        .scaleEffect(shown ? 1 : 0.5)
                        .opacity(shown ? 1 : 0)
                        .offset(y: shown ? 0 : 8)
                        .animation(.spring(response: 0.38, dampingFraction: 0.68)
                                    .delay(0.03 + Double(item.offset) * 0.045), value: shown)
                    }
                }
            }
        }
        .padding(14)
        .onAppear { shown = true }
    }
}

private struct ToolGridCell: View {
    var tool: TaskTool
    var action: () -> Void
    @Local private var hovering = false

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                TaskToolIcon(tool: tool, size: 40)
                    .frame(width: 40, height: 40)
                    .glassChip()
                    .scaleEffect(hovering ? 1.08 : 1)
                Text(tool.name)
                    .font(.system(size: 10.5, weight: .medium))
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(width: 72)
            }
            .padding(.vertical, 6)
            .frame(width: 78)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(hovering ? 0.06 : 0)))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { inside in
            withAnimation(.spring(response: 0.25, dampingFraction: 0.7)) { hovering = inside }
        }
    }
}

// MARK: - Support / Pitch tag

struct KindTag: View {
    @EnvironmentObject var store: Store
    var task: TaskItem
    var body: some View {
        if task.support == true {
            tag("Support", Theme.support)
        } else if store.client(task.clientID)?.isPitch == true {
            tag("Pitch", Theme.pitch)
        }
    }
    private func tag(_ text: String, _ c: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(c)
            .background(c.opacity(0.14), in: Capsule())
            .fixedSize()
    }
}

// MARK: - Logo

/// Mongez's logo: a stopwatch whose hand is a check mark, drawn as one stroke.
struct MongezLogoShape: Shape {
    func path(in rect: CGRect) -> Path {
        let k = min(rect.width, rect.height) / 64
        let o = CGPoint(x: rect.midX - 32 * k, y: rect.midY - 32 * k)
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: o.x + x * k, y: o.y + y * k) }
        var p = Path()
        p.move(to: pt(26, 6)); p.addLine(to: pt(38, 6))          // button
        p.move(to: pt(32, 6)); p.addLine(to: pt(32, 12))
        p.move(to: pt(49, 15)); p.addLine(to: pt(52.5, 11.5))    // side button
        // Dial: from 3 o'clock round the bottom to the top right, leaving a gap for the tick.
        let end = 294.7
        for i in 0...72 {
            let a = (Double(i) / 72 * end) * .pi / 180
            let q = pt(32 + 21.5 * CGFloat(cos(a)), 37 + 21.5 * CGFloat(sin(a)))
            if i == 0 { p.move(to: q) } else { p.addLine(to: q) }
        }
        p.move(to: pt(22, 37.5)); p.addLine(to: pt(29, 44.5)); p.addLine(to: pt(45, 27.5))   // tick
        return p
    }
}

struct MongezLogo: View {
    var lineWidth: CGFloat = 2.5
    var body: some View {
        MongezLogoShape()
            .stroke(LinearGradient(colors: [Theme.teal, Theme.coral], startPoint: .topLeading, endPoint: .bottomTrailing),
                    style: StrokeStyle(lineWidth: lineWidth, lineCap: .round, lineJoin: .round))
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

// MARK: - Today / this week / done this month

struct StatsRow: View {
    @EnvironmentObject var store: Store
    var narrow = false

    var body: some View {
        let cal = Calendar.current
        let now = Date()
        let done = store.tasks.filter { t in
            t.status == .complete && cal.isDate(t.workDate ?? t.createdAt, equalTo: now, toGranularity: .month)
        }
        let month = DateFormatter()
        month.dateFormat = "MMM"
        return HStack(spacing: 8) {
            tile("Today", Fmt.short(store.todaySeconds()))
            tile("This week", Fmt.short(store.weekSeconds()))
            tile("Done · \(month.string(from: now))", "\(done.count)")
                .help("Tasks completed this month (by the day you finished them)")
        }
    }

    private func tile(_ label: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .tracking(0.8)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value)
                .font(.system(size: narrow ? 16 : 18, weight: .semibold, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 13).padding(.vertical, 9)
        .glassCard(radius: 16)
    }
}

// MARK: - Task row

struct TaskRow: View {
    @EnvironmentObject var store: Store
    @Environment(\.mainWindowSize) var windowSize
    var task: TaskItem
    /// Tool names show above the icons (the list's last row) instead of below.
    var labelsAbove = false
    /// Fixed widths of the time column and the Done / Edit button, shared with the amend rows.
    static let timeColumn: CGFloat = 64
    static let doneWidth: CGFloat = 34
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
        .padding(.horizontal, 12).padding(.vertical, 10)
        .glassCard(radius: 18, highlight: task.isRunning || subs.contains(where: { $0.isRunning }) || dropping)
        .scaleEffect(hovering ? 1.005 : 1)
        .onHover { hovering = $0 }
        .zIndex(hovering ? 1 : 0)   // a tool's name label shows over the next row
        .animation(.easeOut(duration: 0.15), value: hovering)
        .confirmationDialog("Delete “\(task.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(task.id) }
        } message: {
            Text(subs.isEmpty
                 ? "This only removes it from Mongez. The folder and the sheet row stay."
                 : "This also removes its \(subs.count) amend\(subs.count == 1 ? "" : "s") from Mongez. The folder and the sheet rows stay.")
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
        HStack(spacing: 12) {
            Button { store.toggle(task.id) } label: {
                Image(systemName: task.isRunning ? "pause.fill" : "play.fill")
            }
            .buttonStyle(CircleIconButtonStyle(filled: true, size: 34))
            .help(task.isRunning ? "Pause" : "Start")

            VStack(alignment: .leading, spacing: 4) {
                // The whole name, on two lines if it needs them, so tasks are easy to find.
                Text(task.name)
                    .font(.system(size: 14, weight: .semibold))
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                // What doesn't fit leaves, least needed first (the date, the status, the tag),
                // so the line never pushes the row out of the window.
                ViewThatFits(in: .horizontal) {
                    meta(status: true, kind: true, date: true)
                    meta(status: true, kind: true, date: false)
                    meta(status: false, kind: true, date: false)
                    meta(status: false, kind: false, date: false)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            .layoutPriority(1)

            Spacer(minLength: 6)

            // By the window's width: the tools and the render picture, then the tools alone, then
            // every tool folded into one button whose menu has them all.
            let width = windowSize?.width ?? 900
            if width >= 900 {
                HStack(spacing: 8) {
                    if let f = task.folderURL { RenderThumb(folder: f) }
                    TaskTools(task: task, size: 27, labelsAbove: labelsAbove)
                }
            } else if width >= 760 {
                TaskTools(task: task, size: 27, labelsAbove: labelsAbove)
            } else {
                TaskTools(task: task, size: 27, grouped: true, labelsAbove: labelsAbove)
            }

            // One width for every row (00.0 h / 00:00:00), so the icons beside it line up.
            VStack(alignment: .trailing, spacing: 2) {
                Text(task.status == .complete ? "\(Fmt.hoursColumn(task.totalSeconds(at: store.now))) h" : Fmt.clock(task.totalSeconds(at: store.now)))
                    .font(.system(size: 13.5, weight: .medium, design: .rounded).monospacedDigit())
                    .lineLimit(1)
                    .fixedSize()
                    .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.linear) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                if hasSubs {
                    Text("Total \(Fmt.hoursColumn(store.groupSeconds(task.id))) h")
                        .font(.system(size: 10, weight: .medium).monospacedDigit())
                        .foregroundStyle(.tertiary)
                        .fixedSize()
                        .help("This task plus all its amends")
                }
            }
            .frame(minWidth: Self.timeColumn, alignment: .trailing)

            Button { addAmend() } label: { Image(systemName: "plus") }
                .buttonStyle(CircleIconButtonStyle(size: 27))
                .help("Add an amend. It gets its own timer and can be linked to its own Modhesh task.")
            Button { store.requestDone(task.id) } label: {
                Text(doneLabel(task)).lineLimit(1).fixedSize().foregroundStyle(Theme.coral).fontWeight(.semibold)
                    .frame(minWidth: Self.doneWidth)   // Done and Edit take the same room
            }
            .buttonStyle(GlassButtonStyle(compact: true))
        }
        .contentShape(Rectangle())
        .contextMenu {
            Button(task.isRunning ? "Pause" : "Start") { store.toggle(task.id) }
            Button(Features.sheet ? "Done / Log to Sheet…" : "Done…") { store.requestDone(task.id) }
            if task.folderURL != nil {
                Button("Check Render Folder…") { checkRender() }
            }
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

    private func meta(status: Bool, kind: Bool, date: Bool) -> some View {
        HStack(spacing: 6) {
            if status { StatusPill(status: task.status).fixedSize() }
            if kind { KindTag(task: task) }
            clientMenu
            ModheshBadge(taskID: task.id)
            if task.pendingLog != nil {
                Image(systemName: "exclamationmark.icloud")
                    .foregroundStyle(Theme.pink)
                    .help(task.pendingLog?.error ?? "Waiting to be sent")
            }
            if date { Text("· " + Fmt.nice.string(from: task.createdAt)).fixedSize() }
        }
    }

    /// The client's name, shortened when it's long so it can't push the row out of the window.
    private var clientLabel: String {
        let name = store.clientName(task.clientID)
        if name.isEmpty { return "Choose client" }
        return name.count > 22 ? String(name.prefix(21)) + "…" : name
    }

    private var clientMenu: some View {
        let team = CloudSync.shared.profile?.teamID
        let list = store.hasCloudClients ? store.teamClients(team) : store.clients
        let pitches = store.hasCloudClients ? store.teamPitches(team) : []
        return Menu {
            ForEach(list) { c in
                Button(c.missingFromSheet == true ? "\(c.name)  (not in sheet)" : c.name) { store.setClient(task.id, c.id) }
            }
            if !pitches.isEmpty {
                Divider()
                ForEach(pitches) { c in Button("Pitch · \(c.name)") { store.setClient(task.id, c.id) } }
            }
            if !list.isEmpty || !pitches.isEmpty { Divider() }
            Text("Support for another team: Done → Support")
            Button("No client") { store.setClient(task.id, nil) }
        } label: {
            Text(clientLabel)
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

            Text(task.status == .complete ? "\(Fmt.hoursColumn(task.totalSeconds(at: store.now))) h" : Fmt.clock(task.totalSeconds(at: store.now)))
                .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                .lineLimit(1)
                .fixedSize()
                .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.linear) : AnyShapeStyle(HierarchicalShapeStyle.secondary))
                .frame(minWidth: TaskRow.timeColumn, alignment: .trailing)
            Button { store.requestDone(task.id) } label: {
                Text(doneLabel(task)).lineLimit(1).fixedSize().foregroundStyle(Theme.coral).fontWeight(.semibold)
                    .frame(minWidth: TaskRow.doneWidth)
            }
            .buttonStyle(GlassButtonStyle(compact: true))
        }
        .padding(.vertical, 6).padding(.trailing, 6)
        .background(task.isRunning ? Theme.coral.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
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
            Text("This only removes it from Mongez. Its sheet row stays.")
        }
    }
}

/// "Done" while working, "Edit" once completed (to fix the hours or the day).
func doneLabel(_ t: TaskItem) -> String {
    if t.status == .complete { return Features.sheet ? "Log again" : "Edit" }
    return "Done"
}

// MARK: - Import an existing task folder

struct ImportTarget: Identifiable {
    let url: URL
    var id: String { url.path }
}

/// Importing a folder asks for the task's name and its client (or Support for another team),
/// with the client guessed from the folder.
struct ImportFolderSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let url: URL
    var done: () -> Void = {}
    @Local var name = ""
    @Local var clientID: UUID? = nil
    @Local var support = false
    @Local var loaded = false

    var body: some View {
        SheetFrame(title: "Import Task Folder", subtitle: url.path, icon: "folder.badge.plus") {
            FieldRow(label: "Task name") {
                TextField(url.lastPathComponent, text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            FieldRow(label: "Client / Account") {
                ClientPicker(selection: $clientID, support: $support, allowSupport: true)
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button("Import") {
                    _ = store.importFolder(url, name: name, clientID: clientID, support: support)
                    dismiss()
                    done()
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 520)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            if let t = store.tasks.first(where: { $0.folderPath == url.path && $0.parentID == nil }) {
                name = t.name
                clientID = t.clientID
                support = t.support == true
            } else {
                name = url.lastPathComponent
                let guess = store.guessClient(for: url)
                clientID = guess?.id
                // A client of another team means this was support work.
                if let g = guess, let team = CloudSync.shared.profile?.teamID, let gt = g.teamID, gt != team, !g.isPitch {
                    support = true
                }
            }
        }
    }
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
