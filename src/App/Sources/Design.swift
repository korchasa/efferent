import SwiftUI

/// The one place a colour, a shape or a legend is decided.
///
/// The app is dressed as an instrument: an off-white shell, white panels, hard
/// 3-point corners, and one orange that only the scale and the way forward may
/// use. The keys stand off the shell on a still shadow and go down under the
/// finger (`keyCap`); everything else is printed flat. The palette is
/// committed rather than adaptive, and it has one failure
/// mode worth naming — in dark mode the system turns its own text white and
/// leaves it on a light background, which is a blank screen with invisible
/// words on it. That is why every colour here is literal, and why the root view
/// pins the appearance to light instead of half-supporting both.
enum Palette {
    /// #F5F4F1 — the shell everything is printed on.
    static let shell = Color(red: 0.961, green: 0.957, blue: 0.945)
    /// #FFFFFF — panels, rows, the face of the dial.
    static let panel = Color.white
    /// #17181A — everything that has to be read.
    static let ink = Color(red: 0.090, green: 0.094, blue: 0.102)
    /// #55524D — the sentence under a headline.
    static let body = Color(red: 0.333, green: 0.322, blue: 0.302)
    /// #8A8781 — the small capitals printed beside a control.
    static let legend = Color(red: 0.541, green: 0.529, blue: 0.506)
    /// #DDD9D3 — the line around a panel and between two rows.
    static let hairline = Color(red: 0.867, green: 0.851, blue: 0.827)
    /// #CFCAC2 — a mark on the scale that has not been earned yet.
    static let tick = Color(red: 0.812, green: 0.792, blue: 0.761)
    /// #FF4B12 — the scale in motion, and the way forward.
    static let accent = Color(red: 1.000, green: 0.294, blue: 0.071)
    /// #C0392B — a stopped scale, and the one row that destroys something.
    static let alarm = Color(red: 0.753, green: 0.224, blue: 0.169)
}

/// The small monospaced capitals printed next to a control.
///
/// Everything an instrument says about itself is set this way: wide-tracked,
/// uppercase, and small enough that it never competes with the figure it
/// labels. Sentences a person has to read are not legends and stay in the
/// ordinary face.
struct Legend: View {
    let text: String
    var size: CGFloat = 10
    var colour: Color = Palette.legend

    init(_ text: String, size: CGFloat = 10, colour: Color = Palette.legend) {
        self.text = text
        self.size = size
        self.colour = colour
    }

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: size, weight: .medium, design: .monospaced))
            .kerning(size * 0.16)
            .foregroundStyle(colour)
    }
}

/// What the scale is saying, which is not always the same as what it is drawing.
enum RingMood {
    /// Days are going up, or would be the moment there were any.
    case alight
    /// Held back on purpose.
    case resting
    /// Something stopped it.
    case stopped
}

/// The scale around the button.
///
/// Sixty marks, one every six degrees, lit from twelve o'clock as the run in
/// front of it is worked through. It measures that run rather than the archive,
/// so it always reaches the top: ten unsent days fill it exactly as three
/// thousand do. A scale showing a share of the whole history would sit at
/// ninety-nine per cent for every ordinary day and say nothing about whether
/// anything is moving.
struct Dial: View {
    let progress: Double
    let mood: RingMood
    var side: CGFloat = 264
    /// Waiting on something the scale cannot measure yet: the lit arc walks
    /// round the dial instead of standing at a figure it does not have.
    var waiting = false
    /// Whether the dial prints its own face. The everyday dial leaves it to
    /// the key laid over it (`DialKey`); the walkthrough's dial, which is not
    /// a key, prints it here.
    var drawsFace = true

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let marks = 60

    var body: some View {
        ZStack {
            // Driven by the clock only while waiting, and paused otherwise, so
            // a dial at rest costs nothing a frame.
            //
            // Its own `ZStack`, because a timeline lays several children out
            // in a column: without it the sixty marks were strung down the
            // whole screen instead of printed round the face.
            TimelineView(.animation(paused: !waiting)) { context in
                let phase = phase(at: context.date)
                ZStack {
                    ForEach(0 ..< marks, id: \.self) { index in
                        // An unlit mark with its lit self over it, so a mark
                        // can be partly lit: that is what lets the sweep glide
                        // instead of hopping from mark to mark.
                        ZStack {
                            Capsule(style: .continuous).fill(Palette.tick)
                            Capsule(style: .continuous)
                                .fill(litColour)
                                .opacity(light(at: index, phase: phase))
                        }
                        .frame(width: max(1.5, side * 0.0115), height: side * 0.054)
                        .offset(y: -(side / 2 - side * 0.027))
                        .rotationEffect(.degrees(Double(index) * 6))
                    }
                }
            }
            // Every fifth mark is scaled, the way a dial is printed.
            ForEach(0 ..< (marks / 5), id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Palette.tick)
                    .frame(width: max(1, side * 0.0077), height: side * 0.023)
                    .offset(y: -(side * 0.404))
                    .rotationEffect(.degrees(Double(index) * 30))
            }
            if drawsFace {
                Circle()
                    .fill(Palette.panel)
                    .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                    .frame(width: side * 0.723)
                FaceRing(side: side)
            }
        }
        .frame(width: side, height: side)
        .animation(Motion.smoothLong, value: progress)
        .animation(Motion.smoothLong, value: mood)
        // When the wait ends the arc does not jump back to twelve o'clock: its
        // marks fade over to the ones the figure lights.
        .animation(Motion.smoothLong, value: waiting)
    }

    /// How far round one turn of the wait is, from 0 to 1.
    private func phase(at date: Date) -> Double {
        date.timeIntervalSinceReferenceDate
            .truncatingRemainder(dividingBy: Motion.sweepPeriod) / Motion.sweepPeriod
    }

    /// How brightly one mark is lit, from 0 to 1.
    ///
    /// Standing at a figure, the marks up to it are lit and the rest are not.
    /// Waiting, the figure means nothing, so it is set aside: a short arc with
    /// a bright head and a fading tail goes round on its own — a head, because
    /// an even arc going round reads as the figure moving. The head's position
    /// is continuous, so each mark brightens and dims by degrees and the arc
    /// glides at any refresh rate. With Reduce Motion on nothing travels: the
    /// figure's own arc stays put and breathes, which still says "working".
    private func light(at index: Int, phase: Double) -> Double {
        let lit = (0 ..< self.lit).contains(index) ? 1.0 : 0
        guard waiting else { return lit }
        if reduceMotion {
            return lit * (0.6 + 0.4 * cos(phase * 2 * .pi))
        }
        let count = Double(marks)
        let behind = (phase * count - Double(index)).truncatingRemainder(dividingBy: count)
        let distance = behind < 0 ? behind + count : behind
        // The mark the head is just reaching lights over its last step, rather
        // than switching on at once.
        if distance > count - 1 { return distance - (count - 1) }
        return max(0, 1 - distance / Double(Motion.sweepTail))
    }

    /// How many marks are lit. Never quite none while something is moving: a
    /// scale that goes dark at the start of a run reads as broken.
    private var lit: Int {
        guard progress > 0 else { return 0 }
        return max(1, min(marks, Int((Double(marks) * progress).rounded())))
    }

    private var litColour: Color {
        switch mood {
        case .alight: return Palette.accent
        case .resting: return Palette.legend
        case .stopped: return Palette.alarm
        }
    }
}

/// The dotted ring printed on the dial's face.
private struct FaceRing: View {
    let side: CGFloat

    var body: some View {
        Circle()
            .strokeBorder(Palette.tick, style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
            .frame(width: side * 0.662, height: side * 0.662)
    }
}

/// The dial's face as the key it is on the everyday screen: start and stop.
///
/// The biggest control on the shell, so it is a raised disc over the scale and
/// goes down under the thumb like every other key. No tap of its own: the
/// screen already taps once when sending starts or stops, and that is the tap
/// that says the press took.
struct DialKey: ButtonStyle {
    let side: CGFloat

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .frame(width: side * 0.723, height: side * 0.723)
            .background { FaceRing(side: side) }
            .keyCap(in: Circle())
            .environment(\.keyIsDown, configuration.isPressed)
    }
}

/// How far a dial's face is moved off the middle of its disc, so that it looks
/// centred rather than measures centred.
///
/// A stack is centred by its frame, and a frame is not what the eye weighs.
/// The figure's line keeps room for descenders a digit never has, and the big
/// digit is the darkest thing on the face, so "0 · days waiting" sat with its
/// weight 8 pt above the middle of the everyday disc (4.3 % of its diameter),
/// while "Up to date" sat 3.5 pt below it; switching between the two jumped
/// the eye by 11.5 pt (owner, 2026-09-29). The rule is the one a play symbol
/// in a round key follows: the centre of the ink, each point weighted by how
/// dark it is, goes on the centre of the circle. Measured on screenshots of
/// the everyday dial at 3x; re-measure if a face's type changes.
enum FaceBalance {
    /// The count with its unit and the start/stop symbol under it.
    static let figure: CGFloat = 8
    /// The mark, "Up to date" and the symbol.
    static let settled: CGFloat = -3.5
    /// The smaller dial that watches the archive start: the count with its
    /// unit, and no symbol under it.
    static let preparingFigure: CGFloat = 5
    /// The same dial once everything is sent. With no symbol under it the dark
    /// words outweigh the orange mark, so the face sat 10 pt low.
    static let preparingSettled: CGFloat = -10
}

/// The step counter across the top of a setup screen: filled segments and the
/// number in figures, the way a device prints which of its modes is on.
struct StepBar: View {
    let step: Int
    let total: Int

    var body: some View {
        HStack(spacing: 5) {
            ForEach(0 ..< total, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1)
                    .fill(index < step ? Palette.accent : Palette.tick)
                    .frame(width: 18, height: 4)
            }
            Legend(String(format: "%02d/%02d", step, total))
                .contentTransition(.numericText())
                .padding(.leading, 8)
        }
        .animation(Motion.standard, value: step)
    }
}

/// The filled action at the bottom of a screen. One per screen, always in the
/// same place, so the way forward is never something to look for.
struct ProminentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .kerning(2)
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .keyCap(tint: Palette.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .keyDown(configuration.isPressed)
    }
}

/// The invitation to hand the archive to an agent, across the whole shell.
///
/// It exists only while nothing has been handed over, because an archive nobody
/// can read is the state this app is least useful in. Once the text has gone
/// somewhere the invitation is not news any more, and the same action steps
/// down into the row of keys along the bottom.
struct ConnectButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .kerning(2)
            .foregroundStyle(Color.white)
            .frame(maxWidth: .infinity, minHeight: 54)
            .keyCap(tint: Palette.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .keyDown(configuration.isPressed)
    }
}

/// The way out of a screen that is not the way forward: the same typography,
/// printed rather than lit. A word on the shell, never a key, the way a text
/// button is in Apple's own apps.
struct QuietButton: ButtonStyle {
    var colour: Color = Palette.legend

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .kerning(1.8)
            .foregroundStyle(colour)
            .frame(maxWidth: .infinity, minHeight: 46)
            .pressed(configuration.isPressed, dimmed: 0.6)
    }
}

/// A key that runs the width of the shell, for a rare thing that has something
/// to say about itself.
///
/// The same panel, hairline and radius as the keys in the row below it, because
/// that is what makes it read as something to press. Drawn as a bare row with no
/// edges it read as a line of status instead, and the one way into everything an
/// agent has ever done looked like a caption about today.
struct WideKeyButton: View {
    let label: String
    let symbol: String
    /// What it has to say about itself, printed small on the right.
    var detail: String?
    /// A lamp before the name, as the brand row lights when sending is alive.
    var lit = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                Image(systemName: symbol)
                    .font(.system(size: 14, weight: .regular))
                    .foregroundStyle(Palette.ink)
                if lit {
                    Circle()
                        .fill(Palette.accent)
                        .frame(width: 7, height: 7)
                }
                Legend(label, size: 9, colour: Palette.ink)
                Spacer(minLength: 8)
                if let detail {
                    Legend(detail, size: 9)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Palette.tick)
            }
            .padding(.horizontal, 14)
            .frame(maxWidth: .infinity, minHeight: 52)
            .keyCap(in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(RaisedKey())
        .accessibilityLabel(label)
    }
}

/// One key in the row along the bottom: the symbol on the key, the name of the
/// thing printed underneath it.
///
/// The rare actions are keys rather than a menu because a menu hides how many
/// there are, and there are only three. A key can be read without being
/// pressed, which is the point of printing its name on the shell.
struct KeyButton: View {
    let label: String
    let symbol: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            VStack(spacing: 6) {
                Image(systemName: symbol)
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(Palette.ink)
                    .frame(maxWidth: .infinity, minHeight: 52)
                    .keyCap(in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                Legend(label, size: 8)
            }
        }
        .buttonStyle(RaisedKey())
        .accessibilityLabel(label)
    }
}

/// A white block with a hairline around it. Square corners, because everything
/// on this shell is stamped rather than moulded.
struct Panel<Content: View>: View {
    var padding: CGFloat = 0
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .padding(padding)
            .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 3, style: .continuous)
                    .strokeBorder(Palette.hairline, lineWidth: 1)
            )
    }
}

/// The one row that destroys something.
///
/// The same geometry as the way forward, because on the screen it appears on it
/// *is* the way forward — and the alarm colour, because it is the only thing in
/// this app that takes something out of Health.
struct DangerButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .kerning(2)
            .foregroundStyle(Palette.alarm)
            .frame(maxWidth: .infinity, minHeight: 54)
            .pressed(configuration.isPressed, dimmed: 0.6)
    }
}

// MARK: - Raised keys

/// What a key looks like standing on the shell and pressed into it.
///
/// Light comes from straight above and never moves, so every key casts the same
/// shadow: a tight dark line where it meets the shell and a wide soft one under
/// it. Pressed, the key drops by a point and a half and both shadows close up
/// under it, the way a real key's shadow does. Two earlier tries are why it is
/// this plain (owner, 2026-10-07): shadows that followed the phone's tilt read
/// as fake because they stepped between fixed positions, and Liquid Glass on a
/// flat, still shell had nothing under it to bend and read as a white outline.
enum KeyLight {
    /// The line where the key meets the shell, which is all that marks its
    /// edge.
    static let contact = Color.black.opacity(0.14)
    /// The soft shadow the key stands on.
    static let ambient = Color.black.opacity(0.08)
    static let ambientRadius: CGFloat = 10
    static let ambientDrop: CGFloat = 5
    /// How far a key goes down while held.
    static let travel: CGFloat = 1.5

    /// #FAF9F7 — the lower edge of a white key, turning away from the light.
    static let panelLow = Color(red: 0.979, green: 0.976, blue: 0.970)
    /// #FF6331 — the top of the orange key, where the light lands.
    static let accentHigh = Color(red: 1.000, green: 0.388, blue: 0.192)
    /// #F04711 — the lower edge of the orange key.
    static let accentLow = Color(red: 0.941, green: 0.278, blue: 0.067)

    /// #EFEDE9 — the top of a white key sitting in the shell, in the shade
    /// of the rim above it.
    static let panelSunk = Color(red: 0.937, green: 0.929, blue: 0.914)

    /// The face of a key: a touch lighter at the top, where the light lands.
    /// A key that is down sits below the light, so its face turns the other
    /// way, shaded at the top — which is what tells a latched key from the
    /// ones standing beside it, more than the point and a half it dropped.
    /// The only tint is the way forward, so its shades are fixed here rather
    /// than mixed (mixing colours needs iOS 18).
    static func face(_ tint: Color?, down: Bool = false) -> LinearGradient {
        let colours: [Color] = switch (tint == nil, down) {
        case (true, false): [Palette.panel, Palette.panel, panelLow]
        case (true, true): [panelSunk, panelLow, panelLow]
        case (false, false): [accentHigh, Palette.accent, accentLow]
        case (false, true): [accentLow, Palette.accent, Palette.accent]
        }
        return LinearGradient(colors: colours, startPoint: .top, endPoint: .bottom)
    }
}

extension EnvironmentValues {
    /// Whether the key this view is the body of is held down. Set by the
    /// key's button style, read by `keyCap`, so a key whose body is only part
    /// of its label — the row along the bottom, with its name printed under
    /// it — still goes down as one.
    @Entry var keyIsDown = false
}

extension View {
    /// The body of a key: its face and its shadow, raised off the shell and
    /// pressed into it while held. No hairline: the shadow is the key's edge,
    /// and a line drawn round it as well read as an outline again. A tint is
    /// for the way forward only.
    func keyCap(tint: Color? = nil, in shape: some InsettableShape) -> some View {
        modifier(KeyCap(tint: tint, shape: shape))
    }

    /// The press of a key whose style draws its own body: down, and one light
    /// tap under the finger as it lands.
    func keyDown(_ isPressed: Bool) -> some View {
        environment(\.keyIsDown, isPressed)
            .sensoryFeedback(.impact(weight: .light), trigger: isPressed) { _, down in down }
    }
}

private struct KeyCap<S: InsettableShape>: ViewModifier {
    let tint: Color?
    let shape: S

    @Environment(\.keyIsDown) private var down
    @Environment(\.isEnabled) private var enabled

    /// A key that cannot be pressed does not stand up to be pressed: it lies
    /// flat on the shell and fades, so it never reads as one that is broken.
    private var raised: Bool { enabled && !down }

    func body(content: Content) -> some View {
        content
            .background {
                shape.fill(KeyLight.face(tint, down: down && enabled))
                    .shadow(color: KeyLight.contact.opacity(enabled ? 1 : 0), radius: raised ? 1 : 0.5, y: raised ? 1 : 0.5)
                    .shadow(
                        color: KeyLight.ambient.opacity(raised ? 1 : enabled ? 0.5 : 0),
                        radius: raised ? KeyLight.ambientRadius : 3,
                        y: raised ? KeyLight.ambientDrop : 1
                    )
            }
            .opacity(enabled ? 1 : 0.45)
            .offset(y: down && enabled ? KeyLight.travel : 0)
            .animation(Motion.snappy, value: down)
    }
}

/// A key drawn by its own view, whose body is `keyCap`.
struct RaisedKey: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .keyDown(configuration.isPressed)
    }
}

/// A key that stays down once it is chosen, the way the range keys on an old
/// instrument latch: the chosen one sits in the shell, the others stand up. It
/// taps nothing itself — the list it belongs to says when the choice moves.
struct LatchedKey: ButtonStyle {
    let latched: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .environment(\.keyIsDown, latched || configuration.isPressed)
    }
}

/// The line between two rows, inset the way the rows are.
struct RowDivider: View {
    var inset: CGFloat = 0

    var body: some View {
        Palette.hairline
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

extension View {
    /// The shell every screen is printed on.
    func pageBackground() -> some View {
        background(Palette.shell.ignoresSafeArea())
    }
}

/// Digits a person can read at a glance: grouped in threes with a thin space,
/// which is narrow enough not to look like two numbers.
func grouped(_ value: Int) -> String {
    let formatter = NumberFormatter()
    formatter.numberStyle = .decimal
    formatter.groupingSeparator = "\u{2009}"
    return formatter.string(from: NSNumber(value: value)) ?? String(value)
}

/// A day id as a person would say it: "12 Dec 2015".
func spoken(day: String) -> String {
    let parts = day.split(separator: "-")
    guard parts.count == 3, let month = Int(parts[1]), (1 ... 12).contains(month),
          let number = Int(parts[2])
    else { return day }
    let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun",
                  "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
    return "\(number) \(months[month - 1]) \(parts[0])"
}

/// A stretch of time as a person would say it: "about 6 min", "about 2 h 10
/// min". Rounded on purpose — a measured rate does not deserve seconds, and a
/// countdown that ticks invites watching something that needs nobody watching.
func spoken(duration: TimeInterval) -> String {
    let minutes = Int((duration / 60).rounded())
    if minutes < 1 {
        return "less than a minute"
    }
    if minutes < 60 {
        return "about \(minutes) min"
    }
    let hours = minutes / 60
    let rest = minutes % 60
    if rest < 5 {
        return "about \(hours) h"
    }
    return "about \(hours) h \(rest) min"
}
