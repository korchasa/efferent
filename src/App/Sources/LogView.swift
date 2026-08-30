import SwiftUI

/// The log, on screen.
///
/// Not on any key: sending is meant to be a thing nobody has to think about,
/// and a permanent way in would say the opposite. It is behind five taps on the
/// name at the top of the everyday screen — findable when it is asked for, and
/// invisible until then.
struct LogView: View {
    @Environment(\.dismiss) private var dismiss

    /// The end of the log, not the whole of it. Sharing still hands over the
    /// whole file — see ``LogStore/tail(_:)``.
    @State private var excerpt = LogStore.shared.tail()
    @State private var sharing = false
    @State private var clearing = false

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

                        if excerpt.hidden > 0 {
                            Text("Showing the last \(excerpt.text.split(separator: "\n").count) lines. "
                                + "The \(excerpt.hidden) before them are in the file that Send hands over.")
                                .font(.system(size: 12))
                                .foregroundStyle(Palette.body)
                                .fixedSize(horizontal: false, vertical: true)
                        }

                        Text(excerpt.text.isEmpty ? "Nothing written down yet." : excerpt.text)
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
                    Button("Send the log") { sharing = true }
                        .buttonStyle(ProminentButton())
                        .disabled(excerpt.text.isEmpty)
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
                ShareSheet(text: LogStore.shared.read()) { _ in sharing = false }
            }
            .alert("Start a fresh log?", isPresented: $clearing) {
                Button("Clear", role: .destructive) {
                    LogStore.shared.clear()
                    excerpt = LogStore.Excerpt(text: "", hidden: 0)
                }
                Button("Keep", role: .cancel) {}
            } message: {
                Text("Everything written down so far is dropped. It says nothing about what "
                    + "is in the archive, so nothing is lost but the account of it.")
            }
        }
    }

    /// The whole file's size, not the excerpt's: it is the whole file that
    /// gets sent, and a count that shrank when the screen started showing less
    /// would read as lost lines.
    private var measure: String {
        let shown = excerpt.text.isEmpty ? 0 : excerpt.text.split(separator: "\n").count
        return "\(shown + excerpt.hidden) lines"
    }
}
