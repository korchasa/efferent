@testable import Efferent
import HealthKit
import XCTest

/// Writing into Health, against a store that lives in memory.
///
/// HealthKit itself is not exercised here — the simulator's store needs a
/// person to tap through a sheet — so the writer is tested through the seam it
/// takes, and what is asserted is what it hands that seam: which sample, with
/// which metadata, and which word it answers when it will not.
final class HealthWriterTests: XCTestCase {
    /// A Health store made of arrays.
    final class FakeStore: HealthStoring {
        var statuses: [String: HKAuthorizationStatus] = [:]
        var saved: [HKSample] = []
        var deleted: [HKSample] = []
        var failure: Error?

        func authorizationStatus(for type: HKObjectType) -> HKAuthorizationStatus {
            statuses[type.identifier] ?? .sharingAuthorized
        }

        func save(_ sample: HKSample) async throws {
            if let failure {
                throw failure
            }
            // What HealthKit does with a sync identifier: the older sample under
            // the same one goes when a higher version arrives.
            let identifier = sample.metadata?[HKMetadataKeySyncIdentifier] as? String
            saved.removeAll { $0.metadata?[HKMetadataKeySyncIdentifier] as? String == identifier }
            saved.append(sample)
        }

        func delete(_ samples: [HKSample]) async throws {
            if let failure {
                throw failure
            }
            deleted += samples
            saved.removeAll { sample in samples.contains { $0 === sample } }
        }

        func samples(of type: HKSampleType, syncIdentifier: String) async throws -> [HKSample] {
            saved.filter {
                $0.sampleType == type
                    && $0.metadata?[HKMetadataKeySyncIdentifier] as? String == syncIdentifier
            }
        }
    }

    static let utc = Day.calendar(timeZone: TimeZone(secondsFromGMT: 0)!)

    private func writer(_ store: FakeStore, now: Date = Date(timeIntervalSince1970: 1_757_300_000))
        -> HealthKitWriter
    {
        HealthKitWriter(store: store, calendar: Self.utc, now: { now })
    }

    private func meal(
        id: String = "agent:meal:1", metric: String = "dietaryEnergy",
        start: Int64 = 1_757_228_400, end: Int64 = 1_757_229_300,
        value: Double? = 520, unit: String? = "kcal", stage: String? = nil
    ) -> EditItem.Put {
        EditItem.Put(id: id, metric: metric, start: start, end: end, value: value, unit: unit, stage: stage)
    }

    // MARK: - The catalogue

    func testEveryWritableMetricIsAlsoRead() {
        let readable = Dictionary(
            uniqueKeysWithValues: (AggregateMetric.all.map { ($0.type.identifier, $0.name) }
                + SampleMetric.all.map { ($0.type.identifier, $0.name) })
        )
        for metric in WritableMetric.all {
            XCTAssertEqual(
                readable[metric.type.identifier], metric.name,
                "\(metric.name) can be written but would never show up in the archive"
            )
        }
        XCTAssertEqual(
            WritableMetric.all.map(\.name),
            ["sleep", "dietaryEnergy", "dietaryProtein", "dietaryCarbohydrates", "dietaryFat", "dietaryWater", "bodyMass"]
        )
    }

    func testTheUnitsAreTheOnesTheProtocolNames() {
        let units = Dictionary(uniqueKeysWithValues: WritableMetric.all.map { ($0.name, $0.unit?.unitString) })
        XCTAssertEqual(units["dietaryEnergy"], "kcal")
        XCTAssertEqual(units["dietaryProtein"], "g")
        XCTAssertEqual(units["dietaryCarbohydrates"], "g")
        XCTAssertEqual(units["dietaryFat"], "g")
        XCTAssertEqual(units["dietaryWater"], "mL")
        XCTAssertEqual(units["bodyMass"], "kg")
        XCTAssertNil(units["sleep"] ?? nil)
    }

    func testTheSleepStagesRoundTripThroughTheirNames() {
        for (name, value) in WritableMetric.sleepStages {
            XCTAssertEqual(sleepStageName(value.rawValue), name)
        }
        XCTAssertEqual(WritableMetric.sleepStages.count, 6)
    }

    func testTheAppAsksToWriteEveryMetricItCanWrite() {
        for metric in WritableMetric.all {
            XCTAssertTrue(WritableMetric.shareTypes.contains(metric.type), "missing \(metric.name)")
        }
    }

    // MARK: - Putting a sample

    func testAQuantityIsSavedWithItsSyncIdentifierAndVersion() async throws {
        let store = FakeStore()
        let days = try await writer(store).apply(meal(), version: 3)

        XCTAssertEqual(days, ["2025-09-07"])
        let sample = try XCTUnwrap(store.saved.first as? HKQuantitySample)
        XCTAssertEqual(sample.quantityType, HKQuantityType(.dietaryEnergyConsumed))
        XCTAssertEqual(sample.quantity.doubleValue(for: .kilocalorie()), 520)
        XCTAssertEqual(sample.startDate, Date(timeIntervalSince1970: 1_757_228_400))
        XCTAssertEqual(sample.endDate, Date(timeIntervalSince1970: 1_757_229_300))
        XCTAssertEqual(sample.metadata?[HKMetadataKeySyncIdentifier] as? String, "efferent:agent:meal:1")
        XCTAssertEqual(sample.metadata?[HKMetadataKeySyncVersion] as? Int, 3)
    }

    func testASleepStageIsSavedAsACategorySample() async throws {
        let store = FakeStore()
        let days = try await writer(store).apply(
            meal(id: "agent:sleep:1", metric: "sleep", start: 1_757_196_000, end: 1_757_221_200,
                 value: nil, unit: nil, stage: "asleepCore"),
            version: 1
        )
        XCTAssertEqual(days, ["2025-09-06"])
        let sample = try XCTUnwrap(store.saved.first as? HKCategorySample)
        XCTAssertEqual(sample.categoryType, HKCategoryType(.sleepAnalysis))
        XCTAssertEqual(sample.value, HKCategoryValueSleepAnalysis.asleepCore.rawValue)
    }

    func testReplacingASampleNamesTheDayItLeftAsWellAsTheDayItLanded() async throws {
        let store = FakeStore()
        let writer = writer(store)
        _ = try await writer.apply(meal(), version: 1)
        let days = try await writer.apply(
            meal(start: 1_757_228_400 - 86400, end: 1_757_229_300 - 86400), version: 2
        )
        XCTAssertEqual(days, ["2025-09-06", "2025-09-07"])
        XCTAssertEqual(store.saved.count, 1, "the fake replaced it, as HealthKit does")
        XCTAssertEqual(store.saved.first?.metadata?[HKMetadataKeySyncVersion] as? Int, 2)
    }

    // MARK: - Refusals, each with its word

    func testEachWayAnItemCanBeWrongHasItsWord() async {
        let cases: [(EditItem.Put, OutcomeCode)] = [
            (meal(metric: "steps"), .unknownMetric),
            (meal(unit: "kJ"), .badUnit),
            (meal(unit: nil), .badUnit),
            (meal(value: nil), .badRange),
            (meal(value: -1), .badRange),
            (meal(value: .infinity), .badRange),
            (meal(start: 1_757_300_100, end: 1_757_300_200), .badRange),
            (meal(metric: "sleep", value: nil, unit: nil, stage: "asleep"), .badUnit),
            (meal(metric: "sleep", value: nil, unit: nil, stage: nil), .badUnit),
            (meal(metric: "sleep", value: 1, unit: nil, stage: "awake"), .badUnit),
            (meal(metric: "sleep", start: 1_757_100_000, end: 1_757_100_000 + 25 * 3600,
                  value: nil, unit: nil, stage: "awake"), .badRange),
        ]
        for (item, expected) in cases {
            let store = FakeStore()
            do {
                _ = try await writer(store).apply(item, version: 1)
                XCTFail("\(item) was written")
            } catch let WriteRefused.code(code) {
                XCTAssertEqual(code, expected, "\(item)")
            } catch {
                XCTFail("\(item): \(error)")
            }
            XCTAssertTrue(store.saved.isEmpty)
        }
    }

    func testADeniedTypeIsUnauthorizedAndAnUndecidedOneIsNotAsked() async throws {
        let store = FakeStore()
        store.statuses[HKQuantityType(.dietaryEnergyConsumed).identifier] = .sharingDenied
        do {
            _ = try await writer(store).apply(meal(), version: 1)
            XCTFail("written without permission")
        } catch let WriteRefused.code(code) {
            XCTAssertEqual(code, .unauthorized)
        }
        XCTAssertFalse(writer(store).writeAccessUndecided())
        store.statuses[HKCategoryType(.sleepAnalysis).identifier] = .notDetermined
        XCTAssertTrue(writer(store).writeAccessUndecided())
    }

    func testHealthRefusingIsItsOwnWordAndALockedPhoneIsNot() async {
        let store = FakeStore()
        store.failure = NSError(domain: HKError.errorDomain, code: HKError.Code.errorInvalidArgument.rawValue)
        do {
            _ = try await writer(store).apply(meal(), version: 1)
            XCTFail("written")
        } catch let WriteRefused.code(code) {
            XCTAssertEqual(code, .healthRefused)
        } catch {
            XCTFail("\(error)")
        }

        store.failure = NSError(
            domain: HKError.errorDomain, code: HKError.Code.errorDatabaseInaccessible.rawValue
        )
        do {
            _ = try await writer(store).apply(meal(), version: 1)
            XCTFail("written")
        } catch is WriteRefused {
            XCTFail("a locked phone is a condition to wait out, not an answer about the item")
        } catch {
            XCTAssertTrue(HealthReader.isLocked(error))
        }
    }

    // MARK: - Removing

    func testRemovingTakesEveryTypeUnderTheIdAndNamesTheirDays() async throws {
        let store = FakeStore()
        let writer = writer(store)
        _ = try await writer.apply(meal(), version: 1)
        _ = try await writer.apply(meal(id: "agent:meal:2", start: 1_757_100_000, end: 1_757_100_100), version: 1)

        let days = try await writer.remove(id: "agent:meal:1")
        XCTAssertEqual(days, ["2025-09-07"])
        XCTAssertEqual(store.saved.count, 1)
        XCTAssertEqual(store.deleted.count, 1)

        do {
            _ = try await writer.remove(id: "agent:meal:1")
            XCTFail("removed twice")
        } catch let WriteRefused.code(code) {
            XCTAssertEqual(code, .notFound)
        }
    }
}
