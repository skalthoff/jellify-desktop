import XCTest

@testable import Lyrebird

/// Coverage for `InfoPlist.xcstrings` — the string catalog that makes the
/// bundle's user-facing metadata localizable (#359). macOS reads a compiled
/// `<lang>.lproj/InfoPlist.strings` to localize `CFBundleDisplayName`,
/// `CFBundleName`, and `NSHumanReadableCopyright`; before this catalog those
/// keys were stuck at the Info.plist literals.
///
/// SwiftPM doesn't bundle the catalog (resource processing is disabled — see
/// Package.swift), so there's no `Bundle.main` to introspect headlessly. The
/// contract is therefore verified structurally, mirroring
/// `ServerUnreachableBannerTests`: the catalog source is parsed as JSON, and
/// the bundling step in `make-bundle.sh` is read via `#filePath`. A regression
/// that drops a key, blanks a value, or stops compiling the catalog into the
/// .app is caught here rather than in the field.
final class InfoPlistLocalizationTests: XCTestCase {

    /// The three keys macOS localizes from `InfoPlist.strings`. Each must carry
    /// the base (`en`) value that matches the corresponding Info.plist literal.
    private static let expected: [String: String] = [
        "CFBundleDisplayName": "Lyrebird",
        "CFBundleName": "Lyrebird",
        "NSHumanReadableCopyright": "© 2026 Lyrebird. GPL-3.0-only.",
    ]

    // MARK: - Catalog structure

    /// The catalog must parse as JSON, declare `en` as its source language, and
    /// expose exactly the keys macOS localizes — no more, no less.
    func testCatalogParsesAndDeclaresEnglishSource() throws {
        let json = try catalogJSON()
        XCTAssertEqual(json["sourceLanguage"] as? String, "en",
                       "InfoPlist.xcstrings must declare en as its source language")

        let strings = (json["strings"] as? [String: Any]) ?? [:]
        XCTAssertEqual(
            Set(strings.keys),
            Set(Self.expected.keys),
            "InfoPlist.xcstrings must contain exactly the localizable bundle-metadata keys"
        )
    }

    /// Every expected key resolves to a non-empty English `stringUnit` value
    /// that matches the Info.plist literal it localizes. A blank or drifted
    /// value would render an empty Dock name or wrong copyright in the field.
    func testEachKeyHasMatchingEnglishValue() throws {
        let strings = (try catalogJSON()["strings"] as? [String: Any]) ?? [:]
        for (key, expected) in Self.expected {
            guard let value = englishValue(strings, key) else {
                XCTFail("Missing or malformed catalog key: \(key)")
                continue
            }
            XCTAssertFalse(value.isEmpty, "\(key) must have a non-empty English value")
            XCTAssertEqual(value, expected,
                           "\(key) base value must match the Info.plist literal it localizes")
        }
    }

    /// The catalog's base values must agree with the checked-in Info.plist, so
    /// the localized `en` copy can never silently diverge from the unlocalized
    /// fallback baked into the bundle.
    func testBaseValuesMatchInfoPlist() throws {
        let plist = try infoPlist()
        let strings = (try catalogJSON()["strings"] as? [String: Any]) ?? [:]
        for key in Self.expected.keys {
            guard let plistValue = plist[key] as? String else {
                XCTFail("Info.plist is missing \(key)")
                continue
            }
            XCTAssertEqual(englishValue(strings, key), plistValue,
                           "Catalog en value for \(key) must match Info.plist")
        }
    }

    // MARK: - Bundling

    /// The bundling script must compile `InfoPlist.xcstrings`, otherwise the
    /// catalog never reaches the .app and macOS falls back to the Info.plist
    /// literals — the keys would be "localizable" in source but inert at
    /// runtime.
    func testMakeBundleCompilesInfoPlistCatalog() throws {
        let script = try makeBundleSource()
        XCTAssertTrue(script.contains("InfoPlist"),
                      "make-bundle.sh must reference InfoPlist so the catalog is compiled into the .app")
        XCTAssertTrue(script.contains("xcstringstool compile"),
                      "make-bundle.sh must compile catalogs via xcstringstool")
    }

    // MARK: - Helpers

    /// Parses the source `InfoPlist.xcstrings` and returns the top-level object.
    private func catalogJSON(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = resourcesRoot().appendingPathComponent("InfoPlist.xcstrings")
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("Could not read InfoPlist.xcstrings at \(url.path)", file: file, line: line)
            return [:]
        }
        return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    /// Parses the checked-in `Info.plist` template into a dictionary. The
    /// `$VERSION` / `$BUILD` placeholders are irrelevant to the keys under test.
    private func infoPlist(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let url = macosRoot().appendingPathComponent("Resources/Info.plist")
        guard let data = try? Data(contentsOf: url) else {
            XCTFail("Could not read Info.plist at \(url.path)", file: file, line: line)
            return [:]
        }
        let plist = try PropertyListSerialization.propertyList(from: data, format: nil)
        return (plist as? [String: Any]) ?? [:]
    }

    private func makeBundleSource(file: StaticString = #filePath, line: UInt = #line) throws -> String {
        let url = macosRoot().appendingPathComponent("Scripts/make-bundle.sh")
        guard let data = try? Data(contentsOf: url),
              let text = String(data: data, encoding: .utf8) else {
            XCTFail("Could not read make-bundle.sh at \(url.path)", file: file, line: line)
            return ""
        }
        return text
    }

    /// Digs the English `stringUnit` value out of an `.xcstrings` entry.
    private func englishValue(_ strings: [String: Any], _ key: String) -> String? {
        guard
            let entry = strings[key] as? [String: Any],
            let locs = entry["localizations"] as? [String: Any],
            let en = locs["en"] as? [String: Any],
            let unit = en["stringUnit"] as? [String: Any],
            let value = unit["value"] as? String
        else { return nil }
        return value
    }

    /// `macos/Sources/Lyrebird/Resources`, resolved relative to this test file
    /// via `#filePath` so the lookup is independent of the runner's working dir.
    private func resourcesRoot() -> URL {
        macosRoot().appendingPathComponent("Sources/Lyrebird/Resources")
    }

    /// `macos`, resolved relative to this test file via `#filePath`.
    private func macosRoot() -> URL {
        URL(fileURLWithPath: "\(#filePath)")
            .deletingLastPathComponent()          // Tests/LyrebirdTests
            .deletingLastPathComponent()          // Tests
            .deletingLastPathComponent()          // macos
    }
}
