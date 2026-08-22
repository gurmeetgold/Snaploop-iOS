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
                // Neutral white base with restrained pink/violet bloom. Avoids the old
                // peach/golden cast while letting the saturated controls stay crisp.
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

/// Shared full-photo viewer used by Gallery and Event My Photos.
/// Pinch to zoom up to 5x, drag while zoomed, or double-tap to zoom/reset.
struct ZoomablePhotoView: View {
    let image: UIImage

    @State private var scale: CGFloat = 1
    @State private var baseScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var baseOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .highPriorityGesture(magnifyGesture)
                .simultaneousGesture(dragGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.snappy) {
                        if scale > 1.05 {
                            resetZoom()
                        } else {
                            scale = 2.5
                            baseScale = 2.5
                        }
                    }
                }
        }
        .clipped()
    }

    private var magnifyGesture: some Gesture {
        MagnifyGesture()
            .onChanged { value in
                scale = min(max(baseScale * value.magnification, 1), 5)
                if scale <= 1.01 { offset = .zero }
            }
            .onEnded { _ in
                baseScale = scale
                if scale <= 1.01 { resetZoom() }
            }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                guard scale > 1.01 else { return }
                offset = CGSize(
                    width: baseOffset.width + value.translation.width,
                    height: baseOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > 1.01 else {
                    resetZoom()
                    return
                }
                baseOffset = offset
            }
    }

    private func resetZoom() {
        scale = 1
        baseScale = 1
        offset = .zero
        baseOffset = .zero
    }
}