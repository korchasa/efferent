import SwiftUI

/// What the person sees: where data goes, how much is waiting, and a way to
/// push it now.
///
/// It shows counters rather than a permissions state on purpose. HealthKit
/// never tells an app whether read access was granted — that is deliberate, so
/// an app cannot work out what is being hidden from it — so "waiting: 0" is the
/// honest answer to both "no access" and "nothing new".
struct StatusView: View {
    @EnvironmentObject private var services: Services
    @State private var scanning = false
    @State private var confirmingDisconnect = false
    #if DEBUG
        @State private var typedCode = ""
    #endif

    var body: some View {
        NavigationStack {
            Form {
                destinationSection

                if services.destination != nil {
                    outboxSection
                    healthSection
                    firstExportSection
                }

                if let error = services.lastError {
                    Section("Last problem") {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Efferent")
            .sheet(isPresented: $scanning) {
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
            .alert("Disconnect?", isPresented: $confirmingDisconnect) {
                Button("Disconnect", role: .destructive) { services.disconnect() }
                Button("Keep", role: .cancel) {}
            } message: {
                Text(
                    "This phone forgets its signing key, so it can never write to that bucket again. "
                        + "Data already sent stays where it is."
                )
            }
            .onAppear { services.refreshStats() }
        }
    }

    @ViewBuilder private var destinationSection: some View {
        if let destination = services.destination {
            Section("Sending to") {
                LabeledContent("Host", value: destination.endpoint.host() ?? "—")
                // The first characters are enough to tell two buckets apart at a
                // glance; the whole name is not something to leave on a screen.
                LabeledContent("Bucket", value: String(destination.bucket.prefix(8)) + "…")
                Button("Disconnect", role: .destructive) { confirmingDisconnect = true }
            }
        } else {
            Section {
                Button("Scan the pairing code") { scanning = true }
            } footer: {
                Text(
                    "Your reader shows a code holding its address and its public key. "
                        + "Nothing secret travels this way — the key that decrypts never leaves the reader."
                )
            }
            typedCodeSection
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

    private var outboxSection: some View {
        Section("Outbox") {
            LabeledContent("Waiting", value: services.stats.map { String($0.pending) } ?? "—")
            LabeledContent("Confirmed through", value: services.stats.map { String($0.acknowledgedSeq) } ?? "—")
        }
    }

    private var healthSection: some View {
        Section {
            Button("Allow access to Health") {
                Task { await services.requestHealthAccess() }
            }
            Button("Collect and send now") {
                Task {
                    await services.collectNow()
                    await services.sendNow()
                }
            }
        } header: {
            Text("Health")
        } footer: {
            Text("New readings usually go out within an hour — that is as often as iOS wakes the app.")
        }
    }

    private var firstExportSection: some View {
        Section {
            Button("Export the full history") {
                Task { await services.runFirstExport() }
            }
            if let backfill = services.backfill {
                Text(backfill).font(.footnote).foregroundStyle(.secondary)
            }
        } footer: {
            Text("Walks back a month at a time. Leave this screen open; it continues where it stopped.")
        }
    }
}
