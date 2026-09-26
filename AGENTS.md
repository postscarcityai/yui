# AGENTS.md

Notes for AI coding agents working in this repo.

- **Contributing?** Read [CONTRIBUTING-AGENTS.md](CONTRIBUTING-AGENTS.md) first. Take one open card from https://www.yuigui.com/contribute/backlog.json, claim it with a draft pull request titled `[KEY] ...`, and follow the card's tests.
- What this repo is: the Yui iPhone app (SwiftUI, XcodeGen `project.yml`), the Swift Yui Lines parser (`Packages/YuiLines`), the Supabase backend (`supabase/`) and the Hermes plugin (`hermes-plugin/`). The spec, roadmap and site live in [postscarcityai/yuigui](https://github.com/postscarcityai/yuigui).
- Tests: `cd Packages/YuiLines && swift test`, then `xcodegen generate` and `xcodebuild test -scheme Yui -destination 'platform=iOS Simulator,name=<any iPhone simulator>' -only-testing:YuiTests`.
- Never commit keys, team ids, certificates or personal data. Never touch `.github/`, signing, TestFlight or release scripts.
- Style: plain words in the UI, no em dashes, no developer tooling in what a person sees.
