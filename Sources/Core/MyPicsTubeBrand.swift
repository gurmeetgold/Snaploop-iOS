import SwiftUI
import UIKit

/// Brand metadata and system chrome for the MyPicsRoom MVP/TestFlight build.
/// Visual colors live in `Theme` so there is one source of truth.
enum MyPicsTubeBrand {
    static let name = "MyPicsRoom"
    static let tagline = "My pics, found from everyone’s phone."

    static func configureUIKitAppearance() {
        let tab = UITabBarAppearance()
        tab.configureWithOpaqueBackground()
        tab.backgroundColor = UIColor(Theme.canvas)
        tab.shadowColor = UIColor(Theme.navy).withAlphaComponent(0.05)

        let normal = UIColor(Theme.navy.opacity(0.66))
        let selected = UIColor(Theme.coral)
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
        navigation.titleTextAttributes = [.foregroundColor: UIColor(Theme.navy)]
        navigation.largeTitleTextAttributes = [.foregroundColor: UIColor(Theme.navy)]
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
                color: Theme.coral.opacity(configuration.isPressed ? 0.10 : 0.22),
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
            .background(.white.opacity(0.97), in: RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Theme.cardRadius, style: .continuous)
                    .stroke(Theme.separator.opacity(0.16), lineWidth: 1)
            }
            .shadow(color: Theme.navy.opacity(0.06), radius: 18, y: 8)
    }
}
