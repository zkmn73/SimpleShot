import Foundation

/// Import / export of app settings.
///
/// Preferences live in `UserDefaults.standard`, inside the sandbox container plist — hard to
/// find and copy by hand. This service serializes the *portable* subset of them to a JSON
/// file the user can move to a clean install or another machine.
///
/// ## What is portable
/// Only the keys in `portableKeys`, an explicit allowlist of SimpleShot's own remembered
/// choices. Everything else in the domain is ignored on export *and* on import: keys macOS
/// injects (`NS*`, `Apple*`, `METAL_*`, …), keys left behind by older builds or by upstream
/// macshot, and anything a hand-edited file adds. Machine-specific keys the app does write are
/// listed in `localOnlyKeys`; `SettingsPortabilityTests` fails if a key used in code is in
/// neither set, so a new setting can't be forgotten.
enum SettingsPortability {

    // MARK: - Envelope

    static let fileType = "macshot-settings"
    static let schemaVersion = 1

    /// A dated, human-friendly default filename, e.g. `simpleshot-settings-2026-07-08.json`.
    static func suggestedExportFilename() -> String {
        let fmt = DateFormatter()
        fmt.dateFormat = "yyyy-MM-dd"
        return "simpleshot-settings-\(fmt.string(from: Date())).json"
    }

    /// Size cap for a single Data blob (2 MB). Larger blobs are skipped on export and
    /// reported, never silently dropped.
    static let maxDataValueBytes = 2 * 1024 * 1024

    // MARK: - Keys

    /// The settings that transfer between machines.
    static let portableKeys: Set<String> = {
        var keys: Set<String> = [
            // Output
            "imageFormat", "imageQuality", "downscaleRetina",
            FilenameFormatter.userDefaultsKey, SaveActionPreference.userDefaultsKey,
            "quickCaptureMode", "quickCaptureOpenEditor", "closeEditorAfterCopy",
            // Capture
            "captureDelaySeconds", "captureSnapMode", "hideCaptureInstructions",
            "scrollAutoScrollEnabled", "scrollAutoScrollSpeed", "scrollFrozenDetection", "scrollMaxHeight",
            "keepAspectRatio", "keepAspectRatioValue", "resolutionUnitIsPoints",
            // App
            "launchAtLogin", "hideMenuBarIcon", "urlSchemeEnabled",
            // Annotation styles
            "currentStrokeWidth", "numberStrokeWidth", "markerStrokeWidth",
            "lastUsedColor", "lastUsedColorOpacity", "customColors",
            "currentLineStyle", "currentArrowStyle", "arrowReversed",
            "currentRectCornerRadius", "currentRectFillStyle",
            "textFontFamily", "textFontSize", "textBgEnabled", "textBgColor",
            "textOutlineEnabled", "textOutlineColor", "textGlyphStrokeEnabled", "textGlyphStrokeColor",
            "annotationOutlineEnabled", "annotationOutlineColor",
            "numberFormat", "numberStartAt",
            "censorMode",
            "pencilSmoothMode", "pencilPressureEnabled", "smartMarkerEnabled", "stampSize",
        ]
        for slot in HotkeyManager.HotkeySlot.allCases {
            keys.formUnion([slot.keyCodeKey, slot.modifiersKey, slot.disabledKey])
        }
        for action in EditorCommandShortcutManager.Action.allCases {
            keys.insert(EditorCommandShortcutManager.defaultsKey(for: action))
        }
        return keys
    }()

    /// Keys the app writes that deliberately stay on this machine.
    static let localOnlyKeys: Set<String> = [
        // Save folder: a path plus a security-scoped bookmark, only valid here.
        "saveDirectory", "saveDirectoryBookmark",
        // Last pre-selection size: tied to this machine's displays.
        "preSelectionResolutionPresetKind", "preSelectionResolutionPresetAspect",
        "preSelectionResolutionPresetWidth", "preSelectionResolutionPresetHeight",
        // Per-install answer to the "Move to Applications" prompt.
        "suppressMoveToApplications",
        // Set at launch by main.swift, not a user choice.
        "NSViewUsesAutomaticLayerBackingStores",
        // Options of the retired Loupe / Measure / Highlight tools (no toolbar entry point).
        "loupeSize", "loupeMagnification", "loupeOutlineEnabled", "loupeOutlineColor",
        "measureInPoints", "measureClampToSelection",
        HighlightToolHandler.dimOpacityKey, HighlightToolHandler.dashedBorderKey,
    ]

    /// Whether a key is exported and accepted on import.
    static func isPortable(_ key: String) -> Bool {
        portableKeys.contains(key)
    }

    // MARK: - JSON value coding
    //
    // JSONSerialization handles Bool/Int/Double/String/Array/Dictionary directly. The only
    // UserDefaults type it can't represent is Data (archived NSColor, editor shortcuts), which
    // we wrap as a tagged base64 object so import can round-trip it exactly.

    private static let dataTag = "__macshotData__"

    /// Convert a UserDefaults value into something JSONSerialization accepts, or nil to skip.
    private static func jsonEncode(_ value: Any, key: String, skipped: inout [String]) -> Any? {
        if let d = value as? Data {
            if d.count > maxDataValueBytes { skipped.append(key); return nil }
            return [dataTag: d.base64EncodedString()]
        }
        // Recurse into containers so nested Data (rare) is handled and non-JSON leaves are dropped.
        if let arr = value as? [Any] {
            return arr.compactMap { jsonEncode($0, key: key, skipped: &skipped) }
        }
        if let dict = value as? [String: Any] {
            var out: [String: Any] = [:]
            for (k, v) in dict {
                if let e = jsonEncode(v, key: key, skipped: &skipped) { out[k] = e }
            }
            return out
        }
        // Plain JSON scalars pass through; anything else (dates, etc.) is dropped.
        if JSONSerialization.isValidJSONObject([value]) { return value }
        return nil
    }

    /// Reverse of `jsonEncode`: turn tagged base64 objects back into Data.
    private static func jsonDecode(_ value: Any) -> Any {
        if let dict = value as? [String: Any] {
            if let b64 = dict[dataTag] as? String, let d = Data(base64Encoded: b64) {
                return d
            }
            return dict.mapValues { jsonDecode($0) }
        }
        if let arr = value as? [Any] {
            return arr.map { jsonDecode($0) }
        }
        return value
    }

    // MARK: - Export

    struct ExportResult {
        let data: Data
        /// Data values skipped because they exceeded `maxDataValueBytes`.
        let skippedLargeKeys: [String]
        let keyCount: Int
    }

    static func exportData() throws -> ExportResult {
        let all = UserDefaults.standard.dictionaryRepresentation()
        var settings: [String: Any] = [:]
        var skipped: [String] = []

        for (key, value) in all where portableKeys.contains(key) {
            if let encoded = jsonEncode(value, key: key, skipped: &skipped) {
                settings[key] = encoded
            }
        }

        let envelope: [String: Any] = [
            "type": fileType,
            "schemaVersion": schemaVersion,
            "appVersion": Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "?",
            "exportedAt": ISO8601DateFormatter().string(from: Date()),
            "settings": settings,
        ]

        let data = try JSONSerialization.data(withJSONObject: envelope, options: [.prettyPrinted, .sortedKeys])
        return ExportResult(data: data, skippedLargeKeys: skipped, keyCount: settings.count)
    }

    // MARK: - Import

    enum ImportError: LocalizedError {
        case notJSON
        case wrongFileType
        case newerSchema(found: Int)
        case missingSettings

        var errorDescription: String? {
            switch self {
            case .notJSON, .wrongFileType:
                return L("This file is not a valid SimpleShot settings file.")
            case .newerSchema:
                return L("This settings file was made by a newer version of SimpleShot. Please update SimpleShot first.")
            case .missingSettings:
                return L("This settings file contains no settings.")
            }
        }
    }

    struct ImportResult {
        let appliedCount: Int
        /// Keys in the file that were ignored because they are not in `portableKeys`.
        let skippedKeys: [String]
        let sourceAppVersion: String?
    }

    /// Validate and apply an imported settings file using **replace-portable** semantics:
    /// clear every portable key in defaults, then write the file's portable keys. Every other
    /// key on this machine is left untouched.
    @discardableResult
    static func importData(_ data: Data) throws -> ImportResult {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw ImportError.notJSON
        }
        guard (obj["type"] as? String) == fileType else { throw ImportError.wrongFileType }
        let foundSchema = (obj["schemaVersion"] as? Int) ?? 0
        if foundSchema > schemaVersion { throw ImportError.newerSchema(found: foundSchema) }
        guard let settings = obj["settings"] as? [String: Any] else { throw ImportError.missingSettings }

        // Decode everything before mutating defaults, so a bad file can't half-apply. Only
        // allowlisted keys are accepted: a hand-edited or cross-version file can't write anything
        // else into defaults.
        var toWrite: [String: Any] = [:]
        var skipped: [String] = []
        for (key, jsonValue) in settings {
            guard isPortable(key) else { skipped.append(key); continue }
            toWrite[key] = jsonDecode(jsonValue)
        }

        let defaults = UserDefaults.standard
        for key in portableKeys {
            defaults.removeObject(forKey: key)
        }
        for (key, value) in toWrite {
            defaults.set(value, forKey: key)
        }

        return ImportResult(
            appliedCount: toWrite.count,
            skippedKeys: skipped.sorted(),
            sourceAppVersion: obj["appVersion"] as? String
        )
    }
}
