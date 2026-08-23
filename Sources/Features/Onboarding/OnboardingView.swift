import SwiftUI

struct OnboardingView: View {
    @Binding var isCompleted: Bool
    @State private var page = 0
    @State private var motion = false

    private let pages = OnboardingPage.all

    var body: some View {
        ZStack {
            BrandScreenBackground()

            VStack(spacing: 0) {
                topBar

                TabView(selection: $page) {
                    ForEach(Array(pages.enumerated()), id: \.offset) { index, item in
                        onboardingPage(item, index: index)
                            .tag(index)
                    }
                }
                .tabViewStyle(.page(indexDisplayMode: .never))
                .animation(.easeInOut(duration: 0.28), value: page)

                footer
            }
        }
        .onAppear { motion = true }
        .accessibilityElement(children: .contain)
    }

    private var topBar: some View {
        HStack {
            BrandWordmark().scaleEffect(0.82, anchor: .leading)
            Spacer()
            Text("\(page + 1) of \(pages.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 22)
        .padding(.top, 6)
    }

    private func onboardingPage(_ item: OnboardingPage, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 18) {
                Spacer(minLength: 4)
                illustration(for: item, index: index)
                    .frame(height: 205)
                    .accessibilityHidden(true)
                VStack(spacing: 10) {
                    if index == 0 {
                        Text("Welcome to SnapLoop")
                            .font(.headline.weight(.bold))
                            .foregroundStyle(Theme.brandGradient)
                    }
                    Text(item.title)
                        .font(.system(size: 30, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                    Text(item.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(2)
                }
                .padding(.horizontal, 28)
                if let note = item.note {
                    Label(note.text, systemImage: note.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 10)
                        .frame(maxWidth: 340)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 24)
                }
                Spacer(minLength: 4)
            }
            .frame(maxWidth: .infinity)
            .padding(.bottom, 6)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        VStack(spacing: 12) {
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Theme.sunset : Theme.separator.opacity(0.32))
                        .frame(width: index == page ? 24 : 8, height: 8)
                }
            }
            Button { advance() } label: {
                HStack(spacing: 8) {
                    Text(pages[page].primaryCTA)
                    Image(systemName: page == pages.count - 1 ? "checkmark.circle.fill" : "arrow.right")
                }
            }
            .buttonStyle(MyPicsTubePrimaryButtonStyle())
            if page > 0 {
                Button("Back") { withAnimation { page -= 1 } }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(minHeight: 32)
            } else {
                Color.clear.frame(height: 32)
            }
        }
        .padding(.horizontal, 22)
        .padding(.top, 8)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func advance() {
        if page == pages.count - 1 { isCompleted = true; return }
        withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
    }

    @ViewBuilder
    private func illustration(for item: OnboardingPage, index: Int) -> some View {
        ZStack {
            Circle().fill(Theme.softWash).frame(width: 190, height: 190)
            switch item.kind {
            case .find: photoStack
            case .face: faceSetup
            case .trip: tripFlow
            case .result: resultFlow
            case .privacy: privacySummary
            }
        }
    }

    private var photoStack: some View {
        ZStack {
            symbolCard("photo.fill", tint: Theme.sky, rotation: -10, x: -50, y: 16)
            symbolCard("person.2.fill", tint: Theme.violet, rotation: 9, x: 48, y: 8)
            symbolCard("person.crop.square.fill", tint: Theme.sunset, rotation: 0, x: 0, y: -22)
        }
    }

    private var faceSetup: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 30).stroke(Theme.violet.opacity(0.35), lineWidth: 3).frame(width: 140, height: 170)
            Image(systemName: "faceid").font(.system(size: 84, weight: .light)).foregroundStyle(Theme.violet)
            Image(systemName: "iphone.gen3.circle.fill").font(.system(size: 36)).foregroundStyle(Theme.aqua).background(Circle().fill(.white)).offset(x: 65, y: 70)
        }
    }

    private var tripFlow: some View {
        HStack(spacing: 11) {
            featureBubble(icon: "plus.circle.fill", label: "Create")
            Image(systemName: "arrow.left.and.right").font(.title2.bold()).foregroundStyle(Theme.sunset)
            featureBubble(icon: "person.2.badge.plus", label: "Join")
        }
    }

    private var resultFlow: some View {
        HStack(spacing: 10) {
            VStack {
                Image(systemName: "person.2.crop.square.stack.fill")
                    .font(.system(size: 48))
                    .foregroundStyle(Theme.violet)
                Text("Event phones").font(.caption.bold())
            }
            Image(systemName: "arrow.right").font(.title.bold()).foregroundStyle(Theme.sunset)
            VStack {
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 54))
                    .foregroundStyle(Theme.sky)
                Text("Photos of you").font(.caption.bold())
            }
        }
    }

    private var privacySummary: some View {
        VStack(spacing: 9) {
            Image(systemName: "lock.shield.fill").font(.system(size: 58)).foregroundStyle(Theme.sky)
            HStack {
                permissionChip(icon: "calendar", text: "Event dates only")
                permissionChip(icon: "iphone", text: "On-device match")
            }
            HStack {
                permissionChip(icon: "photo.on.rectangle.angled", text: "No full upload")
                permissionChip(icon: "trash", text: "15-day deletion")
            }
        }
    }

    private func symbolCard(_ icon: String, tint: Color, rotation: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22).fill(.white)
            Image(systemName: icon).font(.system(size: 37)).foregroundStyle(tint)
        }
        .frame(width: 86, height: 98)
        .rotationEffect(.degrees(rotation))
        .offset(x: x, y: y)
    }

    private func featureBubble(icon: String, label: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon).font(.system(size: 42)).foregroundStyle(Theme.sunset)
            Text(label).font(.caption.bold())
        }
        .frame(width: 98, height: 104)
        .background(.white, in: RoundedRectangle(cornerRadius: 24))
    }

    private func permissionChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.white, in: Capsule())
    }
}

private struct OnboardingPage {
    enum Kind { case find, face, trip, result, privacy }
    struct Note { let icon: String; let text: String }

    let kind: Kind
    let title: String
    let body: String
    let primaryCTA: String
    let note: Note?

    static let all: [OnboardingPage] = [
        .init(
            kind: .find,
            title: "Find every photo you're in",
            body: "After an Event (e.g. trip), your best photos may be sitting on everyone else's phones. SnapLoop automatically finds the photos you're in and brings them to your phone.",
            primaryCTA: "See How It Works",
            note: .init(icon: "sparkles", text: "No more asking everyone to send you their photos.")
        ),
        .init(
            kind: .face,
            title: "Set up your face once",
            body: "Take a quick guided selfie so SnapLoop can recognize you in Event photos. Your selfie and reference images stay only on this iPhone and are not uploaded to SnapLoop.",
            primaryCTA: "Continue",
            note: .init(icon: "lock.shield.fill", text: "To enable matching, SnapLoop stores only face-template metadata - not your selfie photo.")
        ),
        .init(
            kind: .trip,
            title: "Create an Event or join one",
            body: "Create an Event (e.g. trip, party or family gathering) for your group, or join a friend's Event with an invite. Everyone chooses whether to participate, and each Event has its own people and date range.",
            primaryCTA: "Continue",
            note: .init(icon: "person.2.fill", text: "Nobody is added silently — each person chooses to join.")
        ),
        .init(
            kind: .result,
            title: "Your photos come to you",
            body: "SnapLoop finds photos of you from participating Event members' phones and shares those matches with you automatically. Photos where you are not matched are not shared with you.",
            primaryCTA: "Continue",
            note: .init(icon: "square.and.arrow.down.fill", text: "Save the photos you like to your own photo library.")
        ),
        .init(
            kind: .privacy,
            title: "Private by design",
            body: "SnapLoop never uploads your entire photo library. It checks only photos within your Event's selected date range, and face matching happens on your iPhone.",
            primaryCTA: "Start Using SnapLoop",
            note: .init(icon: "trash.fill", text: "All Event-related cloud data, including matched photo previews, is deleted within 15 days after the Event ends.")
        )
    ]
}

#Preview { OnboardingView(isCompleted: .constant(false)) }
