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
/// readings sent: if it stays at zero, access is the thing to check.
struct StatusView: View {
    @EnvironmentObject private var services: Services
    @State private var scanning = false
    @State private var confirmingDisconnect = false
    @State private var working = false
    #if DEBUG
        @State private var typedCode = ""
    #endif

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
            .sheet(isPresented: $scanning) { scanner }
            .alert("Disconnect?", isPresented: $confirmingDisconnect) {
                Button("Disconnect", role: .destructive) { services.disconnect() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(
                    "This phone forgets its signing key, so it can never write to that bucket again. "
                        + "Data already sent stays where it is."
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
                    Label("No reader yet", systemImage: "qrcode.viewfinder")
                } description: {
                    Text(
                        "Your reader shows a code holding its address and its public key. "
                            + "Nothing secret travels this way — the key that decrypts never leaves it."
                    )
                } actions: {
                    Button("Scan the pairing code") { scanning = true }
                        .buttonStyle(.borderedProminent)
                }
                .listRowBackground(Color.clear)
            }
            typedCodeSection
        }
    }

    private var scanner: some View {
        NavigationStack {
            ScannerView { code in
                scanning = false
                services.pair(withScannedCode: code)
            }
            .ignoresSafeArea()
            .navigationTitle("Scan the code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { scanning = false }
                }
            }
        }
    }

    /// The way in when there is no camera.
    ///
    /// The simulator has none, so scanning — the only way to pair — cannot be
    /// reached there, and neither can any screen behind it. This takes the same
    /// string the code carries and goes through the same `pair` path, so what it
    /// exercises is the real one. Debug builds only: a shipped app that accepts
    /// a pasted destination is a shipped app someone can be talked into pasting
    /// into.
    @ViewBuilder private var typedCodeSection: some View {
        #if DEBUG
            Section {
                TextField("{\"v\":1,\"url\":…,\"pk\":…}", text: $typedCode, axis: .vertical)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .font(.footnote.monospaced())
                Button("Pair with this code") {
                    services.pair(withScannedCode: typedCode.trimmingCharacters(in: .whitespacesAndNewlines))
                    typedCode = ""
                }
                .disabled(typedCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            } header: {
                Text("Debug")
            } footer: {
                Text("Paste what the code holds. Debug builds only — this is not in what ships.")
            }
        #endif
    }

    // MARK: - The everyday screen

    private var paired: some View {
        List {
            Section { headline }
            readingsSection
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

    private var readingsSection: some View {
        Section("Readings") {
            LabeledContent("Sent") {
                Text(Int(services.stats?.acknowledgedSeq ?? 0), format: .number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            LabeledContent("Waiting") {
                Text(services.stats?.pending ?? 0, format: .number)
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
            if let confirmed = services.stats?.acknowledgedAt {
                LabeledContent("Last sent") {
                    Text(confirmed, style: .relative).monospacedDigit()
                }
            }
        }
    }

    private var actionsSection: some View {
        Section {
            Button {
                run {
                    await services.collectNow()
                    await services.sendNow()
                }
            } label: {
                LabeledContent("Collect and send now") {
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
                run { await services.runFirstExport() }
            }
            .disabled(working)
            if let backfill = services.backfill {
                LabeledContent("Progress") {
                    Text(backfill).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("History")
        } footer: {
            Text("Walks back a month at a time. Keep this screen open; it continues where it stopped.")
        }
    }

    @ViewBuilder private var readerSection: some View {
        if let destination = services.destination {
            Section("Reader") {
                LabeledContent("Host", value: destination.endpoint.host() ?? "—")
                // The first characters are enough to tell two buckets apart at a
                // glance; the whole name is not something to leave on a screen.
                LabeledContent("Bucket", value: String(destination.bucket.prefix(8)) + "…")
                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
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
            detail = Text("Reading the outbox.")
            return
        }
        if stats.pending > 0 {
            symbol = "arrow.up.circle.fill"
            tint = .blue
            title = "Sending"
            detail = Text("\(stats.pending, format: .number) readings still to go.")
            return
        }
        if stats.acknowledgedSeq == 0 {
            symbol = "circle.dashed"
            tint = .secondary
            title = "Nothing sent yet"
            detail = Text("Allow access to Health, then collect once to get started.")
            return
        }
        symbol = "checkmark.circle.fill"
        tint = .green
        title = "Up to date"
        detail = Text("Everything Health has offered is on your server.")
    }
}
