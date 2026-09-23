import Carbon
import Cocoa
import XCTest

/// Shortcut matching decides whether a keypress edits the capture or does
/// nothing. These tests drive the matcher with synthesized events, which is the
/// deterministic half — the ASCII fallback path reads the machine's live
/// keyboard layout and is exercised separately below.
final class KeyboardShortcutMatcherTests: XCTestCase {

    func testMatchesTheSameCharacterAndModifiers() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    func testCharacterComparisonIgnoresCase() {
        let event = TestKeyEvent.keyDown(characters: "Z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "Z", modifiers: [.command, .shift]))
    }

    func testModifiersMustMatchExactly() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]),
                       "⌘⇧Z must not trigger a plain ⌘Z binding — that's how redo would fire undo")
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command, .shift]))
    }

    func testIrrelevantModifiersAreIgnored() {
        let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z,
                                         modifiers: [.command, .capsLock, .function, .numericPad])
        XCTAssertTrue(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]),
                      "caps lock shouldn't break a shortcut")
    }

    func testModifierExtractionKeepsOnlyTheFourThatMatter() {
        let event = TestKeyEvent.keyDown(characters: "a", keyCode: TestKeyEvent.Code.a,
                                         modifiers: [.command, .option, .capsLock, .help])
        XCTAssertEqual(KeyboardShortcutMatcher.modifiers(in: event), [.command, .option])
    }

    func testADifferentCharacterDoesNotMatch() {
        let event = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "z", modifiers: [.command]))
    }

    func testSemanticCharacterFollowsTheLayoutsCharacterNotTheKeyCode() {
        // A QWERTZ keyboard reports "y" from the key that is Z on QWERTY. The
        // matcher must follow the printed character, so ⌘Z stays ⌘Z.
        let qwertz = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
        XCTAssertEqual(KeyboardShortcutMatcher.semanticCharacter(for: qwertz), "y")
        XCTAssertTrue(KeyboardShortcutMatcher.matches(qwertz, character: "y", modifiers: [.command]))
    }

    func testToolCharactersIncludeTheTypedCharacter() {
        let event = TestKeyEvent.keyDown(characters: "r", keyCode: 15)
        XCTAssertTrue(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    func testToolCharactersAreLowercased() {
        let event = TestKeyEvent.keyDown(characters: "R", keyCode: 15, modifiers: [.shift])
        XCTAssertTrue(KeyboardShortcutMatcher.toolCharacters(for: event).contains("r"))
    }

    func testNonLatinInputStillOffersAnASCIIFallback() {
        // Cyrillic "я" — the app's Latin defaults have to stay reachable, so the
        // matcher offers the ASCII-capable layout's character as well.
        let event = TestKeyEvent.keyDown(characters: "я", keyCode: TestKeyEvent.Code.z)
        let candidates = KeyboardShortcutMatcher.toolCharacters(for: event)
        XCTAssertTrue(candidates.contains("я"), "the typed character is always a candidate")
        XCTAssertGreaterThan(candidates.count, 1, "a non-Latin character needs an ASCII fallback too")
        XCTAssertTrue(candidates.contains { $0.unicodeScalars.first?.isASCII == true })
    }

    func testControlCharactersAreNotShortcuts() {
        for character in ["\n", "\r", "\t", "\u{1B}", "\0"] {
            let event = TestKeyEvent.keyDown(characters: character, keyCode: TestKeyEvent.Code.escape)
            XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: character, modifiers: []),
                           "\(character.debugDescription) must not resolve as a character shortcut")
        }
    }

    func testMultiCharacterInputIsNotAShortcut() {
        let event = TestKeyEvent.keyDown(characters: "ab", keyCode: TestKeyEvent.Code.a)
        XCTAssertFalse(KeyboardShortcutMatcher.matches(event, character: "ab", modifiers: []))
    }
}

/// Undo/redo chords are user-configurable, and a mis-resolved chord either does
/// nothing or does the opposite of what the user meant.
final class EditorCommandShortcutTests: XCTestCase {

    private let undoKey = "editorCommandShortcuts.undo"
    private let redoKey = "editorCommandShortcuts.redo"

    private func withCleanShortcuts(_ body: () throws -> Void) rethrows {
        try withDefaults([undoKey: nil, redoKey: nil], body)
    }

    // MARK: - Defaults

    func testDefaultUndoAndRedoChords() {
        withCleanShortcuts {
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])])
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .redo),
                           [.init(character: "z", modifiers: [.command, .shift]),
                            .init(character: "y", modifiers: [.command])])
        }
    }

    func testDefaultChordsResolveToTheirActions() {
        withCleanShortcuts {
            let undo = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            let redoShift = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command, .shift])
            let redoY = TestKeyEvent.keyDown(characters: "y", keyCode: TestKeyEvent.Code.y, modifiers: [.command])

            XCTAssertEqual(EditorCommandShortcutManager.action(for: undo), .undo)
            XCTAssertEqual(EditorCommandShortcutManager.action(for: redoShift), .redo)
            XCTAssertEqual(EditorCommandShortcutManager.action(for: redoY), .redo)
        }
    }

    func testAnUnboundChordResolvesToNothing() {
        withCleanShortcuts {
            let event = TestKeyEvent.keyDown(characters: "q", keyCode: 12, modifiers: [.command, .option])
            XCTAssertNil(EditorCommandShortcutManager.action(for: event))
        }
    }

    // MARK: - Shortcut normalization

    func testShortcutsNormalizeCaseAndIrrelevantModifiers() {
        let upper = EditorCommandShortcutManager.Shortcut(character: "Z", modifiers: [.command, .capsLock])
        let lower = EditorCommandShortcutManager.Shortcut(character: "z", modifiers: [.command])
        XCTAssertEqual(upper, lower, "the same chord typed with caps lock on must compare equal")
    }

    func testShortcutRoundTripsThroughItsStoredForm() throws {
        let shortcut = EditorCommandShortcutManager.Shortcut(character: "k", modifiers: [.command, .option])
        let decoded = try JSONDecoder().decode(
            EditorCommandShortcutManager.Shortcut.self,
            from: try JSONEncoder().encode(shortcut))
        XCTAssertEqual(decoded, shortcut)
        XCTAssertEqual(decoded.modifiers, [.command, .option])
    }

    // MARK: - Rebinding

    func testRebindingTakesTheChordFromTheOtherAction() {
        withCleanShortcuts {
            // Bind ⌘Z (undo's default) to redo.
            EditorCommandShortcutManager.setShortcut(.init(character: "z", modifiers: [.command]), for: .redo)

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            XCTAssertEqual(EditorCommandShortcutManager.action(for: event), .redo,
                           "a chord can only mean one thing")
            XCTAssertFalse(EditorCommandShortcutManager.shortcuts(for: .undo)
                .contains(.init(character: "z", modifiers: [.command])),
                           "undo must lose the chord it no longer owns")
        }
    }

    func testRebindingReplacesRatherThanAppends() {
        withCleanShortcuts {
            EditorCommandShortcutManager.setShortcut(.init(character: "u", modifiers: [.command]), for: .undo)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo).count, 1)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo).first?.character, "u")
        }
    }

    func testDisableRemovesTheBindingWithoutRestoringTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            XCTAssertTrue(EditorCommandShortcutManager.shortcuts(for: .undo).isEmpty,
                          "disabled must stay disabled, not silently fall back to ⌘Z")

            let event = TestKeyEvent.keyDown(characters: "z", keyCode: TestKeyEvent.Code.z, modifiers: [.command])
            XCTAssertNil(EditorCommandShortcutManager.action(for: event))
        }
    }

    func testResetBringsBackTheDefault() {
        withCleanShortcuts {
            EditorCommandShortcutManager.disable(.undo)
            EditorCommandShortcutManager.reset(.undo)
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])])
        }
    }

    func testCorruptStoredDataFallsBackToDefaults() {
        withDefaults([undoKey: Data("not json".utf8)]) {
            XCTAssertEqual(EditorCommandShortcutManager.shortcuts(for: .undo),
                           [.init(character: "z", modifiers: [.command])],
                           "a damaged preference must not leave the editor without undo")
        }
    }

    func testDisplayStringsAreHumanReadable() {
        withCleanShortcuts {
            let undo = EditorCommandShortcutManager.displayString(for: .undo)
            XCTAssertTrue(undo.contains("\u{2318}"), "expected ⌘ in \(undo)")
            XCTAssertTrue(undo.uppercased().contains("Z"))
        }
    }

    func testMenuItemGetsTheConfiguredChord() {
        withCleanShortcuts {
            let item = NSMenuItem()
            EditorCommandShortcutManager.applyPrimaryMenuShortcut(for: .undo, to: item)
            XCTAssertEqual(item.keyEquivalent.lowercased(), "z")
            XCTAssertTrue(item.keyEquivalentModifierMask.contains(.command))
        }
    }
}

/// Global hotkeys stay physical key-code bindings; only their display strings
/// are translated. These cover the parts that don't touch Carbon registration.
final class HotkeyManagerTests: XCTestCase {

    func testEverySlotHasDistinctDefaultsKeys() {
        var seen = Set<String>()
        for slot in HotkeyManager.HotkeySlot.allCases {
            for key in [slot.keyCodeKey, slot.modifiersKey, slot.disabledKey] {
                XCTAssertTrue(seen.insert(key).inserted, "`\(key)` is used by two hotkey slots, so they'd overwrite each other")
            }
        }
    }

    func testSavingAndReadingAHotkeyRoundTrips() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.saveHotkey(for: slot, keyCode: 12, modifiers: UInt32(cmdKey | shiftKey))
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, 12)
            XCTAssertEqual(read.modifiers, UInt32(cmdKey | shiftKey))
        }
    }

    func testAnUnsetHotkeyReportsItsDefault() {
        let slot = HotkeyManager.HotkeySlot.captureArea
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, slot.defaultKeyCode)
            XCTAssertEqual(read.modifiers, slot.defaultModifiers)
        }
    }

    func testDisablingAHotkeyReportsNoBinding() {
        let slot = HotkeyManager.HotkeySlot.captureFullScreen
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            let read = HotkeyManager.readHotkey(for: slot)
            XCTAssertEqual(read.keyCode, 0)
            XCTAssertEqual(read.modifiers, 0)
            XCTAssertEqual(HotkeyManager.displayString(for: slot), L("None"))
        }
    }

    func testSavingAfterDisablingReEnables() {
        let slot = HotkeyManager.HotkeySlot.captureFullScreen
        withDefaults([slot.keyCodeKey: nil, slot.modifiersKey: nil, slot.disabledKey: nil]) {
            HotkeyManager.disableHotkey(for: slot)
            HotkeyManager.saveHotkey(for: slot, keyCode: 15, modifiers: UInt32(cmdKey))
            XCTAssertEqual(HotkeyManager.readHotkey(for: slot).keyCode, 15)
        }
    }

    func testModifierSymbolsAreInTheOrderMacOSShowsThem() {
        let all = HotkeyManager.modifierString(from: UInt32(controlKey | optionKey | shiftKey | cmdKey))
        XCTAssertEqual(all, "\u{2303}\u{2325}\u{21E7}\u{2318}", "macOS renders modifiers as ⌃⌥⇧⌘")
        XCTAssertEqual(HotkeyManager.modifierString(from: 0), "")
    }

    func testFunctionKeysAreRecognized() {
        XCTAssertTrue(HotkeyManager.isFunctionKey(UInt32(kVK_F1)))
        XCTAssertTrue(HotkeyManager.isFunctionKey(UInt32(kVK_F20)))
        XCTAssertFalse(HotkeyManager.isFunctionKey(UInt32(kVK_ANSI_A)),
                       "a plain letter needs a modifier, so it mustn't be treated like F1")
    }

    func testSpecialKeysGetStableNames() {
        XCTAssertEqual(HotkeyManager.keyString(from: UInt32(kVK_Space)), "Space")
        XCTAssertEqual(HotkeyManager.keyString(from: UInt32(kVK_F5)), "F5")
    }

    func testEverySlotHasALabelAndADisplayString() {
        for slot in HotkeyManager.HotkeySlot.allCases {
            XCTAssertFalse(slot.label.isEmpty, "slot \(slot) has no label")
            XCTAssertFalse(HotkeyManager.displayString(for: slot).isEmpty)
        }
    }
}
