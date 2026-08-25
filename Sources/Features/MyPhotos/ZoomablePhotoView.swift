import SwiftUI
import UIKit

/// Full-photo zoom surface used inside the Gallery pager.
/// One-finger drags belong to the surrounding pager while the photo is at 1x.
/// After zooming, the photo owns one-finger panning until zoom is reset.
struct ZoomablePhotoView: View {
    let image: UIImage
    var minimumZoomScale: CGFloat = 1
    var maximumZoomScale: CGFloat = 5
    var onZoomChanged: (Bool) -> Void = { _ in }

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
        .onDisappear { onZoomChanged(false) }
        .accessibilityHint("Swipe left or right for another photo. Pinch or double-tap to zoom.")
    }

    @ViewBuilder
    private func interactiveImage(in size: CGSize) -> some View {
        if panningEnabled {
            baseImage(in: size)
                .highPriorityGesture(panGesture)
        } else {
            // Do not attach any one-finger drag recognizer at normal size. This
            // leaves horizontal and downward swipes entirely to the Gallery.
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
            .simultaneousGesture(magnificationGesture)
            .onTapGesture(count: 2) {
                withAnimation(.spring(response: 0.26, dampingFraction: 0.88)) {
                    if scale > minimumZoomScale + 0.01 {
                        resetZoom()
                    } else {
                        scale = min(2.5, maximumZoomScale)
                        committedScale = scale
                        panningEnabled = true
                        onZoomChanged(true)
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
                    withAnimation(.easeOut(duration: 0.16)) { resetZoom() }
                } else {
                    panningEnabled = true
                    onZoomChanged(true)
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
        onZoomChanged(false)
    }
}
