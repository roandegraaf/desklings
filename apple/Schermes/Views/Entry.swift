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

            if let url = Session.parse(session.address) { CleartextWarning(url: url) }

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

/// Nothing at all for HTTPS or this device's own loopback.
struct CleartextWarning: View {
    let url: URL

    var body: some View {
        if Session.isCleartext(url) {
            Label {
                Text("Plain HTTP: your password and session cross the network unencrypted. Put the daemon behind HTTPS unless this network is yours alone.")
            } icon: {
                Image(systemName: "lock.open.fill").foregroundStyle(Theme.needsYou)
            }
            .font(.footnote)
            .foregroundStyle(Theme.muted)
            .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Setup on a daemon with no owner yet, login on one that has one. Setup takes the code the daemon
/// printed in its log; a login with TOTP on asks for the authenticator code once the password is
/// right, or a recovery code instead.
struct GateView: View {
    @Bindable var session: Session
    @State private var password = ""
    @State private var setupCode = ""
    @State private var code = ""
    @State private var needsCode = false
    @State private var usingRecovery = false
    @State private var trouble: String?
    @State private var working = false
    /// The daemon's backoff: nothing is sent before this, since it would only extend the wait.
    @State private var lockedUntil: Date?

    private var isSetup: Bool { session.phase == .setup }

    /// The daemon's own floor, checked here so setup does not spend a round trip to be told it.
    /// A login is whatever was already chosen, so anything non-empty may be tried.
    private var ready: Bool {
        if isSetup { return password.count >= MIN_PASSWORD_LENGTH && !blank(setupCode) }
        return !password.isEmpty && (!needsCode || !blank(code))
    }

    private func blank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var prompt: String {
        if isSetup {
            return "First visit. Choose the owner password — at least \(MIN_PASSWORD_LENGTH) characters — and enter the setup code from the daemon's log."
        }
        if needsCode {
            return usingRecovery
                ? "Enter one of the recovery codes you saved when you turned on two-factor sign-in."
                : "Enter the 6-digit code from your authenticator app."
        }
        return "Log in to reach your agents."
    }

    var body: some View {
        VStack(spacing: 20) {
            BloubView(state: isSetup ? .wink : .idle, identity: .standard(for: "schermes"), size: 112)
                .padding(.bottom, 4)

            Text("schermes")
                .font(.pageTitle)
                .foregroundStyle(Theme.ink)

            Text(prompt)
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)

            SecureField("password", text: $password)
                .textFieldStyle(.plain)
                .gateField()
                .onSubmit(submit)

            if isSetup {
                TextField("setup code", text: $setupCode)
                    .codeField()
                    .onSubmit(submit)
            } else if needsCode {
                TextField(usingRecovery ? "xxxx-xxxx-xxxx-xxxx" : "123456", text: $code)
                    .codeField(digits: !usingRecovery)
                    .onSubmit(submit)
            }

            Button(action: submit) { Text(isSetup ? "Set password" : "Log in").frame(maxWidth: .infinity) }
                .buttonStyle(.pill(.primary))
                .controlSize(.large)
                .disabled(working || !ready || lockedUntil != nil)

            if let url = session.client?.baseURL { CleartextWarning(url: url) }

            if needsCode && !isSetup {
                Button(usingRecovery ? "Use the authenticator code" : "Use a recovery code") {
                    usingRecovery.toggle()
                    code = ""
                    trouble = nil
                }
                .buttonStyle(.plain)
                .font(.footnote.weight(.semibold))
                .foregroundStyle(Theme.secondary)
            }

            Button("Use a different daemon") {
                needsCode = false
                usingRecovery = false
                code = ""
                setupCode = ""
                trouble = nil
                session.forgetServer()
            }
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
        .task(id: lockedUntil) {
            guard let lockedUntil else { return }
            try? await Task.sleep(for: .seconds(max(lockedUntil.timeIntervalSinceNow, 0)))
            if !Task.isCancelled { self.lockedUntil = nil }
        }
    }

    private func submit() {
        guard !working, ready, lockedUntil == nil else { return }
        working = true
        trouble = nil
        let sentCode = needsCode
        Task {
            do {
                try await session.enter(
                    password: password,
                    setupToken: setupCode,
                    totp: sentCode && !usingRecovery ? code : nil,
                    recoveryCode: sentCode && usingRecovery ? code : nil
                )
                password = ""
                setupCode = ""
                code = ""
                needsCode = false
                usingRecovery = false
            } catch SchermesError.totpRequired(let message) {
                needsCode = true
                code = ""
                if sentCode { trouble = message }
            } catch SchermesError.tooManyAttempts(let wait, let message) {
                lockedUntil = .now.addingTimeInterval(TimeInterval(wait))
                trouble = message
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
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

    /// A code is pasted or read off another screen: no capitals, no corrections, and on a phone
    /// the one-time-code keyboard, which offers the code from Passwords.
    func codeField(digits: Bool = false) -> some View {
        textFieldStyle(.plain)
            .autocorrectionDisabled()
            #if os(iOS)
            .textInputAutocapitalization(.never)
            .keyboardType(digits ? .numberPad : .asciiCapable)
            .textContentType(digits ? .oneTimeCode : nil)
            #endif
            .font(.body.monospaced())
            .gateField()
    }
}
