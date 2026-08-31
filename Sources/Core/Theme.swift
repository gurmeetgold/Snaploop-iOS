import SwiftUI

/// SnapLoop visual system: a crisp, saturated social-photo palette.
/// The brand moves from warm coral/orange through hot pink into violet/blue.
public enum Theme {

    // MARK: - Brand colors
    // Deliberately redder and more saturated than the prior golden/peach pass.
    public static let orange = Color(red: 1.00, green: 0.34, blue: 0.10)         // #FF571A
    public static let coral = Color(red: 1.00, green: 0.19, blue: 0.29)          // #FF304A
    public static let coralDeep = Color(red: 0.96, green: 0.06, blue: 0.24)      // #F50F3D
    public static let coralSoft = Color(red: 1.00, green: 0.90, blue: 0.93)
    public static let peach = Color(red: 1.00, green: 0.43, blue: 0.14)          // #FF6E24
    public static let hotPink = Color(red: 1.00, green: 0.00, blue: 0.44)        // #FF0070
    public static let magenta = Color(red: 0.91, green: 0.00, blue: 0.72)        // #E800B8
    public static let lilac = Color(red: 0.49, green: 0.08, blue: 1.00)          // #7D14FF
    public static let lilacSoft = Color(red: 0.95, green: 0.91, blue: 1.00)
    public static let blue = Color(red: 0.27, green: 0.23, blue: 1.00)           // #453BFF
    public static let blueSoft = Color(red: 0.91, green: 0.91, blue: 1.00)
    public static let mint = Color(red: 0.05, green: 0.79, blue: 0.46)
    public static let amber = Color(red: 1.00, green: 0.63, blue: 0.08)

    // MARK: - Adaptive semantic colors
    public static let ink = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.97, green: 0.97, blue: 1.00, alpha: 1)
            : UIColor(red: 0.045, green: 0.050, blue: 0.10, alpha: 1)
    })

    public static let navy = ink

    public static let canvas = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.018, green: 0.025, blue: 0.070, alpha: 1)
            : UIColor(red: 0.998, green: 0.996, blue: 1.000, alpha: 1)
    })

    public static let surface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.045, green: 0.055, blue: 0.105, alpha: 1)
            : UIColor.white
    })

    public static let elevatedSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.060, green: 0.070, blue: 0.130, alpha: 1)
            : UIColor(red: 0.998, green: 0.996, blue: 1.0, alpha: 1)
    })

    public static let subtleSurface = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor(red: 0.075, green: 0.085, blue: 0.150, alpha: 1)
            : UIColor(red: 0.982, green: 0.974, blue: 0.994, alpha: 1)
    })

    public static let divider = Color(uiColor: UIColor { traits in
        traits.userInterfaceStyle == .dark
            ? UIColor.white.withAlphaComponent(0.11)
            : UIColor.black.withAlphaComponent(0.07)
    })

    // Compatibility aliases used by existing screens.
    public static let sunset = coral
    public static let sunsetDeep = coralDeep
    public static let pink = hotPink
    public static let aqua = mint
    public static let sky = blue
    public static let skyDeep = Color(red: 0.19, green: 0.19, blue: 0.96)
    public static let violet = lilac
    public static let violetDeep = Color(red: 0.38, green: 0.04, blue: 0.88)
    public static let separator = Color(uiColor: .separator)

    // MARK: - Gradients
    /// Primary SnapLoop gradient: vivid coral/orange → hot pink → violet → blue.
    public static let brandGradient = LinearGradient(
        colors: [peach, coral, hotPink, magenta, lilac, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let coralGradient = LinearGradient(
        colors: [peach, coral, hotPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let sunsetGradient = coralGradient

    public static let socialGradient = LinearGradient(
        colors: [coral, hotPink, magenta, lilac, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let skyGradient = LinearGradient(
        colors: [blue, lilac],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let violetGradient = LinearGradient(
        colors: [coral, hotPink, magenta, lilac, blue],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let amberGradient = LinearGradient(
        colors: [peach, coral, hotPink],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    public static let galleryGradient = LinearGradient(
        colors: [peach, coral, hotPink, magenta, lilac, blue],
        startPoint: .leading,
        endPoint: .trailing
    )

    public static let softWash = LinearGradient(
        colors: [
            Color(red: 1.00, green: 0.95, blue: 0.97).opacity(0.76),
            coralSoft.opacity(0.54),
            lilacSoft.opacity(0.52),
            blueSoft.opacity(0.42)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
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

private struct EventContextNameKey: EnvironmentKey {
    static let defaultValue: String? = nil
}

extension EnvironmentValues {
    var eventContextName: String? {
        get { self[EventContextNameKey.self] }
        set { self[EventContextNameKey.self] = newValue }
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
        .shadow(color: Theme.hotPink.opacity(0.18), radius: 14, y: 8)
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
                isSelected ? AnyShapeStyle(Theme.brandGradient) : AnyShapeStyle(Theme.surface),
                in: Capsule()
            )
            .foregroundStyle(isSelected ? .white : Theme.ink)
            .overlay(Capsule().strokeBorder(isSelected ? .clear : Theme.divider))
            .shadow(color: isSelected ? Theme.hotPink.opacity(0.22) : .clear, radius: 10, y: 4)
        }
        .buttonStyle(.plain)
    }
}

struct InsightBanner: View {
    let value: String
    let label: String
    let systemImage: String
    @Environment(\.eventContextName) private var eventContextName

    private var displayedLabel: String {
        guard label == "photos found of you",
              let eventContextName = eventContextName?.trimmingCharacters(in: .whitespacesAndNewlines),
              !eventContextName.isEmpty else { return label }
        return "\(label) in \(eventContextName)"
    }

    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.system(size: 42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                Text(displayedLabel)
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
        .shadow(color: Theme.hotPink.opacity(0.20), radius: 18, y: 8)
    }
}
