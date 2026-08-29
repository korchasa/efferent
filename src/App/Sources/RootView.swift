import SwiftUI

/// Which of the two screens the app is on.
///
/// There are only two, and the answer is a fact about the phone rather than a
/// place it navigated to: an archive has been made and the walkthrough finished,
/// or it has not. Restoring that on launch is what stops a person being dropped
/// halfway into a setup they abandoned, or shown the walkthrough again after an
/// update.
struct RootView: View {
    @EnvironmentObject private var services: Services

    var body: some View {
        Group {
            if services.setupComplete {
                HomeView()
            } else {
                SetupView()
            }
        }
        // The palette is committed rather than adaptive, so the appearance is
        // pinned instead of half-supported. Left to the system, dark mode turns
        // the text white and leaves it on a light background — words nobody can
        // read, which is exactly how a consent screen shipped blank once.
        .preferredColorScheme(.light)
        .animation(.easeInOut(duration: 0.3), value: services.setupComplete)
    }
}
