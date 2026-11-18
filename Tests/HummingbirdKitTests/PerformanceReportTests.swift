import Foundation
import XCTest
@testable import HummingbirdKit

/// MetricKit payload handling, fed stand-in payloads: MetricKit's payload
/// classes cannot be constructed outside the system (use Xcode's Debug >
/// Simulate MetricKit Payloads for the real path).
final class PerformanceReportTests: XCTestCase {
    func testStoreKeepsNewestReportsWithinLimits() throws {
        let stores = makeTestStores()
        let store = PerformanceReportStore(cachesDirectory: stores.cachesDirectory, maximumFiles: 3, maximumBytes: 1_000)
        for index in 0..<5 {
            try store.write(Data("{\"index\":\(index)}".utf8), kind: "hang",
                            begin: Date(timeIntervalSince1970: TimeInterval(index)),
                            end: Date(timeIntervalSince1970: TimeInterval(index + 100)))
        }
        let names = store.reports().map(\.lastPathComponent)
        XCTAssertEqual(names, ["hang-104-4.json", "hang-103-3.json", "hang-102-2.json"])
        XCTAssertTrue(store.directory.path.hasPrefix(stores.cachesDirectory.path))
    }

    func testStoreDropsReportsBeyondByteLimit() throws {
        let store = PerformanceReportStore(cachesDirectory: makeTestStores().cachesDirectory, maximumFiles: 10, maximumBytes: 25)
        try store.write(Data(repeating: 0x20, count: 20), kind: "crash", begin: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2))
        try store.write(Data(repeating: 0x20, count: 20), kind: "crash", begin: Date(timeIntervalSince1970: 3), end: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(store.reports().map(\.lastPathComponent), ["crash-4-3.json"])
    }

    func testExportBundlesEveryReport() async throws {
        let stores = makeTestStores()
        let store = PerformanceReportStore(cachesDirectory: stores.cachesDirectory)
        let nothing = try await store.exportBundle(to: makeTestDirectory())
        XCTAssertNil(nothing)
        try store.write(Data("{\"hangDiagnostics\":[]}".utf8), kind: "hang", begin: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2))
        try store.write(Data("{\"crashDiagnostics\":[]}".utf8), kind: "crash", begin: Date(timeIntervalSince1970: 3), end: Date(timeIntervalSince1970: 4))
        let exported = try await store.exportBundle(to: makeTestDirectory())
        let url = try XCTUnwrap(exported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let reports = try XCTUnwrap(object["reports"] as? [[String: Any]])
        XCTAssertEqual(reports.compactMap { $0["file"] as? String }, ["crash-4-3.json", "hang-2-1.json"])
        XCTAssertNotNil(reports.first?["payload"] as? [String: Any])
    }

    func testStallLogKeepsNewestRecordsWithinLimits() async throws {
        let stores = makeTestStores()
        let log = StallLog(cachesDirectory: stores.cachesDirectory, maximumRecords: 2, maximumAge: 60 * 60)
        let now = Date()
        log.append(.init(date: now.addingTimeInterval(-2 * 60 * 60), milliseconds: 900, context: [:]))
        log.append(.init(date: now.addingTimeInterval(-3), milliseconds: 300, context: ["route": "home"]))
        log.append(.init(date: now.addingTimeInterval(-2), milliseconds: 400, context: [:]))
        log.append(.init(date: now.addingTimeInterval(-1), milliseconds: 500, context: [:]))
        await log.flush()
        let records = await log.records()
        XCTAssertEqual(records.map(\.milliseconds), [400, 500])
        XCTAssertTrue(log.fileURL.path.hasPrefix(stores.cachesDirectory.path))
    }

    func testExportIncludesRecordedStalls() async throws {
        let stores = makeTestStores()
        let store = PerformanceReportStore(cachesDirectory: stores.cachesDirectory)
        store.stallLog.append(.init(date: Date(), milliseconds: 1_234, context: ["route": "library"]))
        await store.stallLog.flush()
        let exported = try await store.exportBundle(to: makeTestDirectory())
        let url = try XCTUnwrap(exported)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
        let stalls = try XCTUnwrap(object["stalls"] as? [[String: Any]])
        XCTAssertEqual(stalls.first?["milliseconds"] as? Int, 1_234)
        XCTAssertEqual((stalls.first?["context"] as? [String: String])?["route"], "library")
        XCTAssertEqual((object["reports"] as? [Any])?.count, 0)
    }

    func testClearDeletesReportsStallsAndExport() async throws {
        let stores = makeTestStores()
        let store = PerformanceReportStore(cachesDirectory: stores.cachesDirectory)
        try store.write(Data("{\"hangDiagnostics\":[]}".utf8), kind: "hang", begin: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2))
        store.stallLog.append(.init(date: Date(), milliseconds: 900, context: [:]))
        await store.stallLog.flush()
        let exportDirectory = makeTestDirectory().appendingPathComponent("Export", isDirectory: true)
        let exported = try await store.exportBundle(to: exportDirectory)
        XCTAssertNotNil(exported)

        try await store.clear(exportDirectory: exportDirectory)

        XCTAssertEqual(store.reports(), [])
        let stalls = await store.stallLog.records()
        XCTAssertEqual(stalls, [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: exportDirectory.path))
        let afterwards = try await store.exportBundle(to: exportDirectory)
        XCTAssertNil(afterwards, "nothing is left to export")
    }

    func testRetentionDropsPayloadsOlderThanTheMaximumAge() throws {
        let stores = makeTestStores()
        let store = PerformanceReportStore(cachesDirectory: stores.cachesDirectory, maximumAge: 30 * 24 * 60 * 60)
        let old = try store.write(Data("{}".utf8), kind: "hang", begin: Date(timeIntervalSince1970: 1), end: Date(timeIntervalSince1970: 2))
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-31 * 24 * 60 * 60)],
                                              ofItemAtPath: old.path)
        try store.write(Data("{}".utf8), kind: "crash", begin: Date(timeIntervalSince1970: 3), end: Date(timeIntervalSince1970: 4))
        XCTAssertEqual(store.reports().map(\.lastPathComponent), ["crash-4-3.json"], "the oldest payload is dropped")
    }

    #if canImport(MetricKit) && !os(tvOS)
    func testReporterStoresStandInDiagnosticsUnderTheirKinds() async throws {
        let store = PerformanceReportStore(cachesDirectory: makeTestStores().cachesDirectory)
        let reporter = PerformanceReporter(store: store)
        reporter.record(
            [
                PerformanceDiagnostic(kind: .hang, applicationBuild: "7", milliseconds: 1_500),
                PerformanceDiagnostic(kind: .crash, applicationBuild: "7", signal: 11),
            ],
            json: Data("{\"stand-in\":true}".utf8),
            begin: Date(timeIntervalSince1970: 10), end: Date(timeIntervalSince1970: 20)
        )
        reporter.record([], json: Data("{}".utf8), begin: Date(timeIntervalSince1970: 30), end: Date(timeIntervalSince1970: 40))
        await reporter.flush()
        XCTAssertEqual(Set(store.reports().map(\.lastPathComponent)), ["crash+hang-20-10.json", "diagnostic-40-30.json"])
    }
    #endif
}
