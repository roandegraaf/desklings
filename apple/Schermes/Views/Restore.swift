import SwiftUI

extension RewindPreview {
    var hasFileChanges: Bool { files.contains { $0.count > 0 } }

    /// The daemon refuses `files` while any agent in the thread lacks a snapshot.
    var canPutFilesBack: Bool { noSnapshot.isEmpty && hasFileChanges }

    /// Every agent's changes, one path a line, the first `limit` of them and how many more there are.
    func fileLines(limit: Int) -> (lines: [String], more: Int) {
        let all = files.flatMap { changes in
            changes.added.map { "added    \($0)" } + changes.changed.map { "changed  \($0)" } + changes.removed.map { "removed  \($0)" }
        }
        return (Array(all.prefix(limit)), max(all.count - limit, 0))
    }
}

/// The daemon's line after a rewind put an agent's files back: quiet, not an owner bubble.
struct RestoreLine: View {
    let message: Message

    var body: some View {
        Label {
            Text("Files put back · \(Date(timeIntervalSince1970: Double(message.createdAt) / 1000).formatted(date: .omitted, time: .shortened))")
        } icon: {
            Image(systemName: "arrow.uturn.backward")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .help(message.content)
        .accessibilityElement(children: .combine)
    }
}

/// Restore or Retry, asked first: what goes from the thread, whether the files go back too, and
/// what stays done whatever the owner picks.
struct RewindSheet: View {
    let retry: Bool
    let title: (String) -> String
    let load: () async throws -> RewindPreview
    let confirm: (_ files: Bool) async throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var preview: RewindPreview?
    @State private var putFilesBack = false
    @State private var working = false
    @State private var trouble: String?

    private static let listed = 6

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(retry ? "Retry this reply?" : "Restore to this message?")
                        .font(.system(.title2, design: .rounded, weight: .bold))
                    if let preview {
                        Text(removedLine(preview))
                            .font(.subheadline)
                            .foregroundStyle(Theme.secondary)
                    }
                }
                if let preview {
                    details(preview)
                } else if trouble == nil {
                    ProgressView().frame(maxWidth: .infinity)
                }
                if let trouble {
                    Label(trouble, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(Theme.failed)
                }
            }
            .padding(20)
        }
        .safeAreaInset(edge: .bottom) {
            HStack(spacing: 8) {
                Button { dismiss() } label: {
                    Text("Cancel").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.secondary))
                .keyboardShortcut(.cancelAction)
                Button(role: .destructive) { go() } label: {
                    Text(retry ? "Retry" : "Restore").frame(maxWidth: .infinity)
                }
                .buttonStyle(.pill(.destructive))
                .disabled(working || (preview == nil && trouble == nil))
            }
            .controlSize(.large)
            .padding(20)
            .background(Theme.panel)
        }
        .background(Theme.panel)
        .presentationDetents([.medium, .large])
        .presentationBackground(Theme.panel)
        #if os(macOS)
        .frame(minWidth: 400, idealWidth: 440, minHeight: 320, idealHeight: 440)
        #endif
        .task {
            do {
                let loaded = try await load()
                preview = loaded
                putFilesBack = loaded.canPutFilesBack
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }

    private func removedLine(_ preview: RewindPreview) -> String {
        let later = retry ? preview.removed : max(preview.removed - 1, 0)
        let removed = later == 0 ? "Nothing after it is removed" : "\(later) later message\(later == 1 ? "" : "s") will be removed"
        return retry ? "\(removed) and the agent answers again." : "\(removed); your message goes back into the box."
    }

    @ViewBuilder
    private func details(_ preview: RewindPreview) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Toggle(isOn: $putFilesBack) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Put the files back too").font(.body.weight(.semibold))
                    ForEach(filesLines(preview), id: \.self) { line in
                        Text(line).font(.footnote).foregroundStyle(Theme.muted)
                    }
                }
            }
            .disabled(!preview.canPutFilesBack || working)
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            let (lines, more) = preview.fileLines(limit: Self.listed)
            if !lines.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(lines, id: \.self) { Text($0).lineLimit(1).truncationMode(.middle) }
                    if more > 0 { Text("and \(more) more") }
                }
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Theme.secondary)
                .padding(.horizontal, 14)
                .padding(.bottom, 12)
                .opacity(putFilesBack ? 1 : 0.5)
            }
            if !preview.cantUndo.isEmpty {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(Theme.failed)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Can't be taken back").fontWeight(.semibold)
                        ForEach(preview.cantUndo, id: \.self) { Text($0.text) }
                    }
                }
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                .background(Theme.failed.opacity(0.12))
            }
        }
        .background(Theme.card, in: .rect(cornerRadius: 18))
        .clipShape(.rect(cornerRadius: 18))
        .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Theme.hairline))
    }

    private func filesLines(_ preview: RewindPreview) -> [String] {
        if !preview.noSnapshot.isEmpty {
            let names = preview.noSnapshot.map(title).formatted(.list(type: .and))
            return ["There is no snapshot of \(names)'s files from before this message, so they stay as they are."]
        }
        if !preview.hasFileChanges { return ["No files changed after this message."] }
        return preview.files.filter { $0.count > 0 }.map { changes in
            "\(title(changes.agent)) changed \(changes.count) file\(changes.count == 1 ? "" : "s") after this message"
        }
    }

    private func go() {
        working = true
        trouble = nil
        Task {
            do {
                try await confirm(putFilesBack && preview?.canPutFilesBack == true)
                dismiss()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            working = false
        }
    }
}
