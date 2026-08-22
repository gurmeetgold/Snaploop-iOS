import SwiftUI
import UIKit

/// SnapLoop production brand mark: vivid social-photo gradient + white S + aperture.
/// Built from scalable vector primitives so it stays crisp and never clips at small sizes.
struct BrandMark: View {
    var size: CGFloat = 72

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                .fill(Theme.brandGradient)
                .overlay {
                    LinearGradient(
                        colors: [.white.opacity(0.20), .clear, .black.opacity(0.06)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                    .clipShape(RoundedRectangle(cornerRadius: size * 0.24, style: .continuous))
                }
                .overlay {
                    RoundedRectangle(cornerRadius: size * 0.24, style: .continuous)
                        .strokeBorder(.white.opacity(0.28), lineWidth: max(1, size * 0.012))
                }

            Text("S")
                .font(.system(size: size * 0.74, weight: .heavy, design: .rounded))
                .foregroundStyle(.white)
                .minimumScaleFactor(1)
                .shadow(color: .black.opacity(0.16), radius: size * 0.025, y: size * 0.018)
                .offset(y: -size * 0.006)

            ApertureMark(size: size * 0.31)
                .shadow(color: .black.opacity(0.18), radius: size * 0.026, y: size * 0.012)
        }
        .frame(width: size, height: size)
        .shadow(color: Theme.hotPink.opacity(0.22), radius: size * 0.10, y: size * 0.035)
        .accessibilityHidden(true)
    }
}

private struct ApertureMark: View {
    let size: CGFloat

    var body: some View {
        ZStack {
            Circle()
                .fill(
                    LinearGradient(
                        colors: [Theme.coralDeep, Theme.hotPink, Theme.magenta, Theme.violetDeep],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            ForEach(0..<6, id: \.self) { index in
                ApertureBlade()
                    .fill(.white.opacity(0.98))
                    .rotationEffect(.degrees(Double(index) * 60))
            }

            Circle()
                .fill(Theme.magenta)
                .frame(width: size * 0.18, height: size * 0.18)
        }
        .frame(width: size, height: size)
    }
}

private struct ApertureBlade: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: rect.midX, y: rect.minY + rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX * 0.83, y: rect.minY + rect.height * 0.28))
        path.addLine(to: CGPoint(x: rect.maxX * 0.64, y: rect.midY))
        path.addLine(to: c)
        path.closeSubpath()
        return path
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
                    colors: [Theme.lilac.opacity(0.14), Theme.canvas.opacity(0.0)],
                    center: .topTrailing,
                    startRadius: 20,
                    endRadius: 540
                )
                RadialGradient(
                    colors: [Theme.hotPink.opacity(0.10), Theme.canvas.opacity(0.0)],
                    center: .bottomLeading,
                    startRadius: 20,
                    endRadius: 520
                )
            } else {
                LinearGradient(
                    colors: [
                        Color.white,
                        Color(red: 1.00, green: 0.96, blue: 0.94),
                        Color(red: 1.00, green: 0.95, blue: 0.98),
                        Color(red: 0.97, green: 0.95, blue: 1.00)
                    ],
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
            .shadow(color: Theme.hotPink.opacity(0.07), radius: 18, y: 8)
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
