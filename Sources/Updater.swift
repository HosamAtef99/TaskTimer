import Foundation
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Where updates come from: the GitHub repo's latest release.
/// GitHub Actions builds TaskTimer.app on every push and publishes it as a release with
/// three files: TaskTimer.app.zip, VERSION and NOTES.txt.
enum UpdateSource {
    static let repo = "mo-animation/TaskTimer"   // owner/name

    static var isConfigured: Bool { !repo.hasPrefix("__") && repo.contains("/") }

    static func asset(_ name: String) -> URL? {
        URL(string: "https://github.com/\(repo)/releases/latest/download/\(name)")
    }
    static var releasesPage: URL? { URL(string: "https://github.com/\(repo)/releases") }
}

@MainActor
final class UpdateManager: ObservableObject {
    static let shared = UpdateManager()

    struct Candidate: Equatable {
        enum Kind: Equatable {
            case release(URL)      // ready-built TaskTimer.app.zip to download
            case appZip(URL)       // a TaskTimer.app.zip on disk
            case sourceZip(URL)    // a source zip on disk (needs the Command Line Tools)
        }
        let version: String
        let notes: String
        let kind: Kind
    }

    @Published var available: Candidate?
    @Published var installing = false
    @Published var progressText = ""
    @Published var lastMessage: String?
    @Published var lastChecked: Date?

    /// Set right before quitting for an update, so the running timer is left running.
    private(set) var quittingForUpdate = false

    private var timer: Timer?
    private var activeObserver: NSObjectProtocol?

    nonisolated static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0"
    }

    private init() {}

    func start() {
        announceIfJustUpdated()
        check(silent: true)
        // Every 15 minutes, and when the app comes to the front (at most every 5 minutes).
        timer = Timer.scheduledTimer(withTimeInterval: 15 * 60, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.check(silent: true) }
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                if let last = self.lastChecked, Date().timeIntervalSince(last) < 5 * 60 { return }
                self.check(silent: true)
            }
        }
    }

    // MARK: - Checking

    func check(silent: Bool) {
        guard !installing else { return }
        guard UpdateSource.isConfigured else {
            if !silent { lastMessage = "Updates aren't connected to GitHub in this build." }
            return
        }
        lastChecked = Date()
        Task { @MainActor in
            do {
                let latest = try await Self.fetchText("VERSION").trimmingCharacters(in: .whitespacesAndNewlines)
                guard !latest.isEmpty, latest.count < 20 else { throw URLError(.cannotParseResponse) }
                if Self.isNewer(latest, than: Self.currentVersion), let zip = UpdateSource.asset("TaskTimer.app.zip") {
                    let notes = (try? await Self.fetchText("NOTES.txt")) ?? ""
                    available = Candidate(version: latest, notes: Self.shortNotes(notes), kind: .release(zip))
                } else {
                    available = nil
                }
                if !silent {
                    let msg = available.map { "Version \($0.version) is ready — press Update" }
                        ?? "You're on the latest version (\(Self.currentVersion))"
                    lastMessage = msg
                    Store.shared.flash(msg)
                }
            } catch {
                if !silent {
                    lastMessage = "Couldn't check for updates: \(error.localizedDescription)"
                }
            }
        }
    }

    nonisolated private static func fetchText(_ asset: String) async throws -> String {
        guard let url = UpdateSource.asset(asset) else { throw URLError(.badURL) }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 20)
        req.setValue("TaskTimer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.fileDoesNotExist) }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func shortNotes(_ s: String) -> String {
        let lines = s.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("#") }
            .map { $0.hasPrefix("- ") ? String($0.dropFirst(2)) : $0 }
        return lines.prefix(3).joined(separator: " · ")
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").map { Int($0) ?? 0 }
        let pb = b.split(separator: ".").map { Int($0) ?? 0 }
        for i in 0..<max(pa.count, pb.count) {
            let x = i < pa.count ? pa[i] : 0, y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    // MARK: - Installing

    /// Lets the user pick a TaskTimer.app.zip (ready-built) or a TaskTimer source zip.
    func installFromFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.allowedContentTypes = [.zip]
        panel.message = "Choose a TaskTimer zip to install"
        panel.prompt = "Install"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        let listing = Self.run("/usr/bin/unzip", ["-Z1", url.path]) ?? ""
        if listing.contains("TaskTimer.app/Contents/Info.plist") {
            install(Candidate(version: "?", notes: "", kind: .appZip(url)))
        } else if let v = Self.run("/usr/bin/unzip", ["-p", url.path, "*/Resources/VERSION"])?
                    .trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty {
            install(Candidate(version: v, notes: "", kind: .sourceZip(url)))
        } else {
            lastMessage = "That zip doesn't look like TaskTimer."
        }
    }

    func install(_ c: Candidate) {
        guard !installing else { return }
        installing = true
        lastMessage = nil
        Task { @MainActor in
            do {
                switch c.kind {
                case .release(let remote):
                    progressText = "Downloading version \(c.version)…"
                    let zip = try await Self.download(remote)
                    try await swapIn(appZip: zip)
                case .appZip(let zip):
                    try await swapIn(appZip: zip)
                case .sourceZip(let zip):
                    try buildFromSource(zip)
                }
            } catch {
                installing = false
                quittingForUpdate = false
                progressText = ""
                lastMessage = "Update failed, nothing changed: \(error.localizedDescription)"
                Store.shared.flash("Update failed — nothing changed")
            }
        }
    }

    nonisolated private static func download(_ url: URL) async throws -> URL {
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 120)
        req.setValue("TaskTimer/\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else { throw URLError(.badServerResponse) }
        let dest = workDir().appendingPathComponent("TaskTimer.app.zip")
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        return dest
    }

    nonisolated private static func workDir() -> URL {
        let d = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("TaskTimer/update", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    nonisolated private static var logURL: URL {
        let logs = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        return logs.appendingPathComponent("TaskTimer-update.log")
    }

    /// Unpacks a ready-built app, checks it, then quits and lets a tiny helper swap it in.
    private func swapIn(appZip zip: URL) async throws {
        progressText = "Installing…"
        let fm = FileManager.default
        let unpack = Self.workDir().appendingPathComponent("unpacked", isDirectory: true)
        try? fm.removeItem(at: unpack)
        try fm.createDirectory(at: unpack, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path]) != nil else {
            throw UpdateError("Couldn't unpack the update.")
        }
        let newApp = unpack.appendingPathComponent("TaskTimer.app")
        guard let info = NSDictionary(contentsOf: newApp.appendingPathComponent("Contents/Info.plist")),
              (info["CFBundleIdentifier"] as? String) == Bundle.main.bundleIdentifier else {
            throw UpdateError("The download isn't a TaskTimer app.")
        }

        let dest = Bundle.main.bundleURL
        let parent = dest.deletingLastPathComponent()
        guard fm.isWritableFile(atPath: parent.path) else {
            throw UpdateError("Can't write to \(parent.path). Move TaskTimer to Applications and try again.")
        }

        // Swap only after this copy has quit; keep the old app if anything fails.
        let helper = Self.workDir().appendingPathComponent("swap.sh")
        let script = """
        #!/bin/bash
        PID="$1"; SRC="$2"; DEST="$3"
        for i in $(seq 1 100); do kill -0 "$PID" 2>/dev/null || break; sleep 0.2; done
        rm -rf "$DEST.new" "$DEST.old"
        if ditto "$SRC" "$DEST.new" && mv "$DEST" "$DEST.old" && mv "$DEST.new" "$DEST"; then
          rm -rf "$DEST.old"
          xattr -dr com.apple.quarantine "$DEST" 2>/dev/null || true
          echo "TT_SWAP_OK"
        else
          [ -d "$DEST" ] || mv "$DEST.old" "$DEST" 2>/dev/null
          rm -rf "$DEST.new"
          echo "TT_SWAP_FAILED"
        fi
        open "$DEST"
        """
        try script.write(to: helper, atomically: true, encoding: .utf8)

        Store.shared.saveNow()
        quittingForUpdate = true
        UserDefaults.standard.set(Self.currentVersion, forKey: "updatedFromVersion")

        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "nohup /bin/bash \"$0\" \"$1\" \"$2\" \"$3\" > \"$4\" 2>&1 &",
                       helper.path, String(ProcessInfo.processInfo.processIdentifier),
                       newApp.path, dest.path, Self.logURL.path]
        try p.run()
        p.waitUntilExit()
        try? await Task.sleep(nanoseconds: 300_000_000)
        NSApp.terminate(nil)
    }

    /// Old path for source zips: rebuild with the bundled build script (needs Command Line Tools).
    private func buildFromSource(_ zip: URL) throws {
        progressText = "Building… TaskTimer will reopen by itself in about a minute."
        let unpack = Self.workDir().appendingPathComponent("source", isDirectory: true)
        try? FileManager.default.removeItem(at: unpack)
        try FileManager.default.createDirectory(at: unpack, withIntermediateDirectories: true)
        guard Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, unpack.path]) != nil,
              let script = Self.findFile("Build TaskTimer.command", in: unpack) else {
            throw UpdateError("Couldn't open the source zip.")
        }
        Store.shared.saveNow()
        quittingForUpdate = true
        UserDefaults.standard.set(Self.currentVersion, forKey: "updatedFromVersion")
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/bash")
        p.arguments = ["-c", "TT_UPDATE=1 nohup /bin/bash \"$0\" > \"$1\" 2>&1 &", script.path, Self.logURL.path]
        try p.run()
        watchBuildLog()
    }

    private func watchBuildLog() {
        Task { @MainActor in
            for _ in 0..<240 {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard let text = try? String(contentsOf: Self.logURL, encoding: .utf8) else { continue }
                if text.contains("TT_BUILD_FAILED") {
                    let firstError = text.split(separator: "\n").first { $0.contains("error:") }.map(String.init)
                    installing = false
                    quittingForUpdate = false
                    progressText = ""
                    lastMessage = "The update didn't build, so you're still on \(Self.currentVersion). "
                        + (firstError.map { "First error: \($0)" } ?? "")
                    Store.shared.flash("Update failed — nothing changed")
                    return
                }
            }
        }
    }

    // MARK: - Helpers

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    @discardableResult
    nonisolated private static func run(_ tool: String, _ args: [String]) -> String? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8) ?? ""
    }

    nonisolated private static func findFile(_ name: String, in dir: URL) -> URL? {
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        for case let u as URL in e where u.lastPathComponent == name { return u }
        return nil
    }

    private func announceIfJustUpdated() {
        let d = UserDefaults.standard
        guard let from = d.string(forKey: "updatedFromVersion") else { return }
        d.removeObject(forKey: "updatedFromVersion")
        if from != Self.currentVersion {
            Store.shared.flash("Updated to version \(Self.currentVersion) ✓")
            Store.shared.notify(title: "TaskTimer updated", body: "Now on version \(Self.currentVersion).")
        } else if let log = try? String(contentsOf: Self.logURL, encoding: .utf8), log.contains("TT_SWAP_FAILED") {
            Store.shared.flash("Update couldn't be installed — still on \(Self.currentVersion)")
        }
    }
}

// MARK: - Banner

/// Shown at the top of the main window and the menu bar panel when an update is ready.
struct UpdateBanner: View {
    @ObservedObject var updater = UpdateManager.shared
    var compact = false

    var body: some View {
        if updater.installing {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(updater.progressText.isEmpty ? "Updating…" : updater.progressText)
                    .font(.system(size: 12, weight: .medium))
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 14).padding(.vertical, 10)
            .glassCard(radius: 14, highlight: true)
        } else if let c = updater.available {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: compact ? 14 : 18))
                    .foregroundStyle(Theme.cool)
                VStack(alignment: .leading, spacing: 1) {
                    Text("Version \(c.version) is ready")
                        .font(.system(size: compact ? 12 : 13, weight: .semibold))
                    if !compact {
                        Text(c.notes.isEmpty ? "You're on \(UpdateManager.currentVersion). Your tasks and settings stay as they are." : c.notes)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
                Button("Update") { updater.install(c) }
                    .buttonStyle(GradientButtonStyle(compact: true))
            }
            .padding(.horizontal, 14).padding(.vertical, compact ? 8 : 10)
            .glassCard(radius: 14, highlight: true)
        }
    }
}
