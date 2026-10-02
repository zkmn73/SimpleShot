import Foundation
import XCTest

final class AtomicMediaSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: directory)
    }

    func testMissingAndEmptyExportsNeverReplaceDestination() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("only good take".utf8)
        try previous.write(to: destination)
        let save = try AtomicMediaSave(destinationURL: destination)
        XCTAssertThrowsError(try save.commit())
        try Data().write(to: save.stagingURL)
        XCTAssertThrowsError(try save.commit())
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testAbandonedPartialOutputLeavesDestinationIntact() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let previous = Data("only good take".utf8)
        try previous.write(to: destination)
        var save: AtomicMediaSave? = try AtomicMediaSave(destinationURL: destination)
        try Data("incomplete encoding".utf8).write(to: XCTUnwrap(save?.stagingURL))
        save = nil
        XCTAssertEqual(try Data(contentsOf: destination), previous)
    }

    func testFailedRenameLeavesBothDestinationAndStagedMediaAvailable() throws {
        let destination = directory.appendingPathComponent("folder.png")
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let original = destination.appendingPathComponent("do not remove.txt")
        try Data("original".utf8).write(to: original)
        let save = try AtomicMediaSave(destinationURL: destination)
        let media = Data("finished export".utf8)
        try media.write(to: save.stagingURL)
        XCTAssertThrowsError(try save.commit())
        XCTAssertEqual(try Data(contentsOf: save.stagingURL), media)
        XCTAssertEqual(try Data(contentsOf: original), Data("original".utf8))
    }

    func testSeparateJobsHaveIndependentStagingEvenWithSameDestination() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let first = try AtomicMediaSave(destinationURL: destination)
        let second = try AtomicMediaSave(destinationURL: destination)
        XCTAssertNotEqual(first.stagingURL, second.stagingURL)
        try Data("first".utf8).write(to: first.stagingURL)
        try Data("second".utf8).write(to: second.stagingURL)
        try first.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data("first".utf8))
        try second.commit()
        XCTAssertEqual(try Data(contentsOf: destination), Data("second".utf8))
    }

    func testExclusivePublicationProtectsAFileCreatedAfterDestinationWasChosen() throws {
        let destination = directory.appendingPathComponent("saved.png")
        let save = try AtomicMediaSave(destinationURL: destination)
        try Data("new take".utf8).write(to: save.stagingURL)
        try Data("another app's file".utf8).write(to: destination)
        XCTAssertThrowsError(try save.commit(overwritingExisting: false))
        XCTAssertEqual(try Data(contentsOf: destination), Data("another app's file".utf8))
    }
}
