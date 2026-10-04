import SwiftUI

/// An agent's standing jobs, which the reference calls Routines. The agent writes these too, so
/// the list is polled on a 5 s tick rather than trusted to stay as the owner left it.
struct RoutinesView: View {
    let session: Session
    let agent: Agent

    @State private var schedules: [Schedule]?
    @State private var cron = ""
    @State private var prompt = ""
    @State private var trouble: String?
    @Environment(\.pollPhase) private var pollPhase
    @State private var adding = false

    private var ready: Bool {
        !cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        ThemedForm {
            Section {
                if let schedules {
                    if schedules.isEmpty {
                        Text("Nothing scheduled.").foregroundStyle(Theme.muted)
                    }
                    ForEach(schedules) { schedule in
                        RoutineRow(schedule: schedule) { pause(schedule, $0) }
                            .swipeActions { deleteButton(schedule) }
                            .contextMenu {
                                Button(
                                    schedule.paused ? "Resume" : "Pause",
                                    systemImage: schedule.paused ? "play" : "pause"
                                ) { pause(schedule, !schedule.paused) }
                                deleteButton(schedule)
                            }
                    }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            } footer: {
                Text("Each one starts a turn in \(agent.title)'s thread with you, with its prompt, whether or not anyone is awake. Resuming counts the next run from now rather than making up the runs it missed.")
            }

            if agent.parentId == nil {
                TriggersSection(session: session, agent: agent)
            }

            Section {
                TextField("Cron", text: $cron, prompt: Text("0 7 * * 1-5"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                    .formLabel("Cron")
                if let words = cadence(cron) {
                    Text(words)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                TextField(
                    "Prompt",
                    text: $prompt,
                    prompt: Text("Written for a future \(agent.title) with none of this conversation in front of it"),
                    axis: .vertical
                )
                .lineLimit(2...6)
                Button(adding ? "Adding…" : "Add routine", systemImage: "plus", action: add)
                    .buttonStyle(.pill(.primary))
                    .disabled(adding || !ready)
                // Under the button rather than in a section of its own, which a phone draws below
                // the fold: a cron the daemon refuses is an expected path and this is its only answer.
                if let trouble {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(Theme.failed)
                }
            } header: {
                Text("New routine").formHeader()
            } footer: {
                Text("A cron is read on the daemon's clock. Next runs are shown on yours.")
            }
        }
        .task(id: PollKey(value: agent.name, phase: pollPhase)) {
            await session.poll(every: .seconds(5), pollPhase, failed: { session.note($0, in: &trouble) }) {
                schedules = try await session.run { try await $0.schedules(agent: agent.name) }
            }
        }
    }

    private func deleteButton(_ schedule: Schedule) -> some View {
        Button("Delete", systemImage: "trash", role: .destructive) { delete(schedule) }
    }

    private func add() {
        let cron = cron.trimmingCharacters(in: .whitespacesAndNewlines)
        let prompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !adding, !cron.isEmpty, !prompt.isEmpty else { return }
        adding = true
        Task {
            await change { client in
                let created = try await client.createSchedule(agent: agent.name, cron: cron, prompt: prompt)
                schedules = (schedules ?? []) + [created]
                self.cron = ""
                self.prompt = ""
            }
            adding = false
        }
    }

    private func pause(_ schedule: Schedule, _ paused: Bool) {
        Task {
            await change { client in
                let updated = try await client.pauseSchedule(agent: agent.name, id: schedule.id, paused: paused)
                schedules = schedules?.map { $0.id == updated.id ? updated : $0 }
            }
        }
    }

    private func delete(_ schedule: Schedule) {
        Task {
            await change { client in
                try await client.deleteSchedule(agent: agent.name, id: schedule.id)
                schedules?.removeAll { $0.id == schedule.id }
            }
        }
    }

    /// Each change applies the row the daemon answered with, so a switch does not flick back to
    /// where it was while a fresh list is fetched. The daemon's refusals — a cron with no next
    /// run, a twenty-first schedule — are written for a person and shown as they came.
    private func change(_ call: (SchermesClient) async throws -> Void) async {
        trouble = nil
        do {
            try await session.run(call)
        } catch {
            if !error.isCancellation { trouble = error.localizedDescription }
        }
    }
}

struct RoutineRow: View {
    let schedule: Schedule
    let onPause: (Bool) -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                if let words = cadence(schedule.cron) {
                    Text(words).font(.headline)
                    Text(schedule.cron)
                        .font(.caption.monospaced())
                        .foregroundStyle(Theme.muted)
                } else {
                    Text(schedule.cron).font(.headline.monospaced())
                }
                Text(schedule.prompt)
                    .font(.subheadline)
                    .lineLimit(3)
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            .opacity(schedule.paused ? 0.55 : 1)

            Spacer(minLength: 8)

            Toggle("Runs", isOn: Binding(get: { !schedule.paused }, set: { onPause(!$0) }))
                .labelsHidden()
                .toggleStyle(.switch)
        }
        .padding(.vertical, 2)
    }

    private var timing: String {
        let next = schedule.paused ? "Paused" : "Next " + moment(schedule.nextRunAt)
        return next + " · " + (schedule.lastRunAt.map { "last ran " + moment($0) } ?? "not run yet")
    }

    private func moment(_ millis: Int) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .abbreviated, time: .shortened)
    }
}

/// Main's "Routines and triggers": the agent's schedules and triggers as small cards that open the
/// routines page, and "Ask <agent> to set one up". The inspector shows it, and so does the settings page.
struct RoutinesSummary: View {
    let session: Session
    let agent: Agent
    /// What the cards sit in: white on the inspector's panel, the ground inside a white card.
    var cardFill: Token = Theme.card

    @Environment(AgentLooks.self) private var looks
    @Environment(\.colorScheme) private var scheme
    @State private var schedules: [Schedule]?
    @State private var triggers: [Trigger]?
    @State private var routinesOpen = false
    @State private var asking = false
    @State private var trouble: String?
    @Environment(\.pollPhase) private var pollPhase

    var body: some View {
        let palette = looks[agent.name].palette(dark: scheme == .dark)
        VStack(alignment: .leading, spacing: 8) {
            Text("Routines and triggers").font(.sectionTitle)
            if let schedules, let triggers {
                ForEach(schedules) { schedule in
                    routineCard(
                        symbol: "clock",
                        title: schedule.prompt,
                        detail: [cadence(schedule.cron) ?? schedule.cron, schedule.paused ? "paused" : "next at " + clock(schedule.nextRunAt)]
                            .joined(separator: " · "),
                        palette: palette
                    )
                }
                ForEach(triggers) { trigger in
                    routineCard(
                        symbol: trigger.kind.symbol,
                        title: trigger.reason,
                        detail: trigger.kindWord + " · " + state(trigger),
                        palette: palette
                    )
                }
                if schedules.isEmpty && triggers.isEmpty {
                    Text("Nothing scheduled and nothing watched.")
                        .font(.canvas(12, .caption))
                        .foregroundStyle(Theme.muted)
                }
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            Button(action: askForRoutine) {
                Label("Ask \(agent.title) to set one up", systemImage: "bolt")
                    .lineLimit(1)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.pill(.soft(looks[agent.name].color)))
            .disabled(asking)
            if let trouble {
                Text(trouble).font(.caption).foregroundStyle(Theme.failed)
            }
        }
        .task(id: PollKey(value: agent.name, phase: pollPhase)) {
            await session.poll(every: .seconds(5), pollPhase, failed: { session.note($0, in: &trouble) }) {
                schedules = try await session.run { try await $0.schedules(agent: agent.name) }
                triggers = try await session.run { try await $0.triggers(agent: agent.name) }
            }
        }
        .sheet(isPresented: $routinesOpen) {
            RoutinesAndActivity(session: session, agent: agent, page: .routines)
        }
    }

    private func routineCard(symbol: String, title: String, detail: String, palette: AgentPalette) -> some View {
        Button { routinesOpen = true } label: {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(palette.softText.color)
                    .frame(width: 30, height: 30)
                    .background(palette.soft.color, in: .rect(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 2) {
                    Text(title).font(.canvas(13, .footnote, weight: .semibold))
                    Text(detail).font(.canvas(12, .caption)).foregroundStyle(Theme.muted)
                }
                .lineLimit(1)
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(cardFill, in: .rect(cornerRadius: 14))
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .accessibilityHint("Opens routines and triggers")
    }

    private func state(_ trigger: Trigger) -> String {
        switch trigger.state {
        case .proposed: trigger.needsLogin ? "waiting for the login" : "proposed"
        case .on: "on"
        case .off: "off"
        case .unknown: "in a state this app does not know"
        }
    }

    private func clock(_ millis: Int) -> String {
        Date(timeIntervalSince1970: Double(millis) / 1000).formatted(date: .omitted, time: .shortened)
    }

    /// The same path as Profile's "Ask": a message in its thread, so the agent proposes the routine
    /// or trigger in the chat, where the owner switches it on.
    private func askForRoutine() {
        guard !asking else { return }
        asking = true
        trouble = nil
        Task {
            do {
                _ = try await session.run {
                    try await $0.send(.agent(agent.name), text: "Is there a routine or a trigger that would help with what you do for me? Propose one I can switch on.")
                }
            } catch {
                if !error.isCancellation { trouble = error.localizedDescription }
            }
            asking = false
        }
    }
}
