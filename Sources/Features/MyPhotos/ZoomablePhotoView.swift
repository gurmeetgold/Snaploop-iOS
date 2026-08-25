import SwiftUI
import UIKit

/// Full-photo viewer used by both Event My Photos and the aggregate Gallery.
/// At normal size, horizontal drags are intentionally left to the surrounding
/// Gallery pager. The photo only owns pan gestures after the user has zoomed.
/// A downward, vertical-dominant swipe at 1x dismisses the full-photo view to
/// match the interaction users expect from Apple Photos.
struct ZoomablePhotoView: View {
    let image: UIImage
    var minimumZoomScale: CGFloat = 1
    var maximumZoomScale: CGFloat = 5

    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1
    @State private var committedScale: CGFloat = 1
    @State private var offset: CGSize = .zero
    @State private var committedOffset: CGSize = .zero
    @State private var panningEnabled = false
    @GestureState private var dismissOffset: CGFloat = 0

    var body: some View {
        GeometryReader { proxy in
            interactiveImage(in: proxy.size)
        }
        .offset(y: panningEnabled ? 0 : max(0, dismissOffset))
        .opacity(panningEnabled ? 1 : 1 - min(max(0, dismissOffset) / 900, 0.22))
        .clipped()
        .toolbar(.hidden, for: .tabBar)
        .accessibilityHint("Swipe left or right for another photo. Swipe down to close. Pinch or double-tap to zoom.")
    }

    @ViewBuilder
    private func interactiveImage(in size: CGSize) -> some View {
        if panningEnabled {
            baseImage(in: size)
                .simultaneousGesture(panGesture)
        } else {
            // Keep horizontal paging owned by the surrounding Gallery. This
            // recognizer observes the drag simultaneously and acts only when
            // the gesture is clearly downward and vertical-dominant.
            baseImage(in: size)
                .simultaneousGesture(verticalDismissGesture)
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

    private var verticalDismissGesture: some Gesture {
        DragGesture(minimumDistance: 12)
            .updating($dismissOffset) { value, state, _ in
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                if vertical > 0, vertical > horizontal * 1.15 {
                    state = vertical
                }
            }
            .onEnded { value in
                let vertical = value.translation.height
                let horizontal = abs(value.translation.width)
                guard vertical > 110, vertical > horizontal * 1.15 else { return }
                dismiss()
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
