import SwiftUI
import XCTest
@testable import Yui

/// The hold menu's column (YUI-78): bar above, preview, menu below, all in the
/// window and apart, wherever the message is and however tall it is.
@MainActor
final class HoldLayoutTests: XCTestCase {
    private let size = CGSize(width: 402, height: 700)
    private let bar = CGSize(width: 300, height: 70)
    private let menu = CGSize(width: 220, height: 192)

    private func layout(_ rect: CGRect, reacts: Bool = true, menu: CGSize? = nil) -> ReactionOverlay<EmptyView>.Layout {
        ReactionOverlay<EmptyView>.layout(rect: rect, size: size, bar: reacts ? bar : .zero, menu: menu ?? self.menu, reacts: reacts)
    }

    private func check(_ l: ReactionOverlay<EmptyView>.Layout, reacts: Bool = true, _ what: String) {
        let window = CGRect(origin: .zero, size: size)
        XCTAssertTrue(window.contains(l.menu), "\(what): menu \(l.menu)")
        XCTAssertLessThanOrEqual(l.preview.maxY, l.menu.minY, what)
        XCTAssertGreaterThanOrEqual(l.preview.minY, 0, what)
        if reacts {
            XCTAssertTrue(window.contains(l.bar), "\(what): bar \(l.bar)")
            XCTAssertLessThanOrEqual(l.bar.maxY, l.preview.minY, what)
            XCTAssertFalse(l.bar.intersects(l.menu), what)
        }
    }

    func testTallerThanTheScreenIsCut() {
        // The feedback: a long message that starts under the header and runs past the bottom.
        let l = layout(CGRect(x: 52, y: -140, width: 330, height: 1400))
        check(l, "tall")
        XCTAssertTrue(l.cut)
        XCTAssertEqual(l.preview.minY, 8 + 70 + 10)
        XCTAssertEqual(l.menu.maxY, size.height - 8, accuracy: 0.5)
    }

    func testShortStaysPut() {
        let r = CGRect(x: 52, y: 300, width: 200, height: 60)
        let l = layout(r)
        check(l, "short")
        XCTAssertFalse(l.cut)
        XCTAssertEqual(l.preview, r)
    }

    func testTopComesDownUnderTheBar() {
        let l = layout(CGRect(x: 52, y: 4, width: 200, height: 60))
        check(l, "top")
        XCTAssertFalse(l.cut)
        XCTAssertEqual(l.preview.minY, 88)
    }

    func testBottomLiftsForTheMenu() {
        let l = layout(CGRect(x: 52, y: 620, width: 200, height: 60))
        check(l, "bottom")
        XCTAssertEqual(l.menu.maxY, size.height - 8, accuracy: 0.5)
    }

    func testRemoveRowAndBigTypeStillFit() {
        for h in [240.0, 300, 380] {
            let l = layout(CGRect(x: 52, y: 200, width: 330, height: 500), menu: CGSize(width: 220, height: h))
            check(l, "menu \(h)")
            XCTAssertTrue(l.cut)
        }
    }

    func testOwnMessageHasNoBarAndHugsTheRight() {
        let l = layout(CGRect(x: 250, y: -20, width: 140, height: 900), reacts: false)
        check(l, reacts: false, "mine")
        XCTAssertEqual(l.preview.minY, 8)
        XCTAssertEqual(l.menu.maxX, size.width - 8, accuracy: 0.5)
    }
}
