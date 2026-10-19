import SwiftUI
import AppKit

/// Tasks read from Modhesh (by the TaskTimer Chrome extension) and the TaskTimer task each one
/// is linked to. Linked tasks get their hours, deliverables, stars and start date filled in
/// on Modhesh by the extension.
struct ModheshView: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    @ObservedObject var cloud = CloudSync.shared
    @Local var showLinked = false

    var body: some View {
        let all = cloud.modheshTasks
        let unlinked = all.filter { $0.taskID == nil || store.task($0.taskID!) == nil }
        let linked = all.filter { $0.taskID != nil && store.task($0.taskID!) != nil }

        SheetFrame(title: "Modhesh", subtitle: "Link each Modhesh task to the task you timed", icon: "link") {
            if let e = cloud.modheshError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if all.isEmpty && cloud.modheshError == nil {
                VStack(alignment: .leading, spacing: 6) {
                    Text("No Modhesh tasks yet.").font(.system(size: 13, weight: .semibold))
                    Text("Install the TaskTimer extension in Chrome, sign in to it, then open your tasks on Modhesh once — they show up here.")
                        .font(.system(size: 12)).foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(14)
                .frame(maxWidth: .infinity, alignment: .leading)
                .glassCard(radius: 12)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
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
                Spacer()
                Button("Done") { dismiss() }
                    .buttonStyle(GradientButtonStyle())
                    .keyboardShortcut(.defaultAction)
            }
        }
        .frame(width: 720, height: 620)
        .task { await cloud.loadModhesh() }
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
                    Task { @MainActor in await cloud.linkModhesh(m.code, to: best.task.id) }
                } label: {
                    Text("Link to “\(store.displayName(best.task))”").lineLimit(1)
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .frame(maxWidth: 230)
                .help("Best match by name and account")
            }
            Menu {
                ForEach(suggestions.prefix(25), id: \.task.id) { c in
                    Button(store.displayName(c.task) + (store.clientName(c.task.clientID).isEmpty ? "" : "  — \(store.clientName(c.task.clientID))")) {
                        Task { @MainActor in await cloud.linkModhesh(m.code, to: c.task.id) }
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
                    Text("\(Fmt.hours(t.totalSeconds(at: store.now))) h in TaskTimer")
                        .font(.system(size: 10)).foregroundStyle(.secondary)
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
        let clientID = m.client.isEmpty ? nil : store.addClient(m.client)?.id
        let id = store.addTask(name: FolderService.cleanName(m.title), clientID: clientID, folder: nil,
                               start: false, incoming: true, wantsFolder: true)
        Task { @MainActor in await cloud.linkModhesh(m.code, to: id) }
        store.flash("Added “\(m.title)” to Incoming and linked it")
    }
}
