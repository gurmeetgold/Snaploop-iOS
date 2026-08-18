import SwiftUI

/// MyPicsTube "Sunset Social" design system.
/// Warm sunset coral and pink carry personal-photo actions, aqua/blue signals
/// shared/social surfaces, and soft cream keeps the product bright and premium.
public enum Theme {

    // MARK: Brand colors
    public static let sunset = Color(red: 1.00, green: 0.42, blue: 0.29)     // #FF6B4A
    public static let sunsetDeep = Color(red: 0.96, green: 0.30, blue: 0.30)
    public static let pink = Color(red: 0.98, green: 0.38, blue: 0.55)
    public static let peach = Color(red: 1.00, green: 0.77, blue: 0.63)
    public static let aqua = Color(red: 0.10, green: 0.78, blue: 0.75)
    public static let sky = Color(red: 0.25, green: 0.61, blue: 0.97)
    public static let violet = Color(red: 0.55, green: 0.42, blue: 0.95)
    public static let amber = Color(red: 0.98, green: 0.68, blue: 0.23)
    public static let ink = Color(red: 0.08, green: 0.11, blue: 0.20)
    public static let canvas = Color(red: 0.985, green: 0.977, blue: 0.968)

    // Compatibility aliases while older screens are migrated.
    public static let coral = sunset
    public static let coralDeep = sunsetDeep
    public static let skyDeep = Color(red: 0.12, green: 0.49, blue: 0.90)
    public static let violetDeep = Color(red: 0.43, green: 0.31, blue: 0.86)

    public static let separator = Color(uiColor: .separator)

    // MARK: Gradients
    public static let brandGradient = LinearGradient(
        colors: [sunset, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let coralGradient = brandGradient
    public static let sunsetGradient = LinearGradient(
        colors: [sunset, peach], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let socialGradient = LinearGradient(
        colors: [sky, aqua], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let skyGradient = socialGradient
    public static let violetGradient = LinearGradient(
        colors: [violet, pink], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let amberGradient = LinearGradient(
        colors: [amber, sunset], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let softWash = LinearGradient(
        colors: [peach.opacity(0.30), pink.opacity(0.11), violet.opacity(0.10)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: Geometry
    public static let cardRadius: CGFloat = 24
    public static let tileRadius: CGFloat = 22
    public static let chipRadius: CGFloat = 22

    public static func tint(for status: EventLifecycle.Status) -> Color {
        switch status {
        case .upcoming: return sky
        case .active: return Color(red: 0.10, green: 0.70, blue: 0.38)
        case .grace: return amber
        case .expired: return .secondary
        }
    }
}

struct GradientTile: View {
    let title: String
    let subtitle: String
    let systemImage: String
    let gradient: LinearGradient
    var badge: String?
    var height: CGFloat = 118

    var body: some View {
        ZStack(alignment: .topLeading) {
            gradient
            Circle()
                .fill(.white.opacity(0.12))
                .frame(width: 100, height: 100)
                .offset(x: 78, y: -38)

            VStack(alignment: .leading, spacing: 7) {
                HStack {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(.white.opacity(0.20))
                        Image(systemName: systemImage)
                            .font(.headline)
                            .foregroundStyle(.white)
                    }
                    .frame(width: 40, height: 40)
                    Spacer()
                    if let badge {
                        Text(badge)
                            .font(.caption2).bold()
                            .padding(.horizontal, 8).padding(.vertical, 4)
                            .background(.white.opacity(0.22), in: Capsule())
                            .foregroundStyle(.white)
                    }
                }
                Spacer()
                Text(title).font(.headline).foregroundStyle(.white)
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.88))
            }
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .shadow(color: Theme.ink.opacity(0.08), radius: 14, y: 8)
    }
}

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
            .padding(.horizontal, 14).padding(.vertical, 9)
            .background(
                isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white.opacity(0.88)),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.separator.opacity(0.25)))
            .shadow(color: isSelected ? Theme.sunset.opacity(0.15) : .clear, radius: 8, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct InsightBanner: View {
    let value: String
    let label: String
    let systemImage: String

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(Theme.brandGradient.opacity(0.17))
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Theme.sunset)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title).bold().foregroundStyle(Theme.ink)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.pink.opacity(0.75))
        }
        .padding(16)
        .background(Theme.softWash, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.65))
        }
    }
}
