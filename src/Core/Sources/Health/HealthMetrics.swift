import Foundation
import HealthKit

/// A metric collected as de-duplicated totals per time bucket.
///
/// Only cumulative quantities belong here, and that is the whole reason the
/// catalogue is split in two. iPhone, Watch and third-party apps all write steps
/// for the same minutes; adding the raw samples up double-counts, and the
/// numbers then disagree with what the person sees in the Health app.
/// `HKStatisticsCollectionQuery` is the only thing that picks a source per
/// interval the way Apple does, so cumulative metrics always go through it.
public struct AggregateMetric: Sendable {
    /// Stable name on the wire. Never derive it from the HealthKit identifier —
    /// Apple renames those, and the reader on the other side would break.
    public let name: String
    public let type: HKQuantityType
    public let unit: HKUnit

    init(name: String, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit) {
        self.name = name
        type = HKQuantityType(identifier)
        self.unit = unit
    }

    public static let all: [AggregateMetric] = [
        .init(name: "steps", .stepCount, .count()),
        .init(name: "distanceWalkingRunning", .distanceWalkingRunning, .meter()),
        .init(name: "activeEnergy", .activeEnergyBurned, .kilocalorie()),
        .init(name: "basalEnergy", .basalEnergyBurned, .kilocalorie()),
        .init(name: "flightsClimbed", .flightsClimbed, .count()),
        .init(name: "exerciseTime", .appleExerciseTime, .minute()),
        .init(name: "standTime", .appleStandTime, .minute()),
    ]
}

/// A metric kept record by record, because a total would say nothing.
///
/// A night of sleep is a set of overlapping stretches; a workout is one event
/// with its own shape; a heart rate is a reading at a moment. Summing any of
/// them is meaningless, so these travel as they are and whoever reads them
/// decides what a "night" or a "session" means.
public struct SampleMetric: Sendable {
    public let name: String
    public let type: HKSampleType
    let encode: @Sendable (HKSample) throws -> Data

    public static let all: [SampleMetric] = [
        SampleMetric(name: "sleep", type: HKCategoryType(.sleepAnalysis), encode: encodeSleep),
        SampleMetric(name: "workout", type: HKObjectType.workoutType(), encode: encodeWorkout),
        quantity("heartRate", .heartRate, HKUnit.count().unitDivided(by: .minute())),
        quantity("heartRateVariability", .heartRateVariabilitySDNN, .secondUnit(with: .milli)),
        quantity("restingHeartRate", .restingHeartRate, HKUnit.count().unitDivided(by: .minute())),
        quantity("respiratoryRate", .respiratoryRate, HKUnit.count().unitDivided(by: .minute())),
        quantity("oxygenSaturation", .oxygenSaturation, .percent()),
    ]

    private static func quantity(
        _ name: String, _ identifier: HKQuantityTypeIdentifier, _ unit: HKUnit
    ) -> SampleMetric {
        SampleMetric(name: name, type: HKQuantityType(identifier)) { sample in
            guard let quantity = (sample as? HKQuantitySample)?.quantity else {
                throw HealthError.unexpectedSampleType(metric: name)
            }
            return try Event.payload(QuantityPayload(
                metric: name,
                start: sample.startDate,
                end: sample.endDate,
                value: quantity.doubleValue(for: unit),
                unit: unit.unitString,
                source: sample.sourceRevision.source.name
            ))
        }
    }
}

public enum HealthError: Error, Equatable {
    case unexpectedSampleType(metric: String)
    case notAvailableOnThisDevice
}

// MARK: - Wire payloads

struct AggregatePayload: Encodable {
    let metric: String
    let bucket: String
    let start: Date
    let end: Date
    let value: Double
    let unit: String
}

struct QuantityPayload: Encodable {
    let metric: String
    let start: Date
    let end: Date
    let value: Double
    let unit: String
    let source: String
}

struct SleepPayload: Encodable {
    let metric: String
    let start: Date
    let end: Date
    let stage: String
    let source: String
}

struct WorkoutPayload: Encodable {
    let metric: String
    let start: Date
    let end: Date
    let activity: String
    let duration: Double
    let source: String
}

/// A deletion names its metric so the receiver never has to parse the id apart.
struct DeletionPayload: Encodable {
    let metric: String
}

// MARK: - Encoders

@Sendable private func encodeSleep(_ sample: HKSample) throws -> Data {
    guard let category = sample as? HKCategorySample else {
        throw HealthError.unexpectedSampleType(metric: "sleep")
    }
    return try Event.payload(SleepPayload(
        metric: "sleep",
        start: sample.startDate,
        end: sample.endDate,
        stage: sleepStageName(category.value),
        source: sample.sourceRevision.source.name
    ))
}

/// Since iOS 16 a night is not one interval but a set of overlapping stretches
/// with stages. They are sent exactly as recorded; stitching them into "a night"
/// is a judgement call, and it belongs where it can be changed without shipping
/// a new build.
private func sleepStageName(_ value: Int) -> String {
    switch HKCategoryValueSleepAnalysis(rawValue: value) {
    case .inBed: return "inBed"
    case .awake: return "awake"
    case .asleepUnspecified: return "asleepUnspecified"
    case .asleepCore: return "asleepCore"
    case .asleepDeep: return "asleepDeep"
    case .asleepREM: return "asleepREM"
    default: return "unknown"
    }
}

@Sendable private func encodeWorkout(_ sample: HKSample) throws -> Data {
    guard let workout = sample as? HKWorkout else {
        throw HealthError.unexpectedSampleType(metric: "workout")
    }
    return try Event.payload(WorkoutPayload(
        metric: "workout",
        start: workout.startDate,
        end: workout.endDate,
        activity: String(workout.workoutActivityType.rawValue),
        duration: workout.duration,
        source: workout.sourceRevision.source.name
    ))
}
