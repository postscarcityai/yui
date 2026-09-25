import Foundation
import Testing
@testable import YuiLines

// A war room need is one block (t_f493137c): the context rides on the choose
// as tag=, title= and body=, with the question and options unchanged.

@Test("choose keeps tag, title and body beside its question and options")
func chooseContext() {
    let line = #"choose@need-t_8b02462c "How did it go?" "Works"|"Phone only"|"Not yet"|"You decide" +other tag=INT-7 title="Claude adapter" body="In claude.ai add Yui as a custom connector, then ask Claude for a 5 minute timer.""#
    let nodes = YuiLines.parse(line)
    #expect(nodes.count == 1)
    let p = nodes.first?.props
    #expect(p?["q"]?.string == "How did it go?")
    #expect(p?["options"]?.array?.compactMap(\.string) == ["Works", "Phone only", "Not yet", "You decide"])
    #expect(p?["tag"]?.string == "INT-7")
    #expect(p?["title"]?.string == "Claude adapter")
    #expect(p?["body"]?.string == "In claude.ai add Yui as a custom connector, then ask Claude for a 5 minute timer.")
    #expect(p?["other"]?.bool == true)
}
