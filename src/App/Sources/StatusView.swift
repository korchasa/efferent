import SwiftUI

/// What the person sees.
///
/// One question matters more than everything else on this screen — is it still
/// working — so it is answered first, in a sentence, before any number. The
/// counters are underneath for when the answer is not the expected one.
///
/// There is deliberately no permission state anywhere. HealthKit never tells an
/// app whether read access was granted, on purpose, so an app cannot work out
/// what is being hidden from it. A "no access" indicator here could only ever be
/// a guess, and a confident wrong one. The honest substitute is the count of
/// days sent: if it stays at zero, access is the thing to check.
struct StatusView: View {
    @EnvironmentObject private var services: Services
    @State private var confirmingDisconnect = false
    @State private var working = false

    var body: some View {
        NavigationStack {
            Group {
                if services.destination == nil {
                    unpaired
                } else {
                    paired
                }
            }
            .navigationTitle("Efferent")
            .alert("Disconnect?", isPresented: $confirmingDisconnect) {
                Button("Disconnect", role: .destructive) { services.disconnect() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(
                    "This phone forgets its signing and reading keys. It can never write to this "
                        + "archive again, and the archive can be read only if its connection was "
                        + "already saved on another machine."
                )
            }
            // Counters move on the upload session's own queue while this screen
            // is open, most visibly during the first export. Cancelled with the
            // view, so it costs nothing when nobody is looking.
            .task {
                while !Task.isCancelled {
                    services.refreshStats()
                    try? await Task.sleep(for: .seconds(2))
                }
            }
        }
    }

    // MARK: - Before there is anywhere to send

    private var unpaired: some View {
        List {
            Section {
                ContentUnavailableView {
                    Label("No archive yet", systemImage: "lock.doc")
                } description: {
                    Text(
                        "This phone creates its encrypted archive first. You can connect an agent "
                            + "afterwards, without waiting for the agent to know anything about Efferent."
                    )
                } actions: {
                    Button {
                        run { await services.createArchive() }
                    } label: {
                        if working {
                            ProgressView()
                        } else {
                            Text("Create encrypted archive")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(working || services.deployment == nil)
                }
                .listRowBackground(Color.clear)
            }
            if let deploymentError = services.deploymentError {
                Section("Configuration") {
                    Label(deploymentError, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                }
            }
        }
    }

    // MARK: - The everyday screen

    private var paired: some View {
        List {
            Section { headline }
            daysSection
            actionsSection
            historySection
            readerSection
        }
    }

    private var headline: some View {
        let state = Health(stats: services.stats, problem: services.lastError)
        return HStack(alignment: .firstTextBaseline, spacing: 12) {
            Image(systemName: state.symbol)
                .font(.title2)
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(state.tint)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title).font(.headline)
                state.detail
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private var daysSection: some View {
        Section("Days") {
            LabeledContent("On your server") {
                Text(services.stats?.sentDays ?? 0, format: .number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Waiting") {
                Text(services.stats?.pendingDays ?? 0, format: .number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let sent = services.stats?.lastUploadAt {
                LabeledContent("Last sent") {
                    Text(sent, style: .relative).monospacedDigit()
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                run {
                    await services.refreshNow()
                    await services.sendNow()
                }
            } label: {
                LabeledContent("Re-read and send now") {
                    if working {
                        ProgressView()
                    }
                }
            }
            .disabled(working)

            Button("Allow access to Health") {
                run { await services.requestHealthAccess() }
            }
            .disabled(working)
        } footer: {
            Text(
                "New readings go out on their own, usually within an hour — that is as often as iOS "
                    + "wakes the app. If nothing is ever sent, Health access is the thing to check: "
                    + "iOS does not tell the app what it was granted."
            )
        }
    }

    private var historySection: some View {
        Section {
            Button("Export everything Health has") {
                run { await services.exportEverything() }
            }
            .disabled(working)
            if let reached = services.stats?.backfillReached {
                LabeledContent("Back to", value: reached)
            }
        } header: {
            Text("History")
        } footer: {
            Text(
                "Takes a moment to work out how far Health goes back, then sends a day at a time in "
                    + "the background. Safe to leave: a day is either sent or still waiting."
            )
        }
    }

    @ViewBuilder private var readerSection: some View {
        if let destination = services.destination {
            Section("Archive") {
                LabeledContent("Host", value: destination.endpoint.host() ?? "—")
                // The first characters are enough to tell two buckets apart at a
                // glance; the whole name is not something to leave on a screen.
                LabeledContent("Bucket", value: String(destination.bucket.prefix(8)) + "…")
                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
            }
            if let handoff = services.connectionHandoff {
                Section {
                    ShareLink(item: handoff.text) {
                        Label("Connect an agent", systemImage: "square.and.arrow.up")
                    }
                } footer: {
                    Text(
                        "The shared text contains the reading key. The agent must store it locally "
                            + "and must never send it to Cloudflare or another remote tool."
                    )
                }
            } else {
                Section("Legacy connection") {
                    Text(
                        "This archive was connected by the older reader-first flow. It keeps "
                            + "working, but this phone does not hold its reading key and cannot share it."
                    )
                    .foregroundStyle(.secondary)
                }
            }
        }
    }

    private func run(_ work: @escaping () async -> Void) {
        working = true
        Task {
            await work()
            working = false
        }
    }
}

// MARK: - The one sentence at the top

/// How the app is doing, in the terms a person would use.
///
/// Kept apart from the view so the wording is one thing to read and change, and
/// so the distinction that matters is explicit: "nothing waiting" means the
/// opposite of the same phrase before anything has ever been sent.
private struct Health {
    let symbol: String
    let tint: Color
    let title: String
    let detail: Text

    init(stats: Stats?, problem: String?) {
        if let problem {
            symbol = "exclamationmark.triangle.fill"
            tint = .orange
            title = "Something stopped it"
            detail = Text(problem)
            return
        }
        guard let stats else {
            symbol = "ellipsis.circle"
            tint = .secondary
            title = "Looking"
            detail = Text("Counting the days.")
            return
        }
        if stats.pendingDays > 0 {
            symbol = "arrow.up.circle.fill"
            tint = .blue
            title = "Sending"
            detail = Text("\(stats.pendingDays, format: .number) days still to go.")
            return
        }
        if stats.sentDays == 0 {
            symbol = "circle.dashed"
            tint = .secondary
            title = "Nothing sent yet"
            detail = Text("Allow access to Health, then re-read once to get started.")
            return
        }
        symbol = "checkmark.circle.fill"
        tint = .green
        title = "Up to date"
        detail = Text("Everything Health has offered is on your server.")
    }
}
