import SwiftUI
import UIKit

/// SnapLoop visual identity used throughout the app.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(
                    LinearGradient(
                        colors: [Theme.coral, Theme.pink, Theme.lilac, Theme.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Camera body.
            RoundedRectangle(cornerRadius: size * 0.12, style: .continuous)
                .fill(.white)
                .frame(width: size * 0.58, height: size * 0.42)
                .offset(y: size * 0.02)

            RoundedRectangle(cornerRadius: size * 0.045, style: .continuous)
                .fill(.white)
                .frame(width: size * 0.22, height: size * 0.09)
                .offset(x: -size * 0.12, y: -size * 0.22)

            // Friendly face inside the camera lens.
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.pink, Theme.lilac, Theme.blue],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )
                .frame(width: size * 0.30, height: size * 0.30)
                .offset(y: size * 0.02)

            HStack(spacing: size * 0.075) {
                Circle().fill(.white)
                Circle().fill(.white)
            }
            .frame(width: size * 0.15, height: size * 0.035)
            .offset(y: -size * 0.015)

            Capsule()
                .trim(from: 0.0, to: 0.55)
                .stroke(.white, style: StrokeStyle(lineWidth: max(2, size * 0.035), lineCap: .round))
                .rotationEffect(.degrees(22))
                .frame(width: size * 0.15, height: size * 0.09)
                .offset(y: size * 0.075)

            // Face-finder corner brackets.
            finderCorner
                .rotationEffect(.degrees(0))
                .offset(x: -size * 0.31, y: -size * 0.27)
            finderCorner
                .rotationEffect(.degrees(90))
                .offset(x: size * 0.31, y: -size * 0.27)
            finderCorner
                .rotationEffect(.degrees(270))
                .offset(x: -size * 0.31, y: size * 0.27)
            finderCorner
                .rotationEffect(.degrees(180))
                .offset(x: size * 0.31, y: size * 0.27)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.lilac.opacity(0.18), radius: size * 0.10, y: size * 0.04)
        .accessibilityHidden(true)
    }

    private var finderCorner: some View {
        Path { path in
            path.move(to: CGPoint(x: 0, y: size * 0.12))
            path.addLine(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: size * 0.12, y: 0))
        }
        .stroke(.white.opacity(0.96), style: StrokeStyle(lineWidth: max(2, size * 0.035), lineCap: .round, lineJoin: .round))
        .frame(width: size * 0.12, height: size * 0.12)
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
