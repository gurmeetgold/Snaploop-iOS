import SwiftUI

/// MyPicsTube visual identity used throughout the MVP.
/// The mark is camera-first, echoing the compact camera-view treatment from the
/// selected reference while staying original to MyPicsTube and Coral Luxe.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(.white.opacity(0.97))
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(Theme.coral, lineWidth: max(2, size * 0.055))
                }

            Circle()
                .strokeBorder(
                    LinearGradient(
                        colors: [Theme.coral, Theme.lilac, Theme.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: max(2, size * 0.06)
                )
                .frame(width: size * 0.42, height: size * 0.42)

            Circle()
                .fill(Theme.blue)
                .frame(width: size * 0.10, height: size * 0.10)
                .offset(x: size * 0.28, y: -size * 0.24)

            RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                .fill(Theme.coral)
                .frame(width: size * 0.28, height: size * 0.095)
                .offset(x: -size * 0.18, y: -size * 0.43)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.coral.opacity(0.16), radius: size * 0.11, y: size * 0.05)
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
                    .foregroundStyle(Theme.navy)
                Text("Tube")
                    .foregroundStyle(Theme.coral)
            }
            .font(compact ? .headline : .system(size: 38, weight: .bold, design: .rounded))
        }
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
