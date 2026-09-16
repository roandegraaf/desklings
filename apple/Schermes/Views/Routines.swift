import SwiftUI

/// An agent's standing jobs, which the reference calls Routines. The agent writes these too, so
/// the list is polled on the web UI's 5 s tick rather than trusted to stay as the owner left it.
struct RoutinesView: View {
    let session: Session
    let agent: Agent

    @State private var schedules: [Schedule]?
    @State private var cron = ""
    @State private var prompt = ""
    @State private var trouble: String?
    @State private var adding = false

    private var ready: Bool {
        !cron.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    var body: some View {
        Form {
            Section {
                if let schedules {
                    if schedules.isEmpty {
                        Text("Nothing scheduled.").foregroundStyle(.secondary)
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

            Section {
                TextField("Cron", text: $cron, prompt: Text("0 7 * * 1-5"))
                    .font(.body.monospaced())
                    .autocorrectionDisabled()
                    #if os(iOS)
                    .textInputAutocapitalization(.never)
                    .keyboardType(.numbersAndPunctuation)
                    #endif
                if let words = cadence(cron) {
                    Text(words)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                TextField(
                    "Prompt",
                    text: $prompt,
                    prompt: Text("Written for a future \(agent.title) with none of this conversation in front of it"),
                    axis: .vertical
                )
                .lineLimit(2...6)
                Button(adding ? "Adding…" : "Add routine", action: add)
                    .disabled(adding || !ready)
                // Under the button rather than in a section of its own, which a phone draws below
                // the fold: a cron the daemon refuses is an expected path and this is its only answer.
                if let trouble {
                    Text(trouble)
                        .font(.footnote)
                        .foregroundStyle(.red)
                }
            } header: {
                Text("New routine")
            } footer: {
                Text("A cron is read on the daemon's clock. Next runs are shown on yours.")
            }
        }
        .formStyle(.grouped)
        .task(id: agent.name) {
            while !Task.isCancelled {
                if let rows = try? await session.run({ try await $0.schedules(agent: agent.name) }) {
                    schedules = rows
                }
                try? await Task.sleep(for: .seconds(5))
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
                        .foregroundStyle(.secondary)
                } else {
                    Text(schedule.cron).font(.headline.monospaced())
                }
                Text(schedule.prompt)
                    .font(.subheadline)
                    .lineLimit(3)
                Text(timing)
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
