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

/// Changing an agent's look after it exists. The same picker as the create sheet, over a big live
/// avatar so the choice is made against the thing itself rather than a swatch.
struct AgentLookSheet: View {
    let name: String
    let state: AgentState

    @Environment(AgentLooks.self) private var looks
    @Environment(\.dismiss) private var dismiss
    @State private var identity: BloubIdentity

    init(name: String, state: AgentState, identity: BloubIdentity) {
        self.name = name
        self.state = state
        _identity = State(initialValue: identity)
    }

    var body: some View {
        VStack(spacing: 18) {
            BloubView(state: state.bloub, identity: identity, size: 140)
            Text(name)
                .font(.title3.weight(.semibold))

            BloubPicker(identity: $identity)

            HStack {
                Button("Reset") { identity = .standard(for: name) }
                Spacer()
                Button("Done") { dismiss() }
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
        .onChange(of: identity) { looks[name] = identity }
    }
}
