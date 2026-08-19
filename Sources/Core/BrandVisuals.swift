import SwiftUI

/// MyPicsRoom visual identity used throughout the MVP.
/// Camera-first, light and compact: inspired by the simple camera + wordmark
/// treatment the product team selected, while remaining an original mark.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            // Camera body: deliberately simple so it still reads at tab/icon size.
            RoundedRectangle(cornerRadius: size * 0.22, style: .continuous)
                .strokeBorder(Theme.coral, lineWidth: max(2, size * 0.075))
                .frame(width: size * 0.92, height: size * 0.68)
                .offset(y: size * 0.07)

            RoundedRectangle(cornerRadius: size * 0.06, style: .continuous)
                .fill(Theme.coral)
                .frame(width: size * 0.30, height: size * 0.12)
                .offset(x: -size * 0.18, y: -size * 0.31)

            Circle()
                .fill(.white)
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
                Text("MyPics")
                    .foregroundStyle(Theme.coral)
                Text("Room")
                    .foregroundStyle(Theme.blue)
            }
            .font(compact ? .system(.headline, design: .rounded, weight: .bold) : .system(size: 34, weight: .bold, design: .rounded))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("MyPicsRoom")
    }
}

struct BrandScreenBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.canvas, Theme.coralSoft.opacity(0.32), Theme.lilacSoft.opacity(0.26)],
            startPoint: .topLeading,
            endPoint: .bottomTrailing
        )
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
            .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.16))
            }
            .shadow(color: Theme.navy.opacity(0.065), radius: 18, y: 8)
    }
}
