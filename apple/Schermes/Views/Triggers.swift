import SwiftUI

extension TriggerKind {
    var symbol: String {
        switch self {
        case .webhook: "link"
        case .folder: "folder"
        case .command: "terminal"
        case .imap: "envelope"
        case .other: "bolt"
        }
    }
}

private func clock(_ millis: Int) -> String {
    Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .omitted, time: .shortened)
}

/// A trigger firing or being turned on: the daemon's line to the agent, not the owner speaking.
struct TriggerLine: View {
    let message: Message

    var body: some View {
        Label {
            Text("\(message.content.contains(" is on: ") ? "Trigger turned on" : "Trigger fired") · \(clock(message.createdAt))")
        } icon: {
            Image(systemName: "bolt")
        }
        .font(.caption2.weight(.medium))
        .foregroundStyle(Theme.muted)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

/// The agent's proposal in the chat: what it watches and why, Turn on or Delete, and once it is on
/// how to test it, until the first fire.
struct TriggerCard: View {
    let trigger: Trigger
    let pending: PendingTrigger
    let hookURL: URL?
    /// Opens the login form; nil when there is no form item to open.
    let onLogin: (() -> Void)?
    let act: (TriggerAction) async throws -> Void

    @State private var acting = false
    @State private var trouble: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: trigger.kind.symbol)
                Text("Trigger · \(trigger.kindWord)")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(trigger.state == .on ? Theme.done : Theme.needsYou)

            if let watches = trigger.kind == .webhook ? nil : trigger.watches {
                Text(watches)
                    .font(.subheadline.monospaced())
                    .lineLimit(3)
            }
            Text(trigger.reason)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)

            if trigger.state == .on {
                test
            } else {
                proposal
            }

            if let error = trouble ?? trigger.lastError {
                Text(error)
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var proposal: some View {
        HStack(spacing: 8) {
            Button(role: .destructive) { run(.delete) } label: {
                Text("Delete").frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.secondary))
            if trigger.needsLogin {
                if let onLogin {
                    Button(action: onLogin) { Text("Enter login…").frame(maxWidth: .infinity) }
                        .buttonStyle(.pill(.primary))
                }
            } else {
                Button { run(.on) } label: { Text("Turn on").frame(maxWidth: .infinity) }
                    .buttonStyle(.pill(.primary))
            }
        }
        #if os(macOS)
        .fixedSize()
        #endif
        .disabled(acting)
    }

    @ViewBuilder private var test: some View {
        if let webhook = trigger.webhook {
            CopyRow(label: "URL", value: hookURL?.absoluteString ?? webhook.path)
            CopyRow(label: "Secret", value: webhook.secret)
        }
        if let fired = pending.firedAt {
            Label("Fired · \(clock(fired))", systemImage: "checkmark.circle.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(Theme.done)
        } else {
            Text("Test it: \(trigger.howToTest)")
                .font(.footnote)
            HStack(spacing: 6) {
                ProgressView().controlSize(.mini)
                Text("Waiting for it to fire…")
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)
        }
    }

    private func run(_ action: TriggerAction) {
        acting = true
        trouble = nil
        Task {
            do {
                try await act(action)
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            acting = false
        }
    }
}

/// A value to paste somewhere else, with a copy button.
struct CopyRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(label).font(.caption2).foregroundStyle(Theme.muted)
                Text(value)
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 4)
            Button("Copy \(label)", systemImage: "doc.on.doc") { copyToPasteboard(value) }
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
        }
    }
}

/// The triggers half of "Routines and triggers": state, last fired, dropped, on/off and delete.
struct TriggersSection: View {
    let session: Session
    let agent: Agent

    @State private var triggers: [Trigger]?
    @State private var trouble: String?

    var body: some View {
        Section {
            if let triggers {
                if triggers.isEmpty {
                    Text("No triggers. \(agent.title) proposes them in the chat.").foregroundStyle(Theme.muted)
                }
                ForEach(triggers) { trigger in
                    TriggerRow(trigger: trigger) { act(trigger, $0 ? .on : .off) }
                        .swipeActions { deleteButton(trigger) }
                        .contextMenu { deleteButton(trigger) }
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
            }
        } header: {
            Text("Triggers").formHeader()
        } footer: {
            Text("Each one starts a turn in \(agent.title)'s thread when it fires. Fires past its hourly limit are dropped.")
        }
        .task(id: agent.name) {
            while !Task.isCancelled {
                if let rows = try? await session.run({ try await $0.triggers(agent: agent.name) }) {
                    triggers = rows
                }
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func deleteButton(_ trigger: Trigger) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) { act(trigger, .delete) }
    }

    private func act(_ trigger: Trigger, _ action: TriggerAction) {
        trouble = nil
        Task {
            do {
                let updated = try await session.run { try await $0.actOnTrigger(id: trigger.id, action: action) }
                if let updated {
                    triggers = triggers?.map { $0.id == updated.id ? updated : $0 }
                } else {
                    triggers?.removeAll { $0.id == trigger.id }
                }
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
        }
    }
}

struct TriggerRow: View {
    let trigger: Trigger
    let onSwitch: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Label(trigger.kindWord, systemImage: trigger.kind.symbol).font(.headline)
                if let watches = trigger.watches {
                    Text(watches)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Text(trigger.reason)
                    .font(.subheadline)
                    .lineLimit(3)
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                if let error = trigger.lastError {
                    Text("Last check failed: \(error)")
                        .font(.caption)
                        .foregroundStyle(Theme.failed)
                }
            }
            .opacity(trigger.state == .on ? 1 : 0.55)

            Spacer(minLength: 8)

            Toggle("On", isOn: Binding(get: { trigger.state == .on }, set: onSwitch))
                .labelsHidden()
                .toggleStyle(.switch)
                .disabled(trigger.needsLogin)
        }
        .padding(.vertical, 2)
    }

    private var timing: String {
        let state = switch trigger.state {
        case .proposed: trigger.needsLogin ? "Waiting for the login" : "Proposed"
        case .on: "On"
        case .off: "Off"
        }
        let fired = trigger.lastFiredAt.map {
            "last fired " + Date(timeIntervalSince1970: Double($0) / 1000).formatted(date: .abbreviated, time: .shortened)
        } ?? "not fired yet"
        let parts: [String?] = [state, fired, trigger.dropped > 0 ? "\(trigger.dropped) dropped" : nil]
        return parts.compactMap(\.self).joined(separator: " · ")
    }
}
