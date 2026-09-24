import Cocoa
import XCTest

/// Captures and settings written by older builds must keep loading. Swift's
/// synthesized `init(from:)` demands a key for every non-optional property even
/// when it has a default, so before `LenientDecoding.swift` existed, adding one
/// field to a persisted model silently discarded every annotation in older
/// captures — and, for the history index, every entry at once.
final class LegacyDecodingTests: XCTestCase {

    // MARK: - Annotations

    /// Exactly the fields `CodableAnnotation` required at its first version.
    private let oldestAnnotationJSON = """
    [{"tool":3,"startX":10,"startY":20,"endX":110,"endY":80,"colorRGBA":[1,0,0,1],"strokeWidth":4}]
    """

    func testCaptureFromTheOldestFormatStillLoads() throws {
        let annotations = try XCTUnwrap(
            AnnotationSerializer.decode(Data(oldestAnnotationJSON.utf8)),
            "a capture written before later fields existed must still open with its annotations")
        XCTAssertEqual(annotations.count, 1)
        let ann = annotations[0]
        XCTAssertEqual(ann.tool, .rectangle)
        XCTAssertEqual(ann.startPoint, NSPoint(x: 10, y: 20))
        XCTAssertEqual(ann.endPoint, NSPoint(x: 110, y: 80))
        XCTAssertEqual(ann.strokeWidth, 4)
        // Fields that didn't exist yet fall back to today's defaults.
        XCTAssertEqual(ann.fontSize, 20)
        XCTAssertEqual(ann.dimOpacity, 0.55, accuracy: 0.0001)
        XCTAssertEqual(ann.loupeMagnification, 2.0)
        XCTAssertEqual(ann.censorMode, .pixelate)
        XCTAssertEqual(ann.lineStyle, .solid)
    }

    func testEveryFieldMayBeAbsentExceptTool() throws {
        let annotations = try XCTUnwrap(AnnotationSerializer.decode(Data("""
        [{"tool":0}]
        """.utf8)), "only the tool is genuinely required to draw an annotation")
        XCTAssertEqual(annotations.first?.tool, .pencil)
    }

    func testAnnotationWithoutAToolIsSkipped() {
        XCTAssertNil(AnnotationSerializer.decode(Data("""
        [{"startX":1,"startY":2,"endX":3,"endY":4,"colorRGBA":[0,0,0,1],"strokeWidth":1}]
        """.utf8)), "an annotation with no tool can't be drawn, so it's dropped")
    }

    func testOneCorruptAnnotationDoesNotDiscardTheOthers() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":1},
         {"tool":"not-a-number"},
         {"tool":3,"startX":9,"startY":9,"endX":19,"endY":19,"colorRGBA":[0,1,0,1],"strokeWidth":2}]
        """
        let annotations = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8)))
        XCTAssertEqual(annotations.count, 2, "a corrupt entry should cost one annotation, not the whole capture")
        XCTAssertEqual(annotations.map(\.tool), [.pencil, .rectangle])
    }

    func testWrongTypedFieldFallsBackInsteadOfDiscardingTheAnnotation() throws {
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":"thick",
          "fontSize":"big","isBold":"yes","rotation":null}]
        """
        let ann = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8))?.first)
        XCTAssertEqual(ann.strokeWidth, 3, "a non-numeric stroke width falls back to the default")
        XCTAssertEqual(ann.fontSize, 20)
        XCTAssertFalse(ann.isBold)
        XCTAssertEqual(ann.rotation, 0)
    }

    func testUnknownFutureFieldsAreIgnored() throws {
        // A capture written by a newer build must still open in an older one.
        let json = """
        [{"tool":0,"startX":0,"startY":0,"endX":5,"endY":5,"colorRGBA":[1,0,0,1],"strokeWidth":2,
          "somethingAddedLater":{"nested":true},"anotherNewField":[1,2,3]}]
        """
        let ann = try XCTUnwrap(AnnotationSerializer.decode(Data(json.utf8))?.first)
        XCTAssertEqual(ann.tool, .pencil)
        XCTAssertEqual(ann.strokeWidth, 2)
    }

    func testTodaysFormatStillRoundTripsAfterTheLenientDecoder() throws {
        let ann = AnnotationPersistenceTests.fullyPopulated(tool: .arrow)
        let data = try XCTUnwrap(AnnotationSerializer.encode([ann]))
        let decoded = try XCTUnwrap(AnnotationSerializer.decode(data)?.first)
        XCTAssertEqual(decoded.arrowStyle, ann.arrowStyle)
        XCTAssertEqual(decoded.randomSeed, ann.randomSeed)
        XCTAssertEqual(decoded.dimOpacity, ann.dimOpacity, accuracy: 0.0001)
    }

    // MARK: - LenientArrayDecoder itself

    func testLenientArrayDecoderReturnsNilForNonArrayData() {
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("{}".utf8)))
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("garbage".utf8)))
    }

    func testLenientArrayDecoderReturnsNilWhenEveryElementIsCorrupt() {
        XCTAssertNil(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data("[{},{},{}]".utf8)))
    }

    func testLenientArrayDecoderKeepsOrder() throws {
        let json = "[" + (0..<5).map { #"{"tool":\#($0),"startX":\#($0)}"# }.joined(separator: ",") + "]"
        let decoded = try XCTUnwrap(LenientArrayDecoder.decode(CodableAnnotation.self, from: Data(json.utf8)))
        XCTAssertEqual(decoded.map(\.tool), [0, 1, 2, 3, 4])
    }
}
