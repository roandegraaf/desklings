import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// The `otpauth://` uri as a QR code an authenticator app can scan. Drawn with nearest-neighbour
/// scaling so the modules stay sharp.
func qrCode(_ text: String, scale: CGFloat = 8) -> CGImage? {
    let filter = CIFilter.qrCodeGenerator()
    filter.message = Data(text.utf8)
    filter.correctionLevel = "M"
    guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: scale, y: scale)) else { return nil }
    return CIContext().createCGImage(output, from: output.extent)
}

extension AuditAction {
    var title: String {
        switch self {
        case .setup: "Daemon claimed"
        case .login: "Signed in"
        case .login_failed: "Sign-in refused"
        case .logout: "Signed out"
        case .password_changed: "Password changed"
        case .password_change_failed: "Password change refused"
        case .session_revoked: "Session revoked"
        case .totp_enabled: "Two-factor sign-in turned on"
        case .totp_disabled: "Two-factor sign-in turned off"
        case .recovery_code_used: "Recovery code used"
        case .settings_changed: "Settings changed"
        case .provider_changed: "Provider changed"
        case .model_changed: "Model changed"
        case .mcp_changed: "Plugins changed"
        case .rules_changed: "Rules changed"
        case .unknown: "Something this app does not know yet"
        }
    }

    var symbol: String {
        switch self {
        case .setup: "flag"
        case .login: "person.badge.key"
        case .login_failed, .password_change_failed: "exclamationmark.triangle"
        case .logout, .session_revoked: "rectangle.portrait.and.arrow.right"
        case .password_changed: "key"
        case .totp_enabled, .totp_disabled: "lock.shield"
        case .recovery_code_used: "lifepreserver"
        case .settings_changed, .provider_changed, .model_changed, .mcp_changed, .rules_changed: "slider.horizontal.3"
        case .unknown: "questionmark.circle"
        }
    }

    /// A refusal is what an owner scanning the log is looking for.
    var isRefusal: Bool { self == .login_failed || self == .password_change_failed }
}

private extension JSONValue {
    var shown: String {
        switch self {
        case .null: "none"
        case .bool(let value): value ? "yes" : "no"
        case .number(let value): value.rounded() == value && abs(value) < 1e15 ? String(Int(value)) : String(value)
        case .string(let value): value
        case .array(let values): values.map(\.shown).joined(separator: ", ")
        case .object(let fields): fields.keys.sorted().map { "\($0) \(fields[$0]!.shown)" }.joined(separator: ", ")
        }
    }
}

extension AuditEvent {
    /// The detail the daemon recorded, names and handles only, as one line in a fixed order.
    var detailLine: String? {
        guard let detail, !detail.isEmpty else { return nil }
        return detail.keys.sorted().map { "\($0): \(detail[$0]!.shown)" }.joined(separator: " · ")
    }

    var origin: String? {
        let parts = [ip, userAgent].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}

/// The audit log as loaded so far, newest first. Each older page asks from the oldest id shown,
/// and a page shorter than asked for means there is nothing older.
struct AuditLog: Equatable {
    static let pageSize = 25

    private(set) var events: [AuditEvent] = []
    private(set) var exhausted = false

    var oldest: Int? { events.last?.id }

    mutating func append(_ page: [AuditEvent], asked limit: Int) {
        let known = Set(events.map(\.id))
        events += page.filter { !known.contains($0.id) }
        exhausted = page.count < limit
    }
}

func relativeTime(_ millis: Int) -> String {
    Date(timeIntervalSince1970: Double(millis) / 1000).formatted(.relative(presentation: .named, unitsStyle: .wide))
}

/// Password, second factor, signed-in clients and the audit log. Each section loads and saves on
/// its own, so one refusal never hides the others.
struct AccountPage: View {
    let session: Session

    var body: some View {
        ThemedForm {
            PasswordSection(session: session)
            TotpSection(session: session)
            SessionsSection(session: session)
            AuditSection(session: session)
        }
        .autocorrectionDisabled()
        #if os(iOS)
        .textInputAutocapitalization(.never)
        #endif
        .navigationTitle(SettingsCategory.account.title)
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
    }
}

private struct Trouble: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.failed)
            .textSelection(.enabled)
    }
}

private struct Note: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.footnote)
            .foregroundStyle(Theme.muted)
    }
}

private struct PasswordSection: View {
    let session: Session

    @State private var current = ""
    @State private var next = ""
    @State private var repeated = ""
    @State private var saving = false
    @State private var trouble: String?
    @State private var done: String?

    private var ready: Bool {
        !current.isEmpty && next.count >= MIN_PASSWORD_LENGTH && next == repeated && !saving
    }

    var body: some View {
        Section {
            SecureField("Current password", text: $current, prompt: Text("Current password"))
                .textContentType(.password)
            SecureField("New password", text: $next, prompt: Text("New password"))
                .textContentType(.newPassword)
            SecureField("Repeat new password", text: $repeated, prompt: Text("Repeat new password"))
                .textContentType(.newPassword)
            Button(saving ? "Changing…" : "Change password", action: change)
                .buttonStyle(.pill(.primary))
                .disabled(!ready)
            if let trouble {
                Trouble(text: trouble)
            } else if !repeated.isEmpty && next != repeated {
                Note(text: "The two new passwords differ.")
            } else if let done {
                Note(text: done)
            }
        } header: {
            Text("Password").formHeader()
        } footer: {
            Text("At least \(MIN_PASSWORD_LENGTH) characters. Every other signed-in device is signed out; this one stays signed in.")
        }
    }

    private func change() {
        guard ready else { return }
        saving = true
        trouble = nil
        done = nil
        let current = current, next = next
        Task {
            do {
                let signedOut = try await session.changePassword(current: current, next: next)
                self.current = ""
                self.next = ""
                repeated = ""
                done = signedOut == 0
                    ? "Password changed."
                    : "Password changed. \(signedOut) other session\(signedOut == 1 ? " was" : "s were") signed out."
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            saving = false
        }
    }
}

private struct TotpSection: View {
    let session: Session

    @State private var status: TotpStatus?
    @State private var password = ""
    @State private var setup: TotpSetup?
    @State private var qrImage: CGImage?
    @State private var code = ""
    @State private var recoveryCodes: [String]?
    @State private var turningOff = false
    @State private var withRecoveryCode = false
    @State private var busy = false
    @State private var trouble: String?

    var body: some View {
        Section {
            if let recoveryCodes {
                codesShown(recoveryCodes)
            } else if let setup {
                enrolling(setup)
            } else if let status {
                if status.enabled {
                    enabled(status)
                } else {
                    disabled
                }
            } else if trouble == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let trouble { Trouble(text: trouble) }
        } header: {
            Text("Two-factor sign-in").formHeader()
        } footer: {
            Text("A six-digit code from an authenticator app, asked for after the password at every sign-in. The share sheet and notification buttons keep working on this device's session.")
        }
        .task { await load() }
    }

    @ViewBuilder private var disabled: some View {
        LabeledContent("Status", value: "Off")
        SecureField("Password", text: $password, prompt: Text("Your password"))
            .textContentType(.password)
        Button(busy ? "Starting…" : "Set up", action: begin)
            .buttonStyle(.pill(.primary))
            .disabled(password.isEmpty || busy)
    }

    @ViewBuilder private func enrolling(_ setup: TotpSetup) -> some View {
        if let image = qrImage {
            Image(decorative: image, scale: 1)
                .interpolation(.none)
                .resizable()
                .scaledToFit()
                .frame(width: 180, height: 180)
                .padding(10)
                .background(.white, in: .rect(cornerRadius: 12))
                .frame(maxWidth: .infinity)
                .accessibilityLabel("QR code for your authenticator app")
        }
        LabeledContent("Secret") {
            Text(setup.secret)
                .font(.callout.monospaced())
                .textSelection(.enabled)
                .multilineTextAlignment(.trailing)
        }
        HStack {
            Button("Copy secret", systemImage: "doc.on.doc") { copyToPasteboard(setup.secret) }
                .buttonStyle(.pill(.secondary))
            #if os(iOS)
            if let url = URL(string: setup.uri) {
                Link(destination: url) { Label("Open in authenticator", systemImage: "arrow.up.forward.app") }
                    .buttonStyle(.pill(.secondary))
            }
            #endif
        }
        .buttonStyle(.borderless)
        codeField("Code from the app")
        HStack {
            Button(busy ? "Checking…" : "Turn on", action: confirm)
                .buttonStyle(.pill(.primary))
                .disabled(code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
            Button("Cancel") {
                self.setup = nil
                qrImage = nil
                code = ""
                trouble = nil
            }
            .buttonStyle(.pill(.secondary))
        }
        .buttonStyle(.borderless)
        Note(text: "Scan the code, or type the secret into the app, then enter the six digits it shows.")
    }

    @ViewBuilder private func codesShown(_ codes: [String]) -> some View {
        Note(text: "Two-factor sign-in is on. Keep these recovery codes somewhere safe: each one signs in once without the phone, and they are not shown again.")
        Text(codes.joined(separator: "\n"))
            .font(.callout.monospaced())
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
        HStack {
            Button("Copy", systemImage: "doc.on.doc") { copyToPasteboard(codes.joined(separator: "\n")) }
                .buttonStyle(.pill(.secondary))
            ShareLink(item: codes.joined(separator: "\n")) { Label("Share", systemImage: "square.and.arrow.up") }
                .buttonStyle(.pill(.secondary))
            Button("I saved them") {
                recoveryCodes = nil
                Task { await load() }
            }
            .buttonStyle(.pill(.primary))
        }
        .buttonStyle(.borderless)
    }

    @ViewBuilder private func enabled(_ status: TotpStatus) -> some View {
        LabeledContent(
            "Status",
            value: "On · \(status.recoveryCodesLeft) recovery code\(status.recoveryCodesLeft == 1 ? "" : "s") left"
        )
        if turningOff {
            SecureField("Password", text: $password, prompt: Text("Your password"))
                .textContentType(.password)
            codeField(withRecoveryCode ? "Recovery code" : "Code from the app")
            Button(withRecoveryCode ? "Use the authenticator code" : "Use a recovery code") {
                withRecoveryCode.toggle()
                code = ""
            }
            .buttonStyle(.borderless)
            HStack {
                Button(busy ? "Turning off…" : "Turn off", role: .destructive, action: turnOff)
                    .buttonStyle(.pill(.destructive))
                    .disabled(password.isEmpty || code.trimmingCharacters(in: .whitespaces).isEmpty || busy)
                Button("Cancel") {
                    turningOff = false
                    password = ""
                    code = ""
                    trouble = nil
                }
                .buttonStyle(.pill(.secondary))
            }
            .buttonStyle(.borderless)
        } else {
            Button("Turn off…") { turningOff = true }
                .buttonStyle(.pill(.secondary))
        }
    }

    private func codeField(_ title: String) -> some View {
        TextField(title, text: $code, prompt: Text(title))
            .font(.body.monospaced())
            #if os(iOS)
            .keyboardType(withRecoveryCode && turningOff ? .asciiCapable : .numberPad)
            .textContentType(.oneTimeCode)
            #endif
    }

    private func load() async {
        do {
            status = try await session.run { try await $0.totpStatus() }
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func perform(_ work: @escaping () async throws -> Void) {
        guard !busy else { return }
        busy = true
        trouble = nil
        Task {
            do {
                try await work()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            busy = false
        }
    }

    private func begin() {
        let password = password
        perform {
            let started = try await session.run { try await $0.setupTotp(password: password) }
            qrImage = qrCode(started.uri)
            setup = started
            self.password = ""
            code = ""
        }
    }

    private func confirm() {
        let code = code.trimmingCharacters(in: .whitespaces)
        perform {
            let confirmed = try await session.run { try await $0.confirmTotp(code: code) }
            recoveryCodes = confirmed.recoveryCodes
            setup = nil
            qrImage = nil
            self.code = ""
        }
    }

    private func turnOff() {
        let password = password
        let code = code.trimmingCharacters(in: .whitespaces)
        let recovery = withRecoveryCode
        perform {
            try await session.run {
                try await $0.disableTotp(password: password, code: recovery ? nil : code, recoveryCode: recovery ? code : nil)
            }
            turningOff = false
            withRecoveryCode = false
            self.password = ""
            self.code = ""
            await load()
        }
    }
}

private struct SessionsSection: View {
    let session: Session

    @State private var entries: [SessionEntry]?
    @State private var revoking: Set<String> = []
    @State private var confirmingOwn: SessionEntry?
    @State private var trouble: String?

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Section {
            if let entries {
                ForEach(entries) { entry in
                    row(entry)
                }
            } else if trouble == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if let trouble { Trouble(text: trouble) }
        } header: {
            Text("Sessions").formHeader()
        } footer: {
            Text("Every device signed in to this daemon, most recently seen first. Revoking one signs it out at once.")
        }
        .task { await load() }
        .confirmationDialog(
            "Sign this device out?",
            isPresented: Binding(get: { confirmingOwn != nil }, set: { if !$0 { confirmingOwn = nil } }),
            titleVisibility: .visible,
            presenting: confirmingOwn
        ) { entry in
            Button("Sign out", role: .destructive) {
                dismiss()
                Task {
                    do {
                        try await session.revoke(entry)
                    } catch {
                        if !error.isCancellation { trouble = error.localizedDescription }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("This is the session this app is using. It is taken off the push list too.")
        }
    }

    private func row(_ entry: SessionEntry) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 6) {
                    Text(entry.userAgent ?? "Unknown client")
                        .font(.callout)
                        .lineLimit(2)
                    if entry.current {
                        Text("This device")
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(.quaternary, in: .capsule)
                    }
                }
                Text("Seen \(relativeTime(entry.lastSeenAt ?? entry.createdAt)) · signed in \(relativeTime(entry.createdAt))")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 8)
            Button(entry.current ? "Sign out" : (revoking.contains(entry.handle) ? "Revoking…" : "Revoke"), role: .destructive) {
                if entry.current { confirmingOwn = entry } else { revoke(entry) }
            }
            .buttonStyle(.pill(.destructive))
            .controlSize(.small)
            .disabled(revoking.contains(entry.handle))
        }
        .padding(.vertical, 2)
    }

    private func load() async {
        do {
            entries = try await session.run { try await $0.sessions() }
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }

    private func revoke(_ entry: SessionEntry) {
        revoking.insert(entry.handle)
        trouble = nil
        Task {
            do {
                try await session.revoke(entry)
                entries?.removeAll { $0.handle == entry.handle }
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            revoking.remove(entry.handle)
        }
    }
}

private struct AuditSection: View {
    let session: Session

    @State private var log = AuditLog()
    @State private var loaded = false
    @State private var loading = false
    @State private var trouble: String?

    var body: some View {
        Section {
            if loaded && log.events.isEmpty {
                Note(text: "Nothing recorded yet.")
            }
            ForEach(log.events) { event in
                row(event)
            }
            if !loaded && trouble == nil {
                ProgressView().frame(maxWidth: .infinity)
            }
            if loaded && !log.exhausted {
                Button(loading ? "Loading…" : "Load older") { Task { await page() } }
                    .buttonStyle(.pill(.secondary))
                    .disabled(loading)
            }
            if let trouble { Trouble(text: trouble) }
        } header: {
            Text("Audit log").formHeader()
        } footer: {
            Text("Sign-ins, refusals and changes to settings, models, plugins and rules, newest first. Kept for 90 days.")
        }
        .task { if !loaded { await page() } }
    }

    private func row(_ event: AuditEvent) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: event.action.symbol)
                .foregroundStyle(event.action.isRefusal ? AnyShapeStyle(Theme.failed) : AnyShapeStyle(Theme.muted))
                .frame(width: 20)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline) {
                    Text(event.action.title)
                        .font(.callout)
                    Spacer(minLength: 8)
                    Text(Date(timeIntervalSince1970: Double(event.at) / 1000).formatted(date: .abbreviated, time: .shortened))
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                if let detail = event.detailLine {
                    Text(detail)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.secondary)
                        .lineLimit(3)
                }
                if let origin = event.origin {
                    Text(origin)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
            }
        }
        .textSelection(.enabled)
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }

    private func page() async {
        guard !loading else { return }
        loading = true
        trouble = nil
        let before = log.oldest
        do {
            let events = try await session.run { try await $0.audit(before: before, limit: AuditLog.pageSize) }
            log.append(events, asked: AuditLog.pageSize)
            loaded = true
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
        loading = false
    }
}
