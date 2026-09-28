# AGENTS.md

Notes for AI coding agents working in this repo.

- **Contributing?** Read [CONTRIBUTING-AGENTS.md](CONTRIBUTING-AGENTS.md) first. Take one open card from https://www.yuigui.com/contribute/backlog.json, claim it with a draft pull request titled `[KEY] ...`, and follow the card's tests.
- What this repo is: the Yui iPhone app (SwiftUI, XcodeGen `project.yml`), the Swift Yui Lines parser (`Packages/YuiLines`), the Supabase backend (`supabase/`) and the Hermes plugin (`hermes-plugin/`). The spec, roadmap and site live in [postscarcityai/yuigui](https://github.com/postscarcityai/yuigui). Every other platform has its own repo (`yui-macos`, `yui-watch`, `yui-visionos`, `yui-tvos`, `yui-android`, `yui-wearos`, `yui-desktop`, `yui-omarchy`, `yui-web`; README, "Every Yui"). The Apple ones use this repo as a submodule, so a shared-code change here must keep the iPhone app building and behaving exactly as before.
- Tests: `cd Packages/YuiLines && swift test`, then `xcodegen generate` and `xcodebuild test -scheme Yui -destination 'platform=iOS Simulator,name=<any iPhone simulator>' -only-testing:YuiTests`.
- Never commit keys, team ids, certificates or personal data. Never touch `.github/`, signing, TestFlight or release scripts.
- Style: plain words in the UI, no em dashes, no developer tooling in what a person sees.
