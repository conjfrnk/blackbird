import XCTest
import AppKit
@testable import Blackbird

/// Blind behaviour tests for `AppDelegate.startingDirectory(forOpening:)`
/// (the Finder "Open with Blackbird" / drag-onto-Dock path), written from
/// the spec without sight of the implementation.
///
/// Contract:
///   - file URL to an existing directory → that directory's standardized
///     path.
///   - file URL to an existing regular file → the file's parent directory.
///   - nonexistent path → nil.
///   - non-file URL (https) → nil.
///   - trailing slash + `..` segments are standardized away: the result
///     equals the plain form's result.
///
/// Fixtures live under the SYMLINK-RESOLVED temporary directory
/// (`/private/var/folders/…`) so "standardized" and "symlink-resolved"
/// paths coincide and the equality assertions are unambiguous.
///
/// Pre-flight: one temp dir + one ~5-byte file per test, removed in
/// `tearDown`. No windows, no PTY. < 10 ms.
@MainActor
final class OpenAtFolderBlindTests: XCTestCase {

    private var fixtureDir: URL!

    override func setUpWithError() throws {
        try super.setUpWithError()
        let base = FileManager.default.temporaryDirectory.resolvingSymlinksInPath()
        fixtureDir = base
            .appendingPathComponent("bb-open-at-folder-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: fixtureDir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        if let fixtureDir {
            try? FileManager.default.removeItem(at: fixtureDir)
        }
        try super.tearDownWithError()
    }

    private func makeRegularFile(named name: String) throws -> URL {
        let file = fixtureDir.appendingPathComponent(name, isDirectory: false)
        try Data("hello".utf8).write(to: file)
        return file
    }

    // MARK: - Directory

    func test_existingDirectory_returnsItsStandardizedPath() {
        let result = AppDelegate.startingDirectory(forOpening: fixtureDir)
        XCTAssertEqual(result, fixtureDir.standardizedFileURL.path)
    }

    func test_existingDirectory_resultIsADirectory() throws {
        let result = try XCTUnwrap(AppDelegate.startingDirectory(forOpening: fixtureDir))
        var isDir: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: result, isDirectory: &isDir))
        XCTAssertTrue(isDir.boolValue, "result must point at a directory")
    }

    // MARK: - Regular file

    func test_existingRegularFile_returnsParentDirectory() throws {
        let file = try makeRegularFile(named: "notes.txt")
        let result = AppDelegate.startingDirectory(forOpening: file)
        XCTAssertEqual(result, fixtureDir.standardizedFileURL.path,
                       "a regular file must open at its parent directory")
    }

    func test_regularFileInNestedDirectory_returnsImmediateParent() throws {
        let nested = fixtureDir.appendingPathComponent("a/b", isDirectory: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        let file = nested.appendingPathComponent("script.sh")
        try Data("#!/bin/sh\n".utf8).write(to: file)

        let result = AppDelegate.startingDirectory(forOpening: file)
        XCTAssertEqual(result, nested.standardizedFileURL.path,
                       "the IMMEDIATE parent is the starting directory, not an ancestor")
    }

    // MARK: - Rejections

    func test_nonexistentPath_returnsNil() {
        let missing = fixtureDir.appendingPathComponent("does-not-exist-\(UUID().uuidString)")
        XCTAssertNil(AppDelegate.startingDirectory(forOpening: missing))
    }

    func test_nonexistentFileUnderExistingDirectory_returnsNil() {
        // The parent exists but the leaf doesn't — must not silently fall
        // back to the parent.
        let missing = fixtureDir.appendingPathComponent("ghost.txt", isDirectory: false)
        XCTAssertNil(AppDelegate.startingDirectory(forOpening: missing))
    }

    func test_nonFileURL_returnsNil() throws {
        let https = try XCTUnwrap(URL(string: "https://example.com"))
        XCTAssertNil(AppDelegate.startingDirectory(forOpening: https))
    }

    func test_nonFileURLWithPathLikeComponent_returnsNil() throws {
        // A remote URL whose path happens to match a real local directory
        // must still be refused — scheme, not path, decides.
        let sneaky = try XCTUnwrap(URL(string: "https://example.com" + fixtureDir.path))
        XCTAssertNil(AppDelegate.startingDirectory(forOpening: sneaky))
    }

    // MARK: - Standardization

    func test_trailingSlashAndDotDot_areStandardized() throws {
        let plain = try XCTUnwrap(AppDelegate.startingDirectory(forOpening: fixtureDir))

        let leaf = fixtureDir.lastPathComponent
        // "<parent>/<leaf>/../<leaf>/" — same directory, messy spelling.
        let messyPath = fixtureDir.deletingLastPathComponent().path
            + "/" + leaf + "/../" + leaf + "/"
        let messy = URL(fileURLWithPath: messyPath)
        let result = try XCTUnwrap(AppDelegate.startingDirectory(forOpening: messy))

        XCTAssertEqual(result, plain,
                       "`..` and trailing-slash spellings must resolve to the plain form")
        XCTAssertFalse(result.hasSuffix("/"), "no trailing slash in the result")
        XCTAssertFalse(result.contains("/../"), "no `..` segments in the result")
        XCTAssertEqual(result, fixtureDir.standardizedFileURL.path)
    }

    func test_dotSegments_areStandardized() throws {
        let leaf = fixtureDir.lastPathComponent
        let dotted = URL(fileURLWithPath:
            fixtureDir.deletingLastPathComponent().path + "/./" + leaf + "/.")
        let result = AppDelegate.startingDirectory(forOpening: dotted)
        XCTAssertEqual(result, fixtureDir.standardizedFileURL.path)
    }
}
