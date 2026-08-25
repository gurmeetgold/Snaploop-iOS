import SwiftUI
import UIKit

/// Full-photo viewer used by both Event My Photos and the aggregate Gallery.
/// At normal size, horizontal drags are intentionally left to the surrounding
/// Gallery pager. The photo only owns drag gestures after the user has zoomed.
struct ZoomablePhotoView: View {
    let image: UIImage
    var minimumZoomScale: CGFloat = 1
    var maximumZoomScale: CGFloat = 5

    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var panningEnabled = false

    var body: some View {
        GeometryReader { proxy in
            interactiveImage(in: proxy.size)
        }
        .clipped()
        .accessibilityHint("Swipe left or right for another photo. Pinch or double-tap to zoom.")
    }

    @ViewBuilder
    private func interactiveImage(in size: CGSize) -> some View {
        if panningEnabled {
            baseImage(in: size)
                .simultaneousGesture(panGesture)
        } else {
            // Do not install a DragGesture at 1x. Even a drag handler whose
            // callbacks immediately return can still compete with TabView's
            // paging recognizer and make left/right navigation feel broken.
            baseImage(in: size)
        }
    }

    private func baseImage(in size: CGSize) -> some View {
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(width: size.width, height: size.height)
            .scaleEffect(scale)
            .offset(offset)
            .contentShape(Rectangle())
            .highPriorityGesture(magnificationGesture)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.28, dampingFraction: 0.86)) {
                    if scale > minimumZoomScale + 0.01 {
                        resetZoom()
                    } else {
                        scale = min(2.5, maximumZoomScale)
                        committedScale = scale
                        panningEnabled = true
                    }
                }
            }
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
                } else {
                    panningEnabled = true
                }
            }
    }

    private var panGesture: some Gesture {
        DragGesture(minimumDistance: 2)
            .onChanged { value in
                guard panningEnabled else { return }
                offset = CGSize(
                    width: committedOffset.width + value.translation.width,
                    height: committedOffset.height + value.translation.height
                )
            }
            .onEnded { _ in
                guard panningEnabled else {
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
        panningEnabled = false
    }
}
