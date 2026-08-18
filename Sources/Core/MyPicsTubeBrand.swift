import SwiftUI
import UIKit

/// MyPicsTube visual identity for the MVP/TestFlight build.
///
/// This deliberately changes only presentation. Firebase project identifiers,
/// bundle identifiers, deep-link schemes, stored document fields, and backend
/// function names remain unchanged so the visual rebrand cannot invalidate
/// existing accounts/events or break authentication.
enum MyPicsTubeBrand {
    static let name = "MyPicsTube"
    static let tagline = "Get every photo of you."

    // MARK: Sunset Social palette

    static let sunset = Color(red: 1.000, green: 0.478, blue: 0.271)       // #FF7A45
    static let rose = Color(red: 0.984, green: 0.443, blue: 0.522)         // #FB7185
    static let gold = Color(red: 0.984, green: 0.749, blue: 0.141)         // #FBBF24
    static let aqua = Color(red: 0.176, green: 0.831, blue: 0.749)         // #2DD4BF
    static let lavender = Color(red: 0.655, green: 0.545, blue: 0.980)     // #A78BFA
    static let sky = Color(red: 0.231, green: 0.741, blue: 0.973)          // #3BBDf8-ish

    static let cream = Color(red: 1.000, green: 0.973, blue: 0.949)        // #FFF8F2
    static let canvas = Color(red: 0.985, green: 0.976, blue: 0.968)
    static let surface = Color.white
    static let ink = Color(red: 0.216, green: 0.255, blue: 0.318)          // #374151
    static let secondaryInk = Color(red: 0.420, green: 0.447, blue: 0.502)
    static let hairline = Color.black.opacity(0.06)

    static let primaryGradient = LinearGradient(
        colors: [sunset, rose],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let socialGradient = LinearGradient(
        colors: [rose, lavender],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let freshGradient = LinearGradient(
        colors: [aqua, sky],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let softWash = LinearGradient(
        colors: [
            sunset.opacity(0.12),
            rose.opacity(0.09),
            lavender.opacity(0.09)
        ],
        startPoint: .topLeading,
        endPoint: .bottomTrailing
    )

    static let heroWash = LinearGradient(
        colors: [cream, rose.opacity(0.08), lavender.opacity(0.08)],
        startPoint: .top,
        endPoint: .bottomTrailing
    )

    /// Applies light UIKit chrome so SwiftUI navigation/tab surfaces feel like
    /// the same product instead of default system screens pasted together.
    static func configureUIKitAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(cream)
        tab.shadowColor = UIColor.black.withAlphaComponent(0.05)

        let normal = UIColor(ink.opacity(0.72))
        let selected = UIColor(sunset)
        [tab.stackedLayoutAppearance,
         tab.inlineLayoutAppearance,
         tab.compactInlineLayoutAppearance].forEach { item in
            item.normal.iconColor = normal
            item.normal.titleTextAttributes = [.foregroundColor: normal]
            item.selected.iconColor = selected
            item.selected.titleTextAttributes = [.foregroundColor: selected]
        }
        UITabBar.appearance().standardAppearance = tab
        UITabBar.appearance().scrollEdgeAppearance = tab

        let navigation = UINavigationBarAppearance()
        navigation.configureWithTransparentBackground()
        navigation.titleTextAttributes = [.foregroundColor: UIColor(ink)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(ink)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
}

/// Logo direction selected from the brand exploration: a people/community mark
/// inside a photo/lens ring, recolored for Sunset Social.
struct MyPicsTubeBrandMark: View {
    var size: CGFloat = 64

    var body: some View {
        ZStack {
            Circle()
                .fill(MyPicsTubeBrand.primaryGradient)

            Circle()
                .stroke(.white.opacity(0.30), lineWidth: max(1.5, size * 0.035))
                .padding(size * 0.14)

            Image(systemName: "person.2.fill")
                .font(.system(size: size * 0.35, weight: .semibold, design: .rounded))
                .foregroundStyle(.white)

            Image(systemName: "sparkles")
                .font(.system(size: size * 0.17, weight: .bold))
                .foregroundStyle(MyPicsTubeBrand.gold)
                .offset(x: size * 0.27, y: -size * 0.28)
        }
        .frame(width: size, height: size)
        .shadow(color: MyPicsTubeBrand.rose.opacity(0.22), radius: size * 0.16, y: size * 0.08)
        .accessibilityHidden(true)
    }
}

struct MyPicsTubeWordmark: View {
    var markSize: CGFloat = 68
    var titleSize: CGFloat = 36
    var showsTagline = true

    var body: some View {
        VStack(spacing: 12) {
            MyPicsTubeBrandMark(size: markSize)

            Text(MyPicsTubeBrand.name)
                .font(.system(size: titleSize, weight: .heavy, design: .rounded))
                .foregroundStyle(MyPicsTubeBrand.ink)
                .tracking(-0.8)

            if showsTagline {
                Text(MyPicsTubeBrand.tagline)
                    .font(.system(.subheadline, design: .rounded, weight: .semibold))
                    .foregroundStyle(MyPicsTubeBrand.secondaryInk)
            }
        }
        .accessibilityElement(children: .combine)
    }
}

struct MyPicsTubeCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(MyPicsTubeBrand.surface, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 24, style: .continuous)
                    .stroke(MyPicsTubeBrand.hairline, lineWidth: 1)
            }
            .shadow(color: Color.black.opacity(0.055), radius: 18, y: 8)
    }
}

struct MyPicsTubePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(MyPicsTubeBrand.primaryGradient)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .shadow(
                color: MyPicsTubeBrand.rose.opacity(configuration.isPressed ? 0.10 : 0.20),
                radius: configuration.isPressed ? 4 : 12,
                y: configuration.isPressed ? 2 : 6
            )
            .scaleEffect(configuration.isPressed ? 0.985 : 1)
            .animation(.easeOut(duration: 0.16), value: configuration.isPressed)
    }
}

extension View {
    func myPicsTubeCard(padding: CGFloat = 16) -> some View {
        modifier(MyPicsTubeCardModifier(padding: padding))
    }
}
