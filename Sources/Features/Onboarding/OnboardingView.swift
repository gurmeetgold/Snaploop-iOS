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
            case .trip:
                tripFlow
            case .dates:
                dateRange
            case .face:
                faceSetup
            case .privacy:
                privacyControls
            case .storage:
                storageSummary
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

    private var tripFlow: some View {
        HStack(spacing: 13) {
            featureBubble(icon: "plus.circle.fill", label: "Create")
            Image(systemName: "arrow.left.and.right")
                .font(.title2.bold())
                .foregroundStyle(Theme.sunset)
            featureBubble(icon: "person.2.badge.plus", label: "Join")
        }
    }

    private var dateRange: some View {
        VStack(spacing: 13) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 74, weight: .medium))
                .foregroundStyle(Theme.sunset)
                .symbolEffect(.bounce, value: page)
            HStack(spacing: 8) {
                dateChip("JUL 12", active: true)
                Image(systemName: "arrow.right").foregroundStyle(.secondary)
                dateChip("JUL 18", active: true)
            }
            Text("Only this Trip window")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
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
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 36))
                .foregroundStyle(Theme.aqua)
                .background(Circle().fill(.white))
                .offset(x: 70, y: 78)
        }
    }

    private var privacyControls: some View {
        VStack(spacing: 12) {
            Image(systemName: "lock.shield.fill")
                .font(.system(size: 72))
                .foregroundStyle(Theme.sky)
                .symbolEffect(.pulse, options: .repeating)
            HStack(spacing: 8) {
                permissionChip(icon: "camera.fill", text: "Camera")
                permissionChip(icon: "photo.on.rectangle.angled", text: "Photos")
            }
            Label("You stay in control", systemImage: "hand.raised.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.ink.opacity(0.72))
        }
    }

    private var storageSummary: some View {
        VStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .fill(.white)
                    .shadow(color: Theme.navy.opacity(0.08), radius: 14, y: 7)
                VStack(spacing: 12) {
                    Image(systemName: "icloud.and.arrow.up.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(Theme.aqua)
                    HStack(spacing: 8) {
                        permissionChip(icon: "person.crop.circle", text: "Account")
                        permissionChip(icon: "calendar", text: "Trip")
                    }
                    permissionChip(icon: "photo.badge.checkmark", text: "Matched previews")
                }
            }
            .frame(width: 210, height: 170)

            Label("Not your full photo library", systemImage: "xmark.circle.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(Theme.sunset)
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

    private func dateChip(_ text: String, active: Bool) -> some View {
        Text(text)
            .font(.caption.monospaced().bold())
            .foregroundStyle(active ? Theme.sunset : .secondary)
            .padding(.horizontal, 13)
            .padding(.vertical, 9)
            .background((active ? Theme.peach : Theme.softWash).opacity(0.55), in: Capsule())
    }

    private func permissionChip(icon: String, text: String) -> some View {
        Label(text, systemImage: icon)
            .font(.caption.bold())
            .foregroundStyle(Theme.ink)
            .padding(.horizontal, 12)
            .padding(.vertical, 9)
            .background(.white, in: Capsule())
            .shadow(color: Theme.navy.opacity(0.06), radius: 7, y: 3)
    }
}

private struct OnboardingPage {
    enum Kind { case find, trip, dates, face, privacy, storage }
    struct Note { let icon: String; let text: String }

    let kind: Kind
    let title: String
    let body: String
    let primaryCTA: String
    let note: Note?

    static let all: [OnboardingPage] = [
        .init(
            kind: .find,
            title: "Find the photos you're in",
            body: "After a trip, your best photos may be sitting on everyone else's phones. SnapLoop automatically brings the photos you're in to your phone.",
            primaryCTA: "See How It Works",
            note: .init(icon: "sparkles", text: "Less chasing friends. More of your memories.")
        ),
        .init(
            kind: .trip,
            title: "Create a Trip or join one",
            body: "Create a Trip for your group, or join a friend's Trip with their invite. Everyone stays connected to the same shared experience.",
            primaryCTA: "Continue",
            note: .init(icon: "person.2.fill", text: "Nobody is added silently — each person chooses to join.")
        ),
        .init(
            kind: .dates,
            title: "SnapLoop only looks inside your Trip dates",
            body: "Each Trip has a start and end date. Photo matching is limited to photos taken inside that selected date range — not your entire photo history.",
            primaryCTA: "Got It",
            note: .init(icon: "calendar.badge.checkmark", text: "The Trip date range limits which photos are considered for matching.")
        ),
        .init(
            kind: .face,
            title: "Set up your face once",
            body: "A guided selfie gives SnapLoop a reference to recognize you in Trip photos. Your camera is used for Face Setup when you choose to start it.",
            primaryCTA: "Continue",
            note: .init(icon: "faceid", text: "We'll ask for Camera access only when Face Setup begins.")
        ),
        .init(
            kind: .privacy,
            title: "Your photos. Your control.",
            body: "Photo access lets SnapLoop check Trip-date photos on your iPhone for matches. Full Access works best for automatic discovery; Limited Access works with only the photos you choose. You can change permissions, revoke access, or remove face data at any time.",
            primaryCTA: "Continue",
            note: .init(icon: "lock.shield.fill", text: "SnapLoop explains why access is needed before iOS asks you for permission.")
        ),
        .init(
            kind: .storage,
            title: "What SnapLoop stores",
            body: "SnapLoop does not upload or store your entire photo library. Matching happens on your iPhone. We store only the information needed to run your account and Trips, plus matched optimized previews that are shared with Trip members.",
            primaryCTA: "Continue to SnapLoop",
            note: .init(icon: "iphone", text: "Your original photo library stays on your iPhone — SnapLoop never makes a full copy of it.")
        )
    ]
}

#Preview {
    OnboardingView(isCompleted: .constant(false))
}
