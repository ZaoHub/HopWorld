import SwiftUI

/// Keep shadow parameters fixed while animating the card.
struct WarmCardHover: ViewModifier {
    @Environment(\.colorScheme) private var scheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var isHovered = false

    var cornerRadius: CGFloat = 8
    var fill: Color = .clear
    var baseFill: Color = .clear

    private var warmth: Color {
        scheme == .dark
            ? Color(red: 1, green: 0.62, blue: 0.25)
            : Color(red: 0.80, green: 0.42, blue: 0.08)
    }

    func body(content: Content) -> some View {
        let shape = RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
        content
            .clipShape(shape)
            .background {
                ZStack {
                    shape.fill(baseFill)
                    // Keep both blurs fixed; animate their opacity instead of shadow colors.
                    shape.fill(scheme == .dark ? Color(white: 0.15) : .white)
                        .shadow(color: warmth.opacity(0.10), radius: 10)
                        .shadow(color: .black.opacity(scheme == .dark ? 0.24 : 0.14), radius: 8, y: 3)
                        .opacity(isHovered ? 1 : 0)
                    shape.fill(fill)
                    shape.fill(LinearGradient(
                        colors: [warmth.opacity(scheme == .dark ? 0.16 : 0.09), .clear],
                        startPoint: .topLeading, endPoint: .bottomTrailing
                    ))
                    .opacity(isHovered ? 1 : 0)
                }
            }
            .contentShape(shape)
            .scaleEffect(isHovered && !reduceMotion ? 1.015 : 1)
            .animation(reduceMotion ? nil : .easeOut(duration: 0.16), value: isHovered)
            .zIndex(isHovered ? 1 : 0)
            .onHover { isHovered = $0 }
            .onDisappear { isHovered = false }
    }
}
