import Cocoa
import XCTest

/// A URL action like `capture-fullscreen-quick` sets one of the four `auto*Mode`
/// flags and calls `applyFullScreenSelection()` directly, skipping the drag/click
/// that normally leads to `finishSelection()`. A prior bug had
/// `applyFullScreenSelection()` never check those flags at all, so a fully
/// automatic URL action silently did nothing. These tests pin down that a
/// full-screen selection actually fires the matching auto-trigger exactly once,
/// resets the flag so it can't fire again on a later manual confirm, and that a
/// selection with no auto mode set behaves like a normal manual selection.
@MainActor
final class OverlayAutoModeTests: XCTestCase {

    private final class RecordingDelegate: NSObject, OverlayViewDelegate {
        var ocrRequested = 0
        var quickSaveRequested = 0
        var scrollCaptureRequested = 0
        var confirmed = 0

        func overlayViewDidFinishSelection(_ rect: NSRect) {}
        func overlayViewSelectionDidChange(_ rect: NSRect) {}
        func overlayViewDidCancel() {}
        func overlayViewDidConfirm() { confirmed += 1 }
        func overlayViewDidRequestSave() {}
        func overlayViewDidRequestSaveAs() {}
        func overlayViewDidRequestOCR() { ocrRequested += 1 }
        func overlayViewDidRequestQuickSave() { quickSaveRequested += 1 }
        func overlayViewDidRequestFileSave() {}
        func overlayViewDidRequestDetach() {}
        func overlayViewDidRequestScrollCapture(rect: NSRect) { scrollCaptureRequested += 1 }
        func overlayViewDidRequestStopScrollCapture() {}
        func overlayViewDidRequestCancelScrollCapture() {}
        func overlayViewDidRequestToggleAutoScroll() {}
        func overlayViewDidRequestAccessibilityPermission() {}
        func overlayViewDidBeginSelection() {}
        func overlayViewRemoteSelectionDidChange(_ rect: NSRect) {}
        func overlayViewDidChangeSnapMode() {}
        func overlayViewRemoteSelectionDidFinish(_ rect: NSRect) {}
        func overlayViewDidRequestAddCapture() {}
    }

    private func makeOverlay() -> (OverlayView, RecordingDelegate) {
        let view = OverlayView()
        view.frame = NSRect(x: 0, y: 0, width: 400, height: 300)
        view.screenshotImage = ImageProbe.quadrantImage(width: 400, height: 300)
        let delegate = RecordingDelegate()
        view.overlayDelegate = delegate
        return (view, delegate)
    }

    func testFullScreenSelectionFiresQuickSaveAutoMode() {
        let (view, delegate) = makeOverlay()
        view.autoQuickSaveMode = true
        view.applyFullScreenSelection()
        XCTAssertEqual(delegate.quickSaveRequested, 1)
        XCTAssertFalse(view.autoQuickSaveMode, "one-shot: must not be able to fire again later")
    }

    func testFullScreenSelectionFiresOCRAutoMode() {
        let (view, delegate) = makeOverlay()
        view.autoOCRMode = true
        view.applyFullScreenSelection()
        XCTAssertEqual(delegate.ocrRequested, 1)
        XCTAssertFalse(view.autoOCRMode)
    }

    func testFullScreenSelectionFiresScrollCaptureAutoMode() {
        let (view, delegate) = makeOverlay()
        view.autoScrollCaptureMode = true
        view.applyFullScreenSelection()
        XCTAssertEqual(delegate.scrollCaptureRequested, 1)
        XCTAssertFalse(view.autoScrollCaptureMode)
    }

    func testFullScreenSelectionFiresConfirmAutoMode() {
        let (view, delegate) = makeOverlay()
        view.autoConfirmMode = true
        view.applyFullScreenSelection()
        XCTAssertEqual(delegate.confirmed, 1)
        XCTAssertFalse(view.autoConfirmMode)
    }

    func testFullScreenSelectionWithNoAutoModeDoesNotAutoTrigger() {
        let (view, delegate) = makeOverlay()
        view.applyFullScreenSelection()
        XCTAssertEqual(delegate.quickSaveRequested, 0)
        XCTAssertEqual(delegate.ocrRequested, 0)
        XCTAssertEqual(delegate.scrollCaptureRequested, 0)
        XCTAssertEqual(delegate.confirmed, 0)
        XCTAssertTrue(view.showToolbars, "a manual full-screen selection still needs its toolbar")
    }
}
