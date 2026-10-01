import SwiftUI

/// What a text field holds, so the keyboard and password managers offer the right thing.
enum FieldContent: Equatable {
    case username, email, password, newPassword, oneTimeCode, phone, url, plain
}

extension FormField {
    var content: FieldContent {
        let hint = autocomplete?.lowercased().split(separator: " ").last.map(String.init) ?? ""
        switch hint {
        case "one-time-code": return .oneTimeCode
        case "new-password": return .newPassword
        case "current-password": return .password
        case "username": return .username
        case "email": return .email
        case "tel": return .phone
        case "url": return .url
        default: break
        }
        switch type {
        case "password": return .password
        case "email": return .email
        case "tel": return .phone
        case "url": return .url
        default: return .plain
        }
    }

    /// Only passwords are dotted: iOS reads two secure fields as a sign-up and offers a new
    /// password, so a one-time code or card number shows as typed (it still never reaches the agent).
    var hidesTyping: Bool { content == .password || content == .newPassword }
}

extension UnfillableField {
    var why: String {
        switch reason {
        case "cross_origin_frame": "It sits in a frame from another site"
        case "captcha": "A check only a person can pass"
        case "unknown_widget": "A control the form reader can't work"
        case "file": "A file to upload"
        case "insecure": "A secret on a page without HTTPS"
        default: reason
        }
    }
}

/// The page's origin as the daemon read it, with a lock when it is HTTPS or loopback.
struct FormOrigin: View {
    let form: FormRequest

    var body: some View {
        Label {
            Text(form.origin)
                .font(.subheadline.monospaced().weight(.semibold))
                .lineLimit(1)
                .truncationMode(.middle)
        } icon: {
            Image(systemName: form.secure ? "lock.fill" : "lock.open")
                .foregroundStyle(form.secure ? Theme.ink : Theme.failed)
        }
        .accessibilityLabel(form.secure ? "\(form.origin), secure" : "\(form.origin), not secure")
    }
}

/// The agent's `request_form` in the chat: where, why, and the two ways to answer it.
struct FormCard: View {
    let agent: String
    let form: FormRequest
    let onFill: () -> Void
    let onScreen: () async -> Void

    @State private var acting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "list.bullet.rectangle")
                Text("Needs you · form")
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Theme.needsYou)
            Text("\(agent) asks you to fill a form")
                .font(.subheadline.weight(.semibold))
            FormOrigin(form: form)
            Text(form.reason)
                .font(.footnote)
                .foregroundStyle(Theme.secondary)
            HStack(spacing: 8) {
                Button("Use the agent's screen") {
                    acting = true
                    Task {
                        await onScreen()
                        acting = false
                    }
                }
                .buttonStyle(.pill(.secondary))
                if !form.fields.isEmpty {
                    Button("Fill in…", action: onFill)
                        .buttonStyle(.pill(.primary))
                }
            }
            .controlSize(.small)
            .disabled(acting)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The form itself, as native fields. Only what the owner enters or picks is sent; a field saved
/// for the site may stay blank and the daemon fills it from the vault.
struct FormSheet: View {
    let agent: String
    let form: FormRequest
    let onFill: (FormFill) async throws -> Void
    let onScreen: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: [String: String] = [:]
    @State private var remember = false
    @State private var filling = false
    @State private var trouble: String?

    private var missing: Bool {
        form.fields.contains { $0.required && !$0.saved && (draft[$0.id] ?? "").isEmpty }
    }

    var body: some View {
        ThemedForm {
            Section {
                FormOrigin(form: form)
                Text(form.reason)
                    .foregroundStyle(Theme.secondary)
                if let trouble {
                    Label(trouble, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(Theme.failed)
                }
            } footer: {
                if !form.secure {
                    Text("This page isn't on HTTPS, so its secret fields go to the agent's screen.")
                }
            }
            Section {
                ForEach(form.fields) { field in
                    FieldRow(field: field, value: binding(field.id))
                }
            }
            Section {
                Toggle("Remember for this site", isOn: $remember)
            } footer: {
                Text("Saved values are offered for \(form.origin) next time; they are only typed when you press Fill.")
            }
            if !form.unfillable.isEmpty || trouble != nil {
                Section {
                    ForEach(Array(form.unfillable.enumerated()), id: \.offset) { _, field in
                        LabeledContent(field.label, value: field.why)
                    }
                    Button("Use the agent's screen", action: onScreen)
                } header: {
                    if !form.unfillable.isEmpty { Text("Do these on the agent's screen").formHeader() }
                }
            }
        }
        .sheetChrome(
            "Form for \(agent)",
            confirm: "Fill",
            confirmDisabled: missing || filling,
            cancel: { dismiss() },
            onConfirm: fill
        )
        .presentationBackground(Theme.ground)
        #if os(macOS)
        .frame(minWidth: 440, idealWidth: 480, minHeight: 420, idealHeight: 560)
        #endif
    }

    private func binding(_ id: String) -> Binding<String?> {
        Binding(get: { draft[id] }, set: { draft[id] = $0 })
    }

    private func fill() {
        filling = true
        trouble = nil
        Task {
            do {
                try await onFill(FormFill(fields: form.fields, draft: draft, remember: remember))
                dismiss()
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            filling = false
        }
    }
}

private struct FieldRow: View {
    let field: FormField
    @Binding var value: String?

    private var label: String { field.required ? "\(field.label) *" : field.label }
    private var prompt: String { field.saved ? "Saved for this site" : field.required ? "Required" : "" }

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            control
            if field.saved && field.isChoice {
                Text("Saved for this site; leave blank to use it.")
                    .font(.caption)
                    .foregroundStyle(Theme.secondary)
            }
        }
    }

    @ViewBuilder private var control: some View {
        let text = Binding(get: { value ?? "" }, set: { value = $0 })
        switch field.type {
        case "checkbox":
            Toggle(label, isOn: Binding(get: { value == "true" }, set: { value = $0 ? "true" : "false" }))
        case "select", "radio":
            ValueMenu(label, value: field.options?.first { $0.value == value }?.label ?? "Choose…", selection: $value) {
                Text("Choose…").tag(String?.none)
                ForEach(field.options ?? [], id: \.value) { option in
                    Text(option.label).tag(Optional(option.value))
                }
            }
        case "textarea":
            LabeledContent {
                TextField("", text: text, prompt: Text(prompt), axis: .vertical)
                    .lineLimit(3...8)
                    .accessibilityLabel(label)
            } label: {
                Text(label)
            }
        default:
            LabeledContent {
                Group {
                    if field.hidesTyping {
                        SecureField("", text: text, prompt: Text(prompt))
                    } else {
                        TextField("", text: text, prompt: Text(prompt))
                    }
                }
                .modifier(ContentType(content: field.content))
                .accessibilityLabel(label)
            } label: {
                Text(label)
            }
        }
    }
}

private struct ContentType: ViewModifier {
    let content: FieldContent

    func body(content view: Content) -> some View {
        #if os(iOS)
        view
            .textContentType(uiType)
            .keyboardType(keyboard)
            .textInputAutocapitalization(content == .plain ? .sentences : .never)
            .autocorrectionDisabled(content != .plain)
        #else
        view.textContentType(nsType)
        #endif
    }

    #if os(iOS)
    private var uiType: UITextContentType? {
        switch content {
        case .username: .username
        case .email: .emailAddress
        case .password: .password
        case .newPassword: .newPassword
        case .oneTimeCode: .oneTimeCode
        case .phone: .telephoneNumber
        case .url: .URL
        case .plain: nil
        }
    }

    private var keyboard: UIKeyboardType {
        switch content {
        case .email: .emailAddress
        case .phone: .phonePad
        case .url: .URL
        default: .default
        }
    }
    #else
    private var nsType: NSTextContentType? {
        switch content {
        case .username: .username
        case .email: .emailAddress
        case .password: .password
        case .newPassword: .newPassword
        case .oneTimeCode: .oneTimeCode
        case .phone: .telephoneNumber
        case .url: .URL
        case .plain: nil
        }
    }
    #endif
}
