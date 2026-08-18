import SwiftUI

/// MyPicsTube visual identity used throughout the MVP.
/// The mark follows the selected people/community logo direction and uses the
/// Sunset Social palette so the brand feels warm, youthful and premium.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            Circle()
                .fill(Theme.brandGradient)

            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.40, weight: .semibold))
                .foregroundStyle(.white)
                .offset(y: size * 0.04)

            Image(systemName: "heart.fill")
                .font(.system(size: size * 0.18, weight: .bold))
                .foregroundStyle(.white)
                .offset(x: size * 0.25, y: -size * 0.23)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.sunset.opacity(0.22), radius: size * 0.13, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

struct BrandWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 8 : 12) {
            BrandMark(size: compact ? 38 : 68)
            HStack(spacing: 0) {
                Text("MyPics")
                    .foregroundStyle(Theme.ink)
                Text("Tube")
                    .foregroundStyle(Theme.sunset)
            }
            .font(compact ? .headline : .system(size: 38, weight: .bold, design: .rounded))
        }
    }
}

struct BrandScreenBackground: View {
    var body: some View {
        LinearGradient(
            colors: [Theme.canvas, Theme.peach.opacity(0.32), Theme.pink.opacity(0.10)],
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
            .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .strokeBorder(Theme.separator.opacity(0.22))
            }
            .shadow(color: Theme.ink.opacity(0.055), radius: 18, y: 8)
    }
}
