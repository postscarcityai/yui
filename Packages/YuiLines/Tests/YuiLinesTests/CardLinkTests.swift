import Foundation
import Testing
@testable import YuiLines

// A test build's Install card carries a long signed link: a fragment, an
// encoded manifest url, `&`, `=` and a JWT (TestFlight feedback
// AMbvlwiMPj49qT1jeKlZID4, build 61.1). `url=` must come through whole, or the
// card's button is not a link and the tap goes to the agent instead of Safari.

let fakeToken = "eyJraWQiOiJ0ZXN0IiwiYWxnIjoiSFMyNTYifQ.eyJ1cmwiOiJ5dWktYnVpbGRzLzYxLjEvbWFuaWZlc3QucGxpc3QifQ.c2lnbmF0dXJlLXRlc3Qtb25seQ"
let manifest = "https://ewzzaoperdpxqxkshynx.supabase.co/storage/v1/object/sign/yui-builds/61.1-60480ca53c23/manifest.plist?token=\(fakeToken)"
let encodedManifest = manifest.addingPercentEncoding(withAllowedCharacters: .alphanumerics.union(.init(charactersIn: "-._~")))!

let installLinks = [
    "https://www.yuigui.com/install.html#b=61.1&m=\(encodedManifest)",
    "itms-services://?action=download-manifest&url=\(encodedManifest)",
]

func cardURL(_ line: String) -> [String?] {
    let whole = YuiLines.parse(line).compactMap { $0.props?["url"]?.string }
    var s = YLStreamParser()
    var streamed: [YLNode] = []
    for ch in line.unicodeScalars { streamed += s.push(String(ch)) }
    streamed += s.flush()
    return [whole.first, streamed.compactMap { $0.props?["url"]?.string }.first]
}

@Test("card url= keeps a long encoded link whole", arguments: installLinks)
func cardLongEncodedURL(_ link: String) {
    #expect(link.count > 300)
    for line in [
        #"card "Yui 61.1" body="New build" cta="Install" url=\#(link)"#,
        #"card "Yui 61.1" body="New build" cta="Install" url="\#(link)""#,
        #"card "Yui 61.1" url=\#(link) cta=Install"#,
    ] {
        for got in cardURL(line) {
            #expect(got == link, "\(line)")
        }
        let nodes = YuiLines.parse(line)
        #expect(nodes.count == 1)
        #expect(nodes.first?.props?["cta"]?.string == "Install")
        // What CardPreset.link does with it: a URL with a scheme it opens.
        let u = URL(string: link)
        #expect(["https", "itms-services"].contains(u?.scheme ?? ""))
    }
}
