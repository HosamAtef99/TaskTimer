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
                Toggle(startNow ? "Create task folder" : "Create task folder when I start it", isOn: $makeFolder)
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

    private var autoRoot: URL? { store.autoFolderRoot(for: clientID) }

    private var destinationText: String {
        if let root = autoRoot {
            let m = MonthFolder.preview(in: root)
            let path = (root.path as NSString).abbreviatingWithTildeInPath
            return "\(path)/\(m.name)/" + (m.exists ? "" : "  (new month folder)")
        }
        return location.isEmpty ? "Choose a location…" : (location as NSString).abbreviatingWithTildeInPath
    }

    private var folderHint: String? {
        if autoRoot == nil {
            switch Pref.string(Pref.folderMode) {
            case "client":
                if clientID == nil { return "Pick a client to use its folder." }
                return "This client has no folder yet — set it in Clients (the people icon)."
            case "months":
                return "Set the folder that holds the month folders in Settings → Folders."
            default:
                break
            }
        }
        return nil
    }

    private func create() {
        error = nil
        let clean = FolderService.cleanName(name)
        guard !clean.isEmpty else { return }

        // Incoming: the folder is made later, when the task is started.
        if !startNow {
            if makeFolder, autoRoot == nil, !location.isEmpty {
                UserDefaults.standard.set(location, forKey: Pref.lastLocation)
            }
            store.addTask(name: clean, clientID: clientID, folder: nil, start: false, incoming: true,
                          wantsFolder: makeFolder, folderBase: autoRoot == nil ? location : nil)
            store.flash("Added “\(clean)” to Incoming" + (makeFolder ? " — its folder is made when you start it" : ""))
            dismiss()
            return
        }

        var folder: URL?
        if makeFolder {
            do {
                guard let f = try store.makeTaskFolder(name: clean, clientID: clientID, location: location) else { return }
                folder = f
            } catch {
                self.error = error.localizedDescription
                return
            }
        }
        store.addTask(name: clean, clientID: clientID, folder: folder, start: true)
        if let folder { store.openNewFolder(folder) }
        if folder != nil && FolderService.templateIsMissing {
            store.flash("Created “\(clean)” — no AE template set (Settings → Folders)")
        } else {
            store.flash("Created “\(clean)” — timer running")
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
    @Local var hours = 0
    @Local var minutes = 0
    @Local var deliverables = 1
    @Local var rating = 5
    @Local var challenge = 1
    @Local var loaded = false

    private var task: TaskItem? { store.task(taskID) }
    private var parent: TaskItem? { task.flatMap { store.parent(of: $0) } }
    private var totalMinutes: Int { max(0, hours * 60 + minutes) }

    var body: some View {
        SheetFrame(title: parent == nil ? "Finish Task" : "Finish Amend",
                   subtitle: "Time, day and how it went", icon: "checkmark") {
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

            // Time — big and simple, in steps of half an hour.
            VStack(alignment: .leading, spacing: 8) {
                SectionLabel(text: "Time")
                HStack(spacing: 12) {
                    Button { bump(-30) } label: { Image(systemName: "minus") }
                        .buttonStyle(CircleIconButtonStyle(size: 40))
                        .disabled(totalMinutes == 0)
                        .help("− 30 min")
                    timeField($hours, unit: "h", width: 64)
                    timeField($minutes, unit: "m", width: 64)
                    Button { bump(30) } label: { Image(systemName: "plus") }
                        .buttonStyle(CircleIconButtonStyle(filled: true, size: 40))
                        .help("+ 30 min")
                    Spacer(minLength: 0)
                }
                if let t = task {
                    Text("Timer: \(Fmt.clock(t.totalSeconds(at: store.now))) — rounded to the nearest half hour. Change it if needed.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(14)
            .glassCard(radius: 14, highlight: true)

            HStack(alignment: .top, spacing: 18) {
                FieldRow(label: "Day") {
                    DatePicker("", selection: $date, displayedComponents: .date)
                        .labelsHidden()
                        .datePickerStyle(.field)
                }
                FieldRow(label: "Deliverables") {
                    HStack(spacing: 6) {
                        TextField("", value: $deliverables, format: .number)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 56)
                            .multilineTextAlignment(.trailing)
                        Stepper("", value: $deliverables, in: 0...999).labelsHidden()
                    }
                }
                FieldRow(label: "Happy with this task?") {
                    HStack(spacing: 4) {
                        ForEach(1...5, id: \.self) { n in
                            Button { rating = n } label: {
                                Image(systemName: n <= rating ? "star.fill" : "star")
                                    .font(.system(size: 16))
                                    .foregroundStyle(n <= rating ? AnyShapeStyle(Theme.orange) : AnyShapeStyle(HierarchicalShapeStyle.tertiary))
                            }
                            .buttonStyle(.plain)
                            .help("\(n) of 5")
                        }
                    }
                }
                Spacer(minLength: 0)
            }

            FieldRow(label: "Did you face any challenges?") {
                Picker("", selection: $challenge) {
                    ForEach(ModheshSettings.challenges, id: \.0) { c in Text(c.1).tag(c.0) }
                }
                .labelsHidden()
                .frame(maxWidth: 260, alignment: .leading)
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
        .frame(width: 520)
        .onAppear(perform: load)
        .onChange(of: minutes) { m in
            if m >= 60 { hours += m / 60; minutes = m % 60 }
            if m < 0 { minutes = 0 }
        }
        .onChange(of: hours) { h in if h < 0 { hours = 0 } }
    }

    private func timeField(_ value: Binding<Int>, unit: String, width: CGFloat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 4) {
            TextField("0", value: value, format: .number)
                .textFieldStyle(.plain)
                .font(.system(size: 30, weight: .semibold, design: .rounded).monospacedDigit())
                .multilineTextAlignment(.trailing)
                .frame(width: width)
            Text(unit)
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 10).padding(.vertical, 4)
        .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 10))
    }

    /// Moves to the next / previous half hour.
    private func bump(_ delta: Int) {
        var total = totalMinutes
        if delta > 0 {
            total = (total / 30 + 1) * 30
        } else {
            total = total % 30 == 0 ? total - 30 : (total / 30) * 30
        }
        total = max(0, total)
        hours = total / 60
        minutes = total % 60
    }

    private func load() {
        guard !loaded, let t = task else { return }
        loaded = true
        name = t.name
        clientID = t.clientID
        date = t.workDate ?? Date()
        let secs = t.totalSeconds(at: Date())
        var m = Int((secs / 1800).rounded()) * 30          // nearest half hour
        if secs > 0 && m == 0 { m = 30 }
        hours = m / 60
        minutes = m % 60
        deliverables = t.deliverables ?? max(0, Pref.int(Pref.defaultDeliverables))
        rating = t.rating ?? min(5, max(1, Pref.int(Pref.defaultRating)))
        challenge = t.challenge ?? min(4, max(1, Pref.int(Pref.defaultChallenge)))
    }

    private func save(_ status: TaskStatus) {
        let n = name.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty else { return }
        store.complete(taskID, name: n, clientID: clientID, status: status,
                       date: date, totalSeconds: TimeInterval(totalMinutes * 60),
                       deliverables: max(0, deliverables), rating: min(5, max(1, rating)),
                       challenge: challenge)
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
