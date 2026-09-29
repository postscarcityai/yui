import XCTest
import SwiftUI
@testable import Yui

/// The base type (YUI-211): a sleek sans, a nine-step scale, serif only when a look asks for it.
final class TypeScaleTests: XCTestCase {
    func testBaseIsTheSystemSansAtSemibold() {
        XCTAssertEqual(YuiTheme.yui.type.design, "default")
        XCTAssertEqual(YuiTheme.yui.type.weight, "semibold")
        XCTAssertEqual(YuiTheme.yui.strong, .semibold)
        XCTAssertEqual([YuiTheme.yui.type.display, YuiTheme.yui.type.title, YuiTheme.yui.type.body, YuiTheme.yui.type.caption], [34, 22, 17, 13])
    }

    func testTheScaleSizes() {
        XCTAssertEqual(YuiType.allCases.map(\.size), [34, 28, 22, 17, 17, 15, 15, 13, 12])
        XCTAssertLessThan(YuiType.display.tracking, 0, "tighter on display")
        XCTAssertGreaterThan(YuiType.footnote.tracking, YuiType.caption.tracking, "looser on the smallest sizes")
    }

    func testEverySizeInUseRidesATextStyleSoDynamicTypeApplies() {
        for size in [34.0, 28, 22, 21, 20, 17, 16, 15, 14, 13, 12, 11] {
            XCTAssertNotNil(YuiType.style(for: size), "\(size) is fixed")
        }
        XCTAssertNil(YuiType.style(for: 56), "a big numeral stays fixed")
    }

    func testNoAgentIsSeededWithSerif() {
        for name in ["luna", "akasha", "penny", "quill", "gouda", "urza", "arnold", "r0ss", "monk", "hank", "yui", "basil"] {
            let t = AgentLook.theme(nil, name: name, isYui: false)
            XCTAssertEqual(t.type.design, "default", "\(name) got \(t.type.design)")
            XCTAssertTrue(["semibold", "bold"].contains(t.type.weight), "\(name) weight \(t.type.weight)")
        }
    }

    func testSerifStaysALookOption() {
        XCTAssertEqual(AgentLook.theme(AgentLook(preset: "wizard"), name: "x", isYui: false).type.design, "serif")
        XCTAssertEqual(AgentLook.theme(AgentLook(font: "serif"), name: "x", isYui: false).type.design, "serif")
        XCTAssertEqual(AgentLook.theme(AgentLook(font: "rounded"), name: "x", isYui: false).type.design, "rounded")
        XCTAssertEqual(AgentLook.theme(AgentLook(font: "mono"), name: "x", isYui: false).type.design, "monospaced")
    }
}
