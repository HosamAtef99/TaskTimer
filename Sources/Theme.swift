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

/// Mongez: teal glass with a coral accent (Hosam's pick, 1.30), in light and dark.
/// The old names (blue, purple, pink…) are kept so every screen picks up the new colours.
enum Theme {
    // Main colours
    static let teal = Color.dynamic(0x1E9E92, 0x2BB3A3)
    static let tealLight = Color.dynamic(0x7FE0D4, 0x8FECDF)
    static let tealDeep = Color.dynamic(0x13796F, 0x1E9E92)
    static let coral = Color.dynamic(0xF27A69, 0xFF9585)
    static let ink = Color.dynamic(0x0E2E2E, 0xE8F7F5)

    // Tags
    static let pitch = Color.dynamic(0xB06600, 0xFFC97A)
    static let support = Color.dynamic(0x6A4FD8, 0xC2B5FF)
    static let slate = Color.dynamic(0x55697F, 0xAEB6C6)

    // Old names, mapped onto the new palette
    static let blue = teal
    static let indigo = tealDeep
    static let purple = support
    static let pink = Color.dynamic(0xE5484D, 0xFF7A80)     // errors
    static let orange = Color.dynamic(0xD98A1C, 0xF5B54A)   // warnings
    static let green = Color.dynamic(0x22A866, 0x3FCF85)    // done / OK

    static let colors: [Color] = [tealLight, teal, coral]

    /// Teal → coral (the running clock, highlights).
    static var linear: LinearGradient {
        LinearGradient(colors: [teal, coral], startPoint: .leading, endPoint: .trailing)
    }
    static var diagonal: LinearGradient {
        LinearGradient(colors: [teal, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    /// Teal only (icons, the play button).
    static var cool: LinearGradient {
        LinearGradient(colors: [tealLight, teal], startPoint: .topLeading, endPoint: .bottomTrailing)
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

/// Soft teal and coral light behind frosted glass.
struct GlowBackground: View {
    @Environment(\.colorScheme) var scheme
    var animate = true
    @Local var phase = false

    var body: some View {
        let dark = scheme == .dark
        ZStack {
            (dark ? Color(hex: 0x081416) : Color(hex: 0xEDF8F6))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Color(hex: dark ? 0x12504A : 0x9BE6DC), size: w * 0.75)
                        .offset(x: phase ? -w * 0.28 : -w * 0.34, y: phase ? -h * 0.30 : -h * 0.22)
                    blob(Color(hex: dark ? 0x173E52 : 0xBCE3F0), size: w * 0.55)
                        .offset(x: phase ? w * 0.32 : w * 0.24, y: phase ? -h * 0.20 : -h * 0.30)
                    blob(Color(hex: dark ? 0x5A2E2A : 0xFFD3CB), size: w * 0.6)
                        .offset(x: phase ? w * 0.26 : w * 0.34, y: phase ? h * 0.36 : h * 0.28)
                }
                .frame(width: w, height: h)
            }
            .blur(radius: 90)
            .opacity(dark ? 0.75 : 0.8)
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
            .background(shape.fill(dark ? Color(hex: 0x16383A).opacity(0.35) : Color.white.opacity(0.45)))
            .overlay(
                shape.strokeBorder(
                    highlight ? AnyShapeStyle(Theme.diagonal)
                              : AnyShapeStyle(LinearGradient(
                                    colors: dark ? [.white.opacity(0.22), .white.opacity(0.06)]
                                                 : [.white.opacity(0.95), .white.opacity(0.45)],
                                    startPoint: .top, endPoint: .bottom)),
                    lineWidth: highlight ? 1.5 : 1)
            )
            .shadow(color: dark ? .black.opacity(0.35) : Color(hex: 0x1E786E).opacity(0.10), radius: 16, y: 6)
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

struct GradientButtonStyle: ButtonStyle {
    var compact = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 6 : 9)
            .background(Capsule().fill(Theme.coral))
            .overlay(Capsule().strokeBorder(.white.opacity(0.3), lineWidth: 1))
            .shadow(color: Theme.coral.opacity(configuration.isPressed ? 0.2 : 0.35), radius: 10, y: 4)
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
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
            .glassChip()
            .scaleEffect(configuration.isPressed ? 0.96 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Capsule())
    }
}

struct CircleIconButtonStyle: ButtonStyle {
    var filled = false
    var size: CGFloat = 34
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: size * 0.4, weight: .bold))
            .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(Theme.teal))
            .frame(width: size, height: size)
            .background {
                if filled {
                    Circle().fill(LinearGradient(colors: [Theme.tealLight, Theme.teal], startPoint: .topLeading, endPoint: .bottomTrailing))
                } else {
                    Circle().fill(Color.primary.opacity(0.05))
                }
            }
            .overlay(Circle().strokeBorder(filled ? Color.white.opacity(0.35) : Color.primary.opacity(0.1), lineWidth: 1))
            .shadow(color: filled ? Theme.teal.opacity(0.35) : .clear, radius: 8, y: 3)
            .scaleEffect(configuration.isPressed ? 0.92 : 1)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: configuration.isPressed)
            .contentShape(Circle())
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
