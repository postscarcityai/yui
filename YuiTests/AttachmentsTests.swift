import UIKit
import XCTest
import YuiLines
@testable import Yui

/// Photos from the composer (TestFlight feedback ABEd9FQg0MUy5hNiDKEy13Q): how a
/// message with photos is written as a row, and read back on reopen.
@MainActor
final class AttachmentsTests: XCTestCase {
    static let user = "0f8fad5b-d9cb-469f-a165-70867728950e"
    static let agent = "7c9e6679-7425-40de-944b-e07fc1f90ae7"
    static let path = "\(user)/\(agent)/user/1b4e28ba-2fa1-11d2-883f-0016d3cca427.jpg"

    func testBodyIsTheWordsOrAStandIn() {
        XCTAssertEqual(Attachments.body(text: "  my lunch \n", photos: 1), "my lunch")
        XCTAssertEqual(Attachments.body(text: "", photos: 1), "Photo")
        XCTAssertEqual(Attachments.body(text: " ", photos: 3), "3 photos")
        XCTAssertEqual(Attachments.body(text: "hi", photos: 0), "hi")
    }

    func testMetaCarriesThePaths() throws {
        XCTAssertNil(Attachments.meta(paths: []), "a plain text row gets no meta")
        let meta = try XCTUnwrap(Attachments.meta(paths: [Self.path]))
        // What the host plugin's json.loads sees (the encoder writes "/" as "\/", same value).
        let parsed = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(meta)) as? [String: [String]]
        XCTAssertEqual(parsed, ["photos": [Self.path]])
        XCTAssertEqual(Attachments.paths(meta), [Self.path])
    }

    /// The host plugin's USER_PATH (hermes-plugin/yui/media.py) must match what the app writes.
    func testPathsMatchTheHostPattern() {
        XCTAssertTrue(Attachments.isUserPath(Self.path))
        XCTAssertFalse(Attachments.isUserPath("\(Self.user)/\(Self.agent)/agent/x.jpg"), "agent media is not the person's")
        XCTAssertFalse(Attachments.isUserPath("https://evil.example/x.jpg"))
        let foreign: YLValue = .object(["photos": .array([.string("../../etc/passwd"), .string(Self.path), .number(3)])])
        XCTAssertEqual(Attachments.paths(foreign), [Self.path], "only well-formed user paths come back")
        XCTAssertEqual(Attachments.paths(nil), [])
        XCTAssertEqual(Attachments.paths(.object(["echo": .string("Photo")])), [])
    }

    func testStandInBodyDrawsAsPhotosOnly() {
        XCTAssertEqual(Attachments.caption(body: "Photo", photos: 1), "")
        XCTAssertEqual(Attachments.caption(body: "2 photos", photos: 2), "")
        XCTAssertEqual(Attachments.caption(body: "Photo", photos: 0), "Photo", "a person may just type Photo")
        XCTAssertEqual(Attachments.caption(body: "my lunch", photos: 1), "my lunch")
    }

    func testComposerPhotoIsShrunkToJPEG() throws {
        let big = UIGraphicsImageRenderer(size: CGSize(width: 4000, height: 3000), format: {
            let f = UIGraphicsImageRendererFormat.default(); f.scale = 1; return f
        }()).pngData { ctx in UIColor.systemTeal.setFill(); ctx.fill(CGRect(x: 0, y: 0, width: 4000, height: 3000)) }
        let p = try XCTUnwrap(ComposerPhoto(big))
        XCTAssertEqual(Array(p.jpeg.prefix(3)), [0xFF, 0xD8, 0xFF], "not a JPEG")
        XCTAssertEqual(max(p.preview.size.width, p.preview.size.height) * p.preview.scale, YuiMedia.maxSide)
        XCTAssertNil(ComposerPhoto(Data("not a picture".utf8)))
    }

    /// Reopened: a person's row with photos is one bubble holding them, stand-in hidden.
    func testReopenShowsThePhotos() {
        let store = ChatStore(messages: [])
        store.load([
            ThreadRow(id: "u1", sender: "user", body: "Photo", kind: "text",
                      meta: Attachments.meta(paths: [Self.path]), createdAt: ""),
            ThreadRow(id: "u2", sender: "user", body: "and my dinner", kind: "text",
                      meta: Attachments.meta(paths: [Self.path, Self.path]), createdAt: ""),
            ThreadRow(id: "u3", sender: "user", body: "just words", kind: "text", meta: .object([:]), createdAt: ""),
        ])
        XCTAssertEqual(store.messages.map(\.text), ["", "and my dinner", "just words"])
        XCTAssertEqual(store.messages.map(\.photos.count), [1, 2, 0])
        XCTAssertEqual(store.messages[0].photos, [.stored(Self.path)])
    }
}
