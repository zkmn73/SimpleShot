import Cocoa
import XCTest

/// SimpleShot ships English only. Nothing in the build checks `L("…")` keys
/// against `en.lproj/Localizable.strings`, so a new key that's never added
/// there silently shows the raw key in the UI.
///
/// These read the repository sources directly (via `#filePath`) rather than the
/// test bundle, because the keys live in Swift code, not in resources.
final class LocalizationTests: XCTestCase {

    // MARK: - Repository layout

    private static let repoRoot: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // macshotTests
        .deletingLastPathComponent()  // repo root

    private static let sourceRoot = repoRoot.appendingPathComponent("macshot")

    private static let stringsFile = sourceRoot.appendingPathComponent("en.lproj/Localizable.strings")

    /// The parsed English strings table.
    private static let table: [String: String] = {
        (NSDictionary(contentsOf: stringsFile) as? [String: String]) ?? [:]
    }()

    /// Every `L("literal")` key used in the app sources.
    private static let keysUsedInCode: Set<String> = {
        var keys = Set<String>()
        let pattern = try! NSRegularExpression(pattern: #"\bL\("((?:[^"\\]|\\.)*)"\)"#)
        let enumerator = FileManager.default.enumerator(at: sourceRoot, includingPropertiesForKeys: nil)
        while let url = enumerator?.nextObject() as? URL {
            guard url.pathExtension == "swift",
                  let source = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let range = NSRange(source.startIndex..., in: source)
            for match in pattern.matches(in: source, range: range) {
                guard let keyRange = Range(match.range(at: 1), in: source) else { continue }
                keys.insert(unescape(String(source[keyRange])))
            }
        }
        return keys
    }()

    /// Swift source escapes (`\n`, `\"`) as the .strings file stores them.
    private static func unescape(_ literal: String) -> String {
        literal
            .replacingOccurrences(of: "\\n", with: "\n")
            .replacingOccurrences(of: "\\t", with: "\t")
            .replacingOccurrences(of: "\\\"", with: "\"")
            .replacingOccurrences(of: "\\\\", with: "\\")
    }

    // MARK: - Sanity of the fixture itself

    func testTheTestCanSeeTheTranslations() {
        XCTAssertFalse(Self.table.isEmpty, "expected en.lproj/Localizable.strings at \(Self.stringsFile.path)")
        XCTAssertGreaterThan(Self.keysUsedInCode.count, 100, "the L(\"…\") scan found almost nothing — check the regex")
    }

    // MARK: - Coverage

    func testEveryKeyUsedInCodeExistsInEnglish() {
        let missing = Self.keysUsedInCode.filter { Self.table[$0] == nil }.sorted()
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) key(s) used in code are missing from en.lproj/Localizable.strings, \
            so they'd show as raw keys: \(missing.prefix(10).joined(separator: " | "))
            """)
    }

    func testNoTranslationIsEmpty() {
        let empty = Self.table.filter { $0.value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }.keys.sorted()
        XCTAssertTrue(empty.isEmpty, "an empty string shows as a blank label:\n" + empty.prefix(10).joined(separator: "\n"))
    }

    // MARK: - File hygiene

    func testLocalizableStringsFileParses() {
        XCTAssertNotNil(NSDictionary(contentsOf: Self.stringsFile) as? [String: String],
                        "en.lproj/Localizable.strings is malformed")
    }

    func testNoKeyIsDeclaredTwice() throws {
        // NSDictionary silently keeps the last value, so duplicates hide edits.
        let keyPattern = try NSRegularExpression(pattern: #"^\s*"((?:[^"\\]|\\.)*)"\s*="#, options: [.anchorsMatchLines])
        let text = try String(contentsOf: Self.stringsFile, encoding: .utf8)
        var seen = Set<String>()
        var duplicates: [String] = []
        let range = NSRange(text.startIndex..., in: text)
        for match in keyPattern.matches(in: text, range: range) {
            guard let keyRange = Range(match.range(at: 1), in: text) else { continue }
            let key = String(text[keyRange])
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        XCTAssertTrue(duplicates.isEmpty, "declares \(duplicates.prefix(5)) more than once")
    }
}
