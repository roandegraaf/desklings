import ActivityKit
import SwiftUI
import WidgetKit

@main
struct SchermesWidgets: WidgetBundle {
    var body: some Widget {
        AgentActivityWidget()
    }
}

struct AgentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: AgentActivityAttributes.self) { context in
            LockScreenActivity(attributes: context.attributes, state: context.state)
                .activityBackgroundTint(Color.black.opacity(0.55))
                .activitySystemActionForegroundColor(context.attributes.identity.color.rgb.swiftUI)
        } dynamicIsland: { context in
            let colour = context.attributes.identity.color.rgb.swiftUI
            let state = context.state
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label {
                        Text(context.attributes.label).lineLimit(1)
                    } icon: {
                        Circle().fill(colour).frame(width: 14, height: 14)
                    }
                    .font(.headline)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    StateWord(state: state, colour: colour)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    ActivityDetail(state: state, colour: colour)
                }
            } compactLeading: {
                Circle().fill(colour).frame(width: 12, height: 12)
            } compactTrailing: {
                if state.needsYou > 0 {
                    Image(systemName: "hand.raised.fill").foregroundStyle(.orange)
                } else if state.stepsTotal > 0 {
                    Text("\(state.stepsDone)/\(state.stepsTotal)").monospacedDigit().foregroundStyle(colour)
                } else {
                    Image(systemName: ActivityStateWord(state.state).symbol).foregroundStyle(colour)
                }
            } minimal: {
                Image(systemName: state.needsYou > 0 ? "hand.raised.fill" : ActivityStateWord(state.state).symbol)
                    .foregroundStyle(state.needsYou > 0 ? .orange : colour)
            }
            .keylineTint(colour)
        }
    }
}

/// The app's `AgentState.presentation`, repeated here because the extension does not compile
/// the app's views; an unknown state still gets a word.
struct ActivityStateWord {
    let symbol: String
    let word: String

    init(_ state: String) {
        (symbol, word) = switch state {
        case "idle": ("moon.zzz", "Idle")
        case "thinking": ("ellipsis.bubble", "Thinking")
        case "using_computer": ("cursorarrow.rays", "Using the computer")
        case "using_terminal": ("terminal", "Using the terminal")
        case "waiting_for_user": ("bubble.left", "Ready")
        case "waiting_for_agent": ("hourglass", "Waiting for an agent")
        case "waiting_for_task_worker": ("hourglass", "Waiting for a task worker")
        case "failed": ("exclamationmark.triangle", "Failed")
        case "completed": ("checkmark.circle", "Done")
        default: ("circle.dotted", state)
        }
    }
}

struct StateWord: View {
    let state: AgentActivityAttributes.ContentState
    let colour: Color

    var body: some View {
        let presentation = ActivityStateWord(state.state)
        HStack(spacing: 4) {
            Image(systemName: presentation.symbol)
            Text(presentation.word).lineLimit(1)
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(colour)
    }
}

struct ActivityDetail: View {
    let state: AgentActivityAttributes.ContentState
    let colour: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.title.isEmpty {
                Text(state.title).font(.subheadline).lineLimit(2)
            }
            if state.stepsTotal > 0 {
                ProgressView(value: Double(state.stepsDone), total: Double(state.stepsTotal)) {
                    Text("\(state.stepsDone) of \(state.stepsTotal) steps").font(.caption)
                }
                .tint(colour)
            }
            if state.needsYou > 0 {
                Label(state.needsYou == 1 ? "Needs you" : "Needs you (\(state.needsYou))", systemImage: "hand.raised.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct LockScreenActivity: View {
    let attributes: AgentActivityAttributes
    let state: AgentActivityAttributes.ContentState

    var body: some View {
        let colour = attributes.identity.color.rgb.swiftUI
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Circle().fill(colour).frame(width: 18, height: 18)
                Text(attributes.label).font(.headline).lineLimit(1)
                Spacer()
                StateWord(state: state, colour: colour)
            }
            ActivityDetail(state: state, colour: colour)
        }
        .padding()
        .foregroundStyle(.white)
    }
}

extension BloubRGB {
    var swiftUI: Color { Color(red: r, green: g, blue: b) }
}

#Preview("Lock screen", as: .content, using: AgentActivityAttributes(agent: "alpha", label: "Alpha", look: "cloud:teal")) {
    AgentActivityWidget()
} contentStates: {
    AgentActivityAttributes.ContentState(title: "Ship the site", stepsDone: 1, stepsTotal: 3, needsYou: 0, state: "thinking")
    AgentActivityAttributes.ContentState(title: "Ship the site", stepsDone: 2, stepsTotal: 3, needsYou: 1, state: "waiting_for_user")
}
