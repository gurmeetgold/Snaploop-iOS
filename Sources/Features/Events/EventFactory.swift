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
    public let calendar: Calendar
    public let generators: Generators

    public init(
        config: RemoteConfigValues,
        clock: Clock,
        calendar: Calendar = EventLifecycle.calendar(),
        generators: Generators = .init()
    ) {
        self.config = config
        self.clock = clock
        self.calendar = calendar
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
            config: config,
            calendar: calendar
        )

        let bounds = EventLifecycle.canonicalBounds(
            startsAt: draft.startsAt,
            endsAt: draft.endsAt,
            calendar: calendar
        )
        let startDay = EventLifecycle.localDayNumber(draft.startsAt, calendar: calendar)
        let endDay = EventLifecycle.localDayNumber(draft.endsAt, calendar: calendar)

        return Event(
            id: generators.id(),
            joinCode: generators.joinCode(),
            inviteToken: generators.inviteToken().value,
            creatorUserId: creatorUserId,
            name: name,
            category: draft.category,
            coverImagePath: draft.coverImagePath,
            locationName: draft.locationName,
            startsAt: bounds.lowerBound,
            endsAt: bounds.upperBound,
            photoWindowVersion: EventLifecycle.photoWindowVersion,
            photoWindowTimeZoneId: calendar.timeZone.identifier,
            photoWindowStartDayNumber: startDay,
            photoWindowEndDayNumber: endDay,
            status: .active,
            createdAt: now,
            updatedAt: now
        )
    }

    /// `datesChanged == false` is important for legacy Events. A rename/details
    /// edit must not validate, clamp, normalize or otherwise mutate historical
    /// date values simply because today's ±15 window has moved on.
    public func applyEdit(
        _ draft: EventDraft,
        to event: Event,
        datesChanged: Bool = true
    ) throws -> Event {
        let name = draft.name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw AppError.invalidEventName }
        let now = clock.now()

        var updated = event
        updated.name = name
        updated.category = draft.category
        updated.locationName = draft.locationName
        updated.coverImagePath = draft.coverImagePath

        if datesChanged {
            try EventLifecycle.validateDates(
                startsAt: draft.startsAt,
                endsAt: draft.endsAt,
                now: now,
                config: config,
                calendar: calendar
            )
            let bounds = EventLifecycle.canonicalBounds(
                startsAt: draft.startsAt,
                endsAt: draft.endsAt,
                calendar: calendar
            )
            updated.startsAt = bounds.lowerBound
            updated.endsAt = bounds.upperBound
            updated.photoWindowVersion = EventLifecycle.photoWindowVersion
            updated.photoWindowTimeZoneId = calendar.timeZone.identifier
            updated.photoWindowStartDayNumber = EventLifecycle.localDayNumber(draft.startsAt, calendar: calendar)
            updated.photoWindowEndDayNumber = EventLifecycle.localDayNumber(draft.endsAt, calendar: calendar)
        }

        updated.updatedAt = now
        return updated
    }

    public static func randomJoinCode() -> String {
        let alphabet = Array(JoinCode.alphabet)
        var rng = SystemRandomNumberGenerator()
        return String((0..<JoinCode.length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &rng)] })
    }
}
