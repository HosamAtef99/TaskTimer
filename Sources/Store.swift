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

    private var ticker: Timer?
    private var saveWork: DispatchWorkItem?
    private var retryTimer: Timer?

    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer", isDirectory: true)
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

    func deleteClient(_ id: UUID) {
        clients.removeAll { $0.id == id }
    }

    func taskCount(for clientID: UUID) -> Int {
        tasks.filter { $0.clientID == clientID }.count
    }

    // MARK: - Tasks

    @discardableResult
    func addTask(name: String, clientID: UUID?, folder: URL?, start: Bool) -> UUID {
        var t = TaskItem(name: name, clientID: clientID, folderPath: folder?.path)
        if let folder { writeMarker(t, in: folder) }
        if start {
            stopAll()
            t.sessions.append(WorkSession(start: Date()))
        }
        tasks.insert(t, at: 0)
        return t.id
    }

    /// Imports an existing folder as a task (re-uses its saved info if present).
    func importFolder(_ url: URL) -> UUID {
        if let existing = tasks.first(where: { $0.folderPath == url.path }) { return existing.id }
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
        if let t = task(id), let f = t.folderURL { writeMarker(t, in: f) }
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
            if t.status == .complete { t.status = .inProcess } // feedback round on a finished task
        }
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

    func toggle(_ id: UUID) {
        guard let t = task(id) else { return }
        t.isRunning ? pause(id) : start(id)
    }

    func delete(_ id: UUID) {
        tasks.removeAll { $0.id == id }
    }

    func requestDone(_ id: UUID) {
        doneTarget = DoneTarget(id: id)
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

        let entry = PendingLog(
            task: name,
            client: clientName(clientID),
            member: Pref.string(Pref.memberName),
            status: status.sheetLabel,
            date: Fmt.isoDay.string(from: date),
            seconds: secondsForEntry,
            totalAfter: totalSeconds,
            updateRow: useRow,
            folder: t.folderPath ?? "",
            error: nil)

        update(id) { $0.status = status }
        return await send(entry, for: id, silent: false)
    }

    @discardableResult
    private func send(_ entry: PendingLog, for id: UUID, silent: Bool) async -> Bool {
        do {
            let r = try await SheetService.log(entry)
            update(id) { t in
                t.sheetRow = r.row ?? t.sheetRow
                t.loggedSeconds = entry.totalAfter
                t.lastLoggedAt = Date()
                t.pendingLog = nil
            }
            let verb = (r.updated ?? false) ? "Updated row" : "Added row"
            let rowText = r.row.map { " \($0)" } ?? ""
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
