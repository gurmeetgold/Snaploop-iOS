import SwiftUI
import UIKit

/// Brand metadata and system chrome for the MyPicsTube MVP/TestFlight build.
/// Visual colors live in `Theme` so there is one source of truth.
enum MyPicsTubeBrand {
    static let name = "MyPicsTube"
    static let tagline = "Get every photo of you."

    static func configureUIKitAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.canvas)
        tab.shadowColor = UIColor.black.withAlphaComponent(0.05)

        let normal = UIColor(Theme.ink.opacity(0.68))
        let selected = UIColor(Theme.sunset)
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
        navigation.titleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.ink)]
        UINavigationBar.appearance().standardAppearance = navigation
        UINavigationBar.appearance().compactAppearance = navigation
        UINavigationBar.appearance().scrollEdgeAppearance = navigation
    }
}

struct MyPicsTubePrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(.headline, design: .rounded, weight: .bold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            .background(Theme.brandGradient)
            .clipShape(RoundedRectangle(cornerRadius: 19, style: .continuous))
            .shadow(
                color: Theme.pink.opacity(configuration.isPressed ? 0.10 : 0.20),
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

struct MyPicsTubeCardModifier: ViewModifier {
    var padding: CGFloat = 16

    func body(content: Content) -> some View {
        content
            .padding(padding)
            .background(.white.opacity(0.96), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator.opacity(0.20), lineWidth: 1)
            }
            .shadow(color: Theme.ink.opacity(0.055), radius: 18, y: 8)
    }
}
