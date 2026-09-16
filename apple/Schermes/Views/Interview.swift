import SwiftUI

/// An owner message that answered an `ask_owner` form, drawn as the questions and answers it
/// carries rather than the lines it was sent as.
struct InterviewAnswers: View {
    let answers: [InterviewAnswer]

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Array(answers.enumerated()), id: \.offset) { index, answer in
                VStack(alignment: .leading, spacing: 3) {
                    if let header = answer.header {
                        Text(header.uppercased())
                            .font(.caption2.weight(.semibold))
                            .opacity(0.7)
                    }
                    Text(answer.question)
                        .font(.footnote)
                        .opacity(0.8)
                    if let text = answer.answer {
                        Text(text)
                            .font(.body.weight(.medium))
                            .textSelection(.enabled)
                    } else {
                        Text("Skipped")
                            .font(.callout.italic())
                            .opacity(0.6)
                    }
                }
                if index < answers.count - 1 {
                    Divider().opacity(0.4)
                }
            }
        }
    }
}

/// The form an `ask_owner` call becomes, above the composer until it is answered. One question at
/// a time, because the composer's inset does not scroll and four questions with options fill a
/// window. Each takes a pick from its options, a typed answer, or both; the last step sends the
/// lot as a single owner message, which is what the agent is waiting on.
struct InterviewCard: View {
    let interview: Interview
    let agent: String
    let onAnswer: (String) async -> Void

    @State private var step = 0
    @State private var picked: [Int: Set<Int>] = [:]
    @State private var typed: [Int: String] = [:]
    @State private var sending = false

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var last: Bool { step == interview.questions.count - 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("\(agent) asks")
                Spacer()
                if interview.questions.count > 1 {
                    Text("\(step + 1) of \(interview.questions.count)").monospacedDigit()
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            if step == 0, !interview.intro.isEmpty {
                MarkdownText(content: interview.intro)
            }

            question(step, interview.questions[step])
                .id(step)
                .transition(.opacity)

            HStack(spacing: 8) {
                if step > 0 {
                    Button("Back") { move(-1) }
                        .buttonStyle(.bordered)
                }
                Spacer()
                if last {
                    Button(sending ? "Sending…" : "Answer", action: answer)
                        .buttonStyle(.borderedProminent)
                        .disabled(sending || !anyAnswer)
                } else if answered(step) {
                    Button("Next") { move(1) }
                        .buttonStyle(.borderedProminent)
                } else {
                    Button("Skip") { move(1) }
                        .buttonStyle(.bordered)
                }
            }
            .controlSize(.small)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: .rect(cornerRadius: 16))
    }

    private func question(_ index: Int, _ question: InterviewQuestion) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            if let header = question.header {
                Text(header.uppercased())
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.tint)
            }
            Text(question.question)
                .font(.callout.weight(.medium))
            ForEach(Array((question.options ?? []).enumerated()), id: \.offset) { slot, option in
                optionRow(index, slot, option, multiple: question.multiple == true)
            }
            TextField(
                (question.options ?? []).isEmpty ? "Your answer" : "Or something else",
                text: Binding(get: { typed[index] ?? "" }, set: { typed[index] = $0 }),
                axis: .vertical
            )
            .textFieldStyle(.plain)
            .lineLimit(1...4)
            .font(.callout)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.quaternary, in: .rect(cornerRadius: 8))
            .onSubmit { if last { answer() } else { move(1) } }
        }
    }

    private func move(_ by: Int) {
        withAnimation(reduceMotion ? nil : .snappy) {
            step = min(max(step + by, 0), interview.questions.count - 1)
        }
    }

    private func answered(_ index: Int) -> Bool {
        !(picked[index] ?? []).isEmpty || !(typed[index] ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var anyAnswer: Bool {
        interview.questions.indices.contains(where: answered)
    }

    private func optionRow(_ index: Int, _ slot: Int, _ option: InterviewOption, multiple: Bool) -> some View {
        let chosen = picked[index]?.contains(slot) == true
        return Button {
            var set = multiple ? (picked[index] ?? []) : []
            if chosen { set.remove(slot) } else { set.insert(slot) }
            picked[index] = set
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: chosen
                      ? (multiple ? "checkmark.square.fill" : "checkmark.circle.fill")
                      : (multiple ? "square" : "circle"))
                    .foregroundStyle(chosen ? AnyShapeStyle(.tint) : AnyShapeStyle(.secondary))
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.label).font(.callout)
                    if let description = option.description {
                        Text(description)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 0)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(chosen ? .isSelected : [])
    }

    private func answer() {
        guard !sending else { return }
        sending = true
        let answers = interview.questions.enumerated().map { index, question in
            let labels = (picked[index] ?? []).sorted().compactMap { question.options?[$0].label }
            let own = (typed[index] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            return (labels + (own.isEmpty ? [] : [own])).joined(separator: "; ")
        }
        let reply = interviewReply(interview.questions, answers: answers)
        Task {
            await onAnswer(reply)
            sending = false
        }
    }
}
