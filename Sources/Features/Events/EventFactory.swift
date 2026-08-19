import Foundation

public struct EventDraft: Equatable, Sendable {
    public var name: String
    public var category: EventCategory
    public var startsAt: Date
    public var endsAt: Date
    public var locationName: String?
    public var coverImagePath: String?

    public init(
        name: String,
        category: EventCategory = .other,
        startsAt: Date,
        endsAt: Date,
        locationName: String? = nil,
        coverImagePath: String? = nil
    ) {
        self.name = name
        self.category = category
        self.startsAt = startsAt
        self.endsAt = endsAt
        self.locationName = locationName
        self.coverImagePath = coverImagePath
    }
}

public struct EventFactory {
    public struct Generators {
        public var id: () -> String
        public var joinCode: () -> String
        public var inviteToken: () -> InviteToken
        public init(
            id: @escaping () -> String = { UUID().uuidString },
            joinCode: @escaping () -> String = EventFactory.randomJoinCode,
            inviteToken: @escaping () -> InviteToken = InviteToken.generate
        ) {
            self.id = id
            self.joinCode = joinCode
            self.inviteToken = inviteToken
        }
    }

    public let config: RemoteConfigValues
    public let clock: Clock
    public let generators: Generators

    public init(config: RemoteConfigValues, clock: Clock, generators: Generators = .init()) {
        self.config = config
        self.clock = clock
        self.generators = generators
    }

    public func make(draft: EventDraft, creatorUserId: String) throws -> Event {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidEventName }
        let now = clock.now()
        try EventLifecycle.validateDates(
            startsAt: draft.startsAt,
            endsAt: draft.endsAt,
            now: now,
            config: config
        )

        return Event(
            id: generators.id(),
            joinCode: generators.joinCode(),
            inviteToken: generators.inviteToken().value,
            creatorUserId: creatorUserId,
            name: name,
            category: draft.category,
            coverImagePath: draft.coverImagePath,
            locationName: draft.locationName,
            startsAt: draft.startsAt,
            endsAt: draft.endsAt,
            status: .active,
            createdAt: now,
            updatedAt: now
        )
    }

    public func applyEdit(_ draft: EventDraft, to event: Event) throws -> Event {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidEventName }
        let now = clock.now()
        try EventLifecycle.validateDates(
            startsAt: draft.startsAt,
            endsAt: draft.endsAt,
            now: now,
            config: config
        )
        var updated = event
        updated.name = name
        updated.category = draft.category
        updated.locationName = draft.locationName
        updated.coverImagePath = draft.coverImagePath
        updated.startsAt = draft.startsAt
        updated.endsAt = draft.endsAt
        updated.updatedAt = now
        return updated
    }

    public static func randomJoinCode() -> String {
        let alphabet = Array(JoinCode.alphabet)
        var rng = SystemRandomNumberGenerator()
        return String((0..<JoinCode.length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }
}
