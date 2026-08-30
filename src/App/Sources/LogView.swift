import SwiftUI
import UIKit

/// The log, on screen.
///
/// Not on any key: sending is meant to be a thing nobody has to think about,
/// and a permanent way in would say the opposite. It is behind five taps on the
/// name at the top of the everyday screen — findable when it is asked for, and
/// invisible until then.
struct LogView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var text = LogStore.shared.read()
    @State private var sharing = false
    @State private var clearing = false
    @State private var copied = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 14) {
                        Text("What this app did, in the order it did it. Sending happens in "
                            + "launches nobody sees, so it writes itself down here.")
                            .font(.system(size: 14))
                            .foregroundStyle(Palette.body)
                            .fixedSize(horizontal: false, vertical: true)

                        Text(text.isEmpty ? "Nothing written down yet." : text)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(Palette.ink)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .fixedSize(horizontal: false, vertical: true)
                            .padding(14)
                            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                            .overlay(
                                RoundedRectangle(cornerRadius: 3, style: .continuous)
                                    .strokeBorder(Palette.hairline, lineWidth: 1)
                            )
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)
                    .padding(.bottom, 18)
                }
                .scrollBounceBehavior(.basedOnSize)
                // It reads in the order things happened and opens at the end:
                // the beginning of the log can be days old, and what just went
                // wrong is what anybody opening it came for.
                .defaultScrollAnchor(.bottom)

                VStack(spacing: 6) {
                    Legend(measure, size: 9)
                    Button(copied ? "Copied" : "Copy the log") { copy() }
                        .buttonStyle(ProminentButton())
                        .disabled(text.isEmpty)
                    Button("Send the log") { sharing = true }
                        .buttonStyle(QuietButton())
                        .disabled(text.isEmpty)
                    Button("Start a fresh log") { clearing = true }
                        .buttonStyle(QuietButton())
                }
                .padding(.horizontal, 20)
                .padding(.top, 10)
                .padding(.bottom, 20)
            }
            .pageBackground()
            .navigationTitle("Log")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundStyle(Palette.accent)
                }
            }
            .sheet(isPresented: $sharing) {
                ShareSheet(text: text) { _ in sharing = false }
            }
            .alert("Start a fresh log?", isPresented: $clearing) {
                Button("Clear", role: .destructive) {
                    LogStore.shared.clear()
                    text = ""
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Everything written down so far is dropped. It says nothing about what "
                    + "is in the archive, so nothing is lost but the account of it.")
            }
        }
    }

    /// The whole log to the clipboard. The button says so for a couple of
    /// seconds afterwards: a copy that looks like nothing happened is a copy
    /// somebody does twice.
    private func copy() {
        UIPasteboard.general.string = text
        copied = true
        Task {
            try? await Task.sleep(for: .seconds(2))
            copied = false
        }
    }

    private var measure: String {
        let lines = text.isEmpty ? 0 : text.split(separator: "\n").count
        return "\(lines) lines"
    }
}
