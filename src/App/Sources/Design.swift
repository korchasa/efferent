import SwiftUI

/// The one place a colour, a shape or a legend is decided.
///
/// The app is dressed as an instrument: an off-white shell, white panels, hard
/// 3-point corners, and one orange that only the scale and the way forward may
/// use. The palette is committed rather than adaptive, and it has one failure
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

    private let marks = 60

    var body: some View {
        ZStack {
            ForEach(0 ..< marks, id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(colour(at: index))
                    .frame(width: max(1.5, side * 0.0115), height: side * 0.054)
                    .offset(y: -(side / 2 - side * 0.027))
                    .rotationEffect(.degrees(Double(index) * 6))
            }
            // Every fifth mark is scaled, the way a dial is printed.
            ForEach(0 ..< (marks / 5), id: \.self) { index in
                Capsule(style: .continuous)
                    .fill(Palette.tick)
                    .frame(width: max(1, side * 0.0077), height: side * 0.023)
                    .offset(y: -(side * 0.404))
                    .rotationEffect(.degrees(Double(index) * 30))
            }
            Circle()
                .fill(Palette.panel)
                .overlay(Circle().strokeBorder(Palette.hairline, lineWidth: 1))
                .frame(width: side * 0.723)
            Circle()
                .strokeBorder(Palette.tick, style: StrokeStyle(lineWidth: 1, dash: [1, 5]))
                .frame(width: side * 0.662)
        }
        .frame(width: side, height: side)
        .animation(.easeInOut(duration: 0.45), value: progress)
    }

    /// How many marks are lit. Never quite none while something is moving: a
    /// scale that goes dark at the start of a run reads as broken.
    private var lit: Int {
        guard progress > 0 else { return 0 }
        return max(1, min(marks, Int((Double(marks) * progress).rounded())))
    }

    private func colour(at index: Int) -> Color {
        guard index < lit else { return Palette.tick }
        switch mood {
        case .alight: return Palette.accent
        case .resting: return Palette.legend
        case .stopped: return Palette.alarm
        }
    }
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
                .padding(.leading, 8)
        }
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
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
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
            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
            .opacity(configuration.isPressed ? 0.85 : 1)
    }
}

/// The way out of a screen that is not the way forward: the same typography,
/// printed rather than lit.
struct QuietButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11, weight: .medium, design: .monospaced))
            .textCase(.uppercase)
            .kerning(1.8)
            .foregroundStyle(Palette.legend)
            .frame(maxWidth: .infinity, minHeight: 46)
            .opacity(configuration.isPressed ? 0.6 : 1)
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
                    .background(Palette.panel, in: RoundedRectangle(cornerRadius: 3, style: .continuous))
                    .overlay(
                        RoundedRectangle(cornerRadius: 3, style: .continuous)
                            .strokeBorder(Palette.hairline, lineWidth: 1)
                    )
                Legend(label, size: 8)
            }
        }
        .buttonStyle(.plain)
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
