import SwiftUI
import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        if UserDefaults.standard.bool(forKey: Pref.hideDock) {
            NSApp.setActivationPolicy(.accessory)
        }
        MainActor.assumeIsolated {
            UpdateManager.shared.start()
            NotificationHandler.shared.install()
            RenderWatcher.shared.start()
            AERenderHelper.start()
            ExtensionInstaller.refresh()
            _ = ExtensionMonitor.shared
            if Features.sheet { SheetSync.shared.start() }
            Task { @MainActor in await CloudSync.shared.start() }
        }
    }
    // Keep running in the menu bar when the window is closed.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            // When quitting to install an update, leave the running timer open so it
            // keeps counting through the restart.
            if !UpdateManager.shared.quittingForUpdate {
                Store.shared.stopAll()
            }
            Store.shared.saveNow()
        }
    }
}

@main
struct TaskTimerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var store: Store

    init() {
        Pref.registerDefaults()
        _store = StateObject(wrappedValue: Store.shared)
    }

    var body: some Scene {
        Window("TaskTimer Dev", id: "main") {
            MainView()
                .environmentObject(store)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 640, height: 720)
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Check for Updates…") {
                    UpdateManager.shared.check(silent: false)
                }
            }
            CommandGroup(replacing: .newItem) {
                Button("New Task…") { store.showNewTask = true }
                    .keyboardShortcut("n", modifiers: .command)
            }
            CommandMenu("Timer") {
                Button(store.running == nil ? "No Timer Running" : "Pause") {
                    if let r = store.running { store.pause(r.id) }
                }
                .keyboardShortcut("p", modifiers: [.command, .shift])
                .disabled(store.running == nil)
                Button("Done…") {
                    if let r = store.running { store.requestDone(r.id) }
                }
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .disabled(store.running == nil)
            }
        }

        MenuBarExtra {
            MenuBarPanel()
                .environmentObject(store)
        } label: {
            MenuBarLabel()
                .environmentObject(store)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .environmentObject(store)
        }
    }
}

// MARK: - Menu bar

/// Kept short on purpose: when the menu bar is full (especially next to the camera notch)
/// macOS hides items that don't fit, and a wide label that changes width every second
/// is the first to disappear.
struct MenuBarLabel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow
    @AppStorage(Pref.menuBarStyle) var style = "time"

    var body: some View {
        label
            .onChange(of: store.windowRequest) { _ in
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
    }

    @ViewBuilder
    private var label: some View {
        if let r = store.running, style != "icon" {
            let secs = r.totalSeconds(at: store.now)
            HStack(spacing: 3) {
                Image(systemName: "timer")
                Text(style == "seconds" ? Fmt.clock(secs) : Fmt.menuClock(secs))
                    .monospacedDigit()
            }
        } else {
            Image(systemName: store.running == nil ? "timer" : "timer.circle.fill")
        }
    }
}

struct MenuBarPanel: View {
    @EnvironmentObject var store: Store
    @Environment(\.openWindow) var openWindow

    private var recent: [TaskItem] {
        Array(store.tasks.filter { $0.status != .complete && !$0.isRunning }.prefix(6))
    }

    var body: some View {
        ZStack {
            GlowBackground(animate: false)
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("TaskTimer Dev")
                        .font(.system(size: 15, weight: .bold, design: .rounded))
                        .gradientText()
                    Spacer()
                    Text("Today \(Fmt.short(store.todaySeconds()))")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                }

                UpdateBanner(compact: true)

                if let r = store.running {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(store.displayName(r)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        if !store.clientName(r.clientID).isEmpty {
                            Text(store.clientName(r.clientID)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Text(Fmt.clock(r.totalSeconds(at: store.now)))
                            .font(.system(size: 28, weight: .semibold, design: .rounded).monospacedDigit())
                            .gradientText()
                        HStack(spacing: 8) {
                            Button { store.pause(r.id) } label: { Label("Pause", systemImage: "pause.fill") }
                                .buttonStyle(GlassButtonStyle(compact: true))
                            Button {
                                show()
                                store.requestDone(r.id)
                            } label: { Label("Done", systemImage: "checkmark") }
                                .buttonStyle(GradientButtonStyle(compact: true))
                        }
                    }
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .glassCard(radius: 14, highlight: true)
                } else {
                    Text("No timer running")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }

                if !recent.isEmpty {
                    SectionLabel(text: "Open tasks")
                    VStack(spacing: 4) {
                        ForEach(recent) { t in
                            Button { store.start(t.id) } label: {
                                HStack {
                                    Image(systemName: "play.fill").font(.system(size: 9)).foregroundStyle(Theme.cool)
                                    Text(store.displayName(t)).lineLimit(1)
                                    Spacer()
                                    Text(Fmt.short(t.totalSeconds(at: store.now)))
                                        .foregroundStyle(.secondary)
                                        .monospacedDigit()
                                }
                                .font(.system(size: 12))
                                .padding(.horizontal, 10).padding(.vertical, 6)
                                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                }

                Divider()
                HStack {
                    Button {
                        show()
                        store.showNewTask = true
                    } label: { Label("New Task", systemImage: "plus") }
                        .buttonStyle(GradientButtonStyle(compact: true))
                    Button("Open") { show() }
                        .buttonStyle(GlassButtonStyle(compact: true))
                    Spacer()
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(.borderless)
                        .help("Quit TaskTimer")
                }
            }
            .padding(14)
        }
        .frame(width: 300)
    }

    private func show() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
    }
}
