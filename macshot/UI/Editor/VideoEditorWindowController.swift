import Cocoa
import AVFoundation
import AVKit
import UniformTypeIdentifiers

/// Standalone video editor window for trimming and exporting recorded videos.
final class VideoEditorWindowController: NSObject, NSWindowDelegate {

    private var window: NSWindow?
    private var editorView: VideoEditorView?
    private var preparationJob: MediaExportCoordinator.Job?
    private static var activeControllers: [VideoEditorWindowController] = []

    /// Open a video in the editor.
    /// - Parameters:
    ///   - url: File URL to the video.
    ///   - deleteOnClose: If true (default), temporary input is removed after
    ///     the editor and its background readers release it. Durable recordings
    ///     are always retained. Pass false for other user-owned files.
    static func open(url: URL, deleteOnClose: Bool = true) {
        let controller = VideoEditorWindowController()
        activeControllers.append(controller)
        if activeControllers.count == 1 {
            NSApp.setActivationPolicy(.regular)
        }
        controller.prepare(url: url, deleteOnClose: deleteOnClose)
    }

    private func prepare(url: URL, deleteOnClose: Bool) {
        var prepared: PreparedVideoSource?
        let job = MediaExportCoordinator.shared.start(title: url.lastPathComponent, status: L("Preparing video..."),
            operation: { cancellation, progress in
                let source = try await MediaExportIO.perform {
                    try VideoSourceSnapshot.prepare(url: url, deleteOnClose: deleteOnClose,
                                                    cancellation: cancellation, progress: progress)
                }
                prepared = try await PreparedVideoSource.load(source)
                try cancellation.beginPublication()
            }, completion: { [weak self] result in
                guard let self else { return }
                self.preparationJob = nil
                switch result {
                case .success:
                    if let prepared, self.show(prepared: prepared) { return }
                    (NSApp.delegate as? AppDelegate)?.showFailureToast(CocoaError(.fileReadUnknown).localizedDescription)
                case .failure(let error):
                    if !(error is CancellationError) {
                        (NSApp.delegate as? AppDelegate)?.showFailureToast(error.localizedDescription)
                    }
                }
                Self.activeControllers.removeAll { $0 === self }
                (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
            })
        preparationJob = job
        MediaExportProgressController.show(for: job)
    }

    private func show(prepared: PreparedVideoSource) -> Bool {
        guard let screen = NSScreen.main else { return false }
        let source = prepared.snapshot
        let url = source.originalURL

        // Size window to fit content, capped at 60% of screen
        let controlsH: CGFloat = 172
        let maxW = screen.frame.width * 0.6
        let maxH = screen.frame.height * 0.6
        var contentW: CGFloat = 800
        var contentH: CGFloat = 450

        // Get content dimensions — MP4 uses AVAsset track info
        if let size = prepared.pixelSize {
            let backingScale = screen.backingScaleFactor
            contentW = size.width / backingScale
            contentH = size.height / backingScale
        }
        // GIF: keep defaults — AVFoundation can't read GIF dimensions reliably

        // Scale down to fit screen, maintaining aspect ratio
        let scale = min(1.0, min(maxW / contentW, (maxH - controlsH) / contentH))
        let winW = max(880, contentW * scale)
        let winH = max(400, contentH * scale + controlsH)
        let winX = screen.frame.midX - winW / 2
        let winY = screen.frame.midY - winH / 2

        let win = NSWindow(
            contentRect: NSRect(x: winX, y: winY, width: winW, height: winH),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        // Prefix with the source filename so multiple editor windows are
        // distinguishable in the Dock menu and Window menu.
        win.title = "\(url.deletingPathExtension().lastPathComponent) — \(L("macshot Video Editor"))"
        win.minSize = NSSize(width: 880, height: 400)
        win.autorecalculatesKeyViewLoop = true
        win.isReleasedWhenClosed = false
        win.delegate = self
        win.collectionBehavior = [.fullScreenAuxiliary]
        win.backgroundColor = ToolbarLayout.bgColor

        let view = VideoEditorView(frame: NSRect(x: 0, y: 0, width: winW, height: winH),
                                    prepared: prepared)
        win.contentView = view

        win.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)

        self.window = win
        self.editorView = view
        return true
    }

    func windowWillClose(_ notification: Notification) {
        editorView?.cleanup()
        editorView = nil
        window = nil
        Self.activeControllers.removeAll { $0 === self }
        if Self.activeControllers.isEmpty {
            (NSApp.delegate as? AppDelegate)?.returnFocusIfNeeded()
        }
    }
}

// MARK: - VideoEditorView

private final class VideoEditorView: NSView {

    private let videoURL: URL
    private let mediaURL: URL
    private let sourceFileSize: Int64
    private let encodingSource: VideoExportEncodingPlan.Source?
    private let sourceAudioTrackCount: Int
    private var sourceSnapshot: VideoSourceSnapshot?
    /// The working copy is retained by every background reader. Disposable
    /// public inputs share its lifetime; user files and durable takes remain.
    private var sourceLease: TemporaryMediaLease?
    private let isGIF: Bool
    private var player: AVPlayer?
    private var playerView: AVPlayerView?
    private var effectsOverlay: EffectsPreviewOverlayView?
    private var gifImageView: NSImageView?
    private var asset: AVAsset?
    private var duration: Double = 0

    // Timeline state
    private var trimStart: Double = 0
    private var trimEnd: Double = 0
    private var timelineRect: NSRect = .zero
    private var isDraggingStart: Bool = false
    private var isDraggingEnd: Bool = false
    private var isDraggingScrubber: Bool = false
    private var timeObserver: Any?
    private var gifPlaybackTimer: Timer?
    private var gifPlaybackTime: Double = 0
    private var gifIsPlaying: Bool = false

    // Timeline thumbnails
    private var thumbnailImages: [NSImage] = []
    private var thumbnailsGenerating: Bool = false
    private var thumbnailGenerator: AVAssetImageGenerator?
    private var thumbnailGeneration = UUID()
    private var lastThumbnailWidth: CGFloat = 0

    /// Pre-composited timeline thumbnail strip. Built once when thumbnails
    /// or the timeline width changes; reused on every draw so playback
    /// doesn't loop through N individual NSImage.draw(in:) calls 30 times
    /// per second. Nil → strip needs rebuilding (or no thumbnails yet).
    private var thumbnailStrip: NSImage?
    private var thumbnailStripWidth: CGFloat = 0

    /// Last drawn playhead x-position in view coords. Used by
    /// `invalidatePlayheadArea` to invalidate only the stripe spanning
    /// old→new so AppKit can clip the expensive thumbnail-strip redraw.
    private var lastDrawnPlayheadX: CGFloat?

    // Format toggle (MP4 vs GIF export)
    private var exportAsGIF: Bool = false
    private var formatToggleRect: NSRect = .zero
    private var formatMP4Rect: NSRect = .zero
    private var formatGIFRect: NSRect = .zero

    // Export dimensions
    private var originalWidth: Int = 0
    private var originalHeight: Int = 0
    // Persisted across exports: defaults to 1.0/.high on first use, then remembers
    // whatever the user picked last via dimensionSelected/qualitySelected below.
    private var exportScale: CGFloat = VideoEditorView.loadExportScale()
    private var dimensionsBtnRect: NSRect = .zero

    // Export quality (controls bitrate when re-encoding for MP4 export)
    private var exportQuality: VideoQuality = VideoEditorView.loadExportQuality()

    private static let exportScaleDefaultsKey = "lastExportScale"
    private static let exportQualityDefaultsKey = "lastExportQuality"

    private static func loadExportScale() -> CGFloat {
        let stored = UserDefaults.standard.object(forKey: exportScaleDefaultsKey) as? Double ?? 1.0
        return stored.isFinite && stored > 0 && stored <= 1 ? CGFloat(stored) : 1
    }

    private static func loadExportQuality() -> VideoQuality {
        guard let raw = UserDefaults.standard.string(forKey: exportQualityDefaultsKey),
              let quality = VideoQuality(rawValue: raw) else {
            return .high
        }
        return quality
    }
    private var qualityBtnRect: NSRect = .zero

    // GIF export frame rate (5-30 fps), persisted across sessions
    private var gifExportFPS: Int = {
        let stored = UserDefaults.standard.integer(forKey: "gifExportFPS")
        return stored == 0 ? 15 : min(30, max(5, stored))
    }()
    private var gifFPSBtnRect: NSRect = .zero

    // "+ Effect" toolbar button and the selected-text-segment state that
    // drives the bottom text-options panel.
    private var addEffectBtnRect: NSRect = .zero
    private var selectedTextSegmentID: UUID?
    /// While a text/censor segment is selected, the preview composition is
    /// built without zoom so the selection rect and the rendered content
    /// match 1:1 (zoom would transform the content but not the overlay).
    /// Exports are never affected.
    private var previewSuspendsZoom = false
    private var selectedTextSegment: VideoTextSegment? {
        guard let id = selectedTextSegmentID else { return nil }
        return textSegments.first(where: { $0.id == id })
    }

    // Effects band (zoom + censor segments) lives in its own NSView, hosted
    // inside an NSScrollView so it can overflow vertically when many segments
    // stack onto separate rows. The parent editor observes mutations via the
    // band's delegate and rebuilds the video composition / preview overlay.
    private var effectsBand: EffectsBandView?
    private var effectsScrollView: NSScrollView?
    private var effectsBandHeightConstraint: NSLayoutConstraint?
    private var playerBottomConstraint: NSLayoutConstraint?

    // Bottom options panel for the selected text segment. Sits between the
    // (drawn) trim timeline and the effects band; collapsed to height 0
    // while no text segment is selected.
    private var textOptionsPanel: VideoTextOptionsPanel?
    private var textOptionsPanelHeightConstraint: NSLayoutConstraint?
    /// Height currently occupied by the panel (0 when hidden). Folded into
    /// `controlsH` so the drawn chrome above it shifts up when it appears.
    private var textOptionsPanelH: CGFloat = 0

    // Convenience accessors so call sites don't have to guard the optional.
    private var zoomSegments: [VideoZoomSegment] { effectsBand?.zoomSegments ?? [] }
    private var censorSegments: [VideoCensorSegment] { effectsBand?.censorSegments ?? [] }
    private var cutSegments: [VideoCutSegment] { effectsBand?.cutSegments ?? [] }
    private var textSegments: [VideoTextSegment] { effectsBand?.textSegments ?? [] }
    private var selectedSegmentID: UUID? { effectsBand?.selectedSegmentID }

    // Cached rasterized text overlays. Keyed by segment id; the value carries
    // the spec used to produce the cached CGImage so we can invalidate when
    // any visible property changes. Lives on the editor (main actor) and is
    // snapshotted into the compositor instruction at composition-build time.
    private var textRasterCache: [UUID: (spec: VideoTextRasterizer.Spec, image: CGImage)] = [:]

    // Inline text-editor state for "Edit Text…". Lives on the editor view so
    // we can place a borderless NSTextView over the player at the same rect
    // the EffectsPreviewOverlayView is showing.
    private var inlineTextEditor: InlineVideoTextView?
    private var inlineTextEditorScrollView: NSScrollView?
    private var inlineTextEditingSegmentID: UUID?
    private var pausedForTextEdit: Bool = false

    // NSColorPanel binding state for the "Custom…" color menu action.
    fileprivate enum TextColorPickTarget { case text, background, outline }
    fileprivate var textColorPickerSegmentID: UUID?
    fileprivate var textColorPickerTarget: TextColorPickTarget = .text

    // Button rects
    private var playBtnRect: NSRect = .zero
    private var saveBtnRect: NSRect = .zero
    private var saveArrowRect: NSRect = .zero
    private var copyBtnRect: NSRect = .zero
    private var copyArrowRect: NSRect = .zero
    private var muteBtnRect: NSRect = .zero
    private var finderBtnRect: NSRect = .zero
    private var isMuted: Bool = false
    private var editRevision: UInt64 = 0
    private var encodingPlanRevision: UInt64?
    private var encodingPlanCache: (plan: VideoExportEncodingPlan, duration: Double)?
    private var savedURL: URL? {
        didSet { if savedURL == nil { editRevision &+= 1 } }
    }
    private var statusMessage: String?
    private var statusIsError: Bool = false
    private var statusTimer: Timer?
    private let exportInfoLabel = NSTextField(labelWithString: "")
    private var exportInfoCache: (revision: UInt64, gif: Bool, muted: Bool, text: String)?
    private enum ToolbarControl: Int {
        case play, mute, mp4, gif, dimensions, quality, gifFPS, effect
        case save, saveMenu, finder, copy, copyMenu
    }
    private var toolbarControls: [ToolbarControl: NSButton] = [:]
    /// Guards against re-entrant Save/Copy while an MP4 export is running
    /// (#323 — users repeatedly clicked Save with no progress feedback).
    private var isExporting: Bool = false
    private var activeExportJob: MediaExportCoordinator.Job?
    private var activeExportToken: UUID?

    // Layout
    private let timelinePad: CGFloat = 20
    /// Row height inside the effects band, kept in sync with EffectsBandView.
    /// Also serves as a layout primitive for the scroll view's visible height.
    private let effectsRowStride: CGFloat = 22 + 2
    /// Number of rows visible without scrolling inside the effects scroll view.
    /// Beyond this the scroll view scrolls vertically.
    /// 4 rows in a small window, up to 8 when the window is tall enough (the video keeps
    /// most of the height). Re-evaluated on resize.
    private var effectsVisibleRowCount: Int {
        let fixed = buttonsAreaH + textOptionsPanelH + scrollToLabelsGap + trimBarH
            + labelsAboveTrimGap + labelsRowH + topPadH
        let room = bounds.height * 0.45 - fixed - 6
        return max(4, min(8, Int(room / effectsRowStride)))
    }

    // Vertical layout of the controls band (bottom-up):
    //   [buttons 12→40]          fixed 48pt
    //   [effects scroll view]    variable (rowCount × rowStride - 2, capped)
    //   [gap 8pt]                8
    //   [trim timeline]          36
    //   [time labels]            18
    //   [top pad]                12
    //
    // Time labels sit ABOVE the trim bar so they don't collide with the
    // effects band's "Click to add effects" hint that sits directly
    // above the bottom buttons row.
    private let buttonsAreaH: CGFloat = 48
    private let labelsRowH: CGFloat = 18
    private let trimBarH: CGFloat = 36
    private let topPadH: CGFloat = 12
    /// Gap between the effects scroll view (top) and the trim bar (bottom).
    /// Sized to fit the playhead circle which sits below the trim bar in
    /// this layout (circle is 8pt diameter with 2pt breathing room).
    private let scrollToLabelsGap: CGFloat = 14

    /// Total height of the controls band at the bottom of the editor,
    /// dynamic because the effects scroll view grows with row count.
    private var controlsH: CGFloat {
        return buttonsAreaH
             + effectsScrollViewHeight(forRowCount: currentEffectRowCount)
             + textOptionsPanelH
             + scrollToLabelsGap
             + trimBarH
             + labelsAboveTrimGap
             + labelsRowH
             + topPadH
    }

    /// Live row count; the delegate callback updates it and triggers layout.
    private var currentEffectRowCount: Int = 1

    init(frame: NSRect, prepared: PreparedVideoSource) {
        let source = prepared.snapshot
        self.videoURL = source.originalURL
        self.mediaURL = source.mediaURL
        self.sourceFileSize = prepared.fileSize
        self.encodingSource = prepared.encodingSource
        self.sourceAudioTrackCount = prepared.audioTrackCount
        self.sourceSnapshot = source
        self.sourceLease = source.lease
        self.isGIF = source.mediaURL.pathExtension.lowercased() == "gif"
        self.asset = prepared.asset
        self.duration = prepared.duration
        self.trimEnd = prepared.duration
        if let size = prepared.pixelSize {
            self.originalWidth = SafeNumerics.int(size.width)
            self.originalHeight = SafeNumerics.int(size.height)
        }
        super.init(frame: frame)
        exportInfoLabel.font = NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular)
        exportInfoLabel.textColor = ToolbarLayout.iconColor.withAlphaComponent(0.65)
        exportInfoLabel.alignment = .center
        exportInfoLabel.lineBreakMode = .byTruncatingTail
        addSubview(exportInfoLabel)

        let area = NSTrackingArea(rect: .zero,
                                  options: [.mouseMoved, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)

        setupPlayer()
    }

    required init?(coder: NSCoder) { fatalError() }

    private func setupPlayer() {
        if isGIF {
            setupGIFView()
            return
        }

        // PreparedVideoSource loaded the tracks before this window existed.
        // Reuse that asset so preview and export share its track identities.
        buildPlayerView()
        effectsBand?.duration = duration
    }

    private func setupGIFView() {
        guard let gifImage = NSImage(contentsOf: mediaURL) else { return }
        // Estimate duration from GIF frame count and delay
        if let src = CGImageSourceCreateWithURL(mediaURL as CFURL, nil) {
            let count = CGImageSourceGetCount(src)
            var totalDelay: Double = 0
            for i in 0..<count {
                if let props = CGImageSourceCopyPropertiesAtIndex(src, i, nil) as? [String: Any],
                   let gifProps = props[kCGImagePropertyGIFDictionary as String] as? [String: Any],
                   let delay = gifProps[kCGImagePropertyGIFUnclampedDelayTime as String] as? Double ?? gifProps[kCGImagePropertyGIFDelayTime as String] as? Double {
                    totalDelay += delay
                }
            }
            duration = max(totalDelay, 0.1)
        } else {
            duration = 1.0
        }
        trimEnd = duration

        // Store original GIF dimensions
        if let src = CGImageSourceCreateWithURL(mediaURL as CFURL, nil),
           let img = CGImageSourceCreateImageAtIndex(src, 0, nil) {
            originalWidth = img.width
            originalHeight = img.height
        }

        let iv = NSImageView()
        iv.image = gifImage
        iv.animates = true
        iv.imageScaling = .scaleProportionallyDown
        iv.setContentHuggingPriority(.defaultLow, for: .horizontal)
        iv.setContentHuggingPriority(.defaultLow, for: .vertical)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        iv.setContentCompressionResistancePriority(.defaultLow, for: .vertical)
        iv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(iv)

        NSLayoutConstraint.activate([
            iv.topAnchor.constraint(equalTo: topAnchor),
            iv.leadingAnchor.constraint(equalTo: leadingAnchor),
            iv.trailingAnchor.constraint(equalTo: trailingAnchor),
            iv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -controlsH),
        ])
        gifImageView = iv
        gifIsPlaying = true
        gifPlaybackTime = trimStart
        gifPlaybackTimer = Timer.scheduledTimer(withTimeInterval: 1.0/30.0, repeats: true) { [weak self] _ in
            guard let self = self, self.gifIsPlaying else { return }
            self.gifPlaybackTime += 1.0/30.0
            if self.gifPlaybackTime >= self.trimEnd {
                self.gifPlaybackTime = self.trimStart
            }
            self.invalidatePlayheadArea()
        }
        needsDisplay = true
    }

    private func buildPlayerView() {
        // Use the same AVAsset instance the rest of the editor uses so that
        // track IDs our composition references line up with what AVPlayer is
        // decoding.
        let playerAsset = asset ?? AVAsset(url: mediaURL)
        let item = AVPlayerItem(asset: playerAsset)
        let player = AVPlayer(playerItem: item)
        self.player = player

        let pv = AVPlayerView()
        pv.player = player
        pv.controlsStyle = .none
        pv.translatesAutoresizingMaskIntoConstraints = false
        addSubview(pv)

        let playerBottomC = pv.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -controlsH)
        NSLayoutConstraint.activate([
            pv.topAnchor.constraint(equalTo: topAnchor),
            pv.leadingAnchor.constraint(equalTo: leadingAnchor),
            pv.trailingAnchor.constraint(equalTo: trailingAnchor),
            playerBottomC,
        ])
        playerView = pv
        self.playerBottomConstraint = playerBottomC

        // Overlay for interactive effect editing — sits on top of the player
        // view and pins to the same edges so it tracks window resizes.
        let overlay = EffectsPreviewOverlayView()
        overlay.translatesAutoresizingMaskIntoConstraints = false
        // Video natural size (orientation-applied). Needed so the overlay can
        // compute the letterboxed video rect inside its bounds.
        if let track = playerAsset.tracks(withMediaType: .video).first,
           let layout = VideoRenderGeometry.layout(sourceSize: track.naturalSize,
                                                    preferredTransform: track.preferredTransform) {
            overlay.videoSize = layout.uprightSize
        }
        overlay.onDragEnded = { [weak self] in
            // Snap the displayed rect to the segment's actual state (zoom
            // clamping may have adjusted center/level during the drag).
            self?.refreshOverlaySelection()
        }
        overlay.onChange = { [weak self] newRect in
            self?.overlayRectChanged(newRect)
        }
        overlay.onTextEditRequested = { [weak self] viewRect in
            guard let self = self,
                  let id = self.selectedSegmentID,
                  self.textSegments.contains(where: { $0.id == id }) else { return }
            self.beginInlineTextEdit(segmentID: id, atViewRect: viewRect, hostView: overlay)
        }
        addSubview(overlay)
        NSLayoutConstraint.activate([
            overlay.topAnchor.constraint(equalTo: pv.topAnchor),
            overlay.leadingAnchor.constraint(equalTo: pv.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: pv.trailingAnchor),
            overlay.bottomAnchor.constraint(equalTo: pv.bottomAnchor),
        ])
        effectsOverlay = overlay

        // Effects band — inside a scroll view so many stacked rows don't push
        // the timeline off-screen. Height grows up to
        // `effectsVisibleRowCount` rows, beyond which the scroll view
        // scrolls.
        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.scrollerStyle = .overlay
        scrollView.drawsBackground = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.horizontalScrollElasticity = .none
        let band = EffectsBandView()
        band.translatesAutoresizingMaskIntoConstraints = false
        band.delegate = self
        scrollView.documentView = band
        addSubview(scrollView)

        let scrollHeight = effectsScrollViewHeight(forRowCount: 1)
        let heightC = scrollView.heightAnchor.constraint(equalToConstant: scrollHeight)
        heightC.priority = .required
        NSLayoutConstraint.activate([
            // Inset 4pt less than the trim timeline so effect-pill handles
            // that poke past the pill edge (at startTime=0 or
            // endTime=duration) still have room to render fully. The
            // band itself re-inserts a matching 4pt horizontalInset so
            // pills visually align with the thumbnails above.
            scrollView.leadingAnchor.constraint(equalTo: leadingAnchor, constant: timelinePad - 4),
            scrollView.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(timelinePad - 4)),
            // Scroll view sits directly above the buttons row (y=48 from parent bottom).
            scrollView.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -buttonsAreaH),
            heightC,
            // Document view (band) width matches the scroll view's visible
            // width; height is driven by intrinsicContentSize.
            band.widthAnchor.constraint(equalTo: scrollView.widthAnchor),
        ])
        self.effectsScrollView = scrollView
        self.effectsBand = band
        self.effectsBandHeightConstraint = heightC

        // Text options panel — real-controls inspector for the selected text
        // segment. Pinned to the same horizontal region as the effects band
        // and to the band's top edge; its height constraint animates between
        // 0 and preferredHeight in `updateTextOptionsPanelVisibility()`.
        let textPanel = VideoTextOptionsPanel()
        textPanel.translatesAutoresizingMaskIntoConstraints = false
        textPanel.isHidden = true
        textPanel.onChange = { [weak self] change in
            self?.handleTextOptionsChange(change)
        }
        addSubview(textPanel)
        let textPanelHeightC = textPanel.heightAnchor.constraint(equalToConstant: 0)
        NSLayoutConstraint.activate([
            textPanel.leadingAnchor.constraint(equalTo: leadingAnchor, constant: timelinePad - 4),
            textPanel.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -(timelinePad - 4)),
            textPanel.bottomAnchor.constraint(equalTo: scrollView.topAnchor),
            textPanelHeightC,
        ])
        self.textOptionsPanel = textPanel
        self.textOptionsPanelHeightConstraint = textPanelHeightC

        // Observe playback position
        timeObserver = player.addPeriodicTimeObserver(forInterval: CMTime(value: 1, timescale: 30), queue: .main) { [weak self] time in
            guard let self = self, !self.isDraggingScrubber else { return }
            // The player's clock may be the cut-stripped composition clock;
            // map it back to the source asset clock before comparing with
            // trim markers (which are in source time).
            let t = self.mapPreviewClockToSourceTime(CMTimeGetSeconds(time))
            if t >= self.trimEnd {
                self.player?.pause()
                let target = self.mapSourceTimeToPreviewClock(self.trimStart)
                self.player?.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000),
                                  toleranceBefore: .zero, toleranceAfter: .zero)
            }
            // Narrow invalidation — just the playhead stripe. The rest of
            // the controls band is static during playback and AppKit's
            // dirty-rect clipping skips their fills. This drops per-frame
            // draw cost from ~30ms (60 thumbnail redraws) to <1ms.
            self.invalidatePlayheadArea()
        }

        generateThumbnails()
        needsDisplay = true
    }

    private func generateThumbnails() {
        guard let asset = asset, !thumbnailsGenerating else { return }
        let tlW = bounds.width - timelinePad * 2
        guard tlW > 0 else { return }
        lastThumbnailWidth = tlW
        thumbnailsGenerating = true

        let thumbH: CGFloat = 30
        let thumbW: CGFloat = thumbH * 16 / 9
        let count = max(1, Int(ceil(tlW / thumbW)))
        let dur = duration

        let generator = AVAssetImageGenerator(asset: asset)
        thumbnailGenerator = generator
        let generation = UUID()
        thumbnailGeneration = generation
        let sourceLease = self.sourceLease
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: thumbW * 2, height: thumbH * 2)
        generator.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 1_000_000_000)
        generator.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 1_000_000_000)

        var times: [NSValue] = []
        for i in 0..<count {
            let t = dur * Double(i) / Double(count)
            times.append(NSValue(time: CMTime(seconds: t, preferredTimescale: 1_000_000_000)))
        }

        // AVFoundation calls this handler from its own queue, with no ordering
        // guarantee across the requested times. The previous version mutated a
        // captured array and counter directly from there, so a lost increment
        // could index past the end — and the array itself was written
        // concurrently. Collect under a lock, keyed by the requested time so a
        // result always lands in the right slot.
        let collector = ThumbnailCollector(count: count)
        generator.generateCGImagesAsynchronously(forTimes: times) { [weak self, sourceLease] requestedTime, cgImage, _, _, _ in
            defer { withExtendedLifetime(sourceLease) {} }
            let image = cgImage.map {
                NSImage(cgImage: $0, size: NSSize(width: CGFloat($0.width), height: CGFloat($0.height)))
            }
            let slot = times.firstIndex { CMTimeCompare($0.timeValue, requestedTime) == 0 }
            guard let finished = collector.record(image, at: slot) else { return }
            DispatchQueue.main.async {
                guard let self, self.thumbnailGeneration == generation else { return }
                self.thumbnailImages = finished
                self.thumbnailStrip = nil           // force rebuild in drawTimeline
                self.thumbnailsGenerating = false
                self.thumbnailGenerator = nil
                self.needsDisplay = true
            }
        }
    }

    /// Build (or rebuild) the pre-composited thumbnail strip cache. Cheap
    /// to call on every draw — returns immediately if the cache is already
    /// valid for `width`. Called from drawTimeline before the strip is
    /// drawn.
    private func rebuildThumbnailStripIfNeeded(width: CGFloat, height: CGFloat) {
        guard !thumbnailImages.isEmpty, width > 0, height > 0 else { return }
        if thumbnailStrip != nil, abs(thumbnailStripWidth - width) < 0.5 { return }

        let size = NSSize(width: width, height: height)
        let strip = NSImage(size: size)
        strip.lockFocus()
        let count = thumbnailImages.count
        for (i, img) in thumbnailImages.enumerated() {
            let x0 = floor(CGFloat(i) * width / CGFloat(count))
            let x1 = ceil(CGFloat(i + 1) * width / CGFloat(count))
            let r = NSRect(x: x0, y: 0, width: x1 - x0, height: height)
            img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1.0)
        }
        strip.unlockFocus()
        thumbnailStrip = strip
        thumbnailStripWidth = width
    }

    func cleanup() {
        thumbnailGeneration = UUID()
        thumbnailGenerator?.cancelAllCGImageGeneration()
        thumbnailGenerator = nil
        if let obs = timeObserver { player?.removeTimeObserver(obs) }
        timeObserver = nil
        player?.pause()
        player?.replaceCurrentItem(with: nil)
        player = nil
        playerView?.player = nil
        asset = nil
        gifImageView?.image = nil
        gifPlaybackTimer?.invalidate()
        gifPlaybackTimer = nil
        // Active jobs retain their own lease until their final read completes.
        sourceLease = nil
        sourceSnapshot = nil
    }

    private var currentPlaybackTime: Double {
        if isGIF {
            return gifPlaybackTime
        } else {
            // Always report in source-asset time so the playhead, thumbnails
            // and trim UI agree regardless of whether the preview is
            // composition-backed (cuts present) or not.
            return mapPreviewClockToSourceTime(CMTimeGetSeconds(player?.currentTime() ?? .zero))
        }
    }

    // MARK: - Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Controls background
        let controlsBg = NSRect(x: 0, y: 0, width: bounds.width, height: controlsH)
        ToolbarLayout.bgColor.setFill()
        NSBezierPath(rect: controlsBg).fill()

        // Separator
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(rect: NSRect(x: 0, y: controlsH, width: bounds.width, height: 0.5)).fill()

        guard duration > 0 else { return }

        // Skip draw sections whose Y-band doesn't intersect the dirty rect.
        // AppKit already clips final drawing to `dirtyRect`, but each
        // `drawX()` method still executes its setup — SF-Symbol
        // rasterization in `drawIconButton` alone costs ~25ms/call. When
        // the 30Hz playhead observer only invalidates the trim-bar band,
        // the bottom buttons row doesn't need to run at all.
        let buttonsBand = NSRect(x: 0, y: 0, width: bounds.width, height: buttonsAreaH)

        drawTimeline()
        if dirtyRect.intersects(buttonsBand) {
            drawButtons()
        }
        drawTimeLabels()
    }


    private func drawTimeline() {
        let tlX = timelinePad
        let tlW = bounds.width - timelinePad * 2
        // Trim timeline bottom sits above the time-labels row, which sits
        // above the effects scroll view. All three adjust upward as the
        // scroll view grows to show more rows.
        let tlH: CGFloat = trimBarH
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        // Trim bar sits directly above the effects scroll view and the
        // text options panel (when visible), with just the
        // `scrollToLabelsGap` for breathing room. Time labels now sit
        // ABOVE the trim bar — see `timeLabelY`.
        let tlY: CGFloat = buttonsAreaH + scrollH + textOptionsPanelH + scrollToLabelsGap
        timelineRect = NSRect(x: tlX, y: tlY, width: tlW, height: tlH)

        // Regenerate thumbnails if width changed significantly
        if abs(tlW - lastThumbnailWidth) > 40 && !thumbnailsGenerating && asset != nil {
            generateThumbnails()
        }
        // Invalidate the cached strip if width changed even slightly so the
        // resampled strip stays aligned with the timeline.
        if abs(thumbnailStripWidth - tlW) > 0.5 { thumbnailStrip = nil }
        rebuildThumbnailStripIfNeeded(width: tlW, height: tlH)

        // Track background with rounded clip
        let trackPath = NSBezierPath(roundedRect: timelineRect, xRadius: 5, yRadius: 5)
        ToolbarLayout.iconColor.withAlphaComponent(0.06).setFill()
        trackPath.fill()

        // Blit the pre-composited thumbnail strip in one draw call. Drawing
        // each thumbnail individually per frame was ~100ms/s during
        // playback; caching brings it to <5ms/s with the same visual.
        NSGraphicsContext.saveGraphicsState()
        trackPath.addClip()
        if let strip = thumbnailStrip {
            strip.draw(in: NSRect(x: tlX, y: tlY, width: tlW, height: tlH),
                       from: .zero, operation: .sourceOver, fraction: 0.5)
        }

        // Dim untrimmed regions
        let startX = tlX + CGFloat(trimStart / duration) * tlW
        let endX = tlX + CGFloat(trimEnd / duration) * tlW
        NSColor.black.withAlphaComponent(0.6).setFill()
        if startX > tlX {
            NSRect(x: tlX, y: tlY, width: startX - tlX, height: tlH).fill()
        }
        if endX < tlX + tlW {
            NSRect(x: endX, y: tlY, width: tlX + tlW - endX, height: tlH).fill()
        }

        // Subtle teal tint for speed ranges — just enough to signal them on
        // the trim bar. The full pill lives on the effects band below.
        for speed in speedSegments where speed.endTime > speed.startTime {
            let sx0 = tlX + CGFloat(max(0, min(duration, speed.startTime)) / duration) * tlW
            let sx1 = tlX + CGFloat(max(0, min(duration, speed.endTime)) / duration) * tlW
            let rect = NSRect(x: sx0, y: tlY, width: max(1, sx1 - sx0), height: tlH)
            NSColor(calibratedRed: 0.10, green: 0.55, blue: 0.50, alpha: 0.28).setFill()
            rect.fill()
        }

        // Draw striped cut overlays inside the trim region — they signal
        // ranges that will be removed on export. Clipped by the track path so
        // overlays never leak past the rounded edges.
        for cut in cutSegments where cut.endTime > cut.startTime {
            let cx0 = tlX + CGFloat(max(0, min(duration, cut.startTime)) / duration) * tlW
            let cx1 = tlX + CGFloat(max(0, min(duration, cut.endTime)) / duration) * tlW
            let cutRect = NSRect(x: cx0, y: tlY, width: max(1, cx1 - cx0), height: tlH)
            // Dark-red tint over the thumbnails.
            NSColor(calibratedRed: 0.50, green: 0.05, blue: 0.08, alpha: 0.55).setFill()
            cutRect.fill()
            // Diagonal hatching.
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(rect: cutRect).addClip()
            NSColor.white.withAlphaComponent(0.22).setStroke()
            let stripes = NSBezierPath()
            stripes.lineWidth = 1
            let step: CGFloat = 6
            var x = cutRect.minX - cutRect.height
            while x < cutRect.maxX + cutRect.height {
                stripes.move(to: NSPoint(x: x, y: cutRect.minY))
                stripes.line(to: NSPoint(x: x + cutRect.height, y: cutRect.maxY))
                x += step
            }
            stripes.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }

        // Trim border highlight
        let trimRect = NSRect(x: startX, y: tlY, width: endX - startX, height: tlH)
        let trimBorder = NSBezierPath(roundedRect: trimRect.insetBy(dx: 0.5, dy: 0.5), xRadius: 2, yRadius: 2)
        trimBorder.lineWidth = 1.5
        ToolbarLayout.accentColor.withAlphaComponent(0.8).setStroke()
        trimBorder.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // Trim handles
        let handleW: CGFloat = 10
        let handleH: CGFloat = tlH + 8

        let startHandleRect = NSRect(x: startX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: startHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: startHandleRect)

        let endHandleRect = NSRect(x: endX - handleW / 2, y: tlY - 4, width: handleW, height: handleH)
        ToolbarLayout.accentColor.setFill()
        NSBezierPath(roundedRect: endHandleRect, xRadius: 3, yRadius: 3).fill()
        drawHandleGrip(in: endHandleRect)

        // Playhead — line spans the full trim timeline. Circle sits BELOW
        // the trim bar in the gap between it and the effects scroll view.
        // (Previously the circle sat above, but the time-labels row lives
        // there now — a circle at x = timelinePad would collide with the
        // current-time label at t = 0.)
        if player != nil || isGIF {
            let currentTime = currentPlaybackTime
            let playheadX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentTime / duration) * tlW))
            // Remember the last drawn position so `invalidatePlayheadArea`
            // can clip invalidation to just the old + new stripe instead
            // of marking the whole view dirty.
            lastDrawnPlayheadX = playheadX

            ToolbarLayout.iconColor.withAlphaComponent(0.9).setFill()
            let playheadRect = NSRect(x: playheadX - 1, y: tlY - 2,
                                       width: 2, height: tlH + 4)
            NSBezierPath(roundedRect: playheadRect, xRadius: 1, yRadius: 1).fill()

            let circleR: CGFloat = 4
            let circleX = playheadX
            // Circle sits centered in the gap below the trim bar, so it's
            // visually "stuck to" the trim bar's bottom edge.
            let circleY = tlY - circleR * 2 - 2
            ToolbarLayout.iconColor.setFill()
            NSBezierPath(ovalIn: NSRect(x: circleX - circleR,
                                          y: circleY,
                                          width: circleR * 2,
                                          height: circleR * 2)).fill()
        }
    }

    /// Mark only the stripe containing the old and new playhead positions
    /// + the left current-time label area as dirty. Lets AppKit clip the
    /// draw so the expensive button-rendering (SF Symbols, NSImage blits)
    /// at the bottom of the controls area stays out of the per-frame path.
    ///
    /// Used in place of `self.needsDisplay = true` from the 30Hz playback
    /// observers. Other mutations (trim drag, segment edits, window
    /// resize) still use `needsDisplay = true` for full redraws.
    private func invalidatePlayheadArea() {
        let tlX = timelinePad
        let tlW = bounds.width - timelinePad * 2
        let newX = max(tlX, min(tlX + tlW, tlX + CGFloat(currentPlaybackTime / max(duration, 0.0001)) * tlW))
        let oldX = lastDrawnPlayheadX ?? newX

        // Y-range that actually needs to redraw when the playhead moves:
        // from the playhead circle (just below the trim bar) up through
        // the time-labels row. Explicitly excludes the bottom buttons
        // (y=0→buttonsAreaH) so SF-Symbol rendering stays off the 30Hz
        // path — that was eating ~1s/10s on the main thread.
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        let tlY = buttonsAreaH + scrollH + textOptionsPanelH + scrollToLabelsGap
        let playheadBandMinY = tlY - 12                                              // below trim bar (circle + padding)
        let playheadBandMaxY = tlY + trimBarH + labelsAboveTrimGap + labelsRowH + 2  // through label row

        // 1) The playhead stripe (line + circle + trim bar content around it).
        //    Generous padding so the 8pt circle and 2pt line land fully inside.
        let pad: CGFloat = 12
        let stripeMinX = min(oldX, newX) - pad
        let stripeMaxX = max(oldX, newX) + pad
        setNeedsDisplay(NSRect(x: stripeMinX, y: playheadBandMinY,
                                width: stripeMaxX - stripeMinX,
                                height: playheadBandMaxY - playheadBandMinY))

        // 2) The left time label (shows current playback time, which changes
        //    every frame). Same vertical band — not the full controls height.
        setNeedsDisplay(NSRect(x: 0, y: playheadBandMinY,
                                width: tlX + 100,
                                height: playheadBandMaxY - playheadBandMinY))
    }

    private func drawHandleGrip(in rect: NSRect) {
        ToolbarLayout.iconColor.withAlphaComponent(0.5).setStroke()
        let path = NSBezierPath()
        path.lineWidth = 1
        let midY = rect.midY
        for dy in stride(from: -3 as CGFloat, through: 3, by: 3) {
            path.move(to: NSPoint(x: rect.midX - 2, y: midY + dy))
            path.line(to: NSPoint(x: rect.midX + 2, y: midY + dy))
        }
        path.stroke()
    }

    private func drawButtons() {
        let btnH: CGFloat = 28
        let btnY: CGFloat = 12
        let gap: CGFloat = 8
        let iconBtnW: CGFloat = 34
        let labelBtnW: CGFloat = 100

        // Pre-compute right group width so left content knows where to stop
        let copyArrowW: CGFloat = 20
        let saveArrowW: CGFloat = 20
        let rightGroupW = (labelBtnW + copyArrowW) + gap + iconBtnW + gap + (labelBtnW + saveArrowW)
        let maxLeftX = bounds.width - timelinePad - rightGroupW - 12  // 12pt breathing room

        // Left group: play, mute
        var x: CGFloat = timelinePad

        let isPlaying = isGIF ? gifIsPlaying : (player?.rate ?? 0 > 0)
        playBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: playBtnRect, symbol: isPlaying ? "pause.fill" : "play.fill", accent: true)
        x += iconBtnW + gap

        muteBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: muteBtnRect, symbol: isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", accent: false, active: isMuted)
        x += iconBtnW + gap

        // Format toggle + file info
        if !isGIF {
            // MP4 | GIF segmented toggle
            let segW: CGFloat = 88
            let segH: CGFloat = 22
            let segY = btnY + (btnH - segH) / 2
            formatToggleRect = NSRect(x: x + 4, y: segY, width: segW, height: segH)
            let halfW = segW / 2
            formatMP4Rect = NSRect(x: formatToggleRect.minX, y: segY, width: halfW, height: segH)
            formatGIFRect = NSRect(x: formatToggleRect.minX + halfW, y: segY, width: halfW, height: segH)

            // Background
            ToolbarLayout.iconColor.withAlphaComponent(0.08).setFill()
            NSBezierPath(roundedRect: formatToggleRect, xRadius: 5, yRadius: 5).fill()

            // Selected segment highlight
            let selRect = exportAsGIF ? formatGIFRect : formatMP4Rect
            ToolbarLayout.accentColor.withAlphaComponent(0.6).setFill()
            NSBezierPath(roundedRect: selRect.insetBy(dx: 1, dy: 1), xRadius: 4, yRadius: 4).fill()

            // Labels
            let selAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .semibold),
                .foregroundColor: ToolbarLayout.iconColor,
            ]
            let unselAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
            ]
            let mp4Str = "MP4" as NSString
            let gifStr = "GIF" as NSString
            let mp4Size = mp4Str.size(withAttributes: selAttrs)
            let gifSize = gifStr.size(withAttributes: selAttrs)
            mp4Str.draw(at: NSPoint(x: formatMP4Rect.midX - mp4Size.width / 2, y: formatMP4Rect.midY - mp4Size.height / 2),
                        withAttributes: exportAsGIF ? unselAttrs : selAttrs)
            gifStr.draw(at: NSPoint(x: formatGIFRect.midX - gifSize.width / 2, y: formatGIFRect.midY - gifSize.height / 2),
                        withAttributes: exportAsGIF ? selAttrs : unselAttrs)
            x += segW + 12
        }

            // Dimensions dropdown button
            dimensionsBtnRect = .zero
            if originalWidth > 0 && x < maxLeftX {
                let exportW = Int(CGFloat(originalWidth) * exportScale)
                let exportH = Int(CGFloat(originalHeight) * exportScale)
                let dimLabel: String
                if exportScale >= 0.999 {
                    dimLabel = "\(originalWidth)×\(originalHeight)"
                } else {
                    let pct = Int((exportScale * 100).rounded())
                    dimLabel = "\(exportW)×\(exportH) (\(pct)%)"
                }
                let dimAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportScale < 0.999 ? 0.7 : 0.4),
                ]
                let dimStr = "  ·  \(dimLabel) ▼" as NSString
                let dimSize = dimStr.size(withAttributes: dimAttrs)
                let dimBtnW = dimSize.width + 8
                if x + dimBtnW < maxLeftX {
                    dimensionsBtnRect = NSRect(x: x, y: btnY, width: dimBtnW, height: btnH)
                    dimStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - dimSize.height) / 2), withAttributes: dimAttrs)
                    x += dimBtnW
                }
            }

            // Quality dropdown (only meaningful when exporting as MP4)
            qualityBtnRect = .zero
            if !exportAsGIF && x < maxLeftX {
                let qualAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(exportQuality != .high ? 0.7 : 0.4),
                ]
                let qualStr = "  ·  \(exportQuality.displayName) ▼" as NSString
                let qualSize = qualStr.size(withAttributes: qualAttrs)
                let qualBtnW = qualSize.width + 8
                if x + qualBtnW < maxLeftX {
                    qualityBtnRect = NSRect(x: x, y: btnY, width: qualBtnW, height: btnH)
                    qualStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - qualSize.height) / 2), withAttributes: qualAttrs)
                    x += qualBtnW
                }
            }

            // GIF frame rate dropdown (only meaningful when exporting as GIF)
            gifFPSBtnRect = .zero
            if exportAsGIF && x < maxLeftX {
                let fpsAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(gifExportFPS != 15 ? 0.7 : 0.4),
                ]
                let fpsStr = "  ·  \(gifExportFPS) fps ▼" as NSString
                let fpsSize = fpsStr.size(withAttributes: fpsAttrs)
                let fpsBtnW = fpsSize.width + 8
                if x + fpsBtnW < maxLeftX {
                    gifFPSBtnRect = NSRect(x: x, y: btnY, width: fpsBtnW, height: btnH)
                    fpsStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - fpsSize.height) / 2), withAttributes: fpsAttrs)
                    x += fpsBtnW
                }
            }

            // "+ Effect" button — add zoom/censor/cut/speed/freeze/text at the playhead
            addEffectBtnRect = .zero
            if effectsBand != nil && x < maxLeftX {
                let addAttrs: [NSAttributedString.Key: Any] = [
                    .font: NSFont.systemFont(ofSize: 10, weight: .medium),
                    .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.7),
                ]
                let addStr = "  ·  + \(L("Effect")) ▼" as NSString
                let addSize = addStr.size(withAttributes: addAttrs)
                let addBtnW = addSize.width + 8
                if x + addBtnW < maxLeftX {
                    addEffectBtnRect = NSRect(x: x, y: btnY, width: addBtnW, height: btnH)
                    addStr.draw(at: NSPoint(x: x + 4, y: btnY + (btnH - addSize.height) / 2), withAttributes: addAttrs)
                    x += addBtnW
                }
            }

        // Right group: save, finder, copy
        x = bounds.width - timelinePad
        let fullCopyW = labelBtnW + copyArrowW
        x -= fullCopyW
        let fullCopyRect = NSRect(x: x, y: btnY, width: fullCopyW, height: btnH)
        copyBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        copyArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: copyArrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullCopyRect, xRadius: 6, yRadius: 6).fill()

        do {
            let iconSize: CGFloat = 12
            let copyAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let copyLabel = L("Copy") as NSString
            let copyLabelSize = copyLabel.size(withAttributes: copyAttrs)
            let totalCopyW = iconSize + 4 + copyLabelSize.width
            let copyStartX = copyBtnRect.midX - totalCopyW / 2
            if let img = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: copyStartX, y: copyBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            copyLabel.draw(at: NSPoint(x: copyStartX + iconSize + 4, y: copyBtnRect.midY - copyLabelSize.height / 2), withAttributes: copyAttrs)
        }

        // Separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let copySep = NSBezierPath()
        copySep.move(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.minY + 4))
        copySep.line(to: NSPoint(x: copyArrowRect.minX, y: copyArrowRect.maxY - 4))
        copySep.lineWidth = 1
        copySep.stroke()

        // Chevron
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: copyArrowRect.midX - chevron.size.width / 2, y: copyArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }

        x -= gap + iconBtnW
        finderBtnRect = NSRect(x: x, y: btnY, width: iconBtnW, height: btnH)
        drawIconButton(rect: finderBtnRect, symbol: "folder", accent: false, dimmed: savedURL == nil)
        let arrowW: CGFloat = 20
        x -= gap + labelBtnW + arrowW
        let fullSaveW = labelBtnW + arrowW
        let fullSaveRect = NSRect(x: x, y: btnY, width: fullSaveW, height: btnH)
        saveBtnRect = NSRect(x: x, y: btnY, width: labelBtnW, height: btnH)
        saveArrowRect = NSRect(x: x + labelBtnW, y: btnY, width: arrowW, height: btnH)

        // Draw combined background
        ToolbarLayout.iconColor.withAlphaComponent(0.1).setFill()
        NSBezierPath(roundedRect: fullSaveRect, xRadius: 6, yRadius: 6).fill()

        // Draw save icon + label
        do {
            let iconSize: CGFloat = 12
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 11, weight: .medium),
                .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.85),
            ]
            let saveLabel = L("Save") as NSString
            let labelSize = saveLabel.size(withAttributes: attrs)
            let totalW = iconSize + 4 + labelSize.width
            let startX = saveBtnRect.midX - totalW / 2
            if let img = NSImage(systemSymbolName: "square.and.arrow.down", accessibilityDescription: nil)?
                    .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
                let tinted = NSImage(size: img.size, flipped: false) { r in
                    img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                    ToolbarLayout.iconColor.withAlphaComponent(0.85).setFill()
                    r.fill(using: .sourceAtop)
                    return true
                }
                tinted.draw(in: NSRect(x: startX, y: saveBtnRect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
            }
            saveLabel.draw(at: NSPoint(x: startX + iconSize + 4, y: saveBtnRect.midY - labelSize.height / 2), withAttributes: attrs)
        }

        // Draw separator line
        ToolbarLayout.iconColor.withAlphaComponent(0.2).setStroke()
        let sep = NSBezierPath()
        sep.move(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.minY + 4))
        sep.line(to: NSPoint(x: saveArrowRect.minX, y: saveArrowRect.maxY - 4))
        sep.lineWidth = 1
        sep.stroke()

        // Draw chevron in arrow portion
        if let chevron = NSImage(systemSymbolName: "chevron.down", accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 8, weight: .semibold)) {
            let tinted = NSImage(size: chevron.size, flipped: false) { r in
                chevron.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(0.6).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: saveArrowRect.midX - chevron.size.width / 2, y: saveArrowRect.midY - chevron.size.height / 2,
                                    width: chevron.size.width, height: chevron.size.height))
        }
        updateToolbarControls()
    }

    /// Keep the existing visual design while giving each control native hit
    /// testing, keyboard focus and accessibility. Transparent NSButtons receive
    /// input normally; the existing drawing supplies their appearance.
    private func updateToolbarControls() {
        func update(_ control: ToolbarControl, _ title: String, _ rect: NSRect,
                    enabled: Bool = true, selected: Bool? = nil) {
            let button: NSButton
            if let existing = toolbarControls[control] { button = existing }
            else {
                button = NSButton(title: title, target: self, action: #selector(toolbarControlPressed(_:)))
                button.tag = control.rawValue
                button.isTransparent = true
                button.isBordered = false
                button.setButtonType(selected == nil ? .momentaryPushIn : .radio)
                button.focusRingType = .exterior
                toolbarControls[control] = button
                addSubview(button)
            }
            button.title = title
            button.toolTip = title
            button.frame = rect
            button.isHidden = rect.isEmpty
            button.isEnabled = enabled
            if let selected { button.state = selected ? .on : .off }
        }
        let playing = isGIF ? gifIsPlaying : (player?.rate ?? 0 > 0)
        update(.play, playing ? L("Pause") : L("Play"), playBtnRect)
        update(.mute, isMuted ? L("Unmute") : L("Mute"), muteBtnRect)
        update(.mp4, "MP4", formatMP4Rect, selected: !exportAsGIF)
        update(.gif, "GIF", formatGIFRect, selected: exportAsGIF)
        update(.dimensions, L("Resolution") + ": \(Int(CGFloat(originalWidth) * exportScale))×\(Int(CGFloat(originalHeight) * exportScale))", dimensionsBtnRect)
        update(.quality, L("Quality:") + " " + exportQuality.displayName, qualityBtnRect)
        update(.gifFPS, L("Frame rate:") + " \(gifExportFPS)", gifFPSBtnRect)
        update(.effect, "+ " + L("Effect"), addEffectBtnRect)
        update(.save, L("Save"), saveBtnRect, enabled: !isExporting)
        update(.saveMenu, L("Save") + "…", saveArrowRect, enabled: !isExporting)
        update(.finder, L("Show in Finder"), finderBtnRect, enabled: savedURL != nil)
        update(.copy, L("Copy"), copyBtnRect, enabled: !isExporting)
        update(.copyMenu, L("Copy") + "…", copyArrowRect, enabled: !isExporting)
    }

    @objc private func toolbarControlPressed(_ sender: NSButton) {
        guard let control = ToolbarControl(rawValue: sender.tag) else { return }
        effectsBand?.clearSelection()
        performToolbarControl(control)
    }

    private func performToolbarControl(_ control: ToolbarControl) {
        switch control {
        case .play: togglePlayPause()
        case .mute: toggleMute()
        case .mp4:
            if exportAsGIF { exportAsGIF = false; savedURL = nil; needsDisplay = true }
        case .gif:
            if !exportAsGIF { exportAsGIF = true; savedURL = nil; needsDisplay = true }
        case .dimensions: showDimensionsMenu()
        case .quality: showQualityMenu()
        case .gifFPS: showGIFFPSMenu()
        case .effect:
            if let menu = effectsBand?.addEffectMenu(clickTime: currentPlaybackTime) {
                popUpAbove(menu, addEffectBtnRect)
            }
        case .save: saveVideo()
        case .saveMenu: showSaveMenu()
        case .finder:
            if let url = savedURL { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .copy: copyToClipboard()
        case .copyMenu: showCopyMenu()
        }
    }

    private func drawIconButton(rect: NSRect, symbol: String, accent: Bool, active: Bool = false, dimmed: Bool = false) {
        let bg = accent ? ToolbarLayout.accentColor : (active ? ToolbarLayout.accentColor.withAlphaComponent(0.4) : ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1))
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 1.0
        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 13, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            let imgRect = NSRect(x: rect.midX - img.size.width / 2, y: rect.midY - img.size.height / 2,
                                  width: img.size.width, height: img.size.height)
            tinted.draw(in: imgRect)
        }
    }

    private func drawLabelButton(rect: NSRect, symbol: String, label: String, dimmed: Bool = false) {
        let bg = ToolbarLayout.iconColor.withAlphaComponent(dimmed ? 0.04 : 0.1)
        bg.setFill()
        NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()

        let alpha: CGFloat = dimmed ? 0.25 : 0.85
        let iconSize: CGFloat = 12
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(alpha),
        ]
        let str = label as NSString
        let textSize = str.size(withAttributes: attrs)
        let iconGap: CGFloat = 8
        let totalW = iconSize + iconGap + textSize.width
        let startX = rect.midX - totalW / 2

        if let img = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: iconSize, weight: .medium)) {
            let tinted = NSImage(size: img.size, flipped: false) { r in
                img.draw(in: r, from: .zero, operation: .sourceOver, fraction: 1)
                ToolbarLayout.iconColor.withAlphaComponent(alpha).setFill()
                r.fill(using: .sourceAtop)
                return true
            }
            tinted.draw(in: NSRect(x: startX, y: rect.midY - img.size.height / 2, width: img.size.width, height: img.size.height))
        }
        str.draw(at: NSPoint(x: startX + iconSize + iconGap, y: rect.midY - textSize.height / 2), withAttributes: attrs)
    }

    /// Time labels sit ABOVE the trim bar (AppKit y=up), so the status
    /// banner "Copied to clipboard!" and the left/right time readouts
    /// don't collide with the effects band's cursor-follow "+" hint or
    /// the "Click to add effects" empty-state that sits just above the
    /// bottom buttons.
    /// Extra vertical gap between the trim bar top and the time labels,
    /// purely for visual breathing room. Without it the labels hug the
    /// top edge of the trim rectangle and look cramped.
    private let labelsAboveTrimGap: CGFloat = 4

    private var timeLabelY: CGFloat {
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
        ]
        let sampleHeight = ("0" as NSString).size(withAttributes: attrs).height
        let scrollH = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        // Bottom of the labels row sits slightly above the top of the
        // trim bar — `labelsAboveTrimGap` gives the text a little
        // breathing room so it doesn't look pasted onto the bar.
        let labelsRowBottom = buttonsAreaH + scrollH + textOptionsPanelH + scrollToLabelsGap + trimBarH + labelsAboveTrimGap
        return labelsRowBottom + (labelsRowH - sampleHeight) / 2
    }

    /// Metadata is cached with the edit state so the 30 Hz playhead redraw does
    /// not repeatedly format byte counts or prepare export settings.
    private var exportInformation: String {
        if let cache = exportInfoCache, cache.revision == editRevision,
           cache.gif == exportAsGIF, cache.muted == isMuted { return cache.text }
        let size = ByteCountFormatter.string(fromByteCount: sourceFileSize, countStyle: .file)
        let fps = 1 / sourceFrameDuration.seconds
        var text = size
        if fps.isFinite && fps > 0 && fps <= 1000 { text += "  ·  \(Int(fps.rounded()))fps" }
        // High and GIF have no comparable bitrate target to estimate.
        if !exportAsGIF, let planned = plannedMP4Export,
           let estimated = planned.plan.estimatedBytes(duration: planned.duration,
                audioTrackCount: isMuted ? 0 : sourceAudioTrackCount,
                audioBitrate: VideoTranscoder.audioBitrate) {
            text += "  →  ~" + ByteCountFormatter.string(fromByteCount: estimated, countStyle: .file)
        }
        exportInfoCache = (editRevision, exportAsGIF, isMuted, text)
        return text
    }

    private func drawTimeLabels() {
        let currentTime = currentPlaybackTime
        // Show the actual output duration so users see the effect of cuts
        // and speed on the final export. Falls back to raw trim span when
        // neither is present (same value, cheaper to compute).
        let trimDuration: Double = {
            if cutSegments.isEmpty && speedSegments.isEmpty && freezeSegments.isEmpty {
                return trimEnd - trimStart
            }
            let kept = VideoCuts.keptRanges(trimStart: trimStart, trimEnd: trimEnd, cuts: cutSegments)
            let pieces = VideoSpeeds.pieces(keptRanges: kept,
                                              speeds: speedSegments,
                                              freezes: freezeSegments)
            return VideoSpeeds.totalCompositionDuration(pieces)
        }()

        let leftStr = formatTime(currentTime) as NSString
        let rightStr = String(format: L("%@ selected"), formatTime(trimDuration)) as NSString
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: ToolbarLayout.iconColor.withAlphaComponent(0.5),
        ]

        leftStr.draw(at: NSPoint(x: timelinePad, y: timeLabelY), withAttributes: attrs)

        let rightSize = rightStr.size(withAttributes: attrs)
        rightStr.draw(at: NSPoint(x: bounds.width - timelinePad - rightSize.width, y: timeLabelY), withAttributes: attrs)

        // Keep source/estimated size visible at the minimum window width. A
        // native label also exposes the full value to accessibility clients.
        let info = statusMessage ?? exportInformation
        if exportInfoLabel.stringValue != info {
            exportInfoLabel.stringValue = info
            exportInfoLabel.toolTip = info
        }
        let leftWidth = leftStr.size(withAttributes: attrs).width
        let reserved = max(leftWidth, rightSize.width) + timelinePad + 12
        exportInfoLabel.frame = NSRect(x: reserved, y: timeLabelY - 1,
            width: max(0, bounds.width - reserved * 2), height: labelsRowH)
        exportInfoLabel.textColor = statusMessage == nil ? ToolbarLayout.iconColor.withAlphaComponent(0.65)
            : (statusIsError ? NSColor(calibratedRed: 1.0, green: 0.5, blue: 0.5, alpha: 1.0) : .systemGreen)
        exportInfoLabel.font = statusMessage == nil ? .monospacedDigitSystemFont(ofSize: 10, weight: .regular)
            : .systemFont(ofSize: 12, weight: .medium)
    }

    private func formatTime(_ seconds: Double) -> String {
        // Derive every field from the rounded total tenths-of-a-second. Computing
        // the tenths digit separately as `(seconds - floor(seconds)) * 10` truncates
        // a value like 2.3s (whose Double is 2.2999…) to ".2" instead of ".3", and
        // never rounds up at the boundary — 1.999s displayed as "0:01.9" instead of
        // "0:02.0". Rounding once at the top keeps minutes/seconds/tenths consistent.
        let totalTenths = Int((seconds * 10).rounded())
        let m = totalTenths / 600
        let s = (totalTenths / 10) % 60
        let tenths = totalTenths % 10
        return String(format: "%d:%02d.%d", m, s, tenths)
    }

    // MARK: - Mouse

    // MARK: - Effects preview overlay

    /// Full sync: update the overlay's selection AND seek the preview to a
    /// time that makes editing intuitive. Call only when selection changes,
    /// not during a drag (seeking mid-drag stutters the decoder).
    private func updateEffectsOverlay() {
        refreshOverlaySelection()
        // Seek only on selection change, based on the newly-selected segment.
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                seekPreview(to: max(0, seg.startTime - 0.05))
            } else if let seg = censorSegments.first(where: { $0.id == id }) {
                seekPreview(to: (seg.startTime + seg.endTime) / 2)
            } else if let seg = textSegments.first(where: { $0.id == id }) {
                seekPreview(to: (seg.startTime + seg.endTime) / 2)
            }
        }
    }

    /// Light sync: update the overlay's displayed rect + kind without seeking.
    /// Safe to call during an active drag or when a segment's properties
    /// change without the selection itself moving.
    private func refreshOverlaySelection() {
        guard let overlay = effectsOverlay else { return }
        if let id = selectedSegmentID {
            if let seg = zoomSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .zoom, rect: rectForZoom(seg))
                return
            }
            if let seg = censorSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .censor(seg.style), rect: seg.rect)
                return
            }
            if let seg = textSegments.first(where: { $0.id == id }) {
                overlay.selection = .init(kind: .text, rect: seg.rect)
                return
            }
        }
        overlay.selection = nil
    }

    private func seekPreview(to t: Double) {
        guard let player = player else { return }
        if player.rate > 0 { player.pause() }
        let target = mapSourceTimeToPreviewClock(t)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000),
                     toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Translate a source-asset time to the current player item's clock.
    /// When preview is composition-backed (cuts present) this collapses the
    /// cut ranges; otherwise it's a pass-through.
    fileprivate func mapSourceTimeToPreviewClock(_ sourceTime: Double) -> Double {
        guard previewUsesComposition else { return sourceTime }
        return previewSourceTimeToComp(sourceTime)
    }

    /// Inverse of `mapSourceTimeToPreviewClock`. Callers that read the
    /// current player time but want it in source-asset terms (e.g. to draw
    /// the playhead) should go through this.
    fileprivate func mapPreviewClockToSourceTime(_ previewTime: Double) -> Double {
        guard previewUsesComposition else { return previewTime }
        return previewCompTimeToSource(previewTime)
    }

    /// Representation of a zoom segment as a normalized rect. Shape is always
    /// a square of side 1/zoomLevel, centered on segment.center. Used only
    /// for display in the overlay — the underlying model still uses
    /// (center, zoomLevel) as its source of truth.
    private func rectForZoom(_ seg: VideoZoomSegment) -> CGRect {
        let side = 1.0 / max(seg.zoomLevel, 0.0001)
        // Clamp so the displayed rect always matches the actually-visible
        // zoom window (the compositor cannot pan past the frame edge).
        let c = VideoZoomSegment.clampedCenter(seg.center, zoom: seg.zoomLevel)
        let x = c.x - side / 2
        let y = c.y - side / 2
        return CGRect(x: x, y: y, width: side, height: side)
    }

    /// Called when the overlay view reports a new normalized rect.
    /// Dispatches based on the currently-selected segment type.
    private func overlayRectChanged(_ rect: CGRect) {
        guard let id = selectedSegmentID else { return }
        savedURL = nil
        if let seg = zoomSegments.first(where: { $0.id == id }) {
            // Derive zoom level from rect size, clamp to model's range. Use
            // the longer side so the entire rect fits inside the zoom window.
            let side = max(rect.width, rect.height, 0.0001)
            let desiredZoom = 1.0 / side
            seg.zoomLevel = max(VideoZoomSegment.minZoom,
                                 min(VideoZoomSegment.maxZoom, desiredZoom))
            // Center on the rect midpoint, clamped so the zoom window stays
            // fully inside the frame — otherwise the compositor's edge clamp
            // would show a different region than the drawn rect.
            seg.center = VideoZoomSegment.clampedCenter(
                CGPoint(x: rect.midX, y: rect.midY), zoom: seg.zoomLevel)
        } else if let seg = censorSegments.first(where: { $0.id == id }) {
            seg.rect = VideoCensorSegment.clampedRect(rect)
        } else if let seg = textSegments.first(where: { $0.id == id }) {
            seg.rect = VideoTextSegment.clampedRect(rect)
            // Rect resize changes pixel size → invalidate raster cache for
            // this segment so the next composition rebuild re-rasterizes
            // at the new size. Drop only this entry; keep other texts cached.
            textRasterCache.removeValue(forKey: id)
        }
        applyZoomTransformForCurrentTime()
        effectsBand?.refreshAfterParentEdit()
        needsDisplay = true
    }

    override var acceptsFirstResponder: Bool { true }


    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        // Trim handles (higher priority than zoom segments)
        let handleHitW: CGFloat = 16
        let startX = timelineRect.minX + CGFloat(trimStart / duration) * timelineRect.width
        let endX = timelineRect.minX + CGFloat(trimEnd / duration) * timelineRect.width

        if abs(point.x - startX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingStart = true; return
        }
        if abs(point.x - endX) < handleHitW && abs(point.y - timelineRect.midY) < 25 {
            isDraggingEnd = true; return
        }

        // Scrub timeline
        if timelineRect.insetBy(dx: 0, dy: -10).contains(point) {
            // Clicking the trim bar deselects any effect segment
            effectsBand?.clearSelection()
            isDraggingScrubber = true
            scrubTo(point: point)
            return
        }

        // Clicking outside the timeline also deselects
        effectsBand?.clearSelection()

        // Native buttons handle normal input. Keep this fallback for events
        // delivered directly to the canvas, using the same action dispatcher.
        let controls: [(NSRect, ToolbarControl)] = [
            (formatMP4Rect, .mp4), (formatGIFRect, .gif), (dimensionsBtnRect, .dimensions),
            (qualityBtnRect, .quality), (gifFPSBtnRect, .gifFPS), (addEffectBtnRect, .effect),
            (playBtnRect, .play), (muteBtnRect, .mute), (saveArrowRect, .saveMenu),
            (saveBtnRect, .save), (finderBtnRect, .finder),
            (copyArrowRect, .copyMenu), (copyBtnRect, .copy),
        ]
        if let control = controls.first(where: { $0.0.contains(point) }) { performToolbarControl(control.1) }
    }

    override func mouseDragged(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)

        if isDraggingStart {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimStart = min(t, trimEnd - 0.1)
            savedURL = nil
            let target = mapSourceTimeToPreviewClock(trimStart)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingEnd {
            let t = max(0, min(duration, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
            trimEnd = max(t, trimStart + 0.1)
            savedURL = nil
            let target = mapSourceTimeToPreviewClock(trimEnd)
            player?.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000), toleranceBefore: .zero, toleranceAfter: .zero)
            needsDisplay = true
        } else if isDraggingScrubber {
            scrubTo(point: point)
        }
    }

    override func mouseUp(with event: NSEvent) {
        isDraggingStart = false
        isDraggingEnd = false
        isDraggingScrubber = false
    }

    private func scrubTo(point: NSPoint) {
        let t = max(trimStart, min(trimEnd, Double((point.x - timelineRect.minX) / timelineRect.width) * duration))
        let target = mapSourceTimeToPreviewClock(t)
        player?.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000), toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - Actions

    private func toggleMute() {
        isMuted.toggle()
        savedURL = nil
        player?.isMuted = isMuted
        needsDisplay = true
    }

    private func togglePlayPause() {
        if isGIF {
            gifIsPlaying.toggle()
            gifImageView?.animates = gifIsPlaying
            if gifIsPlaying {
                gifPlaybackTime = trimStart
            }
            needsDisplay = true
            return
        }
        guard let player = player else { return }
        if player.rate > 0 {
            player.pause()
        } else {
            let current = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
            if current < trimStart || current >= trimEnd - 0.1 {
                let target = mapSourceTimeToPreviewClock(trimStart)
                player.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000))
            }
            player.play()
        }
        needsDisplay = true
    }

    private func showStatus(_ msg: String, isError: Bool = false, persist: Bool = false) {
        statusMessage = msg
        statusIsError = isError
        statusTimer?.invalidate()
        if !persist {
            statusTimer = Timer.scheduledTimer(withTimeInterval: isError ? 6 : 3, repeats: false) { [weak self] _ in
                self?.statusMessage = nil
                self?.needsDisplay = true
            }
        }
        needsDisplay = true
    }

    /// One app-owned lifecycle for every editor export. The native progress
    /// window remains usable after this view has been released.
    private func startExport(status: String, title: String,
        operation: @escaping @MainActor (MediaExportCancellation, @escaping @Sendable (Double) -> Void) async throws -> Void,
        completion: @escaping @MainActor (Result<Void, Error>) -> Void) {
        guard !isExporting else { completion(.failure(CancellationError())); return }
        isExporting = true
        let token = UUID()
        activeExportToken = token
        showStatus(status, persist: true)
        let job = MediaExportCoordinator.shared.start(title: title, status: status, operation: { [weak self] cancellation, report in
            let progress: @Sendable (Double) -> Void = { [weak self] fraction in
                guard fraction.isFinite else { return }
                report(fraction)
                let percent = Int(max(0, min(1, fraction)) * 100)
                DispatchQueue.main.async {
                    guard self?.activeExportToken == token, self?.activeExportJob?.isCancelling != true else { return }
                    self?.showStatus(status + " \(percent)%", persist: true)
                }
            }
            try await operation(cancellation, progress)
        }, completion: { [weak self] result in
            self?.isExporting = false
            self?.activeExportJob = nil
            self?.activeExportToken = nil
            if case .failure(let error) = result, error is CancellationError {
                self?.showStatus(L("Cancelled"))
            }
            self?.needsDisplay = true
            completion(result)
        })
        activeExportJob = job
        MediaExportProgressController.show(for: job)
    }

    private func performExport(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL,
                               completion: @escaping (Result<Void, Error>) -> Void) {
        guard !isExporting,
              let prepared = prepareExport(asset: asset, timeRange: timeRange, outputURL: outputURL) else {
            completion(.failure(MediaExportPump.ExportError.invalidSetup))
            return
        }
        startExport(status: L("Exporting..."), title: videoURL.lastPathComponent, operation: { cancellation, progress in
            try await prepared.export(to: outputURL) { progress($0) }
            try cancellation.beginPublication()
        }, completion: completion)
    }

    /// Capture the whole media pipeline before any asynchronous save work.
    /// Compositions, settings and effect snapshots belong exclusively to the
    /// returned job. Later edits can invalidate the cache, but cannot change it.
    private func prepareExport(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> VideoExportJob? {
        if exportQuality == .high {
            guard let session = exportSession(asset: asset, timeRange: timeRange, outputURL: outputURL) else { return nil }
            return VideoExportJob(session: session, sourceLease: sourceLease)
        }
        guard let request = reencodeRequest(asset: asset, timeRange: timeRange, outputURL: outputURL) else { return nil }
        return VideoExportJob(request: request, sourceLease: sourceLease)
    }

    private func copyToClipboard() {
        guard !isExporting else { return }
        // If GIF mode is selected but no GIF has been saved yet, convert to a temp GIF first
        if exportAsGIF && !isGIF && !(savedURL?.pathExtension.lowercased() == "gif") {
            showStatus(L("Converting to GIF…"))
            let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".gif")
            convertToGIF(destURL: tmpURL) { [weak self] success in
                guard let self = self, success else { return }
                self.copyGIFData(from: tmpURL)
            }
            return
        }

        // Trim, zoom/censor/text, cuts, speed, mute etc. exist only in the
        // export pipeline — copying the raw source URL would silently discard
        // them (#193). savedURL is reset to nil on every edit, so it being nil
        // with pending edits means the source file is stale.
        if savedURL == nil && hasPendingEdits {
            showStatus(L("Exporting..."))
            exportEditedTemp { [weak self] result in
                guard let self = self else { return }
                let url: URL
                switch result {
                case .success(let output): url = output
                case .failure(let error):
                    if !(error is CancellationError) { self.showStatus(L("Export failed"), isError: true) }
                    return
                }
                // exportEditedTemp always re-encodes to an MP4 container
                // (AVAssetWriter/AVAssetExportSession hardcode fileType .mp4),
                // so the exported bytes are MP4 regardless of the source name.
                self.copyMP4Data(from: url, contentIsMP4: true)
            }
            return
        }

        guard let url = savedURL else {
            copyUneditedSourceToClipboard()
            return
        }

        if isGIF || url.pathExtension.lowercased() == "gif" {
            copyGIFData(from: url)
        } else {
            copyMP4Data(from: url)
        }
    }

    /// True when the timeline differs from the source file on disk — the same
    /// conditions saveToDestination uses to decide whether an export is needed.
    private var hasPendingEdits: Bool {
        let needsTrim = trimStart > 0.01 || (duration - trimEnd) > 0.01
        let needsScale = exportScale < 0.999
        let needsRecompress = exportQuality != .high
        let needsEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        return needsTrim || isMuted || needsScale || needsRecompress || needsEffects
            || !cutSegments.isEmpty || !speedSegments.isEmpty || !freezeSegments.isEmpty
    }

    /// Export the edited timeline to a temp file using the same pipeline
    /// selection as saveToDestination, calling completion on the main thread.
    private func exportEditedTemp(completion: @escaping (Result<URL, Error>) -> Void) {
        guard let asset = asset else { completion(.failure(MediaExportPump.ExportError.invalidSetup)); return }
        let tmpURL = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".mp4")
        let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 1_000_000_000),
                                    end: CMTime(seconds: trimEnd, preferredTimescale: 1_000_000_000))
        performExport(asset: asset, timeRange: timeRange, outputURL: tmpURL) { result in
            if case .failure = result { try? FileManager.default.removeItem(at: tmpURL) }
            completion(result.map { tmpURL })
        }
    }

    /// A clipboard URL must survive editor close. Publish a separate clone or
    /// bounded copy rather than exposing the private working-copy lifetime.
    private func copyUneditedSourceToClipboard() {
        let sourceURL = mediaURL
        let sourceLease = self.sourceLease
        let isGIF = self.isGIF
        let output = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(sourceURL.pathExtension)
        startExport(status: L("Saving..."), title: videoURL.lastPathComponent, operation: { cancellation, progress in
            try await MediaExportIO.perform {
                let save = try AtomicMediaSave(destinationURL: output)
                try save.copySource(sourceURL, checkCancellation: { try cancellation.check() }, progress: progress)
                try save.commit(overwritingExisting: false, beforePublish: cancellation.beginPublication)
            }
        }, completion: { [weak self, sourceLease] result in
            defer { withExtendedLifetime(sourceLease) {} }
            switch result {
            case .success:
                if isGIF { self?.copyGIFData(from: output) }
                else { self?.copyMP4Data(from: output) }
            case .failure(let error):
                if !(error is CancellationError) {
                    self?.showStatus(L("Save failed") + ": " + error.localizedDescription, isError: true)
                }
            }
        })
    }

    private func copyGIFData(from url: URL) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? UInt64.max
        if byteCount <= 150_000_000, let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType("com.compuserve.gif"))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
        showStatus(L("Copied to clipboard!"))
    }

    /// Copy video as playable pasteboard data. Inline bytes are advertised as
    /// `public.mpeg-4` ONLY when they really are MP4: either the export pipeline
    /// re-encoded them (`contentIsMP4`, used by the edited branch), or the source
    /// file's extension conforms to mpeg4Movie (direct source copy). A `.mov`
    /// source opened in the editor would otherwise have its QuickTime bytes
    /// mislabeled as MP4 and rejected by Mail/Notes/Preview — regressing #329.
    /// Non-MP4 sources, oversized recordings, and read errors fall back to the
    /// file URL (the pre-#329 behaviour) instead of an empty/mislabeled paste.
    private func copyMP4Data(from url: URL, contentIsMP4: Bool = false) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        let isMP4 = contentIsMP4
            || (UTType(filenameExtension: url.pathExtension)?.conforms(to: .mpeg4Movie) ?? false)
        let byteCount = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? UInt64) ?? 0
        // Data(contentsOf:) allocates the full buffer up front and can be
        // jetsam-killed before `try?` catches, so skip inline data for non-MP4
        // sources or recordings over ~150 MB and land the file URL instead.
        if isMP4, byteCount <= 150_000_000, let data = try? Data(contentsOf: url) {
            let item = NSPasteboardItem()
            item.setData(data, forType: NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier))
            item.setString(url.absoluteString, forType: .fileURL)
            pasteboard.writeObjects([item])
        } else {
            pasteboard.writeObjects([url as NSURL])
        }
        showStatus(L("Copied to clipboard!"))
    }

    private func showCopyMenu() {
        let menu = NSMenu()
        let pathItem = NSMenuItem(title: L("Copy Path"), action: #selector(copyPathAction), keyEquivalent: "")
        pathItem.target = self
        menu.addItem(pathItem)
        popUpAbove(menu, copyArrowRect)
    }

    @objc private func copyPathAction() {
        let url = savedURL ?? videoURL
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url.path, forType: .string)
        showStatus(L("Path copied!"))
    }

    private func exportSession(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> AVAssetExportSession? {
        let needsScale = exportScale < 0.999
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        // Use explicit frame cadence when holds are present so each repeated
        // frame also receives its source-time effects.
        let hasFreeze = !freezeSegments.isEmpty

        guard let processed = buildProcessedComposition(
            srcAsset: asset,
            trimStartSec: CMTimeGetSeconds(timeRange.start),
            trimEndSec: CMTimeGetSeconds(timeRange.end),
            includeAudio: !isMuted
        ) else { return nil }

        guard let session = AVAssetExportSession(asset: processed.composition, presetName: AVAssetExportPresetHighestQuality) else { return nil }
        session.metadata = VideoFrameCadence.metadata(for: sourceFrameDuration)
        session.outputURL = outputURL
        session.outputFileType = .mp4

        if needsScale || hasEffects || hasFreeze {
            guard let srcVideoTrack = asset.tracks(withMediaType: .video).first,
                  let layout = VideoRenderGeometry.layout(sourceSize: srcVideoTrack.naturalSize,
                    preferredTransform: srcVideoTrack.preferredTransform) else { return nil }
            let naturalSize = layout.uprightSize
            let (scaledW, scaledH) = VideoEncodingSettings.evenDimensions(
                width: abs(naturalSize.width) * exportScale,
                height: abs(naturalSize.height) * exportScale
            )
            let renderSize = CGSize(width: scaledW, height: scaledH)
            if hasEffects || hasFreeze {
                session.videoComposition = buildEffectsVideoComposition(
                    for: processed.composition,
                    videoTrack: processed.videoTrack,
                    renderSize: renderSize,
                    timeMap: processed.timeMap
                )
            } else {
                // Scale-only: no custom compositor needed, use a plain layer
                // instruction with a single transform.
                session.videoComposition = buildScaleOnlyComposition(
                    videoTrack: processed.videoTrack,
                    renderSize: renderSize,
                    totalDuration: processed.composition.duration
                )
            }
            guard session.videoComposition != nil else { return nil }
        }

        return session
    }

    private func saveVideo() {
        guard !isExporting else { return }
        if exportAsGIF && !isGIF {
            // GIF mode: need Save As panel since extension changes
            saveVideoAs()
            return
        }
        guard let dirURL = SaveDirectoryAccess.resolveRecordingDirectoryIfAccessible() else {
            saveVideoAs()
            return
        }
        let ext = exportAsGIF ? "gif" : videoURL.pathExtension
        let name = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        let destURL = dirURL.appendingPathComponent(name)
        if exportAsGIF && !isGIF {
            convertToGIF(destURL: destURL)
        } else {
            saveToDestination(destURL, dirURL: dirURL)
        }
    }

    private func saveVideoAs() {
        guard !isExporting else { return }
        let panel = NSSavePanel()
        let saveAsGIF = exportAsGIF && !isGIF
        panel.allowedContentTypes = saveAsGIF ? [.gif] : (isGIF ? [.gif] : [.mpeg4Movie])
        let ext = saveAsGIF ? "gif" : videoURL.pathExtension
        panel.nameFieldStringValue = videoURL.deletingPathExtension().lastPathComponent + ".\(ext)"
        panel.directoryURL = SaveDirectoryAccess.recordingDirectoryHint()
        let completion: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard let self = self, !self.isExporting,
                  response == .OK, let url = panel.url else { return }
            if saveAsGIF {
                self.convertToGIF(destURL: url)
            } else {
                self.saveToDestination(url, dirURL: nil)
            }
        }
        if let window = window {
            panel.beginSheetModal(for: window, completionHandler: completion)
        } else {
            panel.begin(completionHandler: completion)
        }
    }

    private func showSaveMenu() {
        saveVideoAs()
    }

    private func showDimensionsMenu() {
        let menu = NSMenu()
        let w = originalWidth, h = originalHeight

        // Original (100%)
        let origItem = NSMenuItem(title: "\(w) × \(h)  (Original)", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
        origItem.target = self
        origItem.tag = 100
        origItem.state = exportScale >= 0.999 ? .on : .off
        menu.addItem(origItem)

        menu.addItem(NSMenuItem.separator())

        // Preset percentages — only include if the result is at least 128px wide
        let presets: [(Int, String)] = [(75, "75%"), (50, "50%"), (33, "33%"), (25, "25%")]
        for (pct, label) in presets {
            let scaledW = w * pct / 100
            let scaledH = h * pct / 100
            guard scaledW >= 128 else { continue }
            // Round to even for codec compatibility
            let evenW = (scaledW / 2) * 2
            let evenH = (scaledH / 2) * 2
            let item = NSMenuItem(title: "\(evenW) × \(evenH)  (\(label))", action: #selector(dimensionSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = pct
            item.state = abs(exportScale - CGFloat(pct) / 100.0) < 0.01 ? .on : .off
            menu.addItem(item)
        }

        popUpAbove(menu, dimensionsBtnRect)
    }

    @objc private func dimensionSelected(_ sender: NSMenuItem) {
        exportScale = CGFloat(sender.tag) / 100.0
        UserDefaults.standard.set(Double(exportScale), forKey: Self.exportScaleDefaultsKey)
        savedURL = nil
        needsDisplay = true
    }

    /// Menus of the bottom button row open UPWARD: the editor usually sits low on the screen,
    /// and a menu opened downward got cut off (long ones — + Effect, GIF fps — needed scrolling).
    private func popUpAbove(_ menu: NSMenu, _ rect: NSRect) {
        // NSMenu has no reliable size before it is shown, so anchor its LAST item just above
        // the button: the rest of the menu then grows upward.
        menu.popUp(positioning: menu.items.last, at: NSPoint(x: rect.minX, y: rect.maxY + 24), in: self)
    }

    private func showQualityMenu() {
        let menu = NSMenu()
        let options: [(VideoQuality, String)] = [
            (.high,   L("High")),
            (.medium, L("Medium")),
            (.low,    L("Low")),
        ]
        for (q, label) in options {
            let item = NSMenuItem(title: label, action: #selector(qualitySelected(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = q.rawValue
            item.state = (q == exportQuality) ? .on : .off
            menu.addItem(item)
        }
        popUpAbove(menu, qualityBtnRect)
    }

    // MARK: - Text options panel (selected text segment)

    /// Mutate the selected text segment and refresh everything that renders it.
    private func mutateSelectedTextSegment(_ mutate: (VideoTextSegment) -> Void) {
        guard let seg = selectedTextSegment else { return }
        mutate(seg)
        seg.rememberStyle()
        textRasterCache.removeValue(forKey: seg.id)
        savedURL = nil
        applyZoomTransformForCurrentTime()
        forcePreviewRedisplayIfPaused()
        effectsBand?.refreshAfterParentEdit()
        needsDisplay = true
    }

    /// AVFoundation does not reliably re-render a paused frame when the
    /// player item's videoComposition is swapped in place, so style changes
    /// made while paused would not show until the next seek or play. A
    /// zero-tolerance seek to the current time forces the compositor to
    /// re-render the visible frame.
    fileprivate func forcePreviewRedisplayIfPaused() {
        guard let player = player, player.rate == 0 else { return }
        let t = player.currentTime()
        player.seek(to: t, toleranceBefore: .zero, toleranceAfter: .zero)
    }

    /// Apply one panel edit to the selected segment, then re-sync the panel
    /// so dependent controls (size label, swatches, enabled states) update.
    private func handleTextOptionsChange(_ change: VideoTextOptionsPanel.Change) {
        guard let seg = selectedTextSegment else { return }
        switch change {
        case .fontFamily(let family):
            mutateSelectedTextSegment { $0.fontFamily = family }
        case .fontSize(let size):
            mutateSelectedTextSegment { $0.fontSize = size }
        case .bold(let flag):
            mutateSelectedTextSegment { $0.bold = flag }
        case .italic(let flag):
            mutateSelectedTextSegment { $0.italic = flag }
        case .bgStyle(let style):
            mutateSelectedTextSegment { $0.bgStyle = style }
        case .alignment(let alignment):
            mutateSelectedTextSegment { $0.alignment = alignment }
        case .outlineEnabled(let flag):
            mutateSelectedTextSegment { $0.outlineEnabled = flag }
        case .outlineWidth(let width):
            mutateSelectedTextSegment { $0.outlineWidth = width }
        case .pickTextColor:
            presentTextColorPicker(segmentID: seg.id, target: .text)
        case .pickBgColor:
            presentTextColorPicker(segmentID: seg.id, target: .background)
        case .pickOutlineColor:
            presentTextColorPicker(segmentID: seg.id, target: .outline)
        }
        textOptionsPanel?.configure(with: seg)
    }

    /// Show the panel (configured for the selection) or collapse it. Follows
    /// the `effectsBand(_:didChangeRowCount:)` pattern: the panel's height
    /// constraint and the player's bottom constraint animate together, and
    /// the custom-drawn chrome above re-lays out via `textOptionsPanelH`.
    private func updateTextOptionsPanelVisibility() {
        if let seg = selectedTextSegment {
            textOptionsPanel?.configure(with: seg)
        }
        let targetH: CGFloat = selectedTextSegment != nil ? VideoTextOptionsPanel.preferredHeight : 0
        guard textOptionsPanelH != targetH else { return }
        textOptionsPanelH = targetH
        textOptionsPanel?.isHidden = (targetH == 0)
        textOptionsPanelHeightConstraint?.animator().constant = targetH
        effectsBandHeightConstraint?.animator().constant = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        playerBottomConstraint?.animator().constant = -controlsH
        needsDisplay = true
    }

    private func showGIFFPSMenu() {
        let menu = NSMenu()
        for fps in 5...30 {
            let item = NSMenuItem(title: "\(fps) fps", action: #selector(gifFPSSelected(_:)), keyEquivalent: "")
            item.target = self
            item.tag = fps
            item.state = (fps == gifExportFPS) ? .on : .off
            menu.addItem(item)
        }
        popUpAbove(menu, gifFPSBtnRect)
    }

    @objc private func gifFPSSelected(_ sender: NSMenuItem) {
        gifExportFPS = min(30, max(5, sender.tag))
        UserDefaults.standard.set(gifExportFPS, forKey: "gifExportFPS")
        savedURL = nil
        needsDisplay = true
    }

    @objc private func qualitySelected(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let q = VideoQuality(rawValue: raw) {
            exportQuality = q
            UserDefaults.standard.set(raw, forKey: Self.exportQualityDefaultsKey)
            savedURL = nil
            needsDisplay = true
        }
    }

    private func convertToGIF(destURL: URL, cacheResult: Bool = true, completion: ((Bool) -> Void)? = nil) {
        guard !isExporting, let asset else { completion?(false); return }
        let revision = editRevision
        let sourceSnapshot = self.sourceSnapshot
        let request: GIFExporter.Request
        do {
            request = try prepareGIF(asset: asset, outputURL: destURL)
        } catch {
            showStatus(L("GIF conversion failed") + ": " + error.localizedDescription, isError: true)
            completion?(false)
            return
        }
        startExport(status: L("Processing GIF…"), title: destURL.lastPathComponent, operation: { cancellation, progress in
            try await GIFExporter.export(request, cancellation: cancellation, progress: progress)
        }, completion: { [weak self] result in
            switch result {
            case .success:
                sourceSnapshot?.didSave(at: destURL)
                if cacheResult, self?.editRevision == revision { self?.savedURL = destURL }
                self?.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                completion?(true)
            case .failure(let error):
                if !(error is CancellationError) {
                    let message = L("GIF conversion failed") + ": " + error.localizedDescription
                    if let self { self.showStatus(message, isError: true) }
                    else { (NSApp.delegate as? AppDelegate)?.showFailureToast(message) }
                }
                completion?(false)
            }
        })
    }

    /// GIF uses the same processed timeline and upright rendering geometry as
    /// MP4. Explicit output cadence repeats sparse source frames for their full
    /// duration; the streaming encoder then combines identical pixels cheaply.
    private func prepareGIF(asset: AVAsset, outputURL: URL) throws -> GIFExporter.Request {
        guard let sourceVideo = asset.tracks(withMediaType: .video).first,
              let layout = VideoRenderGeometry.layout(sourceSize: sourceVideo.naturalSize,
                preferredTransform: sourceVideo.preferredTransform),
              let processed = buildProcessedComposition(srcAsset: asset,
                trimStartSec: trimStart, trimEndSec: trimEnd, includeAudio: false) else {
            throw GIFExporter.ExportError.invalidSetup
        }
        let (width, height) = VideoEncodingSettings.evenDimensions(
            width: layout.uprightSize.width * exportScale, height: layout.uprightSize.height * exportScale)
        let renderSize = CGSize(width: width, height: height)
        let cadence = CMTime(value: 1, timescale: CMTimeScale(min(30, max(5, gifExportFPS))))
        let composition: AVMutableVideoComposition
        if !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty || !freezeSegments.isEmpty {
            guard let effects = buildEffectsVideoComposition(for: processed.composition,
                videoTrack: processed.videoTrack, renderSize: renderSize, timeMap: processed.timeMap) else { throw GIFExporter.ExportError.invalidSetup }
            composition = effects
            composition.frameDuration = cadence
        } else {
            composition = try VideoCompositionRendering.scaleComposition(track: processed.videoTrack,
                renderSize: renderSize, duration: processed.composition.duration, frameDuration: cadence)
        }
        return GIFExporter.Request(asset: processed.composition, videoTrack: processed.videoTrack,
            composition: composition, timeRange: CMTimeRange(start: .zero, duration: processed.composition.duration),
            outputURL: outputURL, sourceLease: sourceLease)
    }

    private func saveToDestination(_ destURL: URL, dirURL: URL?) {
        let directoryLease = SaveDirectoryLease(alreadyAccessing: dirURL)
        guard !isExporting else { return }
        let needsExport = hasPendingEdits
        let sourceURL = mediaURL
        let sourceLease = self.sourceLease
        let sourceSnapshot = self.sourceSnapshot
        let revision = editRevision
        guard !needsExport || asset != nil else { return }
        let timeRange = CMTimeRange(start: CMTime(seconds: trimStart, preferredTimescale: 1_000_000_000),
                                    end: CMTime(seconds: trimEnd, preferredTimescale: 1_000_000_000))
        let job: VideoExportJob?
        if needsExport, let asset {
            guard let prepared = prepareExport(asset: asset, timeRange: timeRange, outputURL: destURL) else {
                showStatus(L("Export failed"), isError: true)
                return
            }
            job = prepared
        } else { job = nil }
        startExport(status: needsExport ? L("Exporting...") : L("Saving..."), title: destURL.lastPathComponent,
            operation: { cancellation, progress in
                let save = try await MediaExportIO.perform { () throws -> AtomicMediaSave in
                    try cancellation.check()
                    return try AtomicMediaSave(destinationURL: destURL)
                }
                if let job {
                    try await job.export(to: save.stagingURL) { progress($0) }
                } else {
                    try await MediaExportIO.perform {
                        try save.copySource(sourceURL, checkCancellation: { try cancellation.check() }, progress: progress)
                    }
                }
                try await MediaExportIO.perform {
                    try save.commit(beforePublish: { try cancellation.beginPublication() })
                }
            }, completion: { [weak self, directoryLease, sourceLease] result in
                defer { withExtendedLifetime(directoryLease) {}; withExtendedLifetime(sourceLease) {} }
                switch result {
                case .success:
                    sourceSnapshot?.didSave(at: destURL)
                    if self?.editRevision == revision { self?.savedURL = destURL }
                    self?.showStatus(String(format: L("Saved to %@"), destURL.lastPathComponent))
                case .failure(let error):
                    guard !(error is CancellationError) else { return }
                    let message = L("Save failed") + ": " + error.localizedDescription
                    if let self { self.showStatus(message, isError: true) }
                    else { (NSApp.delegate as? AppDelegate)?.showFailureToast(message) }
                }
            })
    }

    /// Pure planning is cached by revision, so timeline redraws do not fetch
    /// filesystem/AVFoundation metadata or rebuild the edit map on every frame.
    private var plannedMP4Export: (plan: VideoExportEncodingPlan, duration: Double)? {
        if encodingPlanRevision == editRevision { return encodingPlanCache }
        encodingPlanRevision = editRevision
        encodingPlanCache = nil
        guard !isGIF, exportQuality != .high, let encodingSource else { return nil }
        let kept = VideoCuts.keptRanges(trimStart: trimStart, trimEnd: trimEnd, cuts: cutSegments)
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: speedSegments, freezes: freezeSegments)
        let outputDuration = pieces.reduce(0) { $0 + $1.compositionDuration }
        let consumedDuration = pieces.reduce(0) { $0 + $1.sourceDuration }
        guard let plan = VideoExportEncodingPlan.make(source: encodingSource, scale: exportScale,
            quality: exportQuality, sourceDuration: consumedDuration, outputDuration: outputDuration) else { return nil }
        encodingPlanCache = (plan, outputDuration)
        return encodingPlanCache
    }

    /// Re-encode pipeline with explicit bitrate control via AVAssetReader/Writer.
    /// Used when the user selects a non-High quality preset so the bitrate
    /// actually takes effect (AVAssetExportSession presets hardcode bitrate).
    private func reencodeRequest(asset: AVAsset, timeRange: CMTimeRange, outputURL: URL) -> VideoTranscoder.Request? {
        guard let videoTrack = asset.tracks(withMediaType: .video).first,
              let plan = plannedMP4Export?.plan else {
            return nil
        }

        let outW = plan.width, outH = plan.height
        let cadence = sourceFrameDuration

        let includeAudio = !isMuted
        let srcAudioTracks = asset.tracks(withMediaType: .audio)
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        let hasCuts = !cutSegments.isEmpty
        let hasSpeed = !speedSegments.isEmpty
        let hasFreeze = !freezeSegments.isEmpty

        // When effects OR cuts OR speed OR freeze exist we must route
        // through a composition so cuts skip frames, speed/freeze scale
        // the clock, and the compositor applies zoom + censor. Otherwise
        // we read raw scaled frames directly from the source track and
        // pull audio straight from the original asset.
        //
        // Holds use a constant source-time mapping for effects and an
        // explicit output cadence for repeated frames.
        let readerAsset: AVAsset
        let readerVideoTrack: AVAssetTrack
        let readerAudioTracks: [AVAssetTrack]
        let readerTimeRange: CMTimeRange
        var readerComposition: AVMutableVideoComposition?
        if hasEffects || hasCuts || hasSpeed || hasFreeze {
            guard let processed = buildProcessedComposition(
                srcAsset: asset,
                trimStartSec: CMTimeGetSeconds(timeRange.start),
                trimEndSec: CMTimeGetSeconds(timeRange.end),
                includeAudio: includeAudio
            ) else {
                return nil
            }
            readerAsset = processed.composition
            readerVideoTrack = processed.videoTrack
            readerAudioTracks = processed.audioTracks
            readerTimeRange = CMTimeRange(start: .zero, duration: processed.composition.duration)
            if hasEffects || hasFreeze {
                readerComposition = buildEffectsVideoComposition(
                    for: processed.composition,
                    videoTrack: processed.videoTrack,
                    renderSize: CGSize(width: outW, height: outH),
                    timeMap: processed.timeMap
                )
                guard readerComposition != nil else { return nil }
            } else {
                readerComposition = nil
            }
        } else {
            readerAsset = asset
            readerVideoTrack = videoTrack
            readerAudioTracks = srcAudioTracks
            readerTimeRange = timeRange
            readerComposition = nil
        }

        if readerComposition == nil && (readerVideoTrack.preferredTransform != .identity ||
            CGSize(width: outW, height: outH) != readerVideoTrack.naturalSize || hasSpeed) {
            do {
                readerComposition = try VideoCompositionRendering.scaleComposition(track: readerVideoTrack,
                    renderSize: CGSize(width: outW, height: outH), duration: readerTimeRange.end, frameDuration: cadence)
            } catch { return nil }
        }
        readerComposition?.frameDuration = cadence

        return VideoTranscoder.Request(
            asset: readerAsset, videoTrack: readerVideoTrack,
            audioTracks: includeAudio ? readerAudioTracks : [], composition: readerComposition,
            timeRange: readerTimeRange, outputURL: outputURL,
            videoSettings: plan.outputSettings,
            decodedSize: nil, outputTransform: .identity, sourceFrameDuration: cadence)
    }

    // MARK: - Keyboard

    override func keyDown(with event: NSEvent) {
        switch event.keyCode {
        case 53 where activeExportJob != nil:
            activeExportJob?.cancel()
        case 49: // Space
            togglePlayPause()
        case 123: // Left arrow — step back one frame
            stepFrame(forward: false)
        case 124: // Right arrow — step forward one frame
            stepFrame(forward: true)
        default:
            // Segment-related keys (Delete, +/-) are handled by EffectsBandView
            // when it's first responder; fall through here.
            super.keyDown(with: event)
        }
    }


    /// Rebuild the AVPlayerItem's videoComposition so live playback reflects
    /// the current zoom + censor segments. Also used when editing segments
    /// during playback — AVPlayer picks up composition changes on the next frame.
    ///
    /// Preview strategy:
    ///   - No cuts, no speed: play directly off the original asset. Segment
    ///     times align with the asset clock, so the time-map is a pass-through.
    ///   - Cuts or speed present: play off a composition whose video+audio
    ///     tracks contain the kept/re-timed ranges, so cuts skip and speed
    ///     scales the clock naturally.
    ///
    /// **Flicker avoidance:** swapping the player item causes a black flash
    /// while AVPlayer re-initializes its rendering pipeline, so we only do
    /// it when the cut/speed *topology* changes. Rect/style edits on zoom
    /// or censor segments just refresh `videoComposition` on the current
    /// item — cheap and flicker-free.
    fileprivate func applyZoomTransformForCurrentTime() {
        guard let player = player, let asset = asset else { return }

        let hasCuts = !cutSegments.isEmpty
        let hasSpeed = !speedSegments.isEmpty
        let hasFreeze = !freezeSegments.isEmpty
        let hasEffects = !zoomSegments.isEmpty || !censorSegments.isEmpty || !textSegments.isEmpty
        let needsComposition = hasCuts || hasSpeed || hasFreeze
        // Fingerprint of the full timeline topology (cuts + speeds +
        // freezes). When unchanged we can keep the existing composition-
        // backed player item and only refresh its videoComposition.
        let topoFingerprint = timelineTopologyFingerprint()

        // Fast path: nothing to apply. Fall back to the original asset with
        // no videoComposition.
        if !needsComposition && !hasEffects {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionTopoFingerprint = ""
            } else {
                player.currentItem?.videoComposition = nil
            }
            return
        }

        // Cuts/speed absent: stay on the original asset and only attach the
        // effects composition — much cheaper than rebuilding the player item.
        if !needsComposition {
            if previewUsesComposition {
                swapPreviewPlayerItem(asset: asset, videoComposition: nil)
                previewUsesComposition = false
                previewCompositionTopoFingerprint = ""
            }
            player.currentItem?.videoComposition = buildEffectsVideoComposition(
                for: asset,
                videoTrack: asset.tracks(withMediaType: .video).first,
                renderSize: nil,
                timeMap: singleShiftTimeMap(shift: 0, duration: CMTimeGetSeconds(asset.duration)),
                suspendZoom: previewSuspendsZoom,
                excludingTextSegmentID: inlineTextEditingSegmentID
            )
            return
        }

        // Timeline topology unchanged: reuse the existing item and refresh
        // only the effects composition. Avoids the black flash on rect edits.
        if previewUsesComposition,
           previewCompositionTopoFingerprint == topoFingerprint,
           let currentItem = player.currentItem,
           let compAsset = currentItem.asset as? AVMutableComposition,
           let cvt = compAsset.tracks(withMediaType: .video).first {
            if hasEffects {
                // The existing item retains the exact map used to build it.
                currentItem.videoComposition = buildEffectsVideoComposition(
                    for: compAsset,
                    videoTrack: cvt,
                    renderSize: nil,
                    timeMap: previewTimeline.entries,
                    suspendZoom: previewSuspendsZoom,
                    excludingTextSegmentID: inlineTextEditingSegmentID
                )
            } else {
                currentItem.videoComposition = nil
            }
            return
        }

        // Topology changed (cuts/speed added/removed/resized). Rebuild the
        // composition-backed player item. Preview uses the *full* asset
        // duration — not just the trim range — so scrubbing the trim bars
        // still works against source-asset time.
        guard let processed = buildProcessedComposition(
            srcAsset: asset,
            trimStartSec: 0,
            trimEndSec: duration,
            includeAudio: true
        ) else { return }

        var videoComp: AVMutableVideoComposition?
        if hasEffects {
            videoComp = buildEffectsVideoComposition(
                for: processed.composition,
                videoTrack: processed.videoTrack,
                renderSize: nil,
                timeMap: processed.timeMap,
                suspendZoom: previewSuspendsZoom,
                excludingTextSegmentID: inlineTextEditingSegmentID
            )
        }
        swapPreviewPlayerItem(asset: processed.composition, videoComposition: videoComp, timeMap: processed.timeMap)
        previewUsesComposition = true
        previewCompositionTopoFingerprint = topoFingerprint
    }

    /// Snapshot of the cut+speed topology used to build `player.currentItem`
    /// when that item is a composition. Compared against the current
    /// fingerprint to decide whether a player-item swap is needed.
    private var previewCompositionTopoFingerprint = ""
    private var previewTimeline = VideoTimelineMapping(entries: [])

    /// Replace the player's current item with a new one backed by `asset`,
    /// preserving playback position and rate. Preview seeks target the source
    /// asset clock, so we map the current time through the cut-aware time
    /// map before resuming.
    private func swapPreviewPlayerItem(asset: AVAsset, videoComposition: AVMutableVideoComposition?,
                                       timeMap: [EffectsCompositionInstruction.TimeMapEntry] = []) {
        guard let player = player else { return }
        let wasPlaying = player.rate != 0
        let prevRate = player.rate
        let prevSourceTime: Double = {
            if let current = player.currentItem {
                let t = CMTimeGetSeconds(current.currentTime())
                return previewUsesComposition ? previewCompTimeToSource(t) : t
            }
            return trimStart
        }()

        let newItem = AVPlayerItem(asset: asset)
        newItem.videoComposition = videoComposition
        player.replaceCurrentItem(with: newItem)
        previewTimeline = VideoTimelineMapping(entries: timeMap)

        // Map source time → target item's clock. The comp item's clock is
        // "kept-ranges concatenated from 0". Outside of preview-comp mode
        // (straight asset), source == comp time.
        let targetT: Double
        if videoComposition != nil || asset is AVMutableComposition {
            targetT = previewSourceTimeToComp(prevSourceTime)
        } else {
            targetT = prevSourceTime
        }
        player.seek(to: CMTime(seconds: targetT, preferredTimescale: 1_000_000_000),
                    toleranceBefore: .zero, toleranceAfter: .zero)
        if wasPlaying { player.rate = prevRate }
    }

    /// Convert using the mapping owned by the current player item, even while
    /// the editor is constructing a new cut/speed/freeze timeline.
    ///
    /// Formula: for the piece covering `compTime`,
    ///     `sourceTime = piece.srcStart + (compTime - piece.compStart) * factor`.
    /// Freeze pieces have factor zero, so the source playhead remains at
    /// the selected moment throughout the complete hold.
    private func previewCompTimeToSource(_ compTime: Double) -> Double {
        previewTimeline.sourceTime(at: compTime)
    }

    /// Inverse of `previewCompTimeToSource`. Clamps to the nearest piece
    /// when `sourceTime` falls inside a cut (no piece covers it). For
    /// freeze pieces the mapping is ambiguous — any compTime inside the
    /// hold maps to the same sourceTime. We pick the start of the hold
    /// when the caller asks for that exact frame, which gives seek /
    /// scrub behaviour that feels natural.
    private func previewSourceTimeToComp(_ sourceTime: Double) -> Double {
        previewTimeline.compositionTime(at: sourceTime)
    }

    /// True when the player's current item is a cut-stripped composition
    /// (so its clock no longer matches the source asset).
    private var previewUsesComposition = false

    /// Simple composition for the scale-only export path (no zoom, no censor).
    /// Applies preferredTransform + uniform scale via setTransform — cheap, no
    /// custom compositor cost.
    private func buildScaleOnlyComposition(videoTrack: AVAssetTrack, renderSize: CGSize,
                                           totalDuration: CMTime) -> AVMutableVideoComposition? {
        do {
            return try VideoCompositionRendering.scaleComposition(track: videoTrack, renderSize: renderSize,
                duration: totalDuration,
                frameDuration: sourceFrameDuration)
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return nil
        }
    }

    private var sourceFrameDuration: CMTime {
        guard let cadence = encodingSource?.frameDuration, VideoFrameCadence.isUsable(cadence) else {
            return CMTime(value: 1, timescale: 30)
        }
        return cadence
    }

    /// Build an AVMutableVideoComposition backed by the custom effects
    /// compositor.
    ///
    /// - Parameters:
    ///   - asset: the asset (often an AVMutableComposition) whose track we
    ///     read. Its track IDs must match `videoTrack`.
    ///   - videoTrack: the specific track to read from.
    ///   - renderSize: nil means "use natural-size rendering."
    ///   - timeMap: composition-time → source-asset-time mapping. Callers
    ///     without cuts pass a single entry spanning the whole composition.
    private func buildEffectsVideoComposition(for asset: AVAsset,
                                              videoTrack: AVAssetTrack?,
                                              renderSize: CGSize?,
                                              timeMap: [EffectsCompositionInstruction.TimeMapEntry],
                                              suspendZoom: Bool = false,
                                              excludingTextSegmentID: UUID? = nil) -> AVMutableVideoComposition? {
        let track = videoTrack ?? asset.tracks(withMediaType: .video).first
        guard let videoTrack = track else { return nil }
        guard let layout = VideoRenderGeometry.layout(sourceSize: videoTrack.naturalSize,
            preferredTransform: videoTrack.preferredTransform, renderSize: renderSize) else { return nil }
        let naturalW = layout.uprightSize.width
        let naturalH = layout.uprightSize.height
        let renderW = layout.renderSize.width
        let renderH = layout.renderSize.height

        // Skip composition entirely when there's nothing to render — callers
        // should already guard on this, but being explicit avoids shipping a
        // custom compositor through the pipeline unnecessarily.
        //
        // Holds also use the compositor so source-time effects stay frozen
        // with the image while output frames continue at the chosen cadence.
        guard !zoomSegments.isEmpty || !censorSegments.isEmpty || !freezeSegments.isEmpty || !textSegments.isEmpty else {
            return nil
        }

        // Snapshot segments *by value* into plain arrays. The compositor runs
        // on background queues; we must not share main-actor state with it.
        let zoomSnapshot = suspendZoom ? [] : zoomSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .map(VideoZoomSnapshot.init)
        let censorSnapshot = censorSegments
            .filter { $0.endTime > $0.startTime }
            .sorted { $0.startTime < $1.startTime }
            .map(VideoCensorSnapshot.init)

        // Build text snapshots: rasterize each visible text segment at its
        // render-pixel size, reusing cached images when the spec is
        // unchanged. The cache stays on the main actor; we hand the
        // background-safe `TextSnapshot` (CIImage + scalars) to the
        // compositor instruction.
        let textSnapshots = buildTextSnapshots(renderSize: CGSize(width: renderW, height: renderH),
                                                 naturalSize: CGSize(width: naturalW, height: naturalH),
                                                 excluding: excludingTextSegmentID)

        return VideoCompositionRendering.effectsComposition(
            asset: asset, track: videoTrack, layout: layout, frameDuration: sourceFrameDuration,
            timeMap: timeMap, zoomSegments: zoomSnapshot, censorSegments: censorSnapshot,
            textSnapshots: textSnapshots)
    }

    /// Convenience: build a single-entry time map from a scalar shift. All
    /// existing non-cut, non-speed callers use this — factor 1 means the
    /// piece plays at real time.
    private func singleShiftTimeMap(shift: Double, duration: Double) -> [EffectsCompositionInstruction.TimeMapEntry] {
        return [.init(compStart: 0, compEnd: duration, sourceStart: shift, factor: 1.0)]
    }

    /// The full set of speed segments currently owned by the effects band.
    /// Mirror of `cutSegments` / `zoomSegments` but for speed.
    private var speedSegments: [VideoSpeedSegment] { effectsBand?.speedSegments ?? [] }

    /// Freeze segments — point-in-time pauses. See `VideoFreezeSegment`.
    private var freezeSegments: [VideoFreezeSegment] { effectsBand?.freezeSegments ?? [] }

    /// Result of `buildProcessedComposition` — the composition plus the
    /// matching time-map and the video/audio comp tracks so callers can
    /// route a custom compositor at them.
    fileprivate typealias ProcessedComposition = VideoCompositionBuilder.Result

    /// Build an AVMutableComposition that bakes in the current trim range,
    /// cut list and speed list. Audio tracks mirror the video so A/V stays
    /// in sync across cuts and speed changes.
    ///
    /// - Parameters:
    ///   - srcAsset: Original source asset (for its video/audio tracks).
    ///   - trimStartSec / trimEndSec: Effective trim range in source time.
    ///   - includeAudio: When false, no audio tracks are created.
    ///
    /// Returns nil if the source has no video track or the resulting
    /// composition would be empty.
    fileprivate func buildProcessedComposition(srcAsset: AVAsset,
                                                trimStartSec: Double,
                                                trimEndSec: Double,
                                                includeAudio: Bool) -> ProcessedComposition? {
        let kept = VideoCuts.keptRanges(trimStart: trimStartSec, trimEnd: trimEndSec, cuts: cutSegments)
        let pieces = VideoSpeeds.pieces(keptRanges: kept, speeds: speedSegments, freezes: freezeSegments)
        do {
            return try VideoCompositionBuilder.build(asset: srcAsset, pieces: pieces, includeAudio: includeAudio,
                                                      sourceFrameDuration: sourceFrameDuration)
        } catch {
            showStatus(error.localizedDescription, isError: true)
            return nil
        }
    }

    /// Fingerprint of the current cut+speed+freeze topology — used by the
    /// preview path to decide whether a player-item swap is needed.
    /// Changes to zoom/censor *rects* don't affect this, so those edits
    /// stay cheap.
    fileprivate func timelineTopologyFingerprint() -> String {
        let cuts = cutSegments
            .map { "c:\($0.startTime.bitPattern)-\($0.endTime.bitPattern)" }
        let speeds = speedSegments
            .map { "s:\($0.startTime.bitPattern)-\($0.endTime.bitPattern)@\($0.speedFactor.bitPattern)" }
        let freezes = freezeSegments
            .map { "f:\($0.atTime.bitPattern)@\($0.holdDuration.bitPattern)" }
        return (cuts + speeds + freezes).joined(separator: "|")
    }

    private func stepFrame(forward: Bool) {
        guard let player = player else { return }
        // Pause if playing
        if player.rate > 0 { player.pause(); needsDisplay = true }

        let frameDuration = sourceFrameDuration.seconds
        let currentSource = mapPreviewClockToSourceTime(CMTimeGetSeconds(player.currentTime()))
        let targetSource = forward
            ? min(currentSource + frameDuration, trimEnd)
            : max(currentSource - frameDuration, trimStart)
        let target = mapSourceTimeToPreviewClock(targetSource)
        player.seek(to: CMTime(seconds: target, preferredTimescale: 1_000_000_000),
                     toleranceBefore: .zero, toleranceAfter: .zero)
        needsDisplay = true
    }

    // MARK: - EffectsBandView integration

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        // More / fewer timeline rows fit after a resize.
        let h = effectsScrollViewHeight(forRowCount: currentEffectRowCount)
        if let c = effectsBandHeightConstraint, abs(c.constant - h) > 0.5 {
            c.constant = h
            playerBottomConstraint?.constant = -controlsH
            needsDisplay = true
        }
    }

    /// Compute the scroll view's visible height for a given row count,
    /// capped at `effectsVisibleRowCount` rows so the editor window doesn't
    /// grow beyond a sensible limit. Matches `EffectsBandView.intrinsicContentSize`
    /// including its top/bottom padding so resize handles stay visible.
    fileprivate func effectsScrollViewHeight(forRowCount rows: Int) -> CGFloat {
        let visible = max(1, min(effectsVisibleRowCount, rows))
        // (visible × stride − gap) + 2× vertical inset (matches EffectsBandView.verticalInset = 4)
        return CGFloat(visible) * effectsRowStride - 2 + 8
    }

    // MARK: - Text segment rasterization (cached)

    /// Build per-segment text snapshots used by the compositor. Each visible
    /// text segment is rasterized once at its rect's pixel size; subsequent
    /// builds reuse the cached image when the spec hasn't changed.
    ///
    /// Performance: rasterization is a CGContext draw with a single
    /// NSAttributedString — sub-millisecond at typical sizes. It runs only
    /// when the spec changes (text typed, color/size/bg edited, rect
    /// resized, or render-size changed). Per-frame rendering then composites
    /// the cached CIImage with one transform + one composite.
    fileprivate func buildTextSnapshots(renderSize: CGSize,
                                          naturalSize: CGSize,
                                          excluding excludedSegmentID: UUID? = nil)
        -> [EffectsCompositionInstruction.TextSnapshot]
    {
        guard renderSize.width > 0, renderSize.height > 0 else { return [] }
        var snapshots: [EffectsCompositionInstruction.TextSnapshot] = []
        snapshots.reserveCapacity(textSegments.count)

        // Track which segment ids we still need so we can drop stale entries
        // (e.g. a segment was deleted) at the end.
        var liveIDs = Set<UUID>()

        for seg in textSegments where seg.endTime > seg.startTime {
            if seg.id == excludedSegmentID {
                liveIDs.insert(seg.id)
                continue
            }
            // Pixel size of the segment's rect at the render resolution.
            // The rasterizer uses this to size the canvas; the per-frame
            // composite scales it 1:1 into render-space.
            let pxW = max(2, Int((seg.rect.width * renderSize.width).rounded()))
            let pxH = max(2, Int((seg.rect.height * renderSize.height).rounded()))
            let spec = VideoTextRasterizer.spec(for: seg,
                                                  pixelWidth: pxW,
                                                  pixelHeight: pxH,
                                                  renderHeight: Int(renderSize.height.rounded()))

            let cgImage: CGImage
            if let cached = textRasterCache[seg.id], cached.spec == spec {
                cgImage = cached.image
            } else {
                guard let rendered = VideoTextRasterizer.render(spec) else { continue }
                cgImage = rendered
                textRasterCache[seg.id] = (spec, rendered)
            }
            liveIDs.insert(seg.id)

            let ci = CIImage(cgImage: cgImage)
            snapshots.append(.init(id: seg.id,
                                    startTime: seg.startTime,
                                    endTime: seg.endTime,
                                    rect: seg.rect,
                                    fadeIn: seg.fadeIn,
                                    fadeOut: seg.fadeOut,
                                    image: ci))
        }

        // Evict cache entries for segments that no longer exist. Keeps the
        // dictionary's footprint bounded in long editing sessions.
        for key in Array(textRasterCache.keys) where !liveIDs.contains(key) {
            textRasterCache.removeValue(forKey: key)
        }

        return snapshots
    }

    // MARK: - Inline text editing

    /// Pop a borderless NSTextView at `viewRect` (in `hostView` coordinates)
    /// so the user can type the segment's contents in place. Player pauses
    /// while editing so the user isn't fighting against playback.
    fileprivate func beginInlineTextEdit(segmentID: UUID,
                                          atViewRect viewRect: NSRect,
                                          hostView: NSView) {
        guard let seg = textSegments.first(where: { $0.id == segmentID }) else { return }
        // Cancel any prior edit first.
        cancelInlineTextEdit(commit: false)

        // Pause playback during editing so AVPlayer doesn't drive the rect
        // out from under the text field.
        if let player = player, player.rate > 0 {
            player.pause()
            pausedForTextEdit = true
        }

        // Convert host-view coords to our (editor view's) coords so we can
        // place the field as a sibling of the player view.
        let frame = hostView.convert(viewRect, to: self)

        let displayedVideoHeight = frame.height / max(seg.rect.height, 0.0001)
        var editorFontSize = max(8, seg.fontSize * displayedVideoHeight / 1080)
        editorFontSize = min(editorFontSize, max(8, frame.height * 0.78))

        let font = VideoTextRasterizer.font(family: seg.fontFamily,
                                             size: editorFontSize,
                                             bold: seg.bold,
                                             italic: seg.italic)
        let textColor = nsColor(seg.textColor)
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = nsTextAlignment(for: seg.alignment)
        paragraph.lineBreakMode = .byTruncatingTail
        var typingAttributes: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: textColor,
            .paragraphStyle: paragraph,
        ]
        if seg.outlineEnabled, seg.outlineWidth > 0 {
            // Negative stroke width asks AppKit to draw both stroke and fill.
            // Match the rasterizer's outer-rim calculation at preview scale.
            let displayScale = displayedVideoHeight / 1080
            let displayOutline = max(0.5, seg.outlineWidth * displayScale)
            let strokePercent = (displayOutline * 2 / editorFontSize) * 100
            typingAttributes[.strokeColor] = nsColor(seg.outlineColor)
            typingAttributes[.strokeWidth] = -strokePercent
        }

        // Borderless scrollable text view sized to the segment rect. We use
        // NSTextView (not NSTextField) so multiline edits and large fonts
        // render predictably.
        let scroll = NSScrollView(frame: frame)
        scroll.hasVerticalScroller = false
        scroll.hasHorizontalScroller = false
        scroll.borderType = .noBorder
        scroll.drawsBackground = false
        scroll.wantsLayer = true
        scroll.layer?.backgroundColor = inlineTextBackgroundColor(for: seg)?.cgColor
        scroll.layer?.cornerRadius = inlineTextBackgroundRadius(for: seg, frame: frame)
        scroll.layer?.masksToBounds = true
        scroll.layer?.borderColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1.0).cgColor
        scroll.layer?.borderWidth = 1.5
        scroll.autoresizingMask = []
        scroll.contentView.drawsBackground = false

        let tv = InlineVideoTextView(frame: NSRect(origin: .zero, size: frame.size))
        tv.isRichText = false
        tv.allowsUndo = true
        tv.isVerticallyResizable = false
        tv.isHorizontallyResizable = false
        tv.textContainer?.lineFragmentPadding = 0
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.heightTracksTextView = false
        tv.horizontalTextInset = max(2, editorFontSize * 0.18)
        tv.drawsBackground = false
        tv.font = font
        tv.textColor = textColor
        tv.alignment = paragraph.alignment
        tv.defaultParagraphStyle = paragraph
        tv.typingAttributes = typingAttributes
        tv.insertionPointColor = NSColor(calibratedRed: 1.0, green: 0.78, blue: 0.30, alpha: 1.0)
        tv.string = seg.text
        if let storage = tv.textStorage, storage.length > 0 {
            storage.addAttributes(tv.typingAttributes, range: NSRange(location: 0, length: storage.length))
        }
        tv.centerTextVertically()
        tv.setSelectedRange(NSRange(location: (tv.string as NSString).length, length: 0))
        tv.delegate = self

        scroll.documentView = tv
        addSubview(scroll)

        inlineTextEditor = tv
        inlineTextEditorScrollView = scroll
        inlineTextEditingSegmentID = segmentID
        applyZoomTransformForCurrentTime()
        window?.makeFirstResponder(tv)
    }

    fileprivate func commitInlineTextEdit() {
        guard let id = inlineTextEditingSegmentID,
              let tv = inlineTextEditor,
              let seg = textSegments.first(where: { $0.id == id }) else {
            cancelInlineTextEdit(commit: false)
            return
        }
        let newText = tv.string
        let changed = newText != seg.text
        if changed {
            seg.text = newText
            // Drop the cache for this segment so the next composition
            // rebuild re-rasterizes with the new text.
            textRasterCache.removeValue(forKey: id)
            savedURL = nil
        }
        cancelInlineTextEdit(commit: false)
        if changed {
            effectsBand?.refreshAfterParentEdit()
        }
    }

    fileprivate func cancelInlineTextEdit(commit: Bool) {
        if commit {
            commitInlineTextEdit()
            return
        }
        let wasEditing = inlineTextEditingSegmentID != nil
        inlineTextEditor?.discardUndoHistory()
        inlineTextEditorScrollView?.removeFromSuperview()
        inlineTextEditor = nil
        inlineTextEditorScrollView = nil
        inlineTextEditingSegmentID = nil
        if pausedForTextEdit {
            pausedForTextEdit = false
        }
        window?.makeFirstResponder(self)
        if wasEditing {
            applyZoomTransformForCurrentTime()
        }
        needsDisplay = true
    }

    private func nsColor(_ rgba: VideoTextSegment.RGBA) -> NSColor {
        NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
    }

    private func nsTextAlignment(for alignment: VideoTextSegment.Alignment) -> NSTextAlignment {
        switch alignment {
        case .left: return .left
        case .center: return .center
        case .right: return .right
        }
    }

    private func inlineTextBackgroundColor(for seg: VideoTextSegment) -> NSColor? {
        switch seg.bgStyle {
        case .none:
            return nil
        case .solid, .rounded:
            return nsColor(seg.bgColor)
        }
    }

    private func inlineTextBackgroundRadius(for seg: VideoTextSegment, frame: NSRect) -> CGFloat {
        switch seg.bgStyle {
        case .none, .solid:
            return 0
        case .rounded:
            let shortSide = min(frame.width, frame.height)
            return min(shortSide * 0.25, frame.height * 0.30)
        }
    }

    // MARK: - Custom color picker

    /// Open NSColorPanel and bind it to the given segment's text, background,
    /// or outline color field. The panel stays modal-less so the user can keep
    /// editing other things; we observe `colorDidChange` notifications
    /// while it's relevant and unbind on close.
    fileprivate func presentTextColorPicker(segmentID: UUID, isBackground: Bool) {
        presentTextColorPicker(segmentID: segmentID, target: isBackground ? .background : .text)
    }

    fileprivate func presentTextColorPicker(segmentID: UUID, target: TextColorPickTarget) {
        guard let seg = textSegments.first(where: { $0.id == segmentID }) else { return }
        textColorPickerSegmentID = segmentID
        textColorPickerTarget = target
        let panel = NSColorPanel.shared
        panel.showsAlpha = true
        let rgba: VideoTextSegment.RGBA
        switch target {
        case .text: rgba = seg.textColor
        case .background: rgba = seg.bgColor
        case .outline: rgba = seg.outlineColor
        }
        panel.color = NSColor(srgbRed: rgba.r, green: rgba.g, blue: rgba.b, alpha: rgba.a)
        // Hook up the action target. Reuse a single observer per editor.
        panel.setTarget(self)
        panel.setAction(#selector(textColorPanelDidChange(_:)))
        panel.makeKeyAndOrderFront(nil)
    }

    @objc fileprivate func textColorPanelDidChange(_ sender: NSColorPanel) {
        guard let id = textColorPickerSegmentID,
              let seg = textSegments.first(where: { $0.id == id }) else { return }
        let c = sender.color.usingColorSpace(.sRGB) ?? sender.color
        let rgba = VideoTextSegment.RGBA(
            r: Double(c.redComponent),
            g: Double(c.greenComponent),
            b: Double(c.blueComponent),
            a: Double(c.alphaComponent))
        switch textColorPickerTarget {
        case .text: seg.textColor = rgba
        case .background: seg.bgColor = rgba
        case .outline: seg.outlineColor = rgba
        }
        seg.rememberStyle()
        textRasterCache.removeValue(forKey: id)
        savedURL = nil
        applyZoomTransformForCurrentTime()
        forcePreviewRedisplayIfPaused()
        effectsBand?.refreshAfterParentEdit()
        // Keep the bottom panel's swatches in sync with live color edits.
        if seg.id == selectedTextSegmentID, let selected = selectedTextSegment {
            textOptionsPanel?.configure(with: selected)
        }
    }
}

extension VideoEditorView: EffectsBandViewDelegate {
    func effectsBandDidMutate(_ view: EffectsBandView) {
        savedURL = nil
        applyZoomTransformForCurrentTime()
        // Context-menu style edits happen outside the bottom inspector. Keep
        // its controls in sync and force an exact paused-frame redraw so the
        // new appearance is immediately visible without nudging playback.
        if let selected = selectedTextSegment {
            textOptionsPanel?.configure(with: selected)
            forcePreviewRedisplayIfPaused()
        }
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, didSelectSegment segmentID: UUID?) {
        // Show the bottom text-options panel when a text segment is selected.
        if let id = segmentID, textSegments.contains(where: { $0.id == id }) {
            selectedTextSegmentID = id
        } else {
            selectedTextSegmentID = nil
        }
        // Suspend zoom in the preview while positioning content that the
        // zoom would visually displace relative to the selection overlay.
        let shouldSuspend: Bool = {
            guard let id = segmentID else { return false }
            return textSegments.contains(where: { $0.id == id })
                || censorSegments.contains(where: { $0.id == id })
        }()
        if previewSuspendsZoom != shouldSuspend {
            previewSuspendsZoom = shouldSuspend
            applyZoomTransformForCurrentTime()
            forcePreviewRedisplayIfPaused()
        }
        updateTextOptionsPanelVisibility()
        updateEffectsOverlay()
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, didChangeRowCount rowCount: Int) {
        currentEffectRowCount = rowCount
        let newScrollH = effectsScrollViewHeight(forRowCount: rowCount)
        effectsBandHeightConstraint?.animator().constant = newScrollH
        // Player view also shrinks so the whole controls band (including the
        // trim timeline) has room to grow upward.
        playerBottomConstraint?.animator().constant = -controlsH
        needsDisplay = true
    }

    func effectsBand(_ view: EffectsBandView, showStatus message: String, isError: Bool) {
        showStatus(message, isError: isError)
    }

    func effectsBandDidRequestTextEdit(_ view: EffectsBandView, segmentID: UUID) {
        // Reposition the overlay first so the rect we read is accurate for
        // the current selection state.
        updateEffectsOverlay()
        guard let overlay = effectsOverlay,
              let seg = textSegments.first(where: { $0.id == segmentID }) else { return }
        let viewRect = overlay.viewRectFromNormalized(seg.rect)
        beginInlineTextEdit(segmentID: segmentID, atViewRect: viewRect, hostView: overlay)
    }

    func effectsBandDidRequestTextColorPick(_ view: EffectsBandView,
                                              segmentID: UUID,
                                              isBackground: Bool) {
        presentTextColorPicker(segmentID: segmentID, isBackground: isBackground)
    }
}

extension VideoEditorView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        // Return commits, Escape cancels. Allow Shift+Return for newlines so
        // multi-line text labels stay possible without leaving the editor.
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            commitInlineTextEdit()
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            cancelInlineTextEdit(commit: false)
            return true
        }
        return false
    }

    func textDidChange(_ notification: Notification) {
        // Re-rasterize on every keystroke would burn CPU; instead, cache
        // invalidation happens at commit time. The user sees the new text
        // appear in the inline NSTextView itself while typing — the rasterized
        // overlay just stays at its previous content until commit.
    }

    func textDidEndEditing(_ notification: Notification) {
        // Lost focus → commit. Matches Finder rename behavior.
        commitInlineTextEdit()
    }
}

private final class InlineVideoTextView: ScopedUndoTextView {
    var horizontalTextInset: CGFloat = 0 {
        didSet { centerTextVertically() }
    }

    override func setFrameSize(_ newSize: NSSize) {
        super.setFrameSize(newSize)
        centerTextVertically()
    }

    override func didChangeText() {
        super.didChangeText()
        centerTextVertically()
    }

    func centerTextVertically() {
        guard let container = textContainer, let manager = layoutManager else {
            textContainerInset = NSSize(width: horizontalTextInset, height: 0)
            return
        }
        manager.ensureLayout(for: container)
        let usedHeight = manager.usedRect(for: container).height
        let verticalInset = max(0, floor((bounds.height - usedHeight) / 2))
        textContainerInset = NSSize(width: horizontalTextInset, height: verticalInset)
    }
}

private extension CMSampleBuffer {
    /// Returns a copy with a new presentation timestamp. Duration is preserved.
    func retimed(presentationTime: CMTime) -> CMSampleBuffer? {
        SampleBufferTiming.retimed(self, to: presentationTime)
    }
}

/// Gathers timeline thumbnails delivered out of order from AVFoundation's
/// queue, and reports the finished set exactly once.
private final class ThumbnailCollector {
    private let lock = NSLock()
    private var images: [NSImage]
    private var received = 0
    private var reported = false

    init(count: Int) {
        images = Array(repeating: NSImage(), count: max(0, count))
    }

    /// Records one result. Returns the full set on the final call, nil before.
    func record(_ image: NSImage?, at index: Int?) -> [NSImage]? {
        lock.lock()
        defer { lock.unlock() }
        if let image, let index, images.indices.contains(index) {
            images[index] = image
        }
        received += 1
        guard received >= images.count, !reported else { return nil }
        reported = true
        return images
    }
}
