import SwiftUI
import AppKit

enum TaskFilter: String, CaseIterable, Identifiable {
    case open = "Open", inProcess = "In Process", complete = "Complete", all = "All"
    var id: String { rawValue }
}

struct MainView: View {
    @EnvironmentObject var store: Store
    @Local var filter: TaskFilter = .open
    @Local var search = ""
    @Local var showClients = false

    var body: some View {
        ZStack(alignment: .bottom) {
            GlowBackground()

            VStack(spacing: 16) {
                header
                UpdateBanner()
                HeroCard()
                listControls
                taskList
            }
            .padding(.horizontal, 22)
            .padding(.top, 30)
            .padding(.bottom, 12)

            if let t = store.toast {
                Text(t)
                    .font(.system(size: 12, weight: .semibold))
                    .padding(.horizontal, 16).padding(.vertical, 10)
                    .glassCard(radius: 20, highlight: true)
                    .padding(.bottom, 18)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .frame(minWidth: 560, minHeight: 620)
        .sheet(item: $store.doneTarget) { target in
            DoneSheet(taskID: target.id).environmentObject(store)
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
    }

    // MARK: Header

    private var header: some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("TaskTimer")
                    .font(.system(size: 26, weight: .bold, design: .rounded))
                    .gradientText()
                Text("Today · \(Fmt.short(store.todaySeconds()))")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if store.pendingCount > 0 {
                Button {
                    Task { await store.retryPending(silent: false) }
                } label: {
                    Label("\(store.pendingCount) not sent · Retry", systemImage: "arrow.clockwise")
                        .foregroundStyle(Theme.pink)
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                .help("These logs failed to reach the sheet. Click to try again.")
            }
            Button { showClients = true } label: { Image(systemName: "person.2") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Clients")
            Button { store.showSettings = true } label: { Image(systemName: "gearshape") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Settings")
            Button {
                if let url = FolderService.chooseExistingFolder() {
                    _ = store.importFolder(url)
                    filter = .open
                }
            } label: { Image(systemName: "folder.badge.plus") }
                .buttonStyle(CircleIconButtonStyle())
                .help("Import an existing task folder")
            Button { store.showNewTask = true } label: {
                Label("New Task", systemImage: "plus")
            }
            .buttonStyle(GradientButtonStyle())
        }
    }

    // MARK: List

    private var listControls: some View {
        HStack(spacing: 10) {
            Picker("", selection: $filter) {
                ForEach(TaskFilter.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(maxWidth: 340)
            Spacer()
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Search tasks or clients", text: $search)
                    .textFieldStyle(.plain)
                    .frame(width: 170)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(.thinMaterial, in: Capsule())
        }
    }

    private var filtered: [TaskItem] {
        store.tasks.filter { t in
            let passFilter: Bool
            switch filter {
            case .open: passFilter = t.status != .complete
            case .inProcess: passFilter = t.status == .inProcess
            case .complete: passFilter = t.status == .complete
            case .all: passFilter = true
            }
            guard passFilter else { return false }
            let q = search.trimmingCharacters(in: .whitespaces)
            if q.isEmpty { return true }
            return t.name.localizedCaseInsensitiveContains(q)
                || store.clientName(t.clientID).localizedCaseInsensitiveContains(q)
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

    var body: some View {
        let running = store.running
        HStack(spacing: 22) {
            let secs = running?.totalSeconds(at: store.now) ?? 0
            ZStack {
                TimerRing(running: running != nil,
                          progress: running == nil ? 0 : (secs.truncatingRemainder(dividingBy: 3600)) / 3600,
                          size: 112)
                Image(systemName: running == nil ? "moon.zzz" : "bolt.fill")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(Theme.cool)
            }

            VStack(alignment: .leading, spacing: 6) {
                if let t = running {
                    SectionLabel(text: "Now working on")
                    Text(t.name)
                        .font(.system(size: 20, weight: .semibold))
                        .lineLimit(2)
                    if !store.clientName(t.clientID).isEmpty {
                        Text(store.clientName(t.clientID))
                            .font(.system(size: 12, weight: .medium))
                            .foregroundStyle(.secondary)
                    }
                    Text(Fmt.clock(secs))
                        .font(.system(size: 34, weight: .semibold, design: .rounded).monospacedDigit())
                        .gradientText()
                    HStack(spacing: 8) {
                        Button { store.pause(t.id) } label: { Label("Pause", systemImage: "pause.fill") }
                            .buttonStyle(GlassButtonStyle())
                        Button { store.requestDone(t.id) } label: { Label("Done", systemImage: "checkmark") }
                            .buttonStyle(GradientButtonStyle())
                            .keyboardShortcut(.return, modifiers: .command)
                    }
                } else {
                    SectionLabel(text: "Idle")
                    Text("No timer running")
                        .font(.system(size: 20, weight: .semibold))
                    Text("Start a task below, or create a new one.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(20)
        .glassCard(radius: 24, highlight: running != nil)
        .animation(.spring(response: 0.4, dampingFraction: 0.85), value: running?.id)
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
                    StatusPill(status: task.status)
                    if task.pendingLog != nil {
                        Image(systemName: "exclamationmark.icloud")
                            .foregroundStyle(Theme.pink)
                            .help(task.pendingLog?.error ?? "Waiting to be sent")
                    }
                }
                HStack(spacing: 6) {
                    clientMenu
                    Text("·").foregroundStyle(.tertiary)
                    Text(Fmt.nice.string(from: task.createdAt))
                    if let r = task.sheetRow {
                        Text("·").foregroundStyle(.tertiary)
                        Text("Row \(r)")
                    }
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Spacer(minLength: 8)

            Text(Fmt.clock(task.totalSeconds(at: store.now)))
                .font(.system(size: 15, weight: .medium, design: .rounded).monospacedDigit())
                .foregroundStyle(task.isRunning ? AnyShapeStyle(Theme.linear) : AnyShapeStyle(HierarchicalShapeStyle.secondary))

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
                Button { store.requestDone(task.id) } label: {
                    Text(task.status == .complete ? "Log again" : "Done")
                }
                .buttonStyle(GradientButtonStyle(compact: true))
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .glassCard(radius: 16, highlight: task.isRunning || dropping)
        .scaleEffect(hovering ? 1.005 : 1)
        .onHover { hovering = $0 }
        .animation(.easeOut(duration: 0.15), value: hovering)
        .contextMenu {
            Button(task.isRunning ? "Pause" : "Start") { store.toggle(task.id) }
            Button("Done / Log to Sheet…") { store.requestDone(task.id) }
            Divider()
            Button("Copy Task Name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(task.name, forType: .string)
            }
            if let f = task.folderURL {
                Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) }
            }
            Menu("Mark as") {
                ForEach(TaskStatus.allCases) { s in
                    Button(s.title) { store.update(task.id) { $0.status = s } }
                }
            }
            Divider()
            Button("Delete Task", role: .destructive) { confirmDelete = true }
        }
        .confirmationDialog("Delete “\(task.name)”?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) { store.delete(task.id) }
        } message: {
            Text("This only removes it from TaskTimer. The folder and the sheet row stay.")
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

    private var clientMenu: some View {
        Menu {
            ForEach(store.clients) { c in
                Button(c.name) { store.setClient(task.id, c.id) }
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
