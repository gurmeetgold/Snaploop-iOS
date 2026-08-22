import SwiftUI

/// SnapLoop bright gradient design system.
/// The palette stays energetic in Light Mode and shifts to deep navy surfaces in Dark Mode.
public enum Theme {

    // MARK: - Brand colors
    public static let coral = Color(red: 1.00, green: 0.29, blue: 0.35)          // #FF4A59
    public static let coralDeep = Color(red: 0.95, green: 0.19, blue: 0.34)      // #F33056
    public static let coralSoft = Color(red: 1.00, green: 0.88, blue: 0.89)
    public static let peach = Color(red: 1.00, green: 0.53, blue: 0.31)          // #FF874F
    public static let lilac = Color(red: 0.56, green: 0.27, blue: 0.98)          // #8F45FA
    public static let lilacSoft = Color(red: 0.92, green: 0.88, blue: 1.00)
    public static let blue = Color(red: 0.18, green: 0.36, blue: 1.00)           // #2E5CFF
    public static let blueSoft = Color(red: 0.88, green: 0.92, blue: 1.00)
    public static let mint = Color(red: 0.05, green: 0.79, blue: 0.46)           // #0CC976
    public static let amber = Color(red: 1.00, green: 0.63, blue: 0.08)          // #FFA114

    // MARK: - Adaptive semantic colors
    public static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.96, green: 0.97, blue: 1.00, alpha: 1)
            : UIColor(red: 0.045, green: 0.065, blue: 0.12, alpha: 1)
    })

    public static let navy = ink

    public static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.018, green: 0.050, blue: 0.082, alpha: 1)  // deep blue-black
            : UIColor(red: 0.985, green: 0.988, blue: 0.997, alpha: 1)
    })

    public static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.095, blue: 0.135, alpha: 1)
            : UIColor.white
    })

    public static let elevatedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.055, green: 0.115, blue: 0.16, alpha: 1)
            : UIColor(red: 0.995, green: 0.995, blue: 1.0, alpha: 1)
    })

    public static let subtleSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.13, blue: 0.18, alpha: 1)
            : UIColor(red: 0.965, green: 0.97, blue: 0.985, alpha: 1)
    })

    public static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.10)
            : UIColor.black.withAlphaComponent(0.08)
    })

    // Compatibility aliases while older screens are migrated.
    public static let sunset = coral
    public static let sunsetDeep = coralDeep
    public static let pink = lilac
    public static let aqua = mint
    public static let sky = blue
    public static let skyDeep = Color(red: 0.10, green: 0.38, blue: 0.96)
    public static let violet = lilac
    public static let violetDeep = Color(red: 0.42, green: 0.20, blue: 0.90)
    public static let separator = Color(uiColor: .separator)

    // MARK: - Gradients
    public static let brandGradient = LinearGradient(
        colors: [coral, Color(red: 0.91, green: 0.20, blue: 0.56), lilac, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let coralGradient = LinearGradient(
        colors: [Color(red: 1.00, green: 0.39, blue: 0.27), coralDeep],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let sunsetGradient = coralGradient

    public static let socialGradient = LinearGradient(
        colors: [blue, Color(red: 0.38, green: 0.30, blue: 1.00), lilac],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let skyGradient = socialGradient

    public static let violetGradient = LinearGradient(
        colors: [coral, Color(red: 0.82, green: 0.22, blue: 0.69), lilac, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let amberGradient = LinearGradient(
        colors: [amber, peach, coral],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let galleryGradient = LinearGradient(
        colors: [coral, Color(red: 0.86, green: 0.20, blue: 0.65), lilac, blue],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let softWash = LinearGradient(
        colors: [coralSoft.opacity(0.72), lilacSoft.opacity(0.62), blueSoft.opacity(0.55)],
        startPoint: .leading,
        endPoint: .trailing
    )

    // MARK: - Geometry
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
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
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
        .shadow(color: Color.black.opacity(0.12), radius: 14, y: 8)
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
            .padding(.horizontal, 14)
            .padding(.vertical, 9)
            .background(
                isSelected ? AnyShapeStyle(Theme.socialGradient) : AnyShapeStyle(Theme.surface),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.divider))
            .shadow(color: isSelected ? Theme.lilac.opacity(0.24) : .clear, radius: 10, y: 4)
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
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.94))
            }
            Spacer()
            Image(systemName: systemImage)
                .font(.title)
                .foregroundStyle(.white)
        }
        .padding(20)
        .background(Theme.galleryGradient, in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
        .shadow(color: Theme.lilac.opacity(0.20), radius: 18, y: 8)
    }
}
