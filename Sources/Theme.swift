import SwiftUI

extension Color {
    init(hex: UInt32, alpha: Double = 1) {
        self.init(.sRGB,
                  red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255,
                  opacity: alpha)
    }
}

/// Apple-style multicolour glow: blue → indigo → purple → pink → orange.
enum Theme {
    static let blue = Color(hex: 0x0A84FF)
    static let indigo = Color(hex: 0x5E5CE6)
    static let purple = Color(hex: 0xBF5AF2)
    static let pink = Color(hex: 0xFF375F)
    static let orange = Color(hex: 0xFF9F0A)
    static let green = Color(hex: 0x30D158)

    static let colors: [Color] = [blue, indigo, purple, pink, orange]

    static var linear: LinearGradient {
        LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)
    }
    static var diagonal: LinearGradient {
        LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static var cool: LinearGradient {
        LinearGradient(colors: [blue, indigo, purple], startPoint: .topLeading, endPoint: .bottomTrailing)
    }
    static func angular(_ rotation: Double = 0) -> AngularGradient {
        AngularGradient(colors: colors + [blue], center: .center, angle: .degrees(rotation))
    }

    static func statusColor(_ s: TaskStatus) -> Color {
        switch s {
        case .incoming: return purple
        case .active, .inProcess: return blue
        case .complete: return green
        }
    }
}

// MARK: - Background

/// Soft blurred colour blobs behind a material, like the Apple Intelligence glow.
struct GlowBackground: View {
    @Environment(\.colorScheme) var scheme
    var animate = true
    @Local var phase = false

    var body: some View {
        ZStack {
            (scheme == .dark ? Color(hex: 0x0B0B12) : Color(hex: 0xF5F5FA))
            GeometryReader { geo in
                let w = geo.size.width, h = geo.size.height
                ZStack {
                    blob(Theme.blue, size: w * 0.7)
                        .offset(x: phase ? -w * 0.25 : -w * 0.32, y: phase ? -h * 0.32 : -h * 0.22)
                    blob(Theme.purple, size: w * 0.6)
                        .offset(x: phase ? w * 0.30 : w * 0.22, y: phase ? -h * 0.18 : -h * 0.30)
                    blob(Theme.pink, size: w * 0.55)
                        .offset(x: phase ? w * 0.20 : w * 0.32, y: phase ? h * 0.36 : h * 0.26)
                    blob(Theme.orange, size: w * 0.45)
                        .offset(x: phase ? -w * 0.22 : -w * 0.12, y: phase ? h * 0.40 : h * 0.32)
                }
                .frame(width: w, height: h)
            }
            .blur(radius: 90)
            .opacity(scheme == .dark ? 0.55 : 0.35)
            Rectangle().fill(.ultraThinMaterial).opacity(scheme == .dark ? 0.35 : 0.55)
        }
        .ignoresSafeArea()
        .onAppear {
            guard animate else { return }
            withAnimation(.easeInOut(duration: 9).repeatForever(autoreverses: true)) { phase = true }
        }
    }

    private func blob(_ c: Color, size: CGFloat) -> some View {
        Circle().fill(c).frame(width: size, height: size)
    }
}

// MARK: - Card

struct GlassCard: ViewModifier {
    var radius: CGFloat = 18
    var highlight = false
    func body(content: Content) -> some View {
        content
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: radius, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(highlight ? AnyShapeStyle(Theme.diagonal)
                                            : AnyShapeStyle(Color.primary.opacity(0.08)),
                                  lineWidth: highlight ? 1.5 : 1)
            )
            .shadow(color: .black.opacity(0.08), radius: 14, y: 6)
    }
}

extension View {
    func glassCard(radius: CGFloat = 18, highlight: Bool = false) -> some View {
        modifier(GlassCard(radius: radius, highlight: highlight))
    }
    func gradientText() -> some View {
        foregroundStyle(Theme.linear)
    }
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
            .background(Capsule().fill(Theme.linear))
            .overlay(Capsule().strokeBorder(.white.opacity(0.25), lineWidth: 1))
            .shadow(color: Theme.purple.opacity(configuration.isPressed ? 0.2 : 0.4), radius: 10, y: 4)
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
            .background(.thinMaterial, in: Capsule())
            .overlay(Capsule().strokeBorder(Color.primary.opacity(0.10), lineWidth: 1))
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
            .foregroundStyle(filled ? AnyShapeStyle(Color.white) : AnyShapeStyle(HierarchicalShapeStyle.primary))
            .frame(width: size, height: size)
            .background {
                if filled {
                    Circle().fill(Theme.diagonal)
                } else {
                    Circle().fill(.thinMaterial)
                }
            }
            .overlay(Circle().strokeBorder(Color.primary.opacity(filled ? 0 : 0.1), lineWidth: 1))
            .shadow(color: filled ? Theme.purple.opacity(0.35) : .clear, radius: 8, y: 3)
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
