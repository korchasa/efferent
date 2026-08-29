import SwiftUI

/// The one place a colour or a shape is decided.
///
/// The palette is committed rather than adaptive: warm near-white, ink, and a
/// single ember that only the ring and the actions may use. A committed palette
/// has one failure mode worth naming — in dark mode the system turns its own
/// text white and leaves it on a light background, which is a blank screen with
/// invisible words on it. That is why every colour here is literal, and why the
/// root view pins the appearance to light instead of half-supporting both.
enum Palette {
    /// #FDFBF9 — the page.
    static let surface = Color(red: 0.992, green: 0.984, blue: 0.976)
    /// #16130F — everything that has to be read.
    static let ink = Color(red: 0.086, green: 0.075, blue: 0.059)
    /// #7C746C — the sentence under a headline.
    static let secondary = Color(red: 0.486, green: 0.455, blue: 0.424)
    /// #A79E95 — captions, and the value on the right of a row.
    static let tertiary = Color(red: 0.655, green: 0.620, blue: 0.584)
    /// #FFFFFF — cards and rows.
    static let card = Color.white
    /// #F3EFEA — the line between two rows.
    static let hairline = Color(red: 0.953, green: 0.937, blue: 0.918)
    /// #EFEBE6 — the part of the ring not earned yet.
    static let track = Color(red: 0.937, green: 0.922, blue: 0.902)
    /// #F5F1EC — the disc inside the ring.
    static let disc = Color(red: 0.961, green: 0.945, blue: 0.925)
    /// #F3F0EC — the small round chip in the header.
    static let chip = Color(red: 0.953, green: 0.941, blue: 0.925)
    /// #E2582B — buttons, links, the chosen day.
    static let accent = Color(red: 0.886, green: 0.345, blue: 0.169)
    /// #FDEDE6 — the accent at a whisper, behind a category letter.
    static let accentSoft = Color(red: 0.992, green: 0.929, blue: 0.902)
    /// #CFC7BE — the ring when nothing is being sent.
    static let ash = Color(red: 0.812, green: 0.780, blue: 0.745)
    /// #C0392B — a stopped ring, and the one row that destroys something.
    static let alarm = Color(red: 0.753, green: 0.224, blue: 0.169)

    /// The gradient closes on itself: an angular gradient whose last colour is
    /// not its first shows a seam at twelve o'clock on a full ring.
    static let ember = [
        Color(red: 0.949, green: 0.271, blue: 0.122), // #F2451F
        Color(red: 1.000, green: 0.478, blue: 0.180), // #FF7A2E
        Color(red: 1.000, green: 0.702, blue: 0.125), // #FFB320
        Color(red: 0.949, green: 0.271, blue: 0.122)
    ]
}

/// What the ring is saying, which is not always the same as what it is drawing.
enum RingMood {
    /// Days are going up, or would be the moment there were any.
    case alight
    /// Held back on purpose.
    case resting
    /// Something stopped it.
    case stopped
}

/// The ring around the button.
///
/// It measures the work in front of it rather than the archive, so it always
/// reaches the top: ten unsent days fill it exactly as three thousand do. A
/// ring showing a share of the whole history would sit at ninety-nine per cent
/// for every ordinary day and say nothing about whether anything is moving.
struct EmberRing: View {
    let progress: Double
    let mood: RingMood

    var body: some View {
        ZStack {
            Circle()
                .stroke(Palette.track, style: StrokeStyle(lineWidth: 16))
            Circle()
                // Never quite zero: a trim of exactly zero draws nothing, and a
                // ring that vanishes at the start of a sync reads as broken.
                .trim(from: 0, to: max(0.004, min(1, progress)))
                .stroke(stroke, style: StrokeStyle(lineWidth: 16, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.45), value: progress)
        }
    }

    private var stroke: AnyShapeStyle {
        switch mood {
        case .resting: return AnyShapeStyle(Palette.ash)
        case .stopped: return AnyShapeStyle(Palette.alarm)
        case .alight:
            return AnyShapeStyle(AngularGradient(
                colors: Palette.ember,
                center: .center,
                startAngle: .degrees(0),
                endAngle: .degrees(360)
            ))
        }
    }
}

/// The app's own mark, drawn rather than loaded.
///
/// An icon in the asset catalogue is not readable from inside the app without
/// going through the bundle's icon declarations, and a second copy of the
/// artwork as a plain image is a second thing to keep in step. The shape is
/// small enough to state directly: a phone, an arrow, and the spark it hands
/// over to.
struct AppMark: View {
    var side: CGFloat = 88

    /// The artwork was drawn on a 1024 grid, and every number below is from it.
    private var scale: CGFloat { side / 1024 }

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 229 * scale, style: .continuous)
                .fill(Color(red: 0.059, green: 0.133, blue: 0.200)) // #0F2233

            RoundedRectangle(cornerRadius: 52 * scale, style: .continuous)
                .fill(.white)
                .frame(width: 252 * scale, height: 480 * scale)
                .offset(x: (230 - 512) * scale, y: (508 - 512) * scale)

            Capsule()
                .fill(Color(red: 0.059, green: 0.133, blue: 0.200))
                .frame(width: 88 * scale, height: 22 * scale)
                .offset(x: (230 - 512) * scale, y: (327 - 512) * scale)

            Path { path in
                path.move(to: CGPoint(x: 396 * scale, y: 512 * scale))
                path.addLine(to: CGPoint(x: 520 * scale, y: 512 * scale))
                path.move(to: CGPoint(x: 470 * scale, y: 458 * scale))
                path.addLine(to: CGPoint(x: 528 * scale, y: 512 * scale))
                path.addLine(to: CGPoint(x: 470 * scale, y: 566 * scale))
            }
            .stroke(.white, style: StrokeStyle(lineWidth: 44 * scale, lineCap: .round, lineJoin: .round))

            Path { path in
                path.move(to: CGPoint(x: 760 * scale, y: 350 * scale))
                path.addCurve(
                    to: CGPoint(x: 920 * scale, y: 512 * scale),
                    control1: CGPoint(x: 780 * scale, y: 470 * scale),
                    control2: CGPoint(x: 840 * scale, y: 505 * scale)
                )
                path.addCurve(
                    to: CGPoint(x: 760 * scale, y: 674 * scale),
                    control1: CGPoint(x: 840 * scale, y: 519 * scale),
                    control2: CGPoint(x: 780 * scale, y: 554 * scale)
                )
                path.addCurve(
                    to: CGPoint(x: 600 * scale, y: 512 * scale),
                    control1: CGPoint(x: 740 * scale, y: 554 * scale),
                    control2: CGPoint(x: 680 * scale, y: 519 * scale)
                )
                path.addCurve(
                    to: CGPoint(x: 760 * scale, y: 350 * scale),
                    control1: CGPoint(x: 680 * scale, y: 505 * scale),
                    control2: CGPoint(x: 740 * scale, y: 470 * scale)
                )
            }
            .fill(.white)
        }
        .frame(width: side, height: side)
    }
}

/// The filled action at the bottom of a setup screen. One per screen, always in
/// the same place, so the way forward is never something to look for.
struct ProminentButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity, minHeight: 52)
            .background(Palette.accent, in: Capsule())
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// A white block with rows in it, in the shape iOS uses for grouped settings.
struct Card<Content: View>: View {
    @ViewBuilder var content: Content

    var body: some View {
        VStack(spacing: 0) { content }
            .background(Palette.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

/// The line between two rows, inset the way the rows are.
struct RowDivider: View {
    var inset: CGFloat = 16

    var body: some View {
        Palette.hairline
            .frame(height: 1)
            .padding(.leading, inset)
    }
}

extension View {
    /// The page every screen sits on.
    func pageBackground() -> some View {
        background(Palette.surface.ignoresSafeArea())
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
    if minutes < 1 { return "less than a minute" }
    if minutes < 60 { return "about \(minutes) min" }
    let hours = minutes / 60
    let rest = minutes % 60
    if rest < 5 { return "about \(hours) h" }
    return "about \(hours) h \(rest) min"
}
