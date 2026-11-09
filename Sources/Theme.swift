import SwiftUI
import AppKit

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

extension Color {
    /// A colour that follows light / dark mode.
    static func dynamic(_ light: UInt32, _ dark: UInt32, alpha: Double = 1) -> Color {
        Color(NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            let hex = isDark ? dark : light
            return NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                           green: CGFloat((hex >> 8) & 0xFF) / 255,
                           blue: CGFloat(hex & 0xFF) / 255,
                           alpha: CGFloat(alpha))
        })
    }
}

/// Mongez "Mist" (Hosam approved it after 1.30): the same teal and coral, much softer, in light and dark.
/// Only the main action on a screen is loud (soft gradient, near-black text, a ring of light on hover);
/// everything else is a quiet glass chip. The old names (blue, purple, pink…) are kept so every
/// screen picks up the colours.
enum Theme {
    // Main colours (text and icons)
    static let teal = Color.dynamic(0x2F857C, 0x6CC2B7)
    static let tealLight = Color.dynamic(0x7FCDC2, 0x8FD8CE)
    static let tealDeep = Color.dynamic(0x23675F, 0x4FA79C)
    static let coral = Color.dynamic(0xD9705F, 0xF0A090)
    static let ink = Color.dynamic(0x1C2322, 0xE3EFED)
    /// Text and icons on the loud buttons: near-black, in light and dark.
    static let buttonInk = Color.dynamic(0x152120, 0x14201F)

    // Soft ends of the teal → coral gradient (the running clock, bars, highlighted edges)
    static let softTeal = Color.dynamic(0x3F9A90, 0x6CC2B7)
    static let softCoral = Color.dynamic(0xD98B7D, 0xEBA395)

    // The loud buttons' fills
    private static let coralTop = Color.dynamic(0xFBC3B6, 0xFFC6B9)
    private static let coralBottom = Color.dynamic(0xF4A08E, 0xF39C89)
    private static let tealTop = Color.dynamic(0xB4E6DE, 0xA9E3DA)
    private static let tealBottom = Color.dynamic(0x86CFC4, 0x74C2B7)

    // The ring of light behind a loud button: teal, blue, coral, amber
    static let ringColors: [Color] = [
        Color.dynamic(0x7FD6C9, 0x4FD1C0),
        Color.dynamic(0xA9C8FF, 0x7AA8FF),
        Color.dynamic(0xFFB3A3, 0xFF8F7A),
        Color.dynamic(0xFFD9A0, 0xFFC56E),
    ]

    // Tags
    static let pitch = Color.dynamic(0xA0620A, 0xFFC97A)
    static let support = Color.dynamic(0x5B45B8, 0xC9BDFF)
    static let slate = Color.dynamic(0x5C6B7A, 0xA8B4C2)

    // Old names, mapped onto the new palette
    static let blue = teal
    static let indigo = tealDeep
    static let purple = support
    static let pink = Color.dynamic(0xE5484D, 0xFF7A80)     // errors
    static let orange = Color.dynamic(0xD98A1C, 0xF5B54A)   // warnings
    static let green = Color.dynamic(0x2F9E6A, 0x5FD09A)    // done / OK

    static let colors: [Color] = [tealLight, teal, coral]

    /// Soft teal → coral (the running clock, bars).
    static var linear: LinearGradient {
        LinearGradient(colors: [softTeal, softCoral], startPoint: .leading, endPoint: .trailing)
    }
    static var diagonal: LinearGradient {
        LinearGradient(colors: [softTeal, softCoral], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// The edge of a highlighted card (the running task, the timer box in Done).
    static var edge: LinearGradient {
        LinearGradient(colors: [softTeal.opacity(0.5), softCoral.opacity(0.5)], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Teal only (icons).
    static var cool: LinearGradient {
        LinearGradient(colors: [tealLight, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Fill of the loud coral buttons (New Task, Done, Complete…).
    static var coralFill: LinearGradient {
        LinearGradient(colors: [coralTop, coralBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Fill of the loud round teal buttons (play / pause, + 30 min) and the sheets' icon.
    static var tealFill: LinearGradient {
        LinearGradient(colors: [tealTop, tealBottom], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static let coralShadow = Color.dynamic(0xE8705F, 0x000000, alpha: 0.25)
    static let tealShadow = Color.dynamic(0x2F857C, 0x000000, alpha: 0.25)
    /// The turning ring of light, `rotation` in degrees.
    static func ring(_ rotation: Double = 0) -> AngularGradient {
        AngularGradient(colors: ringColors + [ringColors[0]], center: .center, angle: .degrees(rotation))
    }
    static func angular(_ rotation: Double = 0) -> AngularGradient {
        AngularGradient(colors: [tealLight, teal, coral, tealLight], center: .center, angle: .degrees(rotation))
    }

    static func statusColor(_ s: TaskStatus) -> Color {
        switch s {
        case .incoming: return slate
        case .active, .inProcess: return teal
        case .complete: return green
        }
    }
}

// MARK: - Appearance

/// Settings → General → Appearance: System, Light or Dark for every Mongez window.
enum Appearance {
    static func apply() {
        switch UserDefaults.standard.string(forKey: Pref.appearance) ?? "system" {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil
        }
    }
}

// MARK: - Background

/// Soft teal and coral light behind frosted glass (Mist: calmer than 1.30).
struct GlowBackground: View {
    @Environment(\.colorScheme) var scheme
    var animate = true
    @Local var phase = false

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(hex: 0x0D1617) : Color(hex: 0xEEF4F3))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Color(hex: dark ? 0x16423D : 0xBFE0DA), size: w * 0.75)
                        .offset(x: phase ? -w * 0.28 : -w * 0.34, y: phase ? -h * 0.30 : -h * 0.22)
                    blob(Color(hex: dark ? 0x1A3442 : 0xD6E6EE), size: w * 0.55)
                        .offset(x: phase ? w * 0.32 : w * 0.24, y: phase ? -h * 0.20 : -h * 0.30)
                    blob(Color(hex: dark ? 0x4A2C28 : 0xF3D9D2), size: w * 0.6)
                        .offset(x: phase ? w * 0.26 : w * 0.34, y: phase ? h * 0.36 : h * 0.28)
                }
                .frame(width: w, height: h)
            }
            .blur(radius: 90)
            .opacity(dark ? 0.6 : 0.75)
            Rectangle().fill(.ultraThinMaterial).opacity(dark ? 0.25 : 0.35)
        }
        .ignoresSafeArea()
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 12).repeatForever(autoreverses: true)) { phase = true }
        }
    }

    private func blob(_ c: Color, size: CGFloat) -> some View {
        Circle().fill(c).frame(width: size, height: size)
    }
}

// MARK: - Glass

/// Frosted glass with a bright edge, like Apple's Liquid Glass.
struct GlassCard: ViewModifier {
    @Environment(\.colorScheme) var scheme
    var radius: CGFloat = 18
    var highlight = false
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)
        content
            .background(.ultraThinMaterial, in: shape)
            .background(shape.fill(dark ? Color(hex: 0x1E3436).opacity(0.4) : Color.white.opacity(0.5)))
            .overlay(
                shape.strokeBorder(
                    highlight ? AnyShapeStyle(Theme.edge)
                              : AnyShapeStyle(LinearGradient(
                                    colors: dark ? [.white.opacity(0.22), .white.opacity(0.06)]
                                                 : [.white.opacity(0.95), .white.opacity(0.45)],
                                    startPoint: .top, endPoint: .bottom)),
                    lineWidth: highlight ? 1.5 : 1)
            )
            .shadow(color: dark ? .black.opacity(0.3) : Color(hex: 0x285A55).opacity(0.08), radius: 16, y: 6)
    }
}

extension View {
    func glassCard(radius: CGFloat = 18, highlight: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlight: highlight))
    }
    /// Teal text (titles, numbers).
    func gradientText() -> some View {
        foregroundStyle(LinearGradient(colors: [Theme.teal, Theme.tealDeep], startPoint: .leading, endPoint: .trailing))
    }
}

/// A small round glass chip (tool buttons, tags).
struct GlassChip: ViewModifier {
    @Environment(\.colorScheme) var scheme
    func body(content: Content) -> some View {
        let dark = scheme == .dark
        content
            .background(Capsule().fill(dark ? Color.white.opacity(0.07) : Color.white.opacity(0.72)))
            .overlay(Capsule().strokeBorder(dark ? Color.white.opacity(0.14) : Color.white.opacity(0.95), lineWidth: 1))
    }
}

extension View {
    func glassChip() -> some View { modifier(GlassChip()) }
}

// MARK: - Buttons

/// A loud button (the main action): soft gradient, near-black text, and the motion of the Mist design.
/// Hover: a gradient ring of light turns behind the button. It only runs while the pointer is on the
/// button, so nothing animates in the background. Press: the button sinks, the glow flares out and a
/// gradient wave spreads from behind it.
struct LoudButtonLook<S: InsettableShape>: ViewModifier {
    var shape: S
    var fill: LinearGradient
    var shadow: Color
    var pressed: Bool
    @Environment(\.isEnabled) private var enabled
    @Local private var hovering = false
    @Local private var wave: CGFloat = 1     // 0 → 1 while a wave spreads
    @Local private var waving = false

    func body(content: Content) -> some View {
        let lit = hovering && enabled
        content
            .foregroundStyle(Theme.buttonInk)
            .background {
                ZStack {
                    // The wave a click sends out
                    shape.fill(Theme.ring())
                        .blur(radius: 6)
                        .scaleEffect(x: 1 + 0.5 * wave, y: 1 + 0.9 * wave)
                        .opacity(waving ? 0.85 * Double(1 - wave) : 0)
                    // The turning ring: a soft glow and a thin sharp edge
                    if lit {
                        TimelineView(.animation) { timeline in
                            let turn = timeline.date.timeIntervalSinceReferenceDate
                                .truncatingRemainder(dividingBy: 2.6) / 2.6 * 360
                            ZStack {
                                shape.fill(Theme.ring(turn))
                                    .padding(pressed ? -10 : -6)
                                    .blur(radius: pressed ? 14 : 10)
                                    .opacity(pressed ? 1 : 0.85)
                                shape.fill(Theme.ring(turn))
                                    .padding(-2)
                            }
                        }
                        .transition(.opacity)
                    }
                    shape.fill(fill)
                }
            }
            .shadow(color: shadow, radius: lit ? 10 : 6, y: 3)
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(pressed ? 0.94 : 1)
            .offset(y: lit && !pressed ? -1 : 0)
            .animation(.spring(response: 0.25, dampingFraction: 0.6), value: pressed)
            .animation(.easeOut(duration: 0.3), value: lit)
            .onHover { hovering = $0 }
            .onChange(of: pressed) { down in
                if down && enabled { sendWave() }
            }
    }

    private func sendWave() {
        var reset = Transaction()
        reset.disablesAnimations = true
        withTransaction(reset) {
            wave = 0
            waving = true
        }
        DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.6)) { wave = 1 }
        }
    }
}

/// A quiet button (everything that isn't the main action): a glass chip that brightens on hover.
struct QuietButtonLook<S: InsettableShape>: ViewModifier {
    var shape: S
    var pressed: Bool
    @Environment(\.colorScheme) private var scheme
    @Environment(\.isEnabled) private var enabled
    @Local private var hovering = false

    func body(content: Content) -> some View {
        let dark = scheme == .dark
        let lit = hovering && enabled
        content
            .background(shape.fill(Color.white.opacity(dark ? (lit ? 0.13 : 0.07) : (lit ? 0.98 : 0.72))))
            .overlay(shape.strokeBorder(Color.white.opacity(dark ? 0.14 : 0.95), lineWidth: 1))
            .opacity(enabled ? 1 : 0.5)
            .scaleEffect(pressed ? 0.94 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: pressed)
            .animation(.easeOut(duration: 0.2), value: lit)
            .onHover { hovering = $0 }
    }
}

/// The main action of a screen: New Task, Done, Complete, Create & Start, Assign Task, Add Account…
struct GradientButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .bold))
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 9)
            .modifier(LoudButtonLook(shape: Capsule(), fill: Theme.coralFill, shadow: Theme.coralShadow,
                                     pressed: configuration.isPressed))
            .contentShape(Capsule())
    }
}

struct GlassButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .medium))
            .padding(.horizontal, compact ? 10 : 14)
            .padding(.vertical, compact ? 6 : 8)
            .modifier(QuietButtonLook(shape: Capsule(), pressed: configuration.isPressed))
            .contentShape(Capsule())
    }
}

/// Round icon buttons. `filled` = loud (teal gradient, the ring on hover: play / pause, + 30 min);
/// otherwise a quiet glass circle with a teal icon.
struct CircleIconButtonStyle: ButtonStyle {
    var filled = false
    var size: CGFloat = 34
    @ViewBuilder
    func makeBody(configuration: Configuration) -> some View {
        if filled {
            configuration.label
                .font(.system(size: size * 0.4, weight: .bold))
                .frame(width: size, height: size)
                .modifier(LoudButtonLook(shape: Circle(), fill: Theme.tealFill, shadow: Theme.tealShadow,
                                         pressed: configuration.isPressed))
                .contentShape(Circle())
        } else {
            configuration.label
                .font(.system(size: size * 0.4, weight: .bold))
                .foregroundStyle(Theme.teal)
                .frame(width: size, height: size)
                .modifier(QuietButtonLook(shape: Circle(), pressed: configuration.isPressed))
                .contentShape(Circle())
        }
    }
}

// MARK: - Hover label

/// A name in a small glass label under a button, shown a moment after the pointer stops on it
/// (sooner than a system tooltip, and in the app's style). It takes no room in the layout.
struct HoverLabel: ViewModifier {
    var text: String
    /// Above the button instead of under it (where the space below is cut off).
    var above = false
    @Local private var hovering = false
    @Local private var shown = false

    func body(content: Content) -> some View {
        content
            .onHover { inside in
                hovering = inside
                if inside {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) {
                        guard hovering else { return }
                        withAnimation(.spring(response: 0.28, dampingFraction: 0.75)) { shown = true }
                    }
                } else {
                    withAnimation(.easeOut(duration: 0.12)) { shown = false }
                }
            }
            .overlay(alignment: above ? .top : .bottom) {
                if shown {
                    Text(text)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .fixedSize()
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.regularMaterial, in: Capsule())
                        .overlay(Capsule().strokeBorder(Color.white.opacity(0.35), lineWidth: 1))
                        .shadow(color: .black.opacity(0.15), radius: 6, y: 2)
                        .alignmentGuide(.bottom) { d in d[.top] - 6 }       // just under the button…
                        .alignmentGuide(.top) { d in d[.bottom] + 6 }       // …or just above it
                        .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: above ? .bottom : .top)))
                        .allowsHitTesting(false)
                }
            }
    }
}

extension View {
    func hoverLabel(_ text: String, above: Bool = false) -> some View { modifier(HoverLabel(text: text, above: above)) }
}

// MARK: - Room in the window

private struct MainWindowSizeKey: EnvironmentKey {
    static let defaultValue: CGSize? = nil
}

extension EnvironmentValues {
    /// Size of the main window (set by `MainView`, seen by its rows and sheets): rows fold their
    /// tools when it's narrow, and sheets never grow taller than it (a taller sheet gets cut off).
    var mainWindowSize: CGSize? {
        get { self[MainWindowSizeKey.self] }
        set { self[MainWindowSizeKey.self] = newValue }
    }
}

enum Room {
    /// Space a sheet may take: the main window's height less a margin, so its top and its
    /// buttons stay inside the window.
    static func sheetHeight(_ window: CGSize?) -> CGFloat {
        let h = window?.height ?? NSApp.mainWindow?.contentLayoutRect.height ?? 800
        return max(380, h - 40)
    }
}

// MARK: - Timer ring

struct TimerRing: View {
    var running: Bool
    var progress: Double  // 0...1 within the current hour
    var size: CGFloat = 120
    @Local var spin = 0.0

    var body: some View {
        ZStack {
            Circle().stroke(Color.primary.opacity(0.08), lineWidth: size * 0.075)
            Circle()
                .trim(from: 0, to: max(0.02, progress))
                .stroke(Theme.angular(spin), style: StrokeStyle(lineWidth: size * 0.075, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if running {
                Circle()
                    .stroke(Theme.angular(spin), lineWidth: size * 0.04)
                    .blur(radius: size * 0.08)
                    .opacity(0.55)
            }
        }
        .frame(width: size, height: size)
        .onAppear {
            withAnimation(.linear(duration: 6).repeatForever(autoreverses: false)) { spin = 360 }
        }
    }
}

struct StatusPill: View {
    var status: TaskStatus
    var body: some View {
        Text(status.title)
            .font(.system(size: 10, weight: .semibold))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .foregroundStyle(Theme.statusColor(status))
            .background(Theme.statusColor(status).opacity(0.14), in: Capsule())
    }
}

struct SectionLabel: View {
    var text: String
    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 10, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(.secondary)
    }
}
