import SwiftUI

/// MyPicsTube visual identity used throughout the MVP.
/// This mark follows the selected three-person / flowing-community logo:
/// coral + lilac + blue on a clean field, paired with the MyPicsTube wordmark.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            // Main flowing loop / center person.
            Circle()
                .trim(from: 0.10, to: 0.88)
                .stroke(
                    LinearGradient(
                        colors: [Theme.coral, Theme.lilac, Theme.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    style: StrokeStyle(lineWidth: size * 0.16, lineCap: .round)
                )
                .rotationEffect(.degrees(-22))
                .frame(width: size * 0.58, height: size * 0.58)
                .offset(y: size * 0.08)

            // Three heads, echoing the approved reference logo.
            Circle()
                .fill(Theme.coral)
                .frame(width: size * 0.19, height: size * 0.19)
                .offset(x: -size * 0.22, y: -size * 0.22)

            Circle()
                .fill(Theme.lilac)
                .frame(width: size * 0.21, height: size * 0.21)
                .offset(y: -size * 0.29)

            Circle()
                .fill(Theme.blue)
                .frame(width: size * 0.18, height: size * 0.18)
                .offset(x: size * 0.22, y: -size * 0.17)

            // Side shoulders give the mark a friendly community silhouette.
            Capsule()
                .fill(Theme.coral.opacity(0.92))
                .frame(width: size * 0.30, height: size * 0.13)
                .rotationEffect(.degrees(-28))
                .offset(x: -size * 0.18, y: size * 0.03)

            Capsule()
                .fill(Theme.blue.opacity(0.92))
                .frame(width: size * 0.28, height: size * 0.12)
                .rotationEffect(.degrees(29))
                .offset(x: size * 0.19, y: size * 0.06)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.lilac.opacity(0.18), radius: size * 0.11, y: size * 0.05)
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
