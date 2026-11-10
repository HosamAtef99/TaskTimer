import SwiftUI

/// Team leaders (Hosam's call, 1.33): the tasks waiting for the leader's approval on Modhesh
/// (Tasks → Approve Tasks there), at the top of the Modhesh window, with Approve, Approve All and
/// Return (with a reason). The Chrome extension reads that list in the leader's Chrome and does
/// what's pressed here; nothing is ever approved by itself.
struct ApprovalsSection: View {
    @EnvironmentObject var store: Store
    @ObservedObject var cloud = CloudSync.shared
    @Local var confirmAll = false
    @Local var returning: CloudSync.Approval? = nil
    @Local var asked = false

    var body: some View {
        let list = cloud.approvals
        let free = list.filter { $0.action == nil }
        let busy = list.count - free.count
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                SectionLabel(text: "Waiting for your approval (\(list.count))")
                Spacer()
                Button {
                    asked = true
                    Task { @MainActor in await cloud.requestApprovals() }
                } label: { Label("Check Modhesh", systemImage: "arrow.clockwise") }
                    .buttonStyle(GlassButtonStyle(compact: true))
                    .help("Reads Modhesh's Approve Tasks list again (through the Chrome extension, within half a minute)")
                Button { confirmAll = true } label: {
                    Label("Approve All (\(free.count))", systemImage: "checkmark.seal")
                }
                .buttonStyle(GradientButtonStyle(compact: true))
                .disabled(free.isEmpty)
            }
            if let e = cloud.approvalsError {
                Label(e, systemImage: "exclamationmark.triangle.fill")
                    .font(.system(size: 12)).foregroundStyle(Theme.pink)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Text(statusLine(busy: busy))
                .font(.system(size: 11)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ForEach(list) { a in row(a) }
        }
        .task {
            await cloud.loadSettings()
            await cloud.loadApprovals()
            await cloud.requestApprovals()   // opening the window reads the list once
            while !Task.isCancelled {
                // Faster while the extension is working on something.
                let waiting = asked || cloud.approvals.contains { $0.action != nil }
                try? await Task.sleep(nanoseconds: waiting ? 6_000_000_000 : 30_000_000_000)
                if Task.isCancelled { break }
                let before = cloud.approvalsReadAt
                await cloud.loadSettings()
                await cloud.loadApprovals()
                if cloud.approvalsReadAt != before { asked = false }
            }
        }
        .confirmationDialog("Approve \(free.count) task\(free.count == 1 ? "" : "s") on Modhesh?", isPresented: $confirmAll) {
            Button("Approve All") {
                Task { @MainActor in await cloud.decide(free.map(\.code), action: "approve") }
            }
        } message: {
            Text("Every task in this list is approved on Modhesh with the hours shown. This can't be undone from Mongez.")
        }
        .sheet(item: $returning) { a in
            ReturnSheet(approval: a).environmentObject(store)
        }
    }

    private func statusLine(busy: Int) -> String {
        if busy > 0 { return "Working on \(busy) on Modhesh… Chrome has to be open and signed in to your Modhesh (up to half a minute)." }
        if asked { return "Asking the Chrome extension to read Modhesh… (up to half a minute; Chrome has to be open)" }
        var parts: [String] = []
        if let s = cloud.approvalsStatus, !s.isEmpty { parts.append(s) }
        if let d = cloud.approvalsReadAt { parts.append("read \(Fmt.relative(d))") }
        if parts.isEmpty { return "Not read yet — keep Chrome open with the Mongez extension, signed in to your Modhesh." }
        return parts.joined(separator: " · ")
    }

    private func row(_ a: CloudSync.Approval) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 3) {
                Text(a.title).font(.system(size: 13, weight: .semibold)).lineLimit(2)
                Text([a.assignee, a.client, a.completedAt.isEmpty ? "" : "done \(a.completedAt)"]
                        .filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(2)
                if let n = a.note, !n.isEmpty, a.action == nil {
                    Text(n).font(.system(size: 10)).foregroundStyle(Theme.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            if let s = a.seconds {
                Text("\(Fmt.hours(s)) h")
                    .font(.system(size: 13, weight: .medium, design: .rounded).monospacedDigit())
                    .fixedSize()
            }
            if let action = a.action {
                Text(action == "return" ? "Returning…" : "Approving…")
                    .font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.teal)
                    .fixedSize()
            } else {
                Button("Return…") { returning = a }
                    .buttonStyle(GlassButtonStyle(compact: true))
                Button("Approve") {
                    Task { @MainActor in await cloud.decide([a.code], action: "approve") }
                }
                .buttonStyle(GlassButtonStyle(compact: true))
            }
        }
        .padding(12)
        .glassCard(radius: 12)
    }
}

/// Return a task to its owner, with the reason Modhesh asks for.
struct ReturnSheet: View {
    @EnvironmentObject var store: Store
    @Environment(\.dismiss) var dismiss
    let approval: CloudSync.Approval
    @Local var reason = ""

    var body: some View {
        SheetFrame(title: "Return Task", subtitle: "\(approval.title) — \(approval.assignee)", icon: "arrow.uturn.backward") {
            FieldRow(label: "Reason (sent to Modhesh)") {
                TextEditor(text: $reason)
                    .font(.system(size: 13))
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .frame(height: 110)
                    .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 9))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color.primary.opacity(0.12)))
            }
            HStack {
                Spacer()
                Button("Cancel") { dismiss() }
                    .buttonStyle(GlassButtonStyle())
                    .keyboardShortcut(.cancelAction)
                Button {
                    let r = reason.trimmingCharacters(in: .whitespacesAndNewlines)
                    Task { @MainActor in await CloudSync.shared.decide([approval.code], action: "return", reason: r) }
                    dismiss()
                } label: { Label("Return Task", systemImage: "arrow.uturn.backward") }
                .buttonStyle(GradientButtonStyle())
                .disabled(reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .frame(width: 480)
    }
}
