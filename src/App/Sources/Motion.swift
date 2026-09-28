import SwiftUI

/// The one place a movement is decided, as `Palette` is for a colour.
///
/// Every animation on the shell is one of these springs, called by name, so two
/// screens that make the same kind of change move the same way. A spring rather
/// than a curve because a spring can be interrupted: a second tap mid-change
/// retargets it from where it is on screen, where a curve either finishes or
/// jumps. Two knobs each, the length it feels and how far it overshoots, and
/// nothing on this instrument overshoots — nothing here is thrown.
enum Motion {
    /// Layout that moves, a panel arriving, a step changing, a figure turning
    /// into another figure. The default; start here.
    static let standard = Animation.spring(duration: 0.35, bounce: 0)
    /// A key going down under the finger, a lamp lighting on a row.
    static let snappy = Animation.spring(duration: 0.2, bounce: 0)
    /// The whole screen changing, and the scale catching up with a run.
    static let smoothLong = Animation.spring(duration: 0.5, bounce: 0)
    /// The standard change with Reduce Motion on: a cross-fade of the same
    /// length, so something still visibly changes without anything travelling.
    static let fade = Animation.easeInOut(duration: 0.35)

    /// How far a key sinks while it is held. Small, because it confirms a
    /// press and must not read as the key going somewhere.
    static let pressedScale: CGFloat = 0.97

    /// One turn of the lit arc while the scale waits on something it cannot
    /// measure — the archive being made, Health being read. The only looping
    /// movement in the app, and it stops the moment there is a figure to show.
    /// Slow enough to read as an instrument working, not as a spinner hurrying:
    /// at 1.6 s a turn the arc looked anxious.
    static let sweepPeriod: TimeInterval = 2.4
    /// How many marks the sweeping arc's tail fades over: a fifth of the dial.
    static let sweepTail = 12

    /// How far a panel or a sentence drops as it arrives. Short on purpose: it
    /// only has to say "this came from above", and a longer fall would cross
    /// the controls over it.
    static let arrivalDrop: CGFloat = 8

    /// The standard change, or its cross-fade when motion is reduced.
    static func standard(reduced: Bool) -> Animation {
        reduced ? fade : standard
    }
}

extension AnyTransition {
    /// A step of the walkthrough arriving or leaving. Forward comes in from the
    /// trailing edge and leaves by the leading one, and going back runs the
    /// same path the other way, so the order of the steps is something a person
    /// can feel. With Reduce Motion on it is a cross-fade.
    static func step(forward: Bool, reduced: Bool) -> AnyTransition {
        guard !reduced else { return .opacity }
        return .asymmetric(
            insertion: .move(edge: forward ? .trailing : .leading).combined(with: .opacity),
            removal: .move(edge: forward ? .leading : .trailing).combined(with: .opacity)
        )
    }

    /// Something that joins the shell from just above and leaves the same way:
    /// the strip about an agent's edits, the calendar under its row, a sentence
    /// under a control. A short drop from the control it belongs to, not a
    /// move by its own height — that slid the calendar down over the three
    /// rows above it.
    static func arriving(reduced: Bool) -> AnyTransition {
        reduced ? .opacity : .offset(y: -Motion.arrivalDrop).combined(with: .opacity)
    }

    /// One face of the dial giving way to another. The new face settles in
    /// with a small scale; the old one only fades, and faster, so the two
    /// never stand legibly on top of each other — with a symmetric cross-fade
    /// "Up to date" was still readable through "days waiting".
    static func face(reduced: Bool) -> AnyTransition {
        let leaving = AnyTransition.opacity.animation(reduced ? Motion.fade : Motion.snappy)
        guard !reduced else { return .asymmetric(insertion: .opacity, removal: leaving) }
        return .asymmetric(insertion: .scale(scale: 0.9).combined(with: .opacity), removal: leaving)
    }
}

/// A key that answers the finger the moment it lands, not when it lifts.
///
/// Every key on the shell that is drawn by its own view — the row along the
/// bottom, the wide key, a range, the dial's face — used to be a plain button
/// that did nothing visible until the finger came off. This sinks it a little
/// and dims it while held, which is the whole of what a press needs to say.
struct PressableKey: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .pressed(configuration.isPressed)
    }
}

extension View {
    /// The press feedback every key shares: sunk and dimmed while held. Kept
    /// even with Reduce Motion on, because it says a press landed, and that is
    /// feedback rather than movement.
    func pressed(_ isPressed: Bool, dimmed: Double = 0.85) -> some View {
        scaleEffect(isPressed ? Motion.pressedScale : 1)
            .opacity(isPressed ? dimmed : 1)
            .animation(Motion.snappy, value: isPressed)
    }
}
