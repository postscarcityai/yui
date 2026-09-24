# YuiLines

Swift parser for Yui Lines (YL), the one-line-per-component wire format between an agent and the Yui app. Spec and conformance vectors live in the hub repo: `yuigui/spec/YL.md`, `yuigui/spec/conformance/`. No dependencies.

```swift
import YuiLines

let nodes = YuiLines.parse("timer 40/20x8 Tabata\nask \"Log this set?\"")
// [add timer n1 {work: 40, rest: 20, rounds: 8, label: "Tabata"}, add ask n2 {q: "Log this set?"}]

// Streaming: a node comes out the moment its line's newline arrives.
var stream = YLStreamParser()
for chunk in modelChunks { render(stream.push(chunk)) }
render(stream.flush())

// Or from an AsyncSequence of String chunks:
for try await node in YuiLines.nodes(from: chunks) { render(node) }
```

`YLNode` is `Codable`: `op` (add, patch, save, show, clear, focus, error), `screen`, `preset`, `id`, `target`, `name`, `props`, `message`, `line`. `props` holds only what the line said; defaults are the renderer's job (spec section 4).

## Tests

```
scripts/sync-vectors.sh    # copy vectors from ../../../yuigui/spec/conformance
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test
```

The vectors are copied into `Tests/YuiLinesTests/Resources/conformance` so this repo builds and tests without yuigui checked out. When yuigui does sit next to it, `vectorsMatchHubRepo` fails if the copies are stale.
