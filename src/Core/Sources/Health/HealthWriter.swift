import Foundation
import HealthKit

/// A metric the phone will write into Health at an agent's request.
///
/// The third catalogue, and a subset of the other two on purpose: everything
/// written here is read back by the uploader, so an edit shows up in the
/// archive afterwards like anything the person logged by hand. A test holds
/// the two together.
public struct WritableMetric: Sendable {
    /// The name on the wire — the same one the day format uses for the metric.
    public let name: String
    public let type: HKSampleType
    /// The one unit a value may arrive in. Nil for a category.
    public let unit: HKUnit?

    private init(name: String, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) {
        self.name = name
        type = HKQuantityType(identifier)
        self.unit = unit
    }

    private init(name: String, category identifier: HKCategoryTypeIdentifier) {
        self.name = name
        type = HKCategoryType(identifier)
        unit = nil
    }

    public static let all: [WritableMetric] = [
        .init(name: "sleep", category: .sleepAnalysis),
        .init(name: "dietaryEnergy", .dietaryEnergyConsumed, .kilocalorie()),
        .init(name: "dietaryProtein", .dietaryProtein, .gram()),
        .init(name: "dietaryCarbohydrates", .dietaryCarbohydrates, .gram()),
        .init(name: "dietaryFat", .dietaryFatTotal, .gram()),
        .init(name: "dietaryWater", .dietaryWater, .literUnit(with: .milli)),
        .init(name: "bodyMass", .bodyMass, .gramUnit(with: .kilo)),
    ]

    public static func named(_ name: String) -> WritableMetric? {
        all.first { $0.name == name }
    }

    /// The stages a sleep item may name, the inverse of `sleepStageName`.
    public static let sleepStages: [String: HKCategoryValueSleepAnalysis] = [
        "inBed": .inBed,
        "awake": .awake,
        "asleepUnspecified": .asleepUnspecified,
        "asleepCore": .asleepCore,
        "asleepDeep": .asleepDeep,
        "asleepREM": .asleepREM,
    ]

    /// Every type the app asks to write.
    public static var shareTypes: Set<HKSampleType> {
        Set(all.map(\.type))
    }
}

/// Why an item was not written, in a word the outcome can carry.
public enum WriteRefused: Error, Equatable {
    case code(OutcomeCode)
}

/// The part of `HKHealthStore` the writer uses, so it can be tested against
/// arrays. Samples are found by their sync identifier because that is the only
/// way the writer ever looks for one.
public protocol HealthStoring {
    func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus
    func save(_ sample: HKSample) async throws
    func delete(_ samples: [HKSample]) async throws
    func samples(of type: HKSampleType, syncIdentifier: String) async throws -> [HKSample]
}

extension HKHealthStore: HealthStoring {
    public func save(_ sample: HKSample) async throws {
        try await save(sample as HKObject)
    }

    public func delete(_ samples: [HKSample]) async throws {
        try await delete(samples as [HKObject])
    }

    public func samples(of type: HKSampleType, syncIdentifier: String) async throws -> [HKSample] {
        let descriptor = HKSampleQueryDescriptor(
            predicates: [.sample(
                type: type,
                predicate: HKQuery.predicateForObjects(
                    withMetadataKey: HKMetadataKeySyncIdentifier, allowedValues: [syncIdentifier]
                )
            )],
            sortDescriptors: []
        )
        return try await descriptor.result(for: self)
    }
}

/// Writes what an agent asked for into Health, one item at a time.
public protocol HealthWriter {
    /// Whether some writable type has never been asked about. The system sheet
    /// has not been shown, so nothing can be written yet and nothing is refused
    /// either: the edits wait.
    func writeAccessUndecided() -> Bool
    /// Put the sample, replacing what this app wrote under the same id, and
    /// answer the days that changed: the one it landed on, and the one the
    /// replaced sample left if that was another.
    func apply(_ item: EditItem.Put, version: Int) async throws -> Set<String>
    /// Remove what this app wrote under `id`, answering the days it was in.
    func remove(id: String) async throws -> Set<String>
}

/// The real one.
///
/// Every refusal is a `WriteRefused` with its word, so an edit with one bad
/// item still gets its other items applied. What is not a refusal is Health
/// being unreachable — a locked phone — and that is thrown as it came, because
/// it says nothing about the item and everything about the moment.
public struct HealthKitWriter: HealthWriter {
    /// How long one stretch of sleep may be. A night is under this; a stage
    /// longer than a day is a typo in the instants.
    public static let longestSleep: TimeInterval = 24 * 60 * 60

    private let store: any HealthStoring
    private let calendar: Calendar
    private let now: () -> Date

    public init(
        store: any HealthStoring = HKHealthStore(),
        calendar: Calendar = Day.calendar(),
        now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.calendar = calendar
        self.now = now
    }

    public func writeAccessUndecided() -> Bool {
        WritableMetric.all.contains { store.authorizationStatus(for: $0.type) == .notDetermined }
    }

    public func apply(_ item: EditItem.Put, version: Int) async throws -> Set<String> {
        guard let metric = WritableMetric.named(item.metric) else {
            throw WriteRefused.code(.unknownMetric)
        }
        guard store.authorizationStatus(for: metric.type) == .sharingAuthorized else {
            throw WriteRefused.code(.unauthorized)
        }
        let start = Date(timeIntervalSince1970: TimeInterval(item.start))
        let end = Date(timeIntervalSince1970: TimeInterval(item.end))
        // HealthKit refuses a sample that ends in the future, with an error
        // that names nothing. Said here instead, with a word.
        guard end >= start, end <= now() else { throw WriteRefused.code(.badRange) }

        let metadata: [String: Any] = [
            HKMetadataKeySyncIdentifier: Self.syncIdentifier(item.id),
            HKMetadataKeySyncVersion: version,
        ]
        let sample: HKSample
        if let unit = metric.unit, let type = metric.type as? HKQuantityType {
            guard item.stage == nil, item.unit == unit.unitString else {
                throw WriteRefused.code(.badUnit)
            }
            guard let value = item.value, value.isFinite, value >= 0 else {
                throw WriteRefused.code(.badRange)
            }
            sample = HKQuantitySample(
                type: type,
                quantity: HKQuantity(unit: unit, doubleValue: value),
                start: start,
                end: end,
                metadata: metadata
            )
        } else if let type = metric.type as? HKCategoryType {
            guard item.value == nil, item.unit == nil,
                  let stage = item.stage.flatMap({ WritableMetric.sleepStages[$0] })
            else {
                throw WriteRefused.code(.badUnit)
            }
            guard end.timeIntervalSince(start) <= Self.longestSleep else {
                throw WriteRefused.code(.badRange)
            }
            sample = HKCategorySample(
                type: type, value: stage.rawValue, start: start, end: end, metadata: metadata
            )
        } else {
            throw WriteRefused.code(.unknownMetric)
        }

        // The day the replaced sample was in, before it goes: a meal moved to
        // another day leaves that day changed too, and after the save nothing
        // could ask where it had been.
        var days = try await daysHeld(metric: metric, id: item.id)
        try await saving { try await store.save(sample) }
        days.insert(Day.of(start, in: calendar))
        return days
    }

    public func remove(id: String) async throws -> Set<String> {
        var days: Set<String> = []
        var found: [HKSample] = []
        for metric in WritableMetric.all {
            let samples = try await saving {
                try await store.samples(of: metric.type, syncIdentifier: Self.syncIdentifier(id))
            }
            for sample in samples {
                days.insert(Day.of(sample.startDate, in: calendar))
            }
            found += samples
        }
        guard !found.isEmpty else { throw WriteRefused.code(.notFound) }
        try await saving { try await store.delete(found) }
        return days
    }

    private func daysHeld(metric: WritableMetric, id: String) async throws -> Set<String> {
        let held = try await saving {
            try await store.samples(of: metric.type, syncIdentifier: Self.syncIdentifier(id))
        }
        return Set(held.map { Day.of($0.startDate, in: calendar) })
    }

    /// `efferent:<id>` — the agent's handle, in a namespace of this app's own,
    /// so it can never collide with a sync identifier another app chose.
    static func syncIdentifier(_ id: String) -> String {
        "efferent:" + id
    }

    /// Health's own refusals, sorted into words. A locked phone is not one of
    /// them and is thrown as it came.
    private func saving<T>(_ work: () async throws -> T) async throws -> T {
        do {
            return try await work()
        } catch {
            if HealthReader.isLocked(error) {
                throw error
            }
            let failure = error as NSError
            if failure.domain == HKError.errorDomain,
               failure.code == HKError.Code.errorAuthorizationDenied.rawValue
            {
                throw WriteRefused.code(.unauthorized)
            }
            throw WriteRefused.code(.healthRefused)
        }
    }
}
