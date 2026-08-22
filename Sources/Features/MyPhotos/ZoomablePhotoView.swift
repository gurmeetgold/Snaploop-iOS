import SwiftUI
import UIKit

/// Full-photo viewer used by both Event My Photos and the aggregate Gallery.
/// Supports two-finger pinch zoom, panning while zoomed, and double-tap zoom.
struct ZoomablePhotoView: View {
    let image: UIImage
    var minimumZoomScale: CGFloat = 1
    var maximumZoomScale: CGFloat = 5

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero

    var body: some View {
        GeometryReader { proxy in
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: proxy.size.width, height: proxy.size.height)
                .scaleEffect(scale)
                .offset(offset)
                .contentShape(Rectangle())
                .highPriorityGesture(magnificationGesture)
                .simultaneousGesture(panGesture)
                .onTapGesture(count: 2) {
                    withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                        if scale > minimumZoomScale + 0.01 {
                            resetZoom()
                        } else {
                            scale = min(2.5, maximumZoomScale)
                            committedScale = scale
                        }
                    }
                }
        }
        .clipped()
        .accessibilityHint("Pinch with two fingers to zoom. Double-tap to zoom in or reset.")
    }

    private var magnificationGesture: some Gesture {
        MagnificationGesture()
            .onChanged { value in
                let proposed = committedScale * value
                scale = min(max(proposed, minimumZoomScale), maximumZoomScale)
            }
            .onEnded { _ in
                committedScale = scale
                if scale <= minimumZoomScale + 0.01 {
                    withAnimation(.easeOut(duration: 0.18)) { resetZoom() }
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard scale > minimumZoomScale + 0.01 else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard scale > minimumZoomScale + 0.01 else {
                    resetZoom()
                    return
                }
                committedOffset = offset
            }
    }

    private func resetZoom() {
        scale = minimumZoomScale
        committedScale = minimumZoomScale
        offset = .zero
        committedOffset = .zero
    }
}
