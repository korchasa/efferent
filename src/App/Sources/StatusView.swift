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
    @State private var endpointText = ""
    @State private var tokenText = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Destination") {
                    TextField("https://…", text: $endpointText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    SecureField("Token", text: $tokenText)
                    Button("Save") { save() }
                        .disabled(endpointText.isEmpty)
                }

                Section("Outbox") {
                    LabeledContent("Waiting", value: services.stats.map { String($0.pending) } ?? "—")
                    LabeledContent("Kept for comparison", value: services.stats.map { String($0.retained) } ?? "—")
                    LabeledContent("Confirmed through", value: services.stats.map { String($0.acknowledgedSeq) } ?? "—")
                }

                Section("Health") {
                    Button("Allow access to Health") {
                        Task { await services.requestHealthAccess() }
                    }
                    Button("Collect and send now") {
                        Task {
                            await services.collectNow()
                            await services.sendNow()
                        }
                    }
                }

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

                if let error = services.lastError {
                    Section("Last problem") {
                        Text(error).font(.footnote).foregroundStyle(.secondary)
                    }
                }
            }
            .navigationTitle("Efferent")
        }
        .onAppear {
            endpointText = services.endpoint?.absoluteString ?? ""
            services.refreshStats()
        }
    }

    private func save() {
        guard let url = URL(string: endpointText), url.scheme == "https" else {
            services.setError("The endpoint must be an https URL.")
            return
        }
        services.endpoint = url
        if !tokenText.isEmpty {
            services.storeToken(tokenText)
            tokenText = ""
        }
    }
}
