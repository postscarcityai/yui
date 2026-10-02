# The stage redesign

Chris, Oct 2 2026: "the whole thing is chunky and functionally inept at making these ideas easier to comprehend at a glance ... part chat, part pitch deck, part creative advertisement ... recreate UI elements in a sleek blueprint type way, also just be able to draw."

This is what changed in the app on this branch, what it answers, and what the hub still has to do before agents can use the new `draw` block. Screenshots are in `docs/img/redesign/`.

## What the feedback said

Read from the 101 TestFlight notes since Sep 25. The same six things come back again and again:

| Theme | In Chris's words | Notes |
|---|---|---|
| Show, don't tell | "I want you to actually show me", "re-create wireframes of these UI", "still not seeing any drawings" | ALUttyXB, AEPs5OZG, AKDz8MWq, AH_N-9fd, ACHcboRE |
| Bad graphic design | "This is not good graphic design", "big blocky text everything's bold yuck", "try a different layout" | AOGmS_cF, ALkikjiu, APirVhnh, ADv4muh0 |
| No card in the full screen | "why do we even have a card in there?", "not a fan of cards within cards" | ALUttyXB, APXu3dFU |
| Fewer, fuller pages | "eight screens of basically nothing", "returning as few screens as possible" | AJq7CcQS, AEPs5OZG, ALUjYU_B |
| Caveman, with marks | "Site: good. SEO: strong.", "Invite: Declined", "put a simple checkmark" | AEPs5OZG, AEfIl6dC, ADdQFqWT, ACHcboRE |
| Know where you are | "I don't actually know where I am", "half done, but the thing is still working" | ANG8AA-7, APO8y7eU |

VIS-1 to VIS-5 and DRAW-1 to DRAW-3 already taught agents to send one line and a drawing. The last round of notes (Oct 1 and 2) is about how the app draws what they send. That is what this branch changes.

## What changed

1. **A drawing sits on the page, not in a card.** `sketch`, `mock`, `diagram`, `shapes`, `map`, `chart`, `stat`, `timeline`, `compare` and `draw` have no card round them on the stage. A question is the page too.
2. **Sketches are blueprints.** Thin lines that trace themselves on. A before and after sit side by side: the before dashed and crossed, the after lit in the agent's color and ticked. The yellow highlighter is gone; a lit row has a bar of the agent's color and a wash. Callouts are numbered on the drawing with their words in a key under it, so a row keeps the frame's whole width. Same for `mock`.
3. **`Label: value` lines are a ledger.** Two or more of them read as rows: a tick, a cross, an arrow or a dot (read from the value's own words), the label small, the value bigger. Separate `say` lines that are each a label join into one ledger on one page.
4. **Type steps down.** A headline is bold, not black, set tight, and sized to how much it says. Words always come before the drawing that shows them.
5. **Glass controls, and the agent's name.** The top and bottom buttons are Liquid Glass. The menu button carries the agent's name, and the whole button opens the drawer.
6. **Quieter chrome.** The ask always reads from the left (it used to jump to the right while the agent worked). Back home and New chat are two quiet links, not two slabs.
7. **`draw`: the agent just draws.** See below.

## Bugs fixed

- **"Anything else?" while the agent was still working** (APO8y7eU). Any row from the agent ended the working state, even one that only filled a side screen, the home or the drawer. Now only something to read or answer ends it; the turn's own end still clears it. A turn that truly comes back with nothing says "Nothing to show for that."
- **The ask jumped sides** between the working state (right) and the answer (left).
- **A struck row that wrapped was struck on one line only.**
- **Stacked ideas were centered and narrow** on a page with a small drawing; they now start from the left edge.
- **`-yuiDemoArrive` could not carry a real reply** (a launch argument cannot hold quotes); it reads `-yuiDemoArriveFile` now, and `-yuiDemoStageAt <n>` opens the stage on a page, for shots.

## `draw`

```
draw "Push tap" caption="Tap the banner. The answer plays itself."
<svg viewBox="0 0 360 250">
  <rect class="draw soft" x="30" y="14" width="120" height="222" rx="20"/>
  <circle class="pop accent pulse" cx="118" cy="46" r="13"/>
  <path class="draw accent" d="M158 125 C 178 105, 190 105, 208 125"/>
  <rect class="draw accent" x="216" y="14" width="120" height="222" rx="20"/>
  <text class="fade" x="230" y="96" font-size="15" font-weight="800">Push tap fixed.</text>
</svg>
end
```

`draw [title...] [caption=] [ratio=]`, then markup up to a line that is only `end`. The head is an add; the `end` (or the end of the reply) gives one patch with `source`, the markup as written, exactly as `diagram` does with Mermaid. If the first line after the head does not open a tag, the draw stays empty and the line is read as YL. A drawing is cut at 600 lines or 60,000 characters. Sends no events. In a `deck` or a `plan` it is a page's picture.

Why SVG: every model already writes it well, so there is no new grammar to teach, and it covers what the presets cannot (a gesture, a finger, a chart nobody planned for). The earlier worry ("long, fragile and unsafe") is answered by the box it runs in and by what the phone gives it for free:

- **Colors**: `var(--ink)`, `--soft`, `--accent`, `--mint`, `--lavender`, `--butter`, `--good`, `--bad`, or the classes `.accent`, `.mint`, ... (stroke) and `.fill-accent`, ... (fill). The drawing matches the agent in light and dark with no hex in it.
- **Lines**: a shape with no stroke of its own is a 1.5 pt line in ink with no fill, so plain SVG already looks like a blueprint.
- **Motion**: `class="draw"` traces a line on, `pop` springs a part up, `fade` brings it in, `pulse` keeps it breathing. Parts with one of these come on in the order they are written, a beat apart. Order is the story, as in `shapes`. A script or CSS animation of the agent's own also runs.
- **Shape**: from `ratio=`, else the `viewBox`, else 4:3.

The box: a web view with a content policy of `default-src 'none'` (only inline style and script run, nothing loads from anywhere), no stored data, no base URL, every navigation refused, no touch. Reduce Motion shows it finished.

Not in this cut: drawing libraries. Nothing can load from the network by design, so a library has to ship inside the app. The first to add would be a small one for hand-drawn lines; it is a build decision, not a spec change.

## What the hub has to do

The app half is here (Swift parser, renderer, tests). Agents cannot send `draw` until:

1. `spec/YL.md`: the `draw` section above, and `draw` in the deck and plan member lists.
2. `site/lib/yl/yl.mjs` and the Python, Kotlin and Rust parsers: the block reader, plus two conformance vectors (a draw with its patch, a draw with no markup). The Swift parser already passes its own tests for both.
3. The web renderer: the same page (`DrawPage.html` is the reference), in a sandboxed iframe.
4. `hermes-plugin/yui/compat.py`: `draw` gated by min build (this branch's build number), words-only fallback for older builds, as `diagram` and `mock` have.
5. `spec/CHANNEL.md`: one line and one example. "When no preset draws it, draw it: `draw` then SVG. Use the classes, not hex."
6. Mirror the label packing in `site/lib/yl/chunks.mjs` (`packPages`): consecutive label lines join into one chunk, and a ledger starts its own page.
7. Telegram fallback: the caption, or the title.

## Next, in order

1. Ship `draw` through the hub (above), then score a live day of replies.
2. Gesture marks on `mock` (`part touch`, `part swipe`): gap 2 in `docs/research/yl-visual-gaps.md`, and what "push tap" needed.
3. The working state (ADv4muh0): the doing words in glass, named for what the agent is doing.
4. A short summary of the ask over the answer, written by the agent (a `re "..."` line), in place of the first two lines of it.
