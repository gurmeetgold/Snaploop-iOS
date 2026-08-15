import SwiftUI

/// Placeholder shell; the curation engine and grid are built in Phase 4.
struct HighlightsView: View {
    let event: Event
    var body: some View {
        ContentUnavailableViewCompat(
            title: "Highlights",
            message: "Your best moments from this event will appear here.",
            systemImage: "sparkles")
        .navigationTitle("Highlights")
        .navigationBarTitleDisplayMode(.inline)
    }
}
