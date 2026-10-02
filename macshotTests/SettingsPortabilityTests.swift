import XCTest

/// Exported settings files get shared, attached to bug reports and synced
/// between machines, and imported files may come from anywhere. Both directions
/// therefore go through one explicit allowlist of SimpleShot's own settings.
final class SettingsPortabilityTests: XCTestCase {

    // MARK: - The allowlist

    func testEverydaySettingsArePortable() {
        let settings = [
            "imageFormat", "imageQuality", "downscaleRetina", "filenameTemplate", "saveAction",
            "currentStrokeWidth", "lastUsedColor", "censorMode", "captureSnapMode",
            "hotkeyKeyCode", "hotkeyModifiers", "hotkeyDisabled_1",
            "editorCommandShortcuts.undo", "editorCommandShortcuts.redo",
        ]
        for key in settings {
            XCTAssertTrue(SettingsPortability.isPortable(key), "`\(key)` is a normal setting and should transfer")
        }
    }

    func testEveryHotkeySlotTransfers() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            for key in [slot.keyCodeKey, slot.modifiersKey, slot.disabledKey] {
                XCTAssertTrue(SettingsPortability.isPortable(key), "`\(key)` should transfer")
            }
        }
    }

    func testAnythingNotOnTheListIsRejected() {
        let foreign = [
            // Upstream macshot credentials and removed features.
            "imgbbAPIKey", "googleDriveRefreshToken", "s3SecretKey", "gdriveUserEmail", "imgbbUploads",
            "recordingFormat", "historySize", "beautifyEnabled", "enabledTools", "overlayToolShortcuts",
            // Injected by macOS.
            "NSWindowFrame main", "AppleLanguages", "METAL_ERROR_MODE", "Country", "_internalThing",
            // Anything else.
            "", "somethingNew",
        ]
        for key in foreign {
            XCTAssertFalse(SettingsPortability.isPortable(key), "`\(key)` must not transfer")
        }
    }

    func testLocalOnlyKeysAreNotPortable() {
        XCTAssertTrue(SettingsPortability.portableKeys.isDisjoint(with: SettingsPortability.localOnlyKeys))
        for key in ["saveDirectory", "saveDirectoryBookmark", "suppressMoveToApplications"] {
            XCTAssertTrue(SettingsPortability.localOnlyKeys.contains(key), "`\(key)` is machine-specific")
        }
    }

    /// A key the app reads or writes must be classified, or a new setting would
    /// silently stop transferring.
    func testEveryDefaultsKeyInCodeIsClassified() throws {
        let sourceRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("macshot")
        let pattern = try NSRegularExpression(
            pattern: #"\.(?:set|object|bool|integer|double|float|string|array|stringArray|dictionary|data|removeObject)\([^\n]*?forKey: *"([^"]+)""#)
        let known = SettingsPortability.portableKeys.union(SettingsPortability.localOnlyKeys)
        var found = Set<String>()
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            for match in pattern.matches(in: source, range: NSRange(source.startIndex..., in: source)) {
                guard let range = Range(match.range(at: 1), in: source) else { continue }
                found.insert(String(source[range]))
            }
        }
        XCTAssertGreaterThan(found.count, 20, "the source scan found almost nothing; is the pattern broken?")
        let unclassified = found.subtracting(known).sorted()
        XCTAssertEqual(unclassified, [], "add these to SettingsPortability.portableKeys or localOnlyKeys")
    }

    // MARK: - Import applies only the allowlist

    func testImportIgnoresUnknownKeysAndKeepsLocalOnes() throws {
        let local = "/tmp/simpleshot-test-folder"
        let snapshot = Dictionary(uniqueKeysWithValues:
            (SettingsPortability.portableKeys.union(["saveDirectory", "imgbbAPIKey"])).map {
                ($0, UserDefaults.standard.object(forKey: $0) as Any?)
            })
        try withDefaults(snapshot) {
            UserDefaults.standard.set(local, forKey: "saveDirectory")
            UserDefaults.standard.set(5, forKey: "captureDelaySeconds")
            let json = try JSONSerialization.data(withJSONObject: [
                "type": SettingsPortability.fileType,
                "schemaVersion": SettingsPortability.schemaVersion,
                "settings": [
                    "imageFormat": "jpeg",
                    "imgbbAPIKey": "injected",
                    "saveDirectory": "/elsewhere",
                ],
            ])
            let result = try SettingsPortability.importData(json)

            XCTAssertEqual(result.appliedCount, 1)
            XCTAssertEqual(result.skippedKeys, ["imgbbAPIKey", "saveDirectory"])
            XCTAssertEqual(UserDefaults.standard.string(forKey: "imageFormat"), "jpeg")
            XCTAssertNil(UserDefaults.standard.object(forKey: "imgbbAPIKey"), "an unknown key was written")
            XCTAssertEqual(UserDefaults.standard.string(forKey: "saveDirectory"), local, "the save folder must be kept")
            XCTAssertNil(UserDefaults.standard.object(forKey: "captureDelaySeconds"),
                         "a portable setting absent from the file is reset (replace semantics)")
        }
    }

    // MARK: - Import validation

    func testImportRejectsNonJSON() {
        XCTAssertThrowsError(try SettingsPortability.importData(Data("not json".utf8))) { error in
            XCTAssertTrue(error is SettingsPortability.ImportError, "got \(error)")
        }
    }

    func testImportRejectsAFileFromADifferentApp() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": "some-other-app-settings",
            "schemaVersion": 1,
            "settings": ["imageFormat": "png"],
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json))
    }

    func testImportRejectsANewerSchema() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion + 1,
            "settings": ["imageFormat": "png"],
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json),
                             "a file from a newer macshot must be refused, not half-applied")
    }

    func testImportRejectsAFileWithNoSettings() throws {
        let json = try JSONSerialization.data(withJSONObject: [
            "type": SettingsPortability.fileType,
            "schemaVersion": SettingsPortability.schemaVersion,
        ])
        XCTAssertThrowsError(try SettingsPortability.importData(json))
    }

    func testImportErrorsAllDescribeThemselves() {
        let errors: [SettingsPortability.ImportError] = [
            .notJSON, .wrongFileType, .newerSchema(found: 9), .missingSettings,
        ]
        for error in errors {
            XCTAssertFalse((error.errorDescription ?? "").isEmpty, "\(error) has no user-facing message")
        }
    }

    // MARK: - Export

    func testExportContainsOnlyPortableKeys() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        let settings = try XCTUnwrap(object?["settings"] as? [String: Any])
        for key in settings.keys {
            XCTAssertTrue(SettingsPortability.isPortable(key), "export leaked `\(key)`")
        }
    }

    func testExportIsTaggedSoItCanBeRecognized() throws {
        let result = try SettingsPortability.exportData()
        let object = try JSONSerialization.jsonObject(with: result.data) as? [String: Any]
        XCTAssertEqual(object?["type"] as? String, SettingsPortability.fileType)
        XCTAssertEqual(object?["schemaVersion"] as? Int, SettingsPortability.schemaVersion)
    }

    func testSuggestedFilenameIsAValidJSONName() {
        let name = SettingsPortability.suggestedExportFilename()
        XCTAssertTrue(name.hasSuffix(".json"))
        XCTAssertFalse(name.contains("/"))
        XCTAssertFalse(name.contains(":"))
    }

    func testExportLeavesOutUnknownAndLocalKeys() throws {
        try withDefaults([
            "imgbbAPIKey": "secret-value-1234",
            "saveDirectory": "/Users/someone/Private",
            "imageFormat": "png",
        ]) {
            let result = try SettingsPortability.exportData()
            let text = String(decoding: result.data, as: UTF8.self)
            XCTAssertFalse(text.contains("secret-value-1234"), "an unknown key reached the export file")
            XCTAssertFalse(text.contains("/Users/someone/Private"), "the save folder reached the export file")
            XCTAssertTrue(text.contains("imageFormat"))
        }
    }
}
