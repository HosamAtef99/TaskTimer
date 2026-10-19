import SwiftUI
import AppKit
import ServiceManagement

// MARK: - Clients

struct ClientsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var inSheet = false

    @Local var newName = ""
    @Local var editing: UUID? = nil
    @Local var editText = ""
    @Local var bulk = ""
    @Local var showBulk = false

    var body: some View {
        SheetFrame(title: "Clients", subtitle: "Add them once, then pick from the list", icon: "person.2.fill") {
            HStack(spacing: 8) {
                TextField("Add a client or account", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(add)
                Button("Add", action: add)
                    .buttonStyle(GradientButtonStyle(compact: true))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button { showBulk.toggle() } label: { Image(systemName: "text.badge.plus") }
                    .buttonStyle(CircleIconButtonStyle(size: 28))
                    .help("Paste many clients at once")
            }

            if showBulk {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(text: "One client per line")
                    TextEditor(text: $bulk)
                        .font(.system(size: 12))
                        .frame(height: 90)
                        .scrollContentBackground(.hidden)
                        .padding(6)
                        .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
                    HStack {
                        Spacer()
                        Button("Add all") {
                            for line in bulk.split(whereSeparator: \.isNewline) { store.addClient(String(line)) }
                            bulk = ""
                            showBulk = false
                        }
                        .buttonStyle(GradientButtonStyle(compact: true))
                    }
                }
            }

            ScrollView {
                VStack(spacing: 6) {
                    if store.clients.isEmpty {
                        Text("No clients yet.")
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 30)
                    }
                    ForEach(store.clients) { c in
                        HStack(spacing: 10) {
                            Circle().fill(Theme.diagonal).frame(width: 8, height: 8)
                            if editing == c.id {
                                TextField("", text: $editText)
                                    .textFieldStyle(.roundedBorder)
                                    .onSubmit { store.renameClient(c.id, to: editText); editing = nil }
                            } else {
                                Text(c.name).font(.system(size: 13, weight: .medium))
                                Text("\(store.taskCount(for: c.id)) tasks")
                                    .font(.system(size: 11)).foregroundStyle(.tertiary)
                            }
                            Spacer()
                            Button { editing = c.id; editText = c.name } label: { Image(systemName: "pencil") }
                                .buttonStyle(.borderless)
                            Button { store.deleteClient(c.id) } label: { Image(systemName: "trash") }
                                .buttonStyle(.borderless)
                                .foregroundStyle(Theme.pink)
                        }
                        .padding(.horizontal, 12).padding(.vertical, 8)
                        .glassCard(radius: 10)
                    }
                }
                .padding(2)
            }
            .frame(minHeight: 220)

            if inSheet {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 440, height: inSheet ? 520 : 480)
    }

    private func add() {
        store.addClient(newName)
        newName = ""
    }
}

// MARK: - Settings

struct SettingsView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    var inSheet = false

    @AppStorage(Pref.memberName) var memberName = ""
    @AppStorage(Pref.webAppURL) var webAppURL = ""
    @AppStorage(Pref.token) var token = ""
    @AppStorage(Pref.templatePath) var templatePath = Pref.defaultTemplate
    @AppStorage(Pref.subfolders) var subfolders = Pref.defaultSubfolders
    @AppStorage(Pref.timeFormat) var timeFormat = "hm"
    @AppStorage(Pref.rounding) var rounding = 0
    @AppStorage(Pref.updateSameRow) var updateSameRow = true
    @AppStorage(Pref.hideDock) var hideDock = false
    @AppStorage(Pref.pauseOnSleep) var pauseOnSleep = true
    @AppStorage(Pref.openFinderOnCreate) var openFinder = true
    @AppStorage(Pref.openAEOnCreate) var openAE = false

    @Local var tab = 0
    @Local var testing = false
    @Local var testResult: String? = nil
    @Local var testOK = false
    @Local var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        SheetFrame(title: "Settings", subtitle: "Your name, the team sheet, and folders", icon: "gearshape.fill") {
            Picker("", selection: $tab) {
                Text("Sheet").tag(0)
                Text("Folders").tag(1)
                Text("General").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case 0: sheetTab
                case 1: foldersTab
                default: generalTab
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .topLeading)
            .glassCard(radius: 14)

            Spacer(minLength: 0)

            if inSheet {
                HStack {
                    Spacer()
                    Button("Done") { dismiss() }
                        .buttonStyle(GradientButtonStyle())
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .frame(width: 580, height: 660)
    }

    private var sheetTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "Your name (as written in the sheet)") {
                TextField("Mosap Hassan", text: $memberName).textFieldStyle(.roundedBorder)
            }
            FieldRow(label: "Web App URL (from Apps Script → Deploy)") {
                TextField("https://script.google.com/macros/s/…/exec", text: $webAppURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            FieldRow(label: "Secret token (same as TOKEN in the script)") {
                SecureField("token", text: $token).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button { test() } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small).tint(.white) }
                        Text("Test Connection")
                    }
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(testing || webAppURL.isEmpty)
                if let testResult {
                    Text(testResult)
                        .font(.system(size: 11))
                        .foregroundStyle(testOK ? Theme.green : Theme.pink)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Divider()
            HStack(spacing: 20) {
                FieldRow(label: "Time format") {
                    Picker("", selection: $timeFormat) {
                        Text("2:30").tag("hm")
                        Text("2.5").tag("decimal")
                        Text("150 (min)").tag("minutes")
                    }
                    .labelsHidden().frame(width: 130)
                }
                FieldRow(label: "Round to") {
                    Picker("", selection: $rounding) {
                        Text("Exact").tag(0)
                        Text("5 min").tag(5)
                        Text("10 min").tag(10)
                        Text("15 min").tag(15)
                        Text("30 min").tag(30)
                    }
                    .labelsHidden().frame(width: 110)
                }
            }
            Toggle("When an In Process task is logged again, update its row by default", isOn: $updateSameRow)
                .font(.system(size: 12))
        }
    }

    private var foldersTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "After Effects template (.aep)") {
                HStack {
                    TextField("Path", text: $templatePath)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(size: 11, design: .monospaced))
                    Button("Choose…") {
                        let p = NSOpenPanel()
                        p.canChooseFiles = true
                        p.canChooseDirectories = false
                        if p.runModal() == .OK, let u = p.url { templatePath = u.path }
                    }
                    .buttonStyle(GlassButtonStyle(compact: true))
                }
                if !templatePath.isEmpty && !FileManager.default.fileExists(atPath: templatePath) {
                    Text("File not found at this path.").font(.system(size: 11)).foregroundStyle(Theme.pink)
                }
            }
            FieldRow(label: "Subfolders (one per line)") {
                TextEditor(text: $subfolders)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(height: 140)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            }
            Text("Dropping files on a task moves them by type: PSD / AI → “PSD”, AEP → “AE”, audio → “Sound”, images → “Images”, video → “Videos”, everything else → “Others”. A dropped folder goes to Images or Videos when everything inside is that type, otherwise to Others.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Toggle("Open the folder in Finder after creating", isOn: $openFinder)
            Toggle("Open the AE project after creating", isOn: $openAE)
        }
    }

    private var generalTab: some View {
        VStack(alignment: .leading, spacing: 14) {
            UpdatesSection()
            Divider()
            Toggle("Open TaskTimer at login", isOn: $launchAtLogin)
                .onChange(of: launchAtLogin) { on in
                    do {
                        if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
                    } catch {
                        store.flash("Login item: \(error.localizedDescription)")
                    }
                }
            Toggle("Hide the Dock icon (menu bar only)", isOn: $hideDock)
                .onChange(of: hideDock) { hide in
                    NSApp.setActivationPolicy(hide ? .accessory : .regular)
                    NSApp.activate(ignoringOtherApps: true)
                }
            Toggle("Pause the timer when the Mac goes to sleep", isOn: $pauseOnSleep)
            Divider()
            HStack {
                Button("Show Data Folder") { NSWorkspace.shared.open(store.dataFolder) }
                    .buttonStyle(GlassButtonStyle(compact: true))
                Text("Tasks and clients are saved in data.json there.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
        }
    }

    private func test() {
        testing = true
        testResult = nil
        Task { @MainActor in
            defer { testing = false }
            do {
                let r = try await SheetService.ping()
                testOK = true
                let cols = (r.columns ?? [:])
                let order = ["task", "date", "client", "member", "status", "time"]
                let found = order.map { k in "\(k): \(cols[k] ?? "—")" }.joined(separator: "  ")
                testResult = "Connected to “\(r.sheet ?? "sheet")” ✓\n\(found)"
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
        }
    }
}


// MARK: - Updates

struct UpdatesSection: View {
    @ObservedObject var updater = UpdateManager.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    SectionLabel(text: "Version")
                    Text(UpdateManager.currentVersion)
                        .font(.system(size: 20, weight: .semibold, design: .rounded))
                        .gradientText()
                }
                Spacer()
                if let c = updater.available, !updater.installing {
                    Button("Update to \(c.version)") { updater.install(c) }
                        .buttonStyle(GradientButtonStyle(compact: true))
                }
                Button("Check for Updates") { updater.check(silent: false) }
                    .buttonStyle(GlassButtonStyle(compact: true))
                    .disabled(updater.installing)
                Button("Install from File…") { updater.installFromFile() }
                    .buttonStyle(GlassButtonStyle(compact: true))
                    .disabled(updater.installing)
            }
            if updater.installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(updater.progressText.isEmpty ? "Updating…" : updater.progressText)
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                }
            } else if let m = updater.lastMessage {
                Text(m).font(.system(size: 11)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("New versions come from GitHub and are checked every 15 minutes.")
                    .font(.system(size: 10)).foregroundStyle(.tertiary)
                if UpdateSource.isConfigured, let page = UpdateSource.releasesPage {
                    Link("What's new", destination: page).font(.system(size: 10))
                }
            }
        }
    }
}
