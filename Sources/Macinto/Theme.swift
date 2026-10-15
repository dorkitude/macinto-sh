import AppKit
import SwiftUI

/// Tokyo Night palette and the custom controls used by the control window, onboarding and tutorial.
enum TN {
    static let bg = Color(hex: 0x1a1b26)
    static let bgDeep = Color(hex: 0x16161e)
    static let surface = Color(hex: 0x24283b)
    static let border = Color(hex: 0x292e42)
    static let borderHi = Color(hex: 0x3b4261)
    static let text = Color(hex: 0xc0caf5)
    static let text2 = Color(hex: 0xa9b1d6)
    static let muted = Color(hex: 0x565f89)
    static let blue = Color(hex: 0x7aa2f7)
    static let cyan = Color(hex: 0x7dcfff)
    static let purple = Color(hex: 0xbb9af7)
    static let magenta = Color(hex: 0xff007c)
    static let green = Color(hex: 0x9ece6a)
    static let red = Color(hex: 0xf7768e)
    static let orange = Color(hex: 0xff9e64)
    static let yellow = Color(hex: 0xe0af68)

    static let nsBg = NSColor(srgbRed: 0x1a / 255, green: 0x1b / 255, blue: 0x26 / 255, alpha: 1)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

extension Color {
    init(hex: UInt32) {
        self.init(.sRGB, red: Double((hex >> 16) & 0xff) / 255, green: Double((hex >> 8) & 0xff) / 255,
                  blue: Double(hex & 0xff) / 255)
    }
}

/// Rounded surface with a hairline border.
struct Card: ViewModifier {
    var padding: CGFloat = 12
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(TN.surface))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(TN.border, lineWidth: 1))
    }
}

extension View {
    func card(padding: CGFloat = 12) -> some View { modifier(Card(padding: padding)) }
}

/// Gradient pill with a soft glow. Used for the one main action on each screen.
struct PrimaryButtonStyle: ButtonStyle {
    var colors: [Color] = [TN.blue, TN.purple]
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1).fixedSize()
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(TN.bgDeep)
            .padding(.horizontal, 14).padding(.vertical, 7)
            .background(Capsule().fill(LinearGradient(colors: colors, startPoint: .leading, endPoint: .trailing)))
            .shadow(color: colors.first!.opacity(configuration.isPressed ? 0.2 : 0.45), radius: 8)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .contentShape(Capsule())
    }
}

/// Outlined pill in an accent color.
struct OutlineButtonStyle: ButtonStyle {
    var color: Color = TN.blue
    var small = false
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1).fixedSize()
            .font(.system(size: small ? 11 : 13, weight: .medium))
            .foregroundStyle(color)
            .padding(.horizontal, small ? 9 : 14).padding(.vertical, small ? 4 : 7)
            .background(Capsule().fill(color.opacity(configuration.isPressed ? 0.22 : 0.1)))
            .overlay(Capsule().strokeBorder(color.opacity(0.55), lineWidth: 1))
            .contentShape(Capsule())
    }
}

/// Text-only footer button.
struct GhostButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .lineLimit(1).fixedSize()
            .font(.system(size: 11, weight: .medium))
            .foregroundStyle(configuration.isPressed ? TN.text : TN.text2)
            .padding(.horizontal, 7).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 6).fill(configuration.isPressed ? TN.borderHi : TN.border))
            .contentShape(Rectangle())
    }
}

/// A notched slider: one notch per index in 0..<count. Click or drag anywhere on the track.
struct NotchSlider: View {
    @Binding var index: Int
    let count: Int
    var label: (Int) -> String

    private let thumb: CGFloat = 16

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width - thumb
            let step = w / CGFloat(max(count - 1, 1))
            let x = CGFloat(index) * step
            ZStack(alignment: .leading) {
                Capsule().fill(TN.bgDeep).frame(height: 6)
                    .overlay(Capsule().strokeBorder(TN.border, lineWidth: 1))
                    .padding(.horizontal, thumb / 2)
                Capsule()
                    .fill(LinearGradient(colors: [TN.cyan, TN.blue, TN.purple], startPoint: .leading, endPoint: .trailing))
                    .frame(width: x + 6, height: 6)
                    .padding(.leading, thumb / 2 - 3)
                ForEach(0..<count, id: \.self) { i in
                    Circle().fill(i <= index ? TN.bgDeep.opacity(0.6) : TN.borderHi)
                        .frame(width: 3, height: 3)
                        .offset(x: CGFloat(i) * step + thumb / 2 - 1.5)
                }
                Circle()
                    .fill(TN.text)
                    .overlay(Circle().strokeBorder(TN.blue, lineWidth: 2))
                    .frame(width: thumb, height: thumb)
                    .shadow(color: TN.blue.opacity(0.7), radius: 5)
                    .offset(x: x)
            }
            .frame(height: geo.size.height)
            .contentShape(Rectangle())
            .gesture(DragGesture(minimumDistance: 0).onChanged { g in
                let i = Int(((g.location.x - thumb / 2) / step).rounded())
                let clamped = min(max(i, 0), count - 1)
                if clamped != index { index = clamped }
            })
        }
        .frame(height: 20)
        .accessibilityElement()
        .accessibilityLabel("Duration")
        .accessibilityValue(label(index))
        .accessibilityAdjustableAction { dir in
            switch dir {
            case .increment: index = min(index + 1, count - 1)
            case .decrement: index = max(index - 1, 0)
            @unknown default: break
            }
        }
    }
}

/// The overlay's apple: the same emoji image, red glow and 0.6 s fade/scale pulse.
struct PulsingApple: View {
    var size: CGFloat = Overlay.size
    var glow: CGFloat = 8
    @State private var on = false
    /// Off in snapshot renders, so the image shows the apple at full size and opacity.
    nonisolated(unsafe) static var animates = true

    var body: some View {
        Image(nsImage: AppleImage.emoji(pointSize: size * 0.82, canvas: size))
            .resizable()
            .frame(width: size, height: size)
            .shadow(color: Color(nsColor: .systemRed).opacity(0.8), radius: glow)
            .opacity(on ? 0.25 : 1)
            .scaleEffect(on ? 0.82 : 1)
            .onAppear {
                guard Self.animates else { return }
                withAnimation(.easeInOut(duration: 0.6).repeatForever(autoreverses: true)) { on = true }
            }
    }
}
