import SwiftUI

/// SnapLoop's visual design system: color tokens, gradients, and shared
/// geometry constants. Centralizing these is what lets every screen read as
/// one product instead of a pile of ad hoc styling.
///
/// Palette: warm coral primary (matches the camera/brand mark), sky blue
/// secondary (shared/social surfaces), violet accent (AI-touched surfaces —
/// Highlights — kept visually distinct so users learn "purple = AI, and it's
/// always optional"), soft peach-to-lavender backgrounds.
public enum Theme {

    // MARK: Brand colors
    public static let coral = Color(red: 1.00, green: 0.44, blue: 0.35)      // primary CTA / "you" surfaces
    public static let coralDeep = Color(red: 0.96, green: 0.34, blue: 0.27)
    public static let sky = Color(red: 0.29, green: 0.65, blue: 0.94)        // shared/social surfaces
    public static let skyDeep = Color(red: 0.18, green: 0.52, blue: 0.86)
    public static let violet = Color(red: 0.55, green: 0.47, blue: 0.94)     // AI-touched surfaces
    public static let violetDeep = Color(red: 0.44, green: 0.36, blue: 0.86)
    public static let amber = Color(red: 0.98, green: 0.70, blue: 0.24)      // highlights / delight accents
    public static let ink = Color(red: 0.10, green: 0.13, blue: 0.22)        // headline text

    /// Card hairline color. `ShapeStyle.separator` (bare `.separator`) is an
    /// iOS 17 API; this UIColor-bridged form works back to iOS 13 and keeps the
    /// app on its iOS 16 deployment target.
    public static let separator = Color(uiColor: .separator)

    // MARK: Gradients (used on hero covers, stat tiles, dashboard cards)
    public static let coralGradient = LinearGradient(
        colors: [coral, coralDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let skyGradient = LinearGradient(
        colors: [sky, skyDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let violetGradient = LinearGradient(
        colors: [violet, violetDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let amberGradient = LinearGradient(
        colors: [amber, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    /// Soft background wash for insight/stat banners.
    public static let softWash = LinearGradient(
        colors: [coral.opacity(0.12), violet.opacity(0.10)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: Geometry
    public static let cardRadius: CGFloat = 20
    public static let tileRadius: CGFloat = 18
    public static let chipRadius: CGFloat = 20

    /// Maps an event's phase to a tint, reused across pills/badges everywhere.
    public static func tint(for status: EventLifecycle.Status) -> Color {
        switch status {
        case .upcoming: return sky
        case .active: return .green
        case .grace: return amber
        case .expired: return .secondary
        }
    }
}

/// A reusable gradient tile, the building block of the dashboard's 2×2 grid and
/// the highlights category cards.
struct GradientTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: LinearGradient
    var badge: String?
    var height: CGFloat = 110

    var body: some View {
        ZStack(alignment: .topLeading) {
            gradient
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    Image(systemName: systemImage)
                        .font(.title2)
                        .foregroundStyle(.white)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.caption).bold()
                            .padding(.horizontal, 8).padding(.vertical, 3)
                            .background(.white.opacity(0.25), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.85))
            }
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius))
    }
}

/// The pill-shaped filter chip used on My Photos / Shared Album.
struct FilterChip: View {
    let title: String
    let systemImage: String?
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.subheadline).bold()
            .padding(.horizontal, 14).padding(.vertical, 8)
            .background(isSelected ? AnyShapeStyle(Theme.coral) : AnyShapeStyle(.thinMaterial),
                       in: Capsule())
            .foregroundStyle(isSelected ? .white : .primary)
            .overlay(
                Capsule().strokeBorder(isSelected ? .clear : Color.secondary.opacity(0.25))
            )
        }
        .buttonStyle(.plain)
    }
}

/// A soft, gradient-washed stat banner ("128 photos of you ✨").
struct InsightBanner: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 14).fill(Theme.violet.opacity(0.18))
                Image(systemName: systemImage).font(.title2).foregroundStyle(Theme.violet)
            }
            .frame(width: 52, height: 52)

            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title).bold().foregroundStyle(Theme.ink)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles").foregroundStyle(Theme.violet.opacity(0.6))
        }
        .padding(16)
        .background(Theme.softWash, in: RoundedRectangle(cornerRadius: Theme.cardRadius))
    }
}
