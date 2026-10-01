import SwiftUI

/// Where a daemon lives. Plain HTTP is allowed on purpose; see apple/README.md.
struct ConnectView: View {
    @Bindable var session: Session
    @State private var working = false

    var body: some View {
        VStack(spacing: 20) {
            BloubView(state: .idle, identity: .standard(for: "schermes"), size: 112)
                .padding(.bottom, 4)

            Text("schermes")
                .font(.pageTitle)
                .foregroundStyle(Theme.ink)

            Text("Your daemon's domain, or its address on this network.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            TextField("schermes.example.com or 127.0.0.1:7777", text: $session.address)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .gateField()
                .onSubmit(connect)

            Button(action: connect) { Text("Connect").frame(maxWidth: .infinity) }
                .buttonStyle(.pill(.primary))
                .controlSize(.large)
                .disabled(working || Session.parse(session.address) == nil)

            if let trouble = session.trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }

    private func connect() {
        guard !working else { return }
        working = true
        Task {
            await session.connect()
            working = false
        }
    }
}

/// Setup on a daemon with no owner yet, login on one that has one.
struct GateView: View {
    @Bindable var session: Session
    @State private var password = ""
    @State private var trouble: String?
    @State private var working = false

    private var isSetup: Bool { session.phase == .setup }

    /// The daemon's own floor, checked here so setup does not spend a round trip to be told it.
    /// A login is whatever was already chosen, so anything non-empty may be tried.
    private var longEnough: Bool {
        isSetup ? password.count >= MIN_PASSWORD_LENGTH : !password.isEmpty
    }

    var body: some View {
        VStack(spacing: 20) {
            BloubView(state: isSetup ? .wink : .idle, identity: .standard(for: "schermes"), size: 112)
                .padding(.bottom, 4)

            Text("schermes")
                .font(.pageTitle)
                .foregroundStyle(Theme.ink)

            Text(isSetup
                 ? "First visit. Choose the owner password — at least \(MIN_PASSWORD_LENGTH) characters."
                 : "Log in to reach your agents.")
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            SecureField("password", text: $password)
                .textFieldStyle(.plain)
                .gateField()
                .onSubmit(submit)

            Button(action: submit) { Text(isSetup ? "Set password" : "Log in").frame(maxWidth: .infinity) }
                .buttonStyle(.pill(.primary))
                .controlSize(.large)
                .disabled(working || !longEnough)

            Button("Use a different daemon") { session.forgetServer() }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary)

            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(Theme.failed)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.ground)
    }

    private func submit() {
        guard !working, longEnough else { return }
        working = true
        trouble = nil
        Task {
            do {
                try await session.enter(password: password)
                password = ""
            } catch {
                trouble = error.localizedDescription
            }
            working = false
        }
    }
}

private extension View {
    /// The canvas's text field: a solid r12 well with a hairline, 44 high.
    func gateField() -> some View {
        font(.body)
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
            .background(Theme.panel, in: .rect(cornerRadius: 12))
            .overlay { RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.ink.opacity(0.12)) }
    }
}
