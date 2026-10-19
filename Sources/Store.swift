import Foundation
import AppKit
import SwiftUI
import UserNotifications

struct DoneTarget: Identifiable, Equatable { let id: UUID }

@MainActor
final class Store: ObservableObject {
    static let shared = Store()

    @Published var tasks: [TaskItem] = [] { didSet { scheduleSave() } }
    @Published var clients: [Client] = [] { didSet { scheduleSave() } }
    @Published var now = Date()

    // UI requests (so the menu bar can ask the main window to show a sheet)
    @Published var doneTarget: DoneTarget?
    @Published var showNewTask = false
    @Published var showSettings = false
    @Published var toast: String?
    /// Bumped to ask the menu bar item to open the main window (it holds openWindow).
    @Published var windowRequest = 0
    /// Set when the leader opens the weekly report notification.
    @Published var teamReportRequest = false

    private var ticker: Timer?
    /// Tasks whose row is being sent right now (stops a retry from sending the same row twice).
    private var inFlight: Set<UUID> = []
    private var saveWork: DispatchWorkItem?
    private var retryTimer: Timer?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer Dev", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("data.json")
    }()

    private init() {
        load()
        ticker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.now = Date() }
        }
        retryTimer = Timer.scheduledTimer(withTimeInterval: 120, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.retryPending(silent: true) }
        }
        let ws = NSWorkspace.shared.notificationCenter
        ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, Pref.bool(Pref.pauseOnSleep) else { return }
                if let r = self.running { self.pause(r.id) }
            }
        }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: fileURL) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? dec.decode(AppData.self, from: data) {
            tasks = d.tasks
            clients = d.clients
        }
    }

    private func scheduleSave() {
        saveWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            Task { @MainActor in self?.saveNow() }
        }
        saveWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4, execute: work)
    }

    func saveNow() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(AppData(tasks: tasks, clients: clients)) else { return }
        try? data.write(to: fileURL, options: .atomic)
        CloudSync.shared.scheduleSync()
    }

    var dataFolder: URL { fileURL.deletingLastPathComponent() }

    // MARK: - Lookups

    var running: TaskItem? { tasks.first { $0.isRunning } }

    func index(_ id: UUID) -> Int? { tasks.firstIndex { $0.id == id } }
    func task(_ id: UUID) -> TaskItem? { tasks.first { $0.id == id } }
    func client(_ id: UUID?) -> Client? {
        guard let id else { return nil }
        return clients.first { $0.id == id }
    }
    func clientName(_ id: UUID?) -> String { client(id)?.name ?? "" }

    // MARK: - Amends (subtasks)

    func parent(of t: TaskItem) -> TaskItem? { t.parentID.flatMap { task($0) } }

    func subtasks(of id: UUID) -> [TaskItem] {
        tasks.filter { $0.parentID == id }.sorted { $0.createdAt < $1.createdAt }
    }

    /// The name written in the sheet: "Task" or "Task - Amend 1".
    func displayName(_ t: TaskItem) -> String {
        if let p = parent(of: t) { return "\(p.name) - \(t.name)" }
        return t.name
    }

    /// Time of a task plus all of its amends.
    func groupSeconds(_ id: UUID) -> TimeInterval {
        let own = task(id)?.totalSeconds(at: now) ?? 0
        return subtasks(of: id).reduce(own) { $0 + $1.totalSeconds(at: now) }
    }

    /// Adds "Amend N" under a task (same client and folder) and starts its timer.
    @discardableResult
    func addAmend(to parentID: UUID, start: Bool = true) -> UUID? {
        guard let p = task(parentID), p.parentID == nil else { return nil }
        let used = subtasks(of: parentID).compactMap { s -> Int? in
            let parts = s.name.split(separator: " ")
            guard parts.count == 2, parts[0].lowercased() == "amend" else { return nil }
            return Int(parts[1])
        }
        let n = max(used.max() ?? 0, subtasks(of: parentID).count) + 1
        var s = TaskItem(name: "Amend \(n)", clientID: p.clientID, folderPath: p.folderPath)
        s.parentID = parentID
        if start {
            stopAll()
            s.sessions.append(WorkSession(start: Date()))
        }
        tasks.insert(s, at: 0)
        return s.id
    }

    // MARK: - Clients from the sheet

    /// Adopts the sheet's Account list: adds new accounts, fixes spelling, flags ones no longer in the sheet.
    /// Nothing is deleted, so older tasks keep their client.
    func syncClients(_ names: [String]) {
        let sheet = names.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        guard !sheet.isEmpty else { return }
        func same(_ a: String, _ b: String) -> Bool { a.caseInsensitiveCompare(b) == .orderedSame }

        var list = clients
        for n in sheet where !list.contains(where: { same($0.name, n) }) {
            list.append(Client(name: n))
        }
        for i in list.indices {
            if let exact = sheet.first(where: { same($0, list[i].name) }) {
                list[i].name = exact
                list[i].missingFromSheet = nil
            } else {
                list[i].missingFromSheet = true
            }
        }
        // Sheet order first (as in the dropdown), then anything the sheet no longer has.
        func rank(_ c: Client) -> Int { sheet.firstIndex(where: { same($0, c.name) }) ?? Int.max }
        list.sort {
            let a = rank($0), b = rank($1)
            if a != b { return a < b }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
        if list != clients { clients = list }
    }

    var pendingCount: Int { tasks.filter { $0.pendingLog != nil }.count }

    func todaySeconds() -> TimeInterval {
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        var sum: TimeInterval = 0
        for t in tasks {
            for s in t.sessions {
                let e = s.end ?? now
                let a = max(s.start, start)
                if e > a { sum += e.timeIntervalSince(a) }
            }
        }
        return sum
    }

    // MARK: - Clients

    @discardableResult
    func addClient(_ name: String) -> Client? {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return nil }
        if let existing = clients.first(where: { $0.name.caseInsensitiveCompare(n) == .orderedSame }) {
            return existing
        }
        let c = Client(name: n)
        clients.append(c)
        clients.sort { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return c
    }

    func renameClient(_ id: UUID, to name: String) {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty else { return }
        clients[i].name = n
    }

    func setClientFolder(_ id: UUID, _ path: String?) {
        guard let i = clients.firstIndex(where: { $0.id == id }) else { return }
        clients[i].folderPath = path
    }

    func deleteClient(_ id: UUID) {
        clients.removeAll { $0.id == id }
    }

    func taskCount(for clientID: UUID) -> Int {
        tasks.filter { $0.clientID == clientID }.count
    }

    // MARK: - Tasks

    @discardableResult
    func addTask(name: String, clientID: UUID?, folder: URL?, start: Bool, incoming: Bool = false,
                 wantsFolder: Bool = false, folderBase: String? = nil) -> UUID {
        var t = TaskItem(name: name, clientID: clientID, folderPath: folder?.path)
        if incoming { t.status = .incoming }
        if folder == nil && wantsFolder {
            t.wantsFolder = true
            t.folderBase = folderBase
        }
        if let folder { writeMarker(t, in: folder) }
        if start && !incoming {
            stopAll()
            t.sessions.append(WorkSession(start: Date()))
        }
        tasks.insert(t, at: 0)
        return t.id
    }

    /// A task the team leader added for you (arrives from the team database).
    func adoptAssigned(id: UUID, name: String, client: String, createdAt: Date) {
        guard task(id) == nil else { return }
        let clientID = client.isEmpty ? nil : addClient(client)?.id
        var t = TaskItem(name: name, clientID: clientID, folderPath: nil)
        t.id = id
        t.createdAt = createdAt
        t.status = .incoming
        t.wantsFolder = true
        tasks.insert(t, at: 0)
    }

    /// Imports an existing folder as a task (re-uses its saved info if present).
    func importFolder(_ url: URL) -> UUID {
        if let existing = tasks.first(where: { $0.folderPath == url.path && $0.parentID == nil }) { return existing.id }
        var clientID: UUID?
        let marker = url.appendingPathComponent(".tasktimer.json")
        if let data = try? Data(contentsOf: marker),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let cname = obj["client"] as? String, !cname.isEmpty {
            clientID = addClient(cname)?.id
        }
        return addTask(name: url.lastPathComponent, clientID: clientID, folder: url, start: false)
    }

    private func writeMarker(_ t: TaskItem, in folder: URL) {
        let obj: [String: Any] = [
            "task": t.name,
            "client": clientName(t.clientID),
            "created": Fmt.isoDay.string(from: t.createdAt),
        ]
        if let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted]) {
            try? data.write(to: folder.appendingPathComponent(".tasktimer.json"))
        }
    }

    func update(_ id: UUID, _ change: (inout TaskItem) -> Void) {
        guard let i = index(id) else { return }
        change(&tasks[i])
    }

    func setClient(_ id: UUID, _ clientID: UUID?) {
        update(id) { $0.clientID = clientID }
        if let t = task(id), t.parentID == nil, let f = t.folderURL { writeMarker(t, in: f) }
    }

    func stopAll() {
        let n = Date()
        for i in tasks.indices where tasks[i].isRunning {
            tasks[i].sessions[tasks[i].sessions.count - 1].end = n
        }
    }

    func start(_ id: UUID) {
        stopAll()
        update(id) { t in
            t.sessions.append(WorkSession(start: Date()))
            // Starting an Incoming task, or a feedback round on a finished one, puts it In Progress.
            if t.status == .incoming || t.status == .complete { t.status = .active }
        }
        createDeferredFolder(id)
    }

    func pause(_ id: UUID) {
        update(id) { t in
            guard t.isRunning else { return }
            t.sessions[t.sessions.count - 1].end = Date()
            // drop accidental sub-3-second sessions
            if let s = t.sessions.last, let e = s.end, e.timeIntervalSince(s.start) < 3 {
                t.sessions.removeLast()
            }
        }
    }

    /// Stops a task's timer and any of its amends' timers.
    func stopTaskAndAmends(_ id: UUID) {
        pause(id)
        for s in subtasks(of: id) where s.isRunning { pause(s.id) }
        flash("Timer stopped")
    }

    func runningAmend(of id: UUID) -> UUID? {
        subtasks(of: id).first(where: { $0.isRunning })?.id
    }

    func showMainWindow() {
        windowRequest += 1
        NSApp.activate(ignoringOtherApps: true)
    }

    func toggle(_ id: UUID) {
        guard let t = task(id) else { return }
        t.isRunning ? pause(id) : start(id)
    }

    /// Deleting a task also deletes its amends.
    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id || $0.parentID == id }
    }

    func requestDone(_ id: UUID) {
        doneTarget = DoneTarget(id: id)
    }

    /// Done (no sheet): stops the timer and saves the final hours, day and status.
    func complete(_ id: UUID, name: String, clientID: UUID?, status: TaskStatus,
                  date: Date, totalSeconds: TimeInterval) {
        pause(id)
        guard let t = task(id) else { return }
        let raw = t.rawSeconds()
        update(id) { t in
            t.name = name
            t.clientID = clientID
            t.status = status
            t.workDate = date
            t.manualAdjust = totalSeconds - raw
        }
        flash(status == .complete
              ? "“\(name)” completed · \(Fmt.hours(totalSeconds)) h"
              : "Saved “\(name)” · \(Fmt.hours(totalSeconds)) h")
    }

    // MARK: - Task folders

    /// The folder that holds month folders for a new task (the client's folder or the
    /// months folder, per Settings → Folders), or nil when the location is picked by hand.
    func autoFolderRoot(for clientID: UUID?) -> URL? {
        let fm = FileManager.default
        switch Pref.string(Pref.folderMode) {
        case "client":
            guard let p = client(clientID)?.folderPath, !p.isEmpty, fm.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        case "months":
            let p = Pref.string(Pref.monthsRoot)
            guard !p.isEmpty, fm.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        default:
            return nil
        }
    }

    /// Makes a task folder (this month's folder, the subfolder tree and the AE file).
    /// Returns nil if the person cancelled choosing a location. An existing folder of the
    /// same name is reused instead of failing.
    func makeTaskFolder(name: String, clientID: UUID?, location: String?) throws -> URL? {
        let fm = FileManager.default
        let base: URL
        if let root = autoFolderRoot(for: clientID) {
            base = try MonthFolder.folder(in: root)
        } else if let l = location, !l.isEmpty, fm.fileExists(atPath: l) {
            base = URL(fileURLWithPath: l)
            UserDefaults.standard.set(l, forKey: Pref.lastLocation)
        } else if let picked = FolderService.chooseLocation() {
            base = picked
        } else {
            return nil
        }
        let clean = FolderService.cleanName(name)
        let existing = base.appendingPathComponent(clean, isDirectory: true)
        if fm.fileExists(atPath: existing.path) { return existing }
        return try FolderService.createProject(name: clean, in: base)
    }

    /// Opens the new folder / AE file if Settings say so.
    func openNewFolder(_ folder: URL) {
        if Pref.bool(Pref.openFinderOnCreate) { NSWorkspace.shared.open(folder) }
        if Pref.bool(Pref.openAEOnCreate), let ae = FolderService.aeFile(in: folder) {
            NSWorkspace.shared.open(ae)
        }
    }

    /// An Incoming task was started: make the folder it was waiting for.
    private func createDeferredFolder(_ id: UUID) {
        guard let t = task(id), t.parentID == nil, t.folderPath == nil, t.wantsFolder == true else { return }
        do {
            guard let f = try makeTaskFolder(name: t.name, clientID: t.clientID, location: t.folderBase) else {
                flash("No folder made for “\(t.name)” — the timer is running")
                return
            }
            update(id) { t in
                t.folderPath = f.path
                t.wantsFolder = nil
                t.folderBase = nil
            }
            for s in subtasks(of: id) where s.folderPath == nil {
                update(s.id) { $0.folderPath = f.path }
            }
            if let t2 = task(id) { writeMarker(t2, in: f) }
            openNewFolder(f)
            flash("Folder ready: \((f.path as NSString).abbreviatingWithTildeInPath)")
        } catch {
            flash("Couldn't make the folder: \(error.localizedDescription)")
        }
    }

    // MARK: - Months

    /// First day of the month each task was created in, newest first.
    var taskMonths: [Date] {
        let cal = Calendar.current
        let starts = Set(tasks.compactMap { cal.dateInterval(of: .month, for: $0.createdAt)?.start })
        return starts.sorted(by: >)
    }

    // MARK: - Logging to the sheet

    /// Called from the Done sheet.
    func finish(_ id: UUID, name: String, clientID: UUID?, status: TaskStatus,
                date: Date, totalSeconds: TimeInterval, updateExisting: Bool) async -> Bool {
        pause(id)
        guard let t0 = task(id) else { return false }

        // Apply a manual time edit as an adjustment, so the timer keeps adding on top of it.
        let raw = t0.rawSeconds()
        update(id) { t in
            t.name = name
            t.clientID = clientID
            t.manualAdjust = totalSeconds - raw
        }
        guard let t = task(id) else { return false }

        let useRow = updateExisting ? t.sheetRow : nil
        let secondsForEntry = useRow != nil ? totalSeconds : max(0, totalSeconds - t.loggedSeconds)

        // Updating a row: write to the tab that holds it. New row: the tab from Settings.
        let target: (mode: String, tab: String)
        if useRow != nil, let tab = t.sheetTab, !tab.isEmpty {
            target = ("manual", tab)
        } else {
            target = Pref.tabTarget()
        }

        let entry = PendingLog(
            task: displayName(t),
            client: clientName(clientID),
            member: Pref.string(Pref.memberName),
            status: status.sheetLabel,
            date: Fmt.isoDay.string(from: date),
            seconds: secondsForEntry,
            totalAfter: totalSeconds,
            updateRow: useRow,
            folder: t.folderPath ?? "",
            error: nil,
            tabMode: target.mode,
            tab: target.tab)

        update(id) { $0.status = status }
        return await send(entry, for: id, silent: false)
    }

    @discardableResult
    private func send(_ entry: PendingLog, for id: UUID, silent: Bool) async -> Bool {
        guard !inFlight.contains(id) else { return false }
        inFlight.insert(id)
        defer { inFlight.remove(id) }
        do {
            let r = try await SheetService.log(entry)
            update(id) { t in
                t.sheetRow = r.row ?? t.sheetRow
                if let tab = r.tab { t.sheetTab = tab }
                t.loggedSeconds = entry.totalAfter
                t.lastLoggedAt = Date()
                t.pendingLog = nil
            }
            let verb = (r.updated ?? false) ? "Updated row" : "Added row"
            let rowText = (r.row.map { " \($0)" } ?? "") + (r.tab.map { " (\($0))" } ?? "")
            notify(title: "Logged to sheet ✓", body: "\(entry.task) — \(entry.status) — \(Fmt.sheetTime(entry.seconds)) (\(verb)\(rowText))")
            flash("\(verb)\(rowText) in the sheet ✓")
            return true
        } catch {
            var e = entry
            e.error = error.localizedDescription
            update(id) { $0.pendingLog = e }
            if !silent {
                notify(title: "Couldn't log to sheet", body: "\(entry.task): \(error.localizedDescription) — saved, will retry.")
                flash("Not sent: \(error.localizedDescription)")
            }
            return false
        }
    }

    func retryPending(silent: Bool) async {
        for t in tasks {
            if let p = t.pendingLog {
                await send(p, for: t.id, silent: silent)
            }
        }
    }

    // MARK: - Feedback

    func flash(_ text: String) {
        withAnimation(.spring(response: 0.35, dampingFraction: 0.8)) { toast = text }
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: 3_500_000_000)
            guard let self, self.toast == text else { return }
            withAnimation(.easeOut(duration: 0.25)) { self.toast = nil }
        }
    }

    func notify(title: String, body: String) {
        let c = UNMutableNotificationContent()
        c.title = title
        c.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: c, trigger: nil)
        UNUserNotificationCenter.current().add(req, withCompletionHandler: nil)
    }
}
