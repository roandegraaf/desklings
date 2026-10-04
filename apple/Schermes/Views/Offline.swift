import SwiftUI

/// The top of the console and the chat: the daemon out of reach, with Retry now, or else an
/// action that failed on this screen until the owner dismisses it.
struct TroubleBanner: View {
    let session: Session
    var failure: Binding<String?>? = nil
    /// Why the last refresh failed, below the other two: it clears itself when one works.
    var stale: String? = nil

    var body: some View {
        Group {
            if case .unreachable(let since, let message) = session.reachability {
                card(
                    symbol: "wifi.exclamationmark",
                    title: "Can't reach the daemon",
                    detail: "\(sentence(message)) Since \(since.formatted(date: .omitted, time: .shortened))."
                ) {
                    Button("Retry now") { session.retryNow() }
                        .buttonStyle(.pill(.secondary))
                        .controlSize(.small)
                }
            } else if let failure, let text = failure.wrappedValue {
                card(symbol: "exclamationmark.triangle.fill", title: text, detail: nil) {
                    Button("Dismiss", systemImage: "xmark") { failure.wrappedValue = nil }
                        .labelStyle(.iconOnly)
                        .buttonStyle(.plain)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(Theme.secondary)
                }
            } else if let stale {
                card(symbol: "arrow.triangle.2.circlepath", title: "Could not refresh", detail: stale) {
                    EmptyView()
                }
            }
        }
        .animation(.snappy, value: session.reachability)
    }

    /// URLError's own words end in a full stop and the daemon's don't.
    private func sentence(_ text: String) -> String {
        text.hasSuffix(".") ? text : text + "."
    }

    private func card(symbol: String, title: String, detail: String?, @ViewBuilder action: () -> some View) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .foregroundStyle(Theme.failed)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                if let detail {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Theme.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            action()
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Theme.failed.opacity(0.1), in: .rect(cornerRadius: 14))
        .overlay { RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.failed.opacity(0.35)) }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .contain)
    }
}
