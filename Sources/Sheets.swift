import SwiftUI
import AppKit

// MARK: - Client picker (pick from the saved list, or add a new one inline)

struct ClientPicker: View {
    @EnvironmentObject var store: Store
    @Binding var selection: UUID?
    @Local var adding = false
    @Local var newName = ""

    var body: some View {
        HStack(spacing: 8) {
            if adding {
                TextField("New client name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(commit)
                Button("Add", action: commit)
                    .buttonStyle(GradientButtonStyle(compact: true))
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty)
                Button("Cancel") { adding = false; newName = "" }
                    .buttonStyle(GlassButtonStyle(compact: true))
            } else {
                Picker("", selection: $selection) {
                    Text("— Choose client —").tag(UUID?.none)
                    ForEach(store.clients) { c in
                        Text(c.missingFromSheet == true ? "\(c.name)  (not in sheet)" : c.name).tag(UUID?.some(c.id))
                    }
                }
                .labelsHidden()
                .frame(maxWidth: .infinity)
                Button {
                    adding = true
                } label: { Image(systemName: "plus") }
                    .buttonStyle(CircleIconButtonStyle(size: 26))
                    .help("Add a client to the list")
            }
        }
    }

    private func commit() {
        if let c = store.addClient(newName) { selection = c.id }
        newName = ""
        adding = false
    }
}

struct FieldRow<Content: View>: View {
    var label: String
    @ViewBuilder var content: Content
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: label)
            content
        }
    }
}

struct SheetFrame<Content: View>: View {
    var title: String
    var subtitle: String
    var icon: String
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            GlowBackground(animate: false)
            VStack(alignment: .leading, spacing: 18) {
                HStack(spacing: 12) {
                    Image(systemName: icon)
                        .font(.system(size: 18, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 40, height: 40)
                        .background(Theme.diagonal, in: RoundedRectangle(cornerRadius: 11, style: .continuous))
                        .shadow(color: Theme.purple.opacity(0.35), radius: 8, y: 3)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(title).font(.system(size: 18, weight: .bold, design: .rounded))
                        Text(subtitle).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                }
                content
            }
            .padding(24)
        }
    }
}

// MARK: - New task

struct NewTaskSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss

    @Local var name = ""
    @Local var clientID: UUID? = nil
    @Local var makeFolder = true
    @Local var startNow = true
    @Local var location: String = Pref.string(Pref.lastLocation)
    @Local var error: String? = nil

    var body: some View {
        SheetFrame(title: "New Task", subtitle: "Creates the folder tree and starts the timer", icon: "plus") {
            FieldRow(label: "Task name") {
                TextField("e.g. Ramadan Promo 15s", text: $name)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 14))
            }
            FieldRow(label: "Client / Account") {
                ClientPicker(selection: $clientID)
            }

            VStack(alignment: .leading, spacing: 10) {
                Picker("", selection: $startNow) {
                    Text("Start now").tag(true)
                    Text("Add to Incoming").tag(false)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Toggle("Create task folder", isOn: $makeFolder)
                if makeFolder {
                    HStack(spacing: 8) {
                        Image(systemName: "folder").foregroundStyle(Theme.cool)
                        Text(destinationText)
                            .font(.system(size: 12))
                            .lineLimit(1)
                            .truncationMode(.head)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if autoRoot == nil {
                            Button("Change…") {
                                if let u = FolderService.chooseLocation() { location = u.path }
                            }
                            .buttonStyle(GlassButtonStyle(compact: true))
                        }
                    }
                    if let hint = folderHint {
                        Text(hint)
                            .font(.system(size: 11))
                            .foregroundStyle(Theme.orange)
                    }
                    Text(Pref.subfolderList.joined(separator: "  ·  "))
                        .font(.system(size: 10))
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }
            .padding(14)
            .glassCard(radius: 14)

            if let error {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.pink)
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { create() } label: { Label(startNow ? "Create & Start" : "Add to Incoming", systemImage: "sparkles") }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(FolderService.cleanName(name).isEmpty)
            }
        }
        .frame(width: 480)
    }

    /// Folder that holds the month folders for this task (client's folder, or the months folder),
    /// or nil when the task folder goes to a location picked by hand.
    private var autoRoot: URL? {
        let fm = FileManager.default
        switch Pref.string(Pref.folderMode) {
        case "client":
            guard let p = store.client(clientID)?.folderPath, !p.isEmpty, fm.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        case "months":
            let p = Pref.string(Pref.monthsRoot)
            guard !p.isEmpty, fm.fileExists(atPath: p) else { return nil }
            return URL(fileURLWithPath: p)
        default:
            return nil
        }
    }

    private var destinationText: String {
        if let root = autoRoot {
            let m = MonthFolder.preview(in: root)
            let path = (root.path as NSString).abbreviatingWithTildeInPath
            return "\(path)/\(m.name)/" + (m.exists ? "" : "  (new month folder)")
        }
        return location.isEmpty ? "Choose a location…" : (location as NSString).abbreviatingWithTildeInPath
    }

    private var folderHint: String? {
        guard autoRoot == nil else { return nil }
        switch Pref.string(Pref.folderMode) {
        case "client":
            if clientID == nil { return "Pick a client to use its folder." }
            return "This client has no folder yet — set it in Clients (the people icon)."
        case "months":
            return "Set the folder that holds the month folders in Settings → Folders."
        default:
            return nil
        }
    }

    private func create() {
        error = nil
        let clean = FolderService.cleanName(name)
        guard !clean.isEmpty else { return }
        var folder: URL?
        if makeFolder {
            var base: URL?
            if let root = autoRoot {
                do {
                    base = try MonthFolder.folder(in: root)
                } catch {
                    self.error = error.localizedDescription
                    return
                }
            } else if !location.isEmpty, FileManager.default.fileExists(atPath: location) {
                base = URL(fileURLWithPath: location)
                UserDefaults.standard.set(location, forKey: Pref.lastLocation)
            } else {
                base = FolderService.chooseLocation()
            }
            guard let base else { return }
            do {
                folder = try FolderService.createProject(name: clean, in: base)
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        store.addTask(name: clean, clientID: clientID, folder: folder, start: startNow, incoming: !startNow)
        if let folder {
            if Pref.bool(Pref.openFinderOnCreate) { NSWorkspace.shared.open(folder) }
            if Pref.bool(Pref.openAEOnCreate), let ae = FolderService.aeFile(in: folder) {
                NSWorkspace.shared.open(ae)
            }
        }
        if folder != nil && FolderService.templateIsMissing {
            store.flash("Created “\(clean)” — no AE template set (Settings → Folders)")
        } else {
            store.flash(startNow ? "Created “\(clean)” — timer running" : "Added “\(clean)” to Incoming")
        }
        dismiss()
    }
}

// MARK: - Done (in the app)

struct DoneSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let taskID: UUID

    @Local var name = ""
    @Local var clientID: UUID? = nil
    @Local var date = Date()
    @Local var hours: Double = 0
    @Local var loaded = false

    private var task: TaskItem? { store.task(taskID) }
    private var parent: TaskItem? { task.flatMap { store.parent(of: $0) } }

    var body: some View {
        SheetFrame(title: parent == nil ? "Finish Task" : "Finish Amend",
                   subtitle: "Write the hours and the day", icon: "checkmark") {
            FieldRow(label: parent == nil ? "Task name" : "Amend name") {
                TextField(parent == nil ? "Task" : "Amend 1", text: $name).textFieldStyle(.roundedBorder)
                if let p = parent {
                    Text("Under “\(p.name)” · shown as “\(p.name) - \(name)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            FieldRow(label: "Client / Account") {
                ClientPicker(selection: $clientID)
            }

            HStack(alignment: .top, spacing: 18) {
                FieldRow(label: "Day") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                FieldRow(label: "Hours") {
                    HStack(spacing: 6) {
                        TextField("", value: $hours, format: .number.precision(.fractionLength(0...2)))
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                        Stepper("", onIncrement: { hours += 0.25 },
                                onDecrement: { hours = max(0, hours - 0.25) })
                            .labelsHidden()
                        Text("h").foregroundStyle(.secondary)
                    }
                }
                Spacer()
            }

            if let t = task {
                Text("Timer: \(Fmt.clock(t.totalSeconds(at: store.now))) (≈ \(Fmt.hours(t.totalSeconds(at: store.now))) h). Hours are filled in to the nearest quarter — change them if needed.")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                Button("Save, keep In Progress") { save(.active) }
                    .buttonStyle(GlassButtonStyle())
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { save(.complete) } label: { Label("Complete", systemImage: "checkmark") }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
                    .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 500)
        .onAppear(perform: load)
    }

    private func load() {
        guard !loaded, let t = task else { return }
        loaded = true
        name = t.name
        clientID = t.clientID
        date = t.workDate ?? Date()
        let secs = t.totalSeconds(at: Date())
        var h = (secs / 3600 * 4).rounded() / 4
        if secs > 0 && h == 0 { h = 0.25 }
        hours = h
    }

    private func save(_ status: TaskStatus) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.complete(taskID, name: n, clientID: clientID, status: status,
                       date: date, totalSeconds: max(0, hours) * 3600)
        dismiss()
    }
}

// MARK: - Done → log to sheet (used when Features.sheet is on)

struct SheetDoneSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let taskID: UUID

    @Local var name = ""
    @Local var clientID: UUID? = nil
    @Local var status: TaskStatus = .complete
    @Local var date = Date()
    @Local var hours = 0
    @Local var minutes = 0
    @Local var updateExisting = true
    @Local var sending = false
    @Local var loaded = false

    private var task: TaskItem? { store.task(taskID) }
    private var parent: TaskItem? { task.flatMap { store.parent(of: $0) } }
    private var totalSeconds: TimeInterval { TimeInterval(hours * 3600 + minutes * 60) }

    /// What goes in the sheet's Task column ("Task - Amend 1" for an amend).
    private var sheetName: String {
        let n = name.trimmingCharacters(in: .whitespaces)
        if let p = parent { return "\(p.name) - \(n)" }
        return n
    }

    var body: some View {
        SheetFrame(title: parent == nil ? "Finish Task" : "Finish Amend",
                   subtitle: "Logs a row in the team sheet", icon: "checkmark") {
            FieldRow(label: parent == nil ? "Task name" : "Amend name") {
                TextField(parent == nil ? "Task" : "Amend 1", text: $name).textFieldStyle(.roundedBorder)
                if let p = parent {
                    Text("Under “\(p.name)” · logged as “\(sheetName)”")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                }
            }
            FieldRow(label: "Client / Account") {
                ClientPicker(selection: $clientID)
            }
            FieldRow(label: "Status") {
                Picker("", selection: $status) {
                    Text(TaskStatus.complete.sheetLabel).tag(TaskStatus.complete)
                    Text(TaskStatus.inProcess.sheetLabel).tag(TaskStatus.inProcess)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
            }

            HStack(alignment: .top, spacing: 18) {
                FieldRow(label: "Date") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                FieldRow(label: "Total time") {
                    HStack(spacing: 6) {
                        TextField("", value: $hours, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 46)
                            .multilineTextAlignment(.trailing)
                        Text("h").foregroundStyle(.secondary)
                        TextField("", value: $minutes, format: .number)
                            .textFieldStyle(.roundedBorder).frame(width: 46)
                            .multilineTextAlignment(.trailing)
                        Text("m").foregroundStyle(.secondary)
                        Stepper("", onIncrement: { bump(15) }, onDecrement: { bump(-15) })
                            .labelsHidden()
                    }
                }
                Spacer()
            }

            summary

            if let t = task, t.sheetRow != nil {
                Toggle(isOn: $updateExisting) {
                    Text("Update the same row (\(t.sheetRow!)) instead of adding a new one")
                        .font(.system(size: 12))
                }
            }

            if Pref.string(Pref.webAppURL).isEmpty || Pref.string(Pref.memberName).isEmpty {
                Label("Set your name and the sheet link in Settings first.", systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.orange)
            }

            HStack {
                Button("Save without logging") {
                    store.pause(taskID)
                    store.update(taskID) { t in
                        t.name = name
                        t.clientID = clientID
                        t.status = status
                        t.manualAdjust = totalSeconds - t.rawSeconds()
                    }
                    dismiss()
                }
                .buttonStyle(GlassButtonStyle())
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button { send() } label: {
                    HStack(spacing: 6) {
                        if sending { ProgressView().controlSize(.small).tint(.white) }
                        Text(sending ? "Logging…" : "Log to Sheet")
                    }
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(sending || name.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        }
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: minutes) { m in
            if m >= 60 { hours += m / 60; minutes = m % 60 }
            if m < 0 { minutes = 0 }
        }
        .onChange(of: hours) { h in if h < 0 { hours = 0 } }
    }

    private var summary: some View {
        let t = task
        let willUpdate = updateExisting && t?.sheetRow != nil
        let entrySecs = willUpdate ? totalSeconds : max(0, totalSeconds - (t?.loggedSeconds ?? 0))
        let member = Pref.string(Pref.memberName)
        return VStack(alignment: .leading, spacing: 6) {
            SectionLabel(text: willUpdate ? "Will update row \(t?.sheetRow ?? 0)" : "Will add this row")
            HStack(spacing: 8) {
                cell(sheetName.isEmpty ? "—" : sheetName)
                cell(Fmt.isoDay.string(from: date))
                cell(store.clientName(clientID).isEmpty ? "No client" : store.clientName(clientID))
                cell(member.isEmpty ? "Your name?" : member)
                cell(status.sheetLabel)
                cell(Fmt.sheetTime(entrySecs))
            }
            Text(tabLine(willUpdate: willUpdate))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if !willUpdate, let t, t.loggedSeconds > 0 {
                Text("\(Fmt.short(t.loggedSeconds)) of this task was already logged, so this row only counts the new time.")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassCard(radius: 12, highlight: true)
    }

    private func tabLine(willUpdate: Bool) -> String {
        if willUpdate, let tab = task?.sheetTab, !tab.isEmpty { return "Tab: \(tab)" }
        let target = Pref.tabTarget()
        if target.mode == "manual" { return "Tab: \(target.tab)" }
        let month = DateFormatter()
        month.dateFormat = "MMMM yyyy"
        return "Tab: the \(month.string(from: date)) tab (picked automatically)"
    }

    private func cell(_ s: String) -> some View {
        Text(s)
            .font(.system(size: 11, weight: .medium))
            .lineLimit(1)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Color.primary.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
    }

    private func bump(_ delta: Int) {
        let total = max(0, hours * 60 + minutes + delta)
        hours = total / 60
        minutes = total % 60
    }

    private func load() {
        guard !loaded, let t = task else { return }
        loaded = true
        name = t.name
        clientID = t.clientID
        status = .complete
        let secs = t.totalSeconds(at: Date())
        let totalMin = Int((secs / 60).rounded())
        hours = totalMin / 60
        minutes = totalMin % 60
        updateExisting = Pref.bool(Pref.updateSameRow)
    }

    private func send() {
        sending = true
        let n = name.trimmingCharacters(in: .whitespaces)
        Task { @MainActor in
            _ = await store.finish(taskID, name: n, clientID: clientID, status: status,
                                   date: date, totalSeconds: totalSeconds,
                                   updateExisting: updateExisting)
            sending = false
            dismiss()
        }
    }
}
