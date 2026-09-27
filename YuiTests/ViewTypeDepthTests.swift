import XCTest
import SwiftUI
@testable import Yui

/// Build 229 crashed on launch after Add agent, cancel (feedback AGjOqLXN): the
/// runtime decodes a view's whole generic type by name, one stack frame set per
/// level, and the chat's type nested so deep it ran off the phone's 1 MB main
/// stack inside ChatView.inputRow. These keep the chat's type shallow.
final class ViewTypeDepthTests: XCTestCase {
    /// How deep `<` nests in a type's full name.
    static func depth(_ type: Any.Type) -> Int {
        var d = 0, most = 0
        for ch in String(reflecting: type) {
            if ch == "<" { d += 1; most = max(most, d) } else if ch == ">" { d -= 1 }
        }
        return most
    }

    /// Build 229's chat body nested 129 deep; erased at the layers, the thread and the
    /// input bar it is 47 (the body's own modifiers), and none of the erased parts pass 44.
    static let budget = 60

    func testChatTypeStaysShallow() {
        let d = Self.depth(ChatView.Body.self)
        print("ChatView.Body depth \(d)")
        XCTAssertLessThanOrEqual(d, Self.budget, "the chat's view type nests too deep for the phone's main stack")
    }
}
