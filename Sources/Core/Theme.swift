import SwiftUI

/// MyPicsTube "Coral Luxe" design system.
/// Coral drives personal/photo actions, lilac adds youthful energy, deep navy
/// carries typography and trust, and warm ivory keeps the interface light,
/// premium and calm.
public enum Theme {

    // MARK: Brand colors
    public static let coral = Color(red: 1.00, green: 0.42, blue: 0.37)          // #FF6B5E
    public static let coralDeep = Color(red: 0.96, green: 0.35, blue: 0.29)      // #F45A4B
    public static let coralSoft = Color(red: 1.00, green: 0.88, blue: 0.86)      // #FFE2DE
    public static let peach = Color(red: 1.00, green: 0.84, blue: 0.81)          // #FFD7CF
    public static let lilac = Color(red: 0.65, green: 0.55, blue: 0.98)          // #A78BFA
    public static let lilacSoft = Color(red: 0.93, green: 0.91, blue: 1.00)      // #EEE7FF
    public static let blue = Color(red: 0.31, green: 0.55, blue: 0.99)           // #4F8DFD
    public static let blueSoft = Color(red: 0.91, green: 0.95, blue: 1.00)       // #E8F1FF
    public static let mint = Color(red: 0.15, green: 0.78, blue: 0.48)           // #27C77B
    public static let amber = Color(red: 0.96, green: 0.70, blue: 0.26)          // #F5B342
    public static let ink = Color(red: 0.086, green: 0.094, blue: 0.149)         // #161826
    public static let navy = Color(red: 0.086, green: 0.129, blue: 0.243)        // #16213E
    public static let canvas = Color(red: 0.985, green: 0.976, blue: 0.969)      // warm ivory
    public static let surface = Color.white

    // Compatibility aliases while older screens are migrated.
    public static let sunset = coral
    public static let sunsetDeep = coralDeep
    public static let pink = lilac
    public static let aqua = mint
    public static let sky = blue
    public static let skyDeep = Color(red: 0.22, green: 0.46, blue: 0.90)
    public static let violet = lilac
    public static let violetDeep = Color(red: 0.50, green: 0.39, blue: 0.88)

    public static let separator = Color(uiColor: .separator)

    // MARK: Gradients
    public static let brandGradient = LinearGradient(
        colors: [coral, coralDeep], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let coralGradient = brandGradient
    public static let sunsetGradient = LinearGradient(
        colors: [coral, peach], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let socialGradient = LinearGradient(
        colors: [blue, lilac], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let skyGradient = socialGradient
    public static let violetGradient = LinearGradient(
        colors: [lilac, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let amberGradient = LinearGradient(
        colors: [amber, coral], startPoint: .topLeading, endPoint: .bottomTrailing)
    public static let softWash = LinearGradient(
        colors: [coralSoft.opacity(0.72), lilacSoft.opacity(0.72), blueSoft.opacity(0.48)],
        startPoint: .leading, endPoint: .trailing)

    // MARK: Geometry
    public static let cardRadius: CGFloat = 24
    public static let tileRadius: CGFloat = 22
    public static let chipRadius: CGFloat = 22

    public static func tint(for status: EventLifecycle.Status) -> Color {
        switch status {
        case .upcoming: return blue
        case .active: return mint
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
                Text(subtitle).font(.caption).foregroundStyle(.white.opacity(0.90))
            }
            .padding(16)
        }
        .frame(height: height)
        .clipShape(RoundedRectangle(cornerRadius: Theme.tileRadius, style: .continuous))
        .shadow(color: Theme.navy.opacity(0.10), radius: 14, y: 8)
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
                isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(.white.opacity(0.92)),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : Theme.navy)
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.separator.opacity(0.20)))
            .shadow(color: isSelected ? Theme.coral.opacity(0.18) : .clear, radius: 8, y: 4)
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
                    .fill(Theme.coralSoft)
                Image(systemName: systemImage)
                    .font(.title2)
                    .foregroundStyle(Theme.coralDeep)
            }
            .frame(width: 54, height: 54)

            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title).bold().foregroundStyle(Theme.navy)
                Text(label).font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "sparkles")
                .foregroundStyle(Theme.lilac.opacity(0.85))
        }
        .padding(16)
        .background(Theme.softWash, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                .strokeBorder(.white.opacity(0.78))
        }
    }
}
