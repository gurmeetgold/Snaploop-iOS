import SwiftUI
import UIKit

/// Exact production SnapLoop mark supplied for the app icon and in-app branding.
/// Keeping one raster source prevents the S/aperture geometry from drifting between screens.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        Image("SnapLoopBrandMark")
            .resizable()
            .interpolation(.high)
            .antialiased(true)
            .scaledToFit()
            .frame(width: size, height: size)
            .shadow(color: Theme.hotPink.opacity(0.24), radius: size * 0.10, y: size * 0.035)
            .accessibilityHidden(true)
    }
}

struct BrandWordmark: View {
    var compact = false

    var body: some View {
        HStack(spacing: compact ? 6 : 9) {
            BrandMark(size: compact ? 30 : 48)
            Text("SnapLoop")
                .font(compact ? .system(.headline, design: .rounded, weight: .bold) : .system(size: 34, weight: .bold, design: .rounded))
                .foregroundStyle(Theme.brandGradient)
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
                    colors: [Theme.lilac.opacity(0.16), Theme.canvas.opacity(0.0)],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 540
                )
                RadialGradient(
                    colors: [Theme.hotPink.opacity(0.12), Theme.canvas.opacity(0.0)],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 520
                )
            } else {
                LinearGradient(
                    colors: [
                        Color.white,
                        Color(red: 1.00, green: 0.975, blue: 0.985),
                        Color(red: 0.985, green: 0.970, blue: 1.00),
                        Color.white
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
                RadialGradient(
                    colors: [Theme.hotPink.opacity(0.055), .clear],
                    center: .bottomLeading,
                    startRadius: 10,
                    endRadius: 430
                )
                RadialGradient(
                    colors: [Theme.lilac.opacity(0.045), .clear],
                    center: .topTrailing,
                    startRadius: 10,
                    endRadius: 430
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
            .shadow(color: Theme.hotPink.opacity(0.08), radius: 18, y: 8)
    }
}
