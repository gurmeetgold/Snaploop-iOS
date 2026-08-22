import SwiftUI

/// SnapLoop visual identity used throughout the app.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Theme.coral, lineWidth: max(2, size * 0.075))
                .frame(width: size * 0.92, height: size * 0.68)
                .offset(y: size * 0.07)

            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Theme.coral)
                .frame(width: size * 0.30, height: size * 0.12)
                .offset(x: -size * 0.18, y: -size * 0.31)

            Circle()
                .fill(Theme.surface)
                .overlay {
                    Circle().strokeBorder(Theme.blue, lineWidth: max(2, size * 0.075))
                }
                .frame(width: size * 0.36, height: size * 0.36)
                .offset(y: size * 0.07)

            Circle()
                .fill(Theme.lilac)
                .frame(width: size * 0.11, height: size * 0.11)
                .offset(x: size * 0.28, y: -size * 0.05)
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

struct BrandWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 9) {
            BrandMark(size: compact ? 30 : 48)
            HStack(spacing: 0) {
                Text("Snap").foregroundStyle(Theme.coral)
                Text("Loop").foregroundStyle(Theme.blue)
            }
            .font(compact ? .system(.headline, design: .rounded, weight: .bold) : .system(size: 34, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("SnapLoop")
    }
}

struct BrandScreenBackground: View {
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack {
            Theme.canvas
            if colorScheme == .dark {
                RadialGradient(
                    colors: [Theme.blue.opacity(0.10), Theme.canvas.opacity(0.0)],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 520
                )
                RadialGradient(
                    colors: [Theme.lilac.opacity(0.08), Theme.canvas.opacity(0.0)],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 520
                )
            } else {
                LinearGradient(
                    colors: [Color.white, Theme.blueSoft.opacity(0.18), Theme.lilacSoft.opacity(0.20)],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            }
        }
        .ignoresSafeArea()
    }
}

struct PremiumCard<Content: View>: View {
    @ViewBuilder let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        content
            .padding(16)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.divider)
            }
            .shadow(color: Color.black.opacity(0.10), radius: 18, y: 8)
    }
}
