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
            BrandWordmark()
                .scaleEffect(0.86, anchor: .leading)

            Spacer()

            Text("\(page + 1) of \(pages.count)")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
                .accessibilityLabel("Step \(page + 1) of \(pages.count)")
        }
        .padding(.horizontal, 22)
        .padding(.top, 12)
    }

    private func onboardingPage(_ item: OnboardingPage, index: Int) -> some View {
        ScrollView {
            VStack(spacing: 28) {
                Spacer(minLength: 20)

                illustration(for: item, index: index)
                    .frame(height: 240)
                    .accessibilityHidden(true)

                VStack(spacing: 12) {
                    Text(item.title)
                        .font(.system(size: 32, weight: .bold, design: .rounded))
                        .foregroundStyle(Theme.ink)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    Text(item.body)
                        .font(.body)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .lineSpacing(3)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 28)

                if let note = item.note {
                    Label(note.text, systemImage: note.icon)
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.ink.opacity(0.78))
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, 18)
                        .padding(.vertical, 12)
                        .frame(maxWidth: 340)
                        .background(.white.opacity(0.72), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                        .padding(.horizontal, 24)
                }

                Spacer(minLength: 12)
            }
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.hidden)
    }

    private var footer: some View {
        VStack(spacing: 16) {
            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { index in
                    Capsule()
                        .fill(index == page ? Theme.sunset : Theme.separator.opacity(0.32))
                        .frame(width: index == page ? 24 : 8, height: 8)
                        .animation(.spring(response: 0.32, dampingFraction: 0.8), value: page)
                }
            }
            .accessibilityHidden(true)

            Button {
                advance()
            } label: {
                HStack(spacing: 8) {
                    Text(pages[page].primaryCTA)
                    Image(systemName: page == pages.count - 1 ? "checkmark.circle.fill" : "arrow.right")
                }
            }
            .buttonStyle(MyPicsTubePrimaryButtonStyle())

            if page > 0 {
                Button("Back") {
                    withAnimation { page -= 1 }
                }
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(minHeight: 36)
            } else {
                Color.clear.frame(height: 36)
            }
        }
        .padding(.horizontal, 22)
        .padding(.bottom, 12)
        .background(.ultraThinMaterial.opacity(0.72))
    }

    private func advance() {
        if page == pages.count - 1 {
            isCompleted = true
            return
        }
        withAnimation(.easeInOut(duration: 0.28)) { page += 1 }
    }

    @ViewBuilder
    private func illustration(for item: OnboardingPage, index: Int) -> some View {
        ZStack {
            Circle()
                .fill(Theme.softWash)
                .frame(width: 208, height: 208)
                .scaleEffect(motion ? 1 : 0.92)
                .opacity(motion ? 1 : 0.5)
                .animation(.easeOut(duration: 0.7).delay(Double(index) * 0.05), value: motion)

            switch item.kind {
            case .find:
                photoStack
            case .face:
                faceSetup
            case .trip:
                tripFlow
            case .result:
                resultFlow
            case .privacy:
                privacySummary
            }
        }
    }

    private var photoStack: some View {
        ZStack {
            symbolCard("photo.fill", tint: Theme.sky, rotation: -10, x: -54, y: 18)
            symbolCard("person.2.fill", tint: Theme.violet, rotation: 9, x: 52, y: 10)
            symbolCard("person.crop.square.fill", tint: Theme.sunset, rotation: 0, x: 0, y: -25)
            Image(systemName: "sparkles")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(Theme.sunset)
                .offset(x: 76, y: -70)
                .symbolEffect(.pulse, options: .repeating)
        }
    }

    private var faceSetup: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 32, style: .continuous)
                .stroke(Theme.violet.opacity(0.35), lineWidth: 3)
                .frame(width: 150, height: 184)
            Image(systemName: "faceid")
                .font(.system(size: 92, weight: .light))
                .foregroundStyle(Theme.violet)
            Image(systemName: "iphone.gen3.circle.fill")
                .font(.system(size: 38))
                .foregroundStyle(Theme.aqua)
                .background(Circle().fill(.white))
                .offset(x: 70, y: 78)
        }
    }

    private var tripFlow: some View {
        HStack(spacing: 13) {
            featureBubble(icon: "plus.circle.fill", label: "Create")
            Image(systemName: "arrow.left.and.right")
                .font(.title2.bold())
                .foregroundStyle(Theme.sunset)
            featureBubble(icon: "person.2.badge.plus", label: "Join")
        }
    }

    private var resultFlow: some View {
        HStack(spacing: 10) {
            VStack(spacing: 8) {
                Image(systemName: "person.2.crop.square.stack.fill")
                    .font(.system(size: 52))
                    .foregroundStyle(Theme.violet)
                Text("Trip phones").font(.caption.bold())
            }
            Image(systemName: "arrow.right")
                .font(.title.bold())
                .foregroundStyle(Theme.sunset)
            VStack(spacing: 8) {
                Image(systemName: "person.crop.square.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Theme.sky)
                Text("Photos of you").font(.caption.bold())
            }
        }
    }

    private var privacySummary: some View {
        VStack(spacing: 10) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 66))
                .foregroundStyle(Theme.sky)
            HStack(spacing: 8) {
                permissionChip(icon: "calendar", text: "Trip dates only")
                permissionChip(icon: "iphone", text: "On-device match")
            }
            HStack(spacing: 8) {
                permissionChip(icon: "photo.on.rectangle.angled", text: "No full upload")
                permissionChip(icon: "trash", text: "Deletion controls")
            }
        }
    }

    private func symbolCard(_ icon: String, tint: Color, rotation: Double, x: CGFloat, y: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 22, style: .continuous)
                .fill(.white)
                .shadow(color: Theme.navy.opacity(0.11), radius: 13, y: 7)
            Image(systemName: icon)
                .font(.system(size: 39, weight: .medium))
                .foregroundStyle(tint)
        }
        .frame(width: 92, height: 106)
        .rotationEffect(.degrees(rotation))
        .offset(x: x, y: y)
    }

    private func featureBubble(icon: String, label: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: icon)
                .font(.system(size: 45))
                .foregroundStyle(Theme.sunset)
            Text(label).font(.caption.bold()).foregroundStyle(Theme.ink)
        }
        .frame(width: 104, height: 112)
        .background(.white, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .shadow(color: Theme.navy.opacity(0.08), radius: 14, y: 7)
    }

    private func permissionChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 11)
            .padding(.vertical, 9)
            .background(.white, in: Capsule())
            .shadow(color: Theme.navy.opacity(0.06), radius: 7, y: 3)
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
            body: "After a Trip, your best photos may be sitting on everyone else's phones. SnapLoop automatically finds the photos you're in and brings them to your phone.",
            primaryCTA: "See How It Works",
            note: .init(icon: "sparkles", text: "No more asking everyone to send you their photos.")
        ),
        .init(
            kind: .face,
            title: "Set up your face once",
            body: "Take a quick guided selfie so SnapLoop can recognize you in Trip photos. Your selfie and reference images stay only on this iPhone and are not uploaded to SnapLoop.",
            primaryCTA: "Continue",
            note: .init(icon: "function", text: "To enable matching across your Trips, SnapLoop stores a mathematical face template — not your selfie photo.")
        ),
        .init(
            kind: .trip,
            title: "Create a Trip or join one",
            body: "Create a Trip for your group or join a friend's Trip with an invite. Everyone chooses whether to participate, and each Trip has its own people and date range.",
            primaryCTA: "Continue",
            note: .init(icon: "person.2.fill", text: "Nobody is added silently — each person chooses to join.")
        ),
        .init(
            kind: .result,
            title: "Your photos come to you",
            body: "SnapLoop finds photos of you from participating Trip members' phones and shares those matches with you automatically. Photos where you are not matched are not shared with you.",
            primaryCTA: "Continue",
            note: .init(icon: "square.and.arrow.down.fill", text: "Save the shared photos you like to your own photo library.")
        ),
        .init(
            kind: .privacy,
            title: "Private by design",
            body: "SnapLoop never uploads your entire photo library. It checks only photos within your Trip's selected date range, and face matching happens on your iPhone. SnapLoop stores account and Trip information, your mathematical face-matching profile, and optimized previews of matched photos. You can change permissions, revoke access, remove Face Setup, or delete your account.",
            primaryCTA: "Start Using SnapLoop",
            note: .init(icon: "trash.fill", text: "Matched cloud previews are automatically removed 10 days after a Trip ends. If a Trip is deleted, its Trip-related cloud data is removed within 7 days.")
        )
    ]
}

#Preview {
    OnboardingView(isCompleted: .constant(false))
}
