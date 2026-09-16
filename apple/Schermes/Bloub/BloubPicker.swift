import SwiftUI

/// The eight bodies and the twelve colours, as a pair of rows. Each shape chip is a real avatar,
/// frozen at rest, so what is picked is what is got.
struct BloubPicker: View {
    @Binding var identity: BloubIdentity

    @Environment(\.colorScheme) private var scheme

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            row(label: "Shape") {
                ForEach(BloubShapeId.allCases, id: \.self) { shape in
                    Button {
                        identity.shape = shape
                    } label: {
                        BloubView(
                            state: .idle,
                            identity: BloubIdentity(shape: shape, color: identity.color),
                            size: 40,
                            frozenAt: BloubStates.poseTime(.idle)
                        )
                        .padding(3)
                        .overlay {
                            if identity.shape == shape {
                                Circle().strokeBorder(.tint, lineWidth: 2)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(shape.rawValue)
                }
            }

            row(label: "Colour") {
                ForEach(BloubColorId.allCases, id: \.self) { color in
                    Button {
                        identity.color = color
                    } label: {
                        Circle()
                            .fill(color.rgb(dark: scheme == .dark).color)
                            .frame(width: 26, height: 26)
                            .overlay {
                                Circle().strokeBorder(
                                    identity.color == color ? AnyShapeStyle(.tint)
                                        : AnyShapeStyle(.separator),
                                    lineWidth: identity.color == color ? 2.5 : 1
                                )
                            }
                            .padding(3)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(color.rawValue)
                }
            }
        }
    }

    private func row(label: String, @ViewBuilder content: () -> some View) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            ScrollView(.horizontal) {
                HStack(spacing: 4) { content() }
            }
            .scrollIndicators(.hidden)
        }
    }
}

/// Changing an agent's name and look after it exists. The same picker as the create sheet, over a
/// big live avatar so the choice is made against the thing itself rather than a swatch.
struct AgentLookSheet: View {
    let session: Session
    let agent: Agent

    @Environment(AgentLooks.self) private var looks
    @Environment(\.dismiss) private var dismiss
    @State private var identity: BloubIdentity
    @State private var label: String
    @State private var trouble: String?
    /// What the daemon held when the sheet opened, so Done sends only what moved.
    private let opened: BloubIdentity

    init(session: Session, agent: Agent, identity: BloubIdentity) {
        self.session = session
        self.agent = agent
        opened = identity
        _identity = State(initialValue: identity)
        _label = State(initialValue: agent.title)
    }

    private var wanted: String { label.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(spacing: 18) {
            BloubView(state: agent.state.bloub, identity: identity, size: 140)

            TextField("name", text: $label)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                .multilineTextAlignment(.center)
                .font(.title3.weight(.semibold))
                .onSubmit(finish)
            Text(trouble ?? "Runs as agent-\(agent.name)")
                .font(.footnote.monospaced())
                .foregroundStyle(trouble == nil ? Color.secondary : Color.red)

            BloubPicker(identity: $identity)

            HStack {
                Button("Reset") { identity = .standard(for: agent.name) }
                Spacer()
                Button("Done", action: finish)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(24)
        #if os(macOS)
        .frame(minWidth: 500)
        #else
        .frame(minWidth: 360)
        #endif
        .onChange(of: identity) { looks[agent.name] = identity }
    }

    /// Saves whatever changed — the name, the look, or both — then closes. The look is already on
    /// this device the moment it is picked; the daemon is where the other devices read it from.
    /// The list polls every couple of seconds, so nothing here has to tell it; a save that fails
    /// keeps the sheet open and says why.
    private func finish() {
        let newLabel = wanted != agent.title ? wanted : nil
        let newLook = identity != opened ? identity.token : nil
        guard newLabel != nil || newLook != nil else { return dismiss() }
        if newLabel != nil, !isAgentLabel(wanted) {
            trouble = "One line, up to \(MAX_AGENT_LABEL) characters."
            return
        }
        Task {
            do {
                _ = try await session.run { try await $0.updateAgent(name: agent.name, label: newLabel, look: newLook) }
                dismiss()
            } catch {
                trouble = error.localizedDescription
            }
        }
    }
}
