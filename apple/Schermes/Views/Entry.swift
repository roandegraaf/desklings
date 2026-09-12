import SwiftUI

/// Where a daemon lives. Plain HTTP is allowed on purpose; see apple/README.md.
struct ConnectView: View {
    @Bindable var session: Session
    @State private var working = false

    var body: some View {
        VStack(spacing: 20) {
            Text("schermes")
                .font(.largeTitle.weight(.semibold))

            Text("The address of your daemon. Use https for anything off this network.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            TextField("127.0.0.1:7777", text: $session.address)
                .textFieldStyle(.plain)
                .autocorrectionDisabled()
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .onSubmit(connect)

            Button("Connect", action: connect)
                .buttonStyle(.borderedProminent)
                .disabled(working || Session.parse(session.address) == nil)

            if let trouble = session.trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
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
            Text("schermes")
                .font(.largeTitle.weight(.semibold))

            Text(isSetup
                 ? "First visit. Choose the owner password — at least \(MIN_PASSWORD_LENGTH) characters."
                 : "Log in to reach your agents.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)

            SecureField("password", text: $password)
                .textFieldStyle(.plain)
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .glassEffect(.regular, in: .capsule)
                .onSubmit(submit)

            Button(isSetup ? "Set password" : "Log in", action: submit)
                .buttonStyle(.borderedProminent)
                .disabled(working || !longEnough)

            Button("Use a different daemon") { session.forgetServer() }
                .buttonStyle(.plain)
                .font(.footnote)
                .foregroundStyle(.secondary)

            if let trouble {
                Text(trouble)
                    .font(.footnote)
                    .foregroundStyle(.red)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(32)
        .frame(maxWidth: 420)
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
