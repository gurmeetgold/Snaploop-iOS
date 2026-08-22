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
                        colors: [
                            Color(red: 1.00, green: 0.32, blue: 0.18),
                            Color(red: 1.00, green: 0.08, blue: 0.48),
                            Color(red: 0.74, green: 0.08, blue: 1.00),
                            Color(red: 0.14, green: 0.24, blue: 1.00)
                        ],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    )
                )

            // Bold white S loop.
            SnapLoopSShape()
                .stroke(
                    .white,
                    style: StrokeStyle(
                        lineWidth: max(4, size * 0.145),
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
                .frame(width: size * 0.58, height: size * 0.64)

            // Camera shutter at the center of the S.
            ZStack {
                Circle()
                    .fill(Color(red: 0.48, green: 0.02, blue: 0.46).opacity(0.96))
                ForEach(0..<6, id: \.self) { index in
                    ShutterBladeShape()
                        .fill(.white.opacity(0.96))
                        .rotationEffect(.degrees(Double(index) * 60))
                }
                Circle()
                    .fill(Color(red: 0.69, green: 0.04, blue: 0.75))
                    .frame(width: size * 0.085, height: size * 0.085)
            }
            .frame(width: size * 0.31, height: size * 0.31)
            .shadow(color: .black.opacity(0.16), radius: size * 0.025, y: size * 0.012)
        }
        .frame(width: size, height: size)
        .shadow(color: Color(red: 0.66, green: 0.10, blue: 1.0).opacity(0.26), radius: size * 0.12, y: size * 0.04)
        .accessibilityHidden(true)
    }
}

private struct SnapLoopSShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.maxX * 0.78, y: rect.minY + rect.height * 0.12))
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.38, y: rect.minY + rect.height * 0.12))
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.34, y: rect.midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.minY + rect.height * 0.12),
            control2: CGPoint(x: rect.minX + rect.width * 0.12, y: rect.midY - rect.height * 0.06)
        )
        path.addCurve(
            to: CGPoint(x: rect.maxX * 0.66, y: rect.midY),
            control1: CGPoint(x: rect.minX + rect.width * 0.43, y: rect.midY + rect.height * 0.02),
            control2: CGPoint(x: rect.maxX * 0.57, y: rect.midY - rect.height * 0.02)
        )
        path.addCurve(
            to: CGPoint(x: rect.minX + rect.width * 0.22, y: rect.maxY * 0.88),
            control1: CGPoint(x: rect.maxX * 0.88, y: rect.midY + rect.height * 0.02),
            control2: CGPoint(x: rect.maxX * 0.88, y: rect.maxY * 0.88)
        )
        path.addLine(to: CGPoint(x: rect.minX + rect.width * 0.62, y: rect.maxY * 0.88))
        return path
    }
}

private struct ShutterBladeShape: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        let c = CGPoint(x: rect.midX, y: rect.midY)
        path.move(to: CGPoint(x: c.x, y: rect.minY + rect.height * 0.08))
        path.addLine(to: CGPoint(x: rect.maxX * 0.82, y: rect.minY + rect.height * 0.25))
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
            HStack(spacing: 0) {
                Text("Snap")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 1.00, green: 0.28, blue: 0.20),
                                Color(red: 1.00, green: 0.08, blue: 0.48)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
                Text("Loop")
                    .foregroundStyle(
                        LinearGradient(
                            colors: [
                                Color(red: 0.92, green: 0.04, blue: 0.88),
                                Color(red: 0.55, green: 0.06, blue: 1.00),
                                Color(red: 0.12, green: 0.28, blue: 1.00)
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                    )
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
