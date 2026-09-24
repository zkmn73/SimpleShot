import Cocoa
import XCTest

/// Selection snapping reads the screenshot's own edges so a drag lands exactly
/// on a window or toolbar boundary. A wrong mapping snaps to the wrong place,
/// which is worse than not snapping at all.
final class BoundarySnapIndexTests: XCTestCase {

    /// An image with one hard vertical edge at `edgeX` and one horizontal edge
    /// at `edgeY` (both in image pixels, y from the bottom).
    private func edgedImage(width: Int = 200, height: Int = 160,
                            edgeX: Int = 80, edgeY: Int = 60) -> CGImage {
        let image = ImageProbe.makeImage(width: width, height: height) { context in
            context.setFillColor(CGColor(gray: 0.95, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))
            context.setFillColor(CGColor(gray: 0.05, alpha: 1))
            context.fill(CGRect(x: edgeX, y: 0, width: width - edgeX, height: height))
            context.setFillColor(CGColor(gray: 0.5, alpha: 1))
            context.fill(CGRect(x: 0, y: 0, width: width, height: edgeY))
        }
        return image.cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testAVerticalEdgeIsFound() throws {
        let drawRect = NSRect(x: 0, y: 0, width: 200, height: 160)
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: edgedImage(), drawRect: drawRect))
        let hit = try XCTUnwrap(index.nearestVertical(toViewX: 76, yMinView: 100, yMaxView: 150, radiusPoints: 12),
                                "a hard light/dark edge must be snappable")
        XCTAssertEqual(hit.viewPosition, 80, accuracy: 1.5)
    }

    func testAHorizontalEdgeIsFound() throws {
        let drawRect = NSRect(x: 0, y: 0, width: 200, height: 160)
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: edgedImage(), drawRect: drawRect))
        // The band's top edge is 60px up from the bottom of the image, and the
        // index maps image rows back to AppKit's bottom-left origin, so it
        // lands at view Y 60.
        let hit = try XCTUnwrap(index.nearestHorizontal(toViewY: 56, xMinView: 10, xMaxView: 60, radiusPoints: 12))
        XCTAssertEqual(hit.viewPosition, 60, accuracy: 1.5)
    }

    func testNothingSnapsInAFlatImage() throws {
        let flat = ImageProbe.solidImage(width: 100, height: 100, color: CGColor(gray: 0.6, alpha: 1))
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        let index = try XCTUnwrap(BoundarySnapIndex.build(from: flat, drawRect: NSRect(x: 0, y: 0, width: 100, height: 100)))
        XCTAssertNil(index.nearestVertical(toViewX: 50, yMinView: 10, yMaxView: 90, radiusPoints: 20),
                     "a blank wall of colour has no edge to snap to")
        XCTAssertNil(index.nearestHorizontal(toViewY: 50, xMinView: 10, xMaxView: 90, radiusPoints: 20))
    }

    func testAnEdgeOutsideTheSnapRadiusIsIgnored() throws {
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        XCTAssertNil(index.nearestVertical(toViewX: 20, yMinView: 10, yMaxView: 150, radiusPoints: 5),
                     "snapping must not yank the selection across the screen")
    }

    func testDegenerateImagesAreRefused() throws {
        let onePixel = ImageProbe.solidImage(width: 1, height: 1)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
        XCTAssertNil(BoundarySnapIndex.build(from: onePixel, drawRect: NSRect(x: 0, y: 0, width: 1, height: 1)))
        XCTAssertNil(BoundarySnapIndex.build(from: edgedImage(), drawRect: .zero),
                     "a zero draw rect has no mapping to image pixels")
    }

    func testAnInvertedSpanStillWorks() throws {
        // The caller may pass the drag's start/end in either order.
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        let forward = index.nearestVertical(toViewX: 78, yMinView: 20, yMaxView: 140, radiusPoints: 12)
        let reversed = index.nearestVertical(toViewX: 78, yMinView: 140, yMaxView: 20, radiusPoints: 12)
        XCTAssertEqual(forward?.viewPosition, reversed?.viewPosition)
    }

    func testASpanOutsideTheImageDoesNotCrash() throws {
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: edgedImage(), drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        _ = index.nearestVertical(toViewX: -500, yMinView: -900, yMaxView: 900, radiusPoints: 30)
        _ = index.nearestHorizontal(toViewY: 9999, xMinView: -50, xMaxView: 9999, radiusPoints: 30)
    }

    func testAScaledDrawRectMapsBackToViewCoordinates() throws {
        // A Retina capture: 400x320 pixels drawn into a 200x160 point rect.
        let retina = edgedImage(width: 400, height: 320, edgeX: 160, edgeY: 120)
        let index = try XCTUnwrap(BoundarySnapIndex.build(
            from: retina, drawRect: NSRect(x: 0, y: 0, width: 200, height: 160)))
        let hit = try XCTUnwrap(index.nearestVertical(toViewX: 76, yMinView: 20, yMaxView: 140, radiusPoints: 12))
        XCTAssertEqual(hit.viewPosition, 80, accuracy: 1.5, "pixel 160 of a 2x capture is point 80")
    }
}

/// The preview image behind the overlay is a downscale of the capture. It has
/// to stay proportional and never collapse to nothing.
final class DisplayPreviewImageTests: XCTestCase {

    private func image(_ width: Int, _ height: Int) -> CGImage {
        ImageProbe.solidImage(width: width, height: height)
            .cgImage(forProposedRect: nil, context: nil, hints: nil)!
    }

    func testALargeCaptureIsScaledDownToTheCap() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(5120, 2880), maxPixelDimension: 1400)
        XCTAssertEqual(max(preview.width, preview.height), 1400)
        XCTAssertEqual(Double(preview.width) / Double(preview.height),
                       5120.0 / 2880.0, accuracy: 0.01, "aspect ratio must survive")
    }

    func testASmallCaptureIsReturnedUntouched() {
        let original = image(800, 600)
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: original, maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 800)
        XCTAssertEqual(preview.height, 600)
    }

    func testAnExtremeAspectRatioKeepsBothDimensionsAtLeastOnePixel() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(10000, 3), maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 1400)
        XCTAssertGreaterThanOrEqual(preview.height, 1, "a zero-height image can't be drawn")
    }

    func testAOnePixelCaptureSurvives() {
        let preview = ScreenCaptureManager.makeDisplayPreviewImage(from: image(1, 1), maxPixelDimension: 1400)
        XCTAssertEqual(preview.width, 1)
        XCTAssertEqual(preview.height, 1)
    }
}

/// Flipping must leave an independently-captured snapped-window image alone —
/// only Invert (now removed) touched it; a flip's undo must not clear it.
@MainActor
final class WindowSnapFlipTests: XCTestCase {

    private func makeOverlay() -> OverlayView {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 200, height: 160)
        view.screenshotImage = ImageProbe.solidImage(
            width: 200, height: 160, color: CGColor(srgbRed: 0.8, green: 0.2, blue: 0.1, alpha: 1))
        view.applySelection(NSRect(x: 20, y: 20, width: 100, height: 80))
        return view
    }

    func testFlippingDoesNotDisturbTheSnappedWindowImage() throws {
        let overlay = makeOverlay()
        let snap = ImageProbe.solidImage(width: 100, height: 80)
        overlay.snappedWindowImage = snap

        overlay.flipImageHorizontally()
        XCTAssertTrue(overlay.snappedWindowImage === snap)
        overlay.undo()
        XCTAssertTrue(overlay.snappedWindowImage === snap, "undoing a flip must not clear the window capture")
    }
}
