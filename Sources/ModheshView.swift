import SwiftUI
import AppKit
import QuickLookThumbnailing

/// Tasks read from Modhesh (by the TaskTimer Chrome extension) and the TaskTimer task each one
/// is linked to. Linked tasks get their hours, deliverables and stars filled in on Modhesh by the
/// extension, and the day picked at Done becomes the Modhesh task's Start Date.
struct ModheshView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @Environment(\.mainWindowSize) var windowSize
    @ObservedObject var cloud = CloudSync.shared
    @ObservedObject var monitor = ExtensionMonitor.shared
    @Local var showLinked = false
    @Local var confirmReset = false
    /// The link picked from the list, waiting to be confirmed (with the task's last render).
    @Local var confirm: LinkRequest? = nil

    var body: some View {
        // Only what still needs work: Pending to Start and In Progress.
        let all = cloud.modheshTasks.filter { CloudSync.modheshActive($0.status) }
        let unlinked = all.filter { $0.taskID == nil || store.task($0.taskID!) == nil }
        let linked = all.filter { $0.taskID != nil && store.task($0.taskID!) != nil }

        SheetFrame(title: "Modhesh", subtitle: "Link each Modhesh task to the task you timed", icon: "link", scrolls: false) {
            if !cloud.extensionConnected && !monitor.installed {
                ExtensionStatusRow()
            }
            ModheshOwnerRow()
            if let e = cloud.modheshError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if all.isEmpty && cloud.modheshError == nil && !cloud.isLeader {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Modhesh tasks pending or in progress.").font(.system(size: 13, weight: .semibold))
                    Text("Install the Mongez extension in Chrome and sign in to it, then press Check now in the extension (Chrome's toolbar) — your Modhesh tasks show up here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    if cloud.isLeader { ApprovalsSection().padding(.bottom, 6) }
                    if !unlinked.isEmpty {
                        SectionLabel(text: "Not linked (\(unlinked.count))")
                        ForEach(unlinked) { m in unlinkedRow(m) }
                    }
                    if !linked.isEmpty {
                        Button {
                            showLinked.toggle()
                        } label: {
                            HStack(spacing: 4) {
                                Image(systemName: showLinked ? "chevron.down" : "chevron.right")
                                SectionLabel(text: "Linked (\(linked.count))")
                            }
                        }
                        .buttonStyle(.plain)
                        .padding(.top, 6)
                        if showLinked {
                            ForEach(linked) { m in linkedRow(m) }
                        }
                    }
                }
                .padding(2)
            }

            HStack {
                Button { Task { @MainActor in await cloud.loadModhesh() } } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                Button { confirmReset = true } label: {
                    Label("Clear & re-check", systemImage: "trash")
                }
                .buttonStyle(GlassButtonStyle(compact: true))
                .help("Remove all Modhesh tasks shown here and read your Modhesh again")
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(minWidth: 520, idealWidth: 720, maxWidth: 760,
               minHeight: min(480, Room.sheetHeight(windowSize)), idealHeight: min(620, Room.sheetHeight(windowSize)),
               maxHeight: Room.sheetHeight(windowSize))
        .task {
            await cloud.loadModhesh()
            await cloud.loadSettings()
            // Keep the status line and the list fresh while this window is open.
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                if Task.isCancelled { break }
                await cloud.loadSettings()
                await cloud.loadModhesh()
            }
        }
        .sheet(item: $confirm) { req in
            LinkConfirmSheet(request: req).environmentObject(store)
        }
        .confirmationDialog("Clear Modhesh tasks and re-check?", isPresented: $confirmReset) {
            Button("Clear & re-check", role: .destructive) {
                Task { @MainActor in await cloud.resetModhesh() }
            }
        } message: {
            Text("Removes every Modhesh task here (and their links) that wasn't sent yet. Tasks whose time was already sent stay. Your own Modhesh tasks come back when you press Check now in the Chrome extension (Chrome must be signed in to your Modhesh).")
        }
    }

    // MARK: Rows

    private func info(_ m: CloudSync.ModheshTask) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(m.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
            HStack(spacing: 6) {
                Text(m.client).lineLimit(1)
                Text("·").foregroundStyle(.tertiary)
                Text(m.statusTitle)
                if let l = m.loggedSeconds, l > 0 {
                    Text("·").foregroundStyle(.tertiary)
                    Text("\(Fmt.hours(l)) h logged")
                }
            }
            .font(.system(size: 11))
            .foregroundStyle(.secondary)
        }
    }

    private func unlinkedRow(_ m: CloudSync.ModheshTask) -> some View {
        let suggestions = candidates(for: m)
        return HStack(alignment: .center, spacing: 10) {
            info(m)
            Spacer(minLength: 8)
            if let best = suggestions.first, best.score >= 0.34 {
                Button {
                    confirm = LinkRequest(modhesh: m, taskID: best.task.id)
                } label: {
                    Text("Link to “\(store.displayName(best.task))”").lineLimit(1)
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .frame(maxWidth: 230)
                .help("Best match by name and account")
            }
            Menu {
                ForEach(suggestions.prefix(10), id: \.task.id) { c in
                    Button(store.displayName(c.task) + (store.clientName(c.task.clientID).isEmpty ? "" : "  — \(store.clientName(c.task.clientID))")) {
                        confirm = LinkRequest(modhesh: m, taskID: c.task.id)
                    }
                }
                Divider()
                if !store.groups.isEmpty {
                    Menu("Groups") {
                        ForEach(store.groups) { g in
                            Button("\(g.name)  (\(store.members(of: g.id).count) tasks)") {
                                confirm = LinkRequest(modhesh: m, taskID: g.id)
                            }
                        }
                    }
                }
                Menu("All tasks and amends") {
                    ForEach(store.tasks.filter { $0.parentID == nil }) { t in
                        Button(t.isGroupItem ? "\(t.name)  (group of \(store.members(of: t.id).count))" : t.name) {
                            confirm = LinkRequest(modhesh: m, taskID: t.id)
                        }
                        ForEach(store.subtasks(of: t.id)) { a in
                            Button("      ↳ \(a.name)") {
                                confirm = LinkRequest(modhesh: m, taskID: a.id)
                            }
                        }
                    }
                }
                Divider()
                Button("New task in Incoming") { addToIncoming(m) }
            } label: {
                Text(suggestions.first.map { $0.score >= 0.34 } == true ? "Other…" : "Link…")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(12)
        .glassCard(radius: 12)
    }

    private func linkedRow(_ m: CloudSync.ModheshTask) -> some View {
        HStack(spacing: 10) {
            info(m)
            Spacer(minLength: 8)
            if let id = m.taskID, let t = store.task(id) {
                VStack(alignment: .trailing, spacing: 2) {
                    Text(store.displayName(t)).font(.system(size: 12, weight: .medium)).lineLimit(1)
                    Text("\(Fmt.hours(store.seconds(of: t))) h in Mongez" + (t.isGroupItem ? " · group" : "") + (m.autoLinked ? " · linked by name" : ""))
                        .font(.system(size: 10)).foregroundStyle(.secondary)
                    if let at = m.submittedAt {
                        Text("Sent to approver \(Fmt.relative(at)) · \(Fmt.hours(m.submittedSeconds ?? 0)) h")
                            .font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.green)
                    } else if let note = m.submitNote, !note.isEmpty {
                        Text(note).font(.system(size: 10)).foregroundStyle(Theme.orange).lineLimit(2)
                    } else if t.status != .complete {
                        Text("Sent to approver when you press Done")
                            .font(.system(size: 10)).foregroundStyle(.tertiary)
                    }
                }
            }
            Button("Unlink") {
                Task { @MainActor in await cloud.linkModhesh(m.code, to: nil) }
            }
            .buttonStyle(GlassButtonStyle(compact: true))
        }
        .padding(12)
        .glassCard(radius: 12)
    }

    // MARK: Matching

    struct Candidate {
        let task: TaskItem
        let score: Double
    }

    private static func words(_ s: String) -> Set<String> {
        Set(s.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count > 1 })
    }

    /// TaskTimer tasks ranked by how well their name (and account) match the Modhesh task.
    private func candidates(for m: CloudSync.ModheshTask) -> [Candidate] {
        let linkedIDs = Set(cloud.modheshTasks.compactMap { $0.taskID })
        let mw = Self.words(m.title)
        let mc = Self.words(m.client)
        return store.tasks
            .filter { !linkedIDs.contains($0.id) }
            .map { t -> Candidate in
                let tw = Self.words(store.displayName(t))
                let inter = Double(mw.intersection(tw).count)
                let union = Double(max(1, mw.union(tw).count))
                var score = inter / union
                let tc = Self.words(store.clientName(t.clientID))
                if !mc.isEmpty && !tc.isEmpty && !mc.intersection(tc).isEmpty { score += 0.15 }
                return Candidate(task: t, score: score)
            }
            .sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.task.createdAt > b.task.createdAt
            }
    }

    private func addToIncoming(_ m: CloudSync.ModheshTask) {
        // Only the admin's clients: take the one whose name matches Modhesh's account, if any.
        let clientID = store.matchClient(m.client)?.id
        let id = store.addTask(name: FolderService.cleanName(m.title), clientID: clientID, folder: nil,
                               start: false, incoming: true, wantsFolder: true)
        Task { @MainActor in await cloud.linkModhesh(m.code, to: id) }
        store.flash("Added “\(m.title)” to Incoming and linked it")
    }
}

// MARK: - Confirm a link (Hosam's call, 1.32)

/// A Modhesh task and the Mongez task (or amend, or group) picked for it.
struct LinkRequest: Identifiable {
    let id = UUID()
    let modhesh: CloudSync.ModheshTask
    let taskID: UUID
}

/// Picking a task in the Modhesh window opens this card first: the Modhesh task, the Mongez task
/// with its hours, and its last render, so you can see it's the right one before linking.
struct LinkConfirmSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared
    let request: LinkRequest
    @Local var linking = false

    var body: some View {
        let t = store.task(request.taskID)
        SheetFrame(title: "Link to Modhesh?", subtitle: "Check it's the right task, then confirm", icon: "link") {
            // Modhesh's side
            VStack(alignment: .leading, spacing: 3) {
                SectionLabel(text: "On Modhesh")
                Text(request.modhesh.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text([request.modhesh.client, request.modhesh.statusTitle].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassCard(radius: 12)

            if let t {
                // Mongez's side
                VStack(alignment: .leading, spacing: 10) {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            SectionLabel(text: t.isGroupItem ? "Group in Mongez" : "In Mongez")
                            Text(store.displayName(t)).font(.system(size: 14, weight: .semibold)).lineLimit(2)
                            Text(details(t)).font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer(minLength: 8)
                        Text("\(Fmt.hoursColumn(store.seconds(of: t))) h")
                            .font(.system(size: 16, weight: .semibold, design: .rounded).monospacedDigit())
                    }
                    if t.isGroupItem {
                        let members = store.members(of: t.id)
                        if members.isEmpty {
                            noRender("This group has no tasks yet.")
                        } else {
                            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
                                ForEach(members.prefix(6)) { m in
                                    VStack(alignment: .leading, spacing: 4) {
                                        RenderPreview(folder: m.folderURL, height: 110)
                                        Text(m.name).font(.system(size: 11, weight: .medium)).lineLimit(1)
                                    }
                                }
                            }
                            if members.count > 6 {
                                Text("+ \(members.count - 6) more").font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                        }
                    } else {
                        RenderPreview(folder: t.folderURL ?? store.parent(of: t)?.folderURL, height: 250)
                    }
                }
                .padding(12)
                .glassCard(radius: 12, highlight: true)
            } else {
                noRender("This task isn't in Mongez any more.")
            }

            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    linking = true
                    Task { @MainActor in
                        await cloud.linkModhesh(request.modhesh.code, to: request.taskID)
                        if let t { store.flash("Linked “\(store.displayName(t))” to Modhesh") }
                        dismiss()
                    }
                } label: {
                    Label(linking ? "Linking…" : "Confirm Link", systemImage: "link")
                }
                .buttonStyle(GradientButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(t == nil || linking)
            }
        }
        .frame(width: 560)
    }

    private func details(_ t: TaskItem) -> String {
        var parts: [String] = []
        if t.isGroupItem {
            let n = store.members(of: t.id).count
            parts.append("\(n) task\(n == 1 ? "" : "s")")
        }
        let client = store.clientName(t.clientID)
        if !client.isEmpty { parts.append(client) }
        parts.append(t.status.title)
        parts.append("made " + Fmt.nice.string(from: t.createdAt))
        return parts.joined(separator: " · ")
    }

    private func noRender(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 12)).foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, minHeight: 60)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
    }
}

/// A task's newest render, big (click to open it), or a note when there's none yet.
struct RenderPreview: View {
    let folder: URL?
    var height: CGFloat = 220
    @Local var image: NSImage? = nil
    @Local var file: URL? = nil
    @Local var looked = false

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.black.opacity(0.18))
            if let image, let file {
                Button { NSWorkspace.shared.open(file) } label: {
                    Image(nsImage: image)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity, maxHeight: height)
                }
                .buttonStyle(.plain)
                .help("\(file.lastPathComponent) — click to open it")
                .overlay(alignment: .bottomLeading) {
                    Text(file.lastPathComponent)
                        .font(.system(size: 10, weight: .medium))
                        .lineLimit(1)
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.ultraThinMaterial, in: Capsule())
                        .padding(6)
                }
            } else {
                VStack(spacing: 6) {
                    Image(systemName: looked ? "film" : "hourglass")
                        .font(.system(size: 18))
                    Text(looked ? (folder == nil ? "No folder for this task" : "No render yet") : "Looking for the last render…")
                        .font(.system(size: 11))
                }
                .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity)
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).strokeBorder(Color.primary.opacity(0.12)))
        .task(id: folder) {
            defer { looked = true }
            guard let folder, let found = await RenderThumb.newestRender(in: folder) else { return }
            let url = found.0
            let req = QLThumbnailGenerator.Request(fileAt: url, size: CGSize(width: 960, height: height * 2), scale: 2,
                                                   representationTypes: .thumbnail)
            if let rep = try? await QLThumbnailGenerator.shared.generateBestRepresentation(for: req) {
                image = rep.nsImage
                file = url
            }
        }
    }
}
