import Foundation

// MARK: - Status

enum TaskStatus: String, Codable, CaseIterable, Identifiable {
    case active      // being worked on, never logged yet
    case inProcess   // logged to the sheet as "In Process"
    case complete    // logged to the sheet as "Complete"

    var id: String { rawValue }

    var title: String {
        switch self {
        case .active: return "Active"
        case .inProcess: return "In Process"
        case .complete: return "Complete"
        }
    }

    /// Text written into the Status column of the team sheet
    /// (as picked in Settings → Sheet, filled in from the sheet's Status dropdown).
    var sheetLabel: String {
        switch self {
        case .complete:
            let v = Pref.string(Pref.statusComplete)
            return v.isEmpty ? "Complete" : v
        default:
            let v = Pref.string(Pref.statusInProcess)
            return v.isEmpty ? "In Process" : v
        }
    }
}

// MARK: - Client

struct Client: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    /// true when the last Sync didn't find this name in the sheet's Account dropdown.
    var missingFromSheet: Bool?
}

// MARK: - Work session

struct WorkSession: Codable, Hashable {
    var start: Date
    var end: Date?
}

// MARK: - Task

struct TaskItem: Identifiable, Codable, Hashable {
    var id: UUID = UUID()
    var name: String
    var clientID: UUID?
    var folderPath: String?
    var createdAt: Date = Date()
    var sessions: [WorkSession] = []
    var status: TaskStatus = .active
    /// Minutes added or removed by hand (e.g. forgot to start the timer).
    var manualAdjust: TimeInterval = 0
    /// Total seconds already written to the sheet.
    var loggedSeconds: TimeInterval = 0
    /// Row number in the sheet from the last successful log.
    var sheetRow: Int?
    var lastLoggedAt: Date?
    /// A log that failed (no internet, etc.) and is waiting to be retried.
    var pendingLog: PendingLog?
    /// Set on amends (subtasks): the task they belong to.
    var parentID: UUID?
    /// Tab of the sheet that holds sheetRow.
    var sheetTab: String?

    var isSubtask: Bool { parentID != nil }

    var isRunning: Bool {
        guard let last = sessions.last else { return false }
        return last.end == nil
    }

    func rawSeconds(at now: Date = Date()) -> TimeInterval {
        sessions.reduce(0) { sum, s in
            sum + max(0, (s.end ?? now).timeIntervalSince(s.start))
        }
    }

    func totalSeconds(at now: Date = Date()) -> TimeInterval {
        max(0, rawSeconds(at: now) + manualAdjust)
    }

    var folderURL: URL? {
        guard let p = folderPath else { return nil }
        return URL(fileURLWithPath: p)
    }

    init(name: String, clientID: UUID?, folderPath: String?) {
        self.name = name
        self.clientID = clientID
        self.folderPath = folderPath
    }

    // Tolerant decoding so older data files keep loading after updates.
    enum CodingKeys: String, CodingKey {
        case id, name, clientID, folderPath, createdAt, sessions, status
        case manualAdjust, loggedSeconds, sheetRow, lastLoggedAt, pendingLog
        case parentID, sheetTab
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self, forKey: .id) ?? UUID()
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Untitled"
        clientID = try c.decodeIfPresent(UUID.self, forKey: .clientID)
        folderPath = try c.decodeIfPresent(String.self, forKey: .folderPath)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date()
        sessions = try c.decodeIfPresent([WorkSession].self, forKey: .sessions) ?? []
        status = try c.decodeIfPresent(TaskStatus.self, forKey: .status) ?? .active
        manualAdjust = try c.decodeIfPresent(TimeInterval.self, forKey: .manualAdjust) ?? 0
        loggedSeconds = try c.decodeIfPresent(TimeInterval.self, forKey: .loggedSeconds) ?? 0
        sheetRow = try c.decodeIfPresent(Int.self, forKey: .sheetRow)
        lastLoggedAt = try c.decodeIfPresent(Date.self, forKey: .lastLoggedAt)
        pendingLog = try c.decodeIfPresent(PendingLog.self, forKey: .pendingLog)
        parentID = try c.decodeIfPresent(UUID.self, forKey: .parentID)
        sheetTab = try c.decodeIfPresent(String.self, forKey: .sheetTab)
    }
}

/// Everything needed to (re)send one row to the sheet.
struct PendingLog: Codable, Hashable {
    var task: String
    var client: String
    var member: String
    var status: String
    var date: String          // yyyy-MM-dd
    var seconds: TimeInterval // the time this entry represents
    var totalAfter: TimeInterval
    var updateRow: Int?
    var folder: String
    var error: String?
    /// "auto" (current month's tab) or "manual" (the named tab). nil = old entries.
    var tabMode: String?
    var tab: String?
}

// MARK: - Saved data file

struct AppData: Codable {
    var tasks: [TaskItem] = []
    var clients: [Client] = []
}
