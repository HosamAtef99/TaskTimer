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
    @ObservedObject var sync = SheetSync.shared

    var body: some View {
        SheetFrame(title: "Clients",
                   subtitle: Features.sheet ? "Read from the sheet's Account column — or add them by hand" : "Add them once, then pick from the list. Give each one a folder if you like.",
                   icon: "person.2.fill") {
            if Features.sheet {
            HStack(spacing: 8) {
                Button {
                    Task { await sync.sync(silent: false) }
                } label: {
                    HStack(spacing: 6) {
                        if sync.syncing { ProgressView().controlSize(.small).tint(.white) }
                        Label("Sync from Sheet", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(sync.syncing)
                Text(sync.config?.syncedAt.map { "Last sync \(Fmt.relative($0))" } ?? "Not synced yet")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
            }
            }
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
                                if c.missingFromSheet == true {
                                    Text("Not in sheet")
                                        .font(.system(size: 10, weight: .semibold))
                                        .foregroundStyle(Theme.orange)
                                        .help("The last Sync didn't find this account in the sheet. Old tasks keep it; delete it if it's gone for good.")
                                }
                            }
                            Spacer()
                            if let p = c.folderPath, !p.isEmpty {
                                Text((p as NSString).abbreviatingWithTildeInPath)
                                    .font(.system(size: 10))
                                    .foregroundStyle(FileManager.default.fileExists(atPath: p) ? AnyShapeStyle(HierarchicalShapeStyle.tertiary) : AnyShapeStyle(Theme.pink))
                                    .lineLimit(1)
                                    .truncationMode(.head)
                                    .frame(maxWidth: 140, alignment: .trailing)
                                    .help(FileManager.default.fileExists(atPath: p) ? p : "Folder not found: \(p)")
                            }
                            Menu {
                                Button("Choose Folder…") {
                                    let panel = NSOpenPanel()
                                    panel.canChooseDirectories = true
                                    panel.canChooseFiles = false
                                    panel.canCreateDirectories = true
                                    panel.prompt = "Choose"
                                    panel.message = "Choose \(c.name)'s folder. Month folders and task folders go inside it."
                                    if let p = c.folderPath { panel.directoryURL = URL(fileURLWithPath: p) }
                                    if panel.runModal() == .OK, let u = panel.url { store.setClientFolder(c.id, u.path) }
                                }
                                if let p = c.folderPath, !p.isEmpty {
                                    Button("Show in Finder") { NSWorkspace.shared.open(URL(fileURLWithPath: p)) }
                                    Button("Remove Folder") { store.setClientFolder(c.id, nil) }
                                }
                            } label: {
                                Image(systemName: c.folderPath == nil ? "folder.badge.plus" : "folder")
                            }
                            .menuStyle(.borderlessButton)
                            .menuIndicator(.hidden)
                            .fixedSize()
                            .help("This client's folder")
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
        .frame(width: 520, height: inSheet ? 560 : 520)
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
    @AppStorage(Pref.tabMode) var tabMode = "auto"
    @AppStorage(Pref.tabName) var tabName = ""
    @AppStorage(Pref.statusComplete) var statusComplete = ""
    @AppStorage(Pref.statusInProcess) var statusInProcess = ""
    @AppStorage(Pref.timeFormatFromSheet) var timeFormatFromSheet = true
    @AppStorage(Pref.folderMode) var folderMode = "location"
    @AppStorage(Pref.monthsRoot) var monthsRoot = ""
    @ObservedObject var sync = SheetSync.shared

    @Local var tab = Features.sheet ? 0 : 1
    @Local var testing = false
    @Local var testResult: String? = nil
    @Local var testOK = false
    @Local var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        SheetFrame(title: "Settings", subtitle: Features.sheet ? "Your name, the team sheet, and folders" : "Folders and general options", icon: "gearshape.fill") {
            Picker("", selection: $tab) {
                if Features.sheet { Text("Sheet").tag(0) }
                Text("Team").tag(3)
                Text("Folders").tag(1)
                Text("General").tag(2)
            }
            .pickerStyle(.segmented)
            .labelsHidden()

            Group {
                switch tab {
                case 0: sheetTab
                case 3: AccountSection()
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
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                connectionSection
                Divider()
                fromSheetSection
                Divider()
                HStack(spacing: 20) {
                    FieldRow(label: "Time format") {
                        Picker("", selection: $timeFormat) {
                            Text("2:30").tag("hm")
                            Text("2.5").tag("decimal")
                            Text("150 (min)").tag("minutes")
                        }
                        .labelsHidden().frame(width: 130)
                        .disabled(timeFormatFromSheet)
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
                Toggle("Match the time format already used in the sheet", isOn: $timeFormatFromSheet)
                    .font(.system(size: 12))
                Toggle("When an In Process task is logged again, update its row by default", isOn: $updateSameRow)
                    .font(.system(size: 12))
            }
            .padding(.trailing, 6)
        }
    }

    private var connectionSection: some View {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "Web App URL (from Apps Script → Deploy)") {
                TextField("https://script.google.com/macros/s/…/exec", text: $webAppURL)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 11, design: .monospaced))
            }
            FieldRow(label: "Secret token (same as TOKEN in the script)") {
                SecureField("token", text: $token).textFieldStyle(.roundedBorder)
            }
            HStack(spacing: 10) {
                Button { Task { await sync.sync(silent: false) } } label: {
                    HStack(spacing: 6) {
                        if sync.syncing { ProgressView().controlSize(.small).tint(.white) }
                        Label("Sync from Sheet", systemImage: "arrow.triangle.2.circlepath")
                    }
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(sync.syncing || webAppURL.isEmpty)
                .help("Reads the tabs, column titles and the Account / Status / Team Member dropdowns again")
                Button { test() } label: {
                    HStack(spacing: 6) {
                        if testing { ProgressView().controlSize(.small) }
                        Text("Test Connection")
                    }
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                .disabled(testing || webAppURL.isEmpty)
            }
            if let e = sync.lastError {
                Text(e)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.pink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let c = sync.config {
                Text(syncSummary(c))
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.green)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if let testResult {
                Text(testResult)
                    .font(.system(size: 11))
                    .foregroundStyle(testOK ? Theme.green : Theme.pink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var fromSheetSection: some View {
        let c = sync.config
        let members = c?.members ?? []
        let statuses = c?.statuses ?? []
        let tabs = c?.visibleTabs ?? []
        return VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "Your name (as written in the sheet)") {
                HStack(spacing: 8) {
                    TextField("Hossam atef", text: $memberName).textFieldStyle(.roundedBorder)
                    if !members.isEmpty {
                        Menu {
                            ForEach(members, id: \.self) { m in
                                Button(m) { memberName = m }
                            }
                        } label: { Text("Pick") }
                            .menuStyle(.borderlessButton)
                            .fixedSize()
                            .help("Names from the sheet's Team Member dropdown")
                    }
                }
                if !members.isEmpty, !memberName.isEmpty,
                   !members.contains(where: { $0.caseInsensitiveCompare(memberName) == .orderedSame }) {
                    Text("This name isn't in the sheet's Team Member list.")
                        .font(.system(size: 11)).foregroundStyle(Theme.orange)
                }
            }

            FieldRow(label: "Tab") {
                Picker("", selection: $tabMode) {
                    Text("This month's tab, automatically").tag("auto")
                    Text("A tab I pick").tag("manual")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                if tabMode == "manual" {
                    if tabs.isEmpty {
                        TextField("Tab name", text: $tabName).textFieldStyle(.roundedBorder)
                    } else {
                        Picker("", selection: $tabName) {
                            if !tabs.contains(tabName) {
                                Text(tabName.isEmpty ? "— Choose a tab —" : tabName).tag(tabName)
                            }
                            ForEach(tabs, id: \.self) { Text($0).tag($0) }
                        }
                        .labelsHidden()
                    }
                } else {
                    Text(c?.autoTab.map { "Now: “\($0)”. Rows go to the tab named after the month of the task's date (e.g. “Oct 2026”, “October”, “10-2026”); if none matches, the last tab." }
                         ?? "Rows go to the tab named after the month of the task's date. Press Sync to see which one.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .onChange(of: tabMode) { _ in Task { await sync.sync(silent: true) } }
            .onChange(of: tabName) { _ in Task { await sync.sync(silent: true) } }

            FieldRow(label: "Status words in the sheet") {
                HStack(spacing: 12) {
                    statusPicker("Complete →", selection: $statusComplete, options: statuses)
                    statusPicker("In Process →", selection: $statusInProcess, options: statuses)
                }
            }
        }
    }

    @ViewBuilder
    private func statusPicker(_ title: String, selection: Binding<String>, options: [String]) -> some View {
        HStack(spacing: 6) {
            Text(title).font(.system(size: 12)).foregroundStyle(.secondary)
            if options.isEmpty {
                TextField("", text: selection).textFieldStyle(.roundedBorder).frame(width: 120)
            } else {
                Picker("", selection: selection) {
                    if !options.contains(selection.wrappedValue) {
                        Text(selection.wrappedValue.isEmpty ? "—" : selection.wrappedValue).tag(selection.wrappedValue)
                    }
                    ForEach(options, id: \.self) { Text($0).tag($0) }
                }
                .labelsHidden()
                .frame(width: 140)
            }
        }
    }

    private func syncSummary(_ c: SheetConfig) -> String {
        var parts: [String] = []
        parts.append("“\(c.spreadsheet ?? "Sheet")” → tab “\(c.sheet ?? "?")” ✓")
        parts.append("\(c.clients.count) accounts · \(c.statuses.count) statuses · \(c.members.count) members")
        let order = ["task", "date", "client", "member", "status", "time"]
        parts.append(order.map { k in "\(k): \(c.headers[k].flatMap { $0.isEmpty ? nil : $0 } ?? "—") (\(c.columns[k] ?? "—"))" }
            .joined(separator: "  "))
        if let d = c.syncedAt { parts.append("Synced \(Fmt.relative(d))") }
        return parts.joined(separator: "\n")
    }

    private var foldersTab: some View {
        ScrollView {
        VStack(alignment: .leading, spacing: 14) {
            FieldRow(label: "Where new task folders go") {
                Picker("", selection: $folderMode) {
                    Text("Pick each time").tag("location")
                    Text("Client's folder").tag("client")
                    Text("Month folders").tag("months")
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(folderModeHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if folderMode == "months" {
                    HStack {
                        TextField("Folder that holds the month folders", text: $monthsRoot)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                        Button("Choose…") {
                            let p = NSOpenPanel()
                            p.canChooseFiles = false
                            p.canChooseDirectories = true
                            p.canCreateDirectories = true
                            if p.runModal() == .OK, let u = p.url { monthsRoot = u.path }
                        }
                        .buttonStyle(GlassButtonStyle(compact: true))
                    }
                    if !monthsRoot.isEmpty {
                        if FileManager.default.fileExists(atPath: monthsRoot) {
                            let m = MonthFolder.preview(in: URL(fileURLWithPath: monthsRoot))
                            Text(m.exists ? "This month: “\(m.name)” ✓" : "This month's folder will be created as “\(m.name)”.")
                                .font(.system(size: 11)).foregroundStyle(Theme.green)
                        } else {
                            Text("Folder not found at this path.").font(.system(size: 11)).foregroundStyle(Theme.pink)
                        }
                    }
                }
            }
            Divider()
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
        .padding(.trailing, 6)
        }
    }

    private var folderModeHelp: String {
        switch folderMode {
        case "client":
            return "Each client gets its own folder (set it in Clients). New tasks go into that month's folder inside it: Client folder / Oct 2026 / Task. The month folder is created if it's missing, named like the other month folders there."
        case "months":
            return "All tasks go into one folder of months: Folder / Oct 2026 / Task. The month folder is created if it's missing, named like the other month folders there."
        default:
            return "You pick where each task folder goes when you create it."
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
                    + ((r.version ?? 1) < 2 ? "\nThe script on the sheet is the old version — paste the new TaskTimer.gs to read accounts and tabs from the sheet." : "")
            } catch {
                testOK = false
                testResult = error.localizedDescription
            }
        }
    }
}


// MARK: - Team account

struct AccountSection: View {
    @ObservedObject var auth = CloudAuth.shared
    @ObservedObject var cloud = CloudSync.shared
    @Local var email = ""
    @Local var password = ""
    @Local var editName = ""
    @Local var newPassword = ""
    @Local var newPassword2 = ""
    @Local var passwordMessage: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if let s = auth.session {
                signedIn(s)
            } else {
                signInForm
            }
        }
    }

    private func signedIn(_ s: CloudSession) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                Image(systemName: "person.crop.circle.fill")
                    .font(.system(size: 34))
                    .foregroundStyle(Theme.cool)
                VStack(alignment: .leading, spacing: 2) {
                    Text(cloud.profile?.name ?? s.email).font(.system(size: 15, weight: .semibold))
                    Text(s.email).font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Sign Out") { auth.signOut() }
                    .buttonStyle(GlassButtonStyle(compact: true))
            }
            Divider()
            if let p = cloud.profile {
                if let team = cloud.teamName {
                    Label("Team: \(team)" + (p.isLeader ? " · Leader" : ""), systemImage: "person.3.fill")
                        .font(.system(size: 12))
                } else {
                    Label("Not in a team yet — ask your team leader to add \(s.email).", systemImage: "person.3")
                        .font(.system(size: 12)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                FieldRow(label: "Your name (what your leader sees)") {
                    HStack {
                        TextField(p.name, text: $editName).textFieldStyle(.roundedBorder)
                        Button("Save") {
                            let n = editName.trimmingCharacters(in: .whitespaces)
                            guard !n.isEmpty else { return }
                            Task { @MainActor in await cloud.rename(n); editName = "" }
                        }
                        .buttonStyle(GlassButtonStyle(compact: true))
                        .disabled(editName.trimmingCharacters(in: .whitespaces).isEmpty)
                    }
                }
            }
            HStack(spacing: 10) {
                Button {
                    Task { @MainActor in
                        await cloud.loadProfile()
                        await cloud.pushNow()
                        await cloud.pull()
                    }
                } label: { Label("Sync Now", systemImage: "arrow.triangle.2.circlepath") }
                    .buttonStyle(GradientButtonStyle(compact: true))
                if let e = cloud.error {
                    Text(e).font(.system(size: 11)).foregroundStyle(Theme.pink)
                        .fixedSize(horizontal: false, vertical: true)
                } else if let d = cloud.lastSync {
                    Text("Synced \(Fmt.relative(d))").font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Divider()
            passwordSection
            Text("Your tasks are copied to the team database so your leader can see them. Only you can change them.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var signInForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            FieldRow(label: "Email") {
                TextField("you@company.com", text: $email).textFieldStyle(.roundedBorder)
            }
            FieldRow(label: "Password") {
                SecureField("Password", text: $password)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(go)
            }
            HStack(spacing: 10) {
                Button(action: go) {
                    HStack(spacing: 6) {
                        if auth.busy { ProgressView().controlSize(.small).tint(.white) }
                        Text("Sign In")
                    }
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(auth.busy || email.isEmpty || password.isEmpty)
                if let m = auth.message {
                    Text(m).font(.system(size: 11)).foregroundStyle(Theme.pink)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("Your team leader creates your account and gives you the email and password. After signing in you can change the password here.")
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var passwordSection: some View {
        FieldRow(label: "Change password") {
            HStack(spacing: 8) {
                SecureField("New password (6+ characters)", text: $newPassword).textFieldStyle(.roundedBorder)
                SecureField("Repeat it", text: $newPassword2).textFieldStyle(.roundedBorder)
                Button("Change") {
                    Task { @MainActor in
                        if await auth.changePassword(newPassword) {
                            newPassword = ""
                            newPassword2 = ""
                            passwordMessage = "Password changed ✓"
                        } else {
                            passwordMessage = nil
                        }
                    }
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                .disabled(auth.busy || newPassword.count < 6 || newPassword != newPassword2)
            }
            if let m = passwordMessage {
                Text(m).font(.system(size: 11)).foregroundStyle(Theme.green)
            } else if let m = auth.message {
                Text(m).font(.system(size: 11)).foregroundStyle(Theme.pink)
            }
        }
    }

    private func go() {
        let e = email.trimmingCharacters(in: .whitespaces).lowercased()
        guard !e.isEmpty, !password.isEmpty else { return }
        Task { @MainActor in
            await auth.signIn(email: e, password: password)
            if auth.signedIn { password = "" }
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
