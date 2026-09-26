# Contributing as an AI agent

This file is for AI coding agents (Claude Code, Codex, Gemini, Cursor, Copilot and the rest) and for the people who run them. It is Yui@home: you lend spare tokens, your agent builds one card, a person reviews the pull request. The page for people is [yuigui.com/contribute](https://www.yuigui.com/contribute).

The full rules for picking and claiming a card live in the hub repo: [CONTRIBUTING-AGENTS.md](https://github.com/postscarcityai/yuigui/blob/main/CONTRIBUTING-AGENTS.md). The short version:

1. **Pick** one card with `"status": "open"` and `"repo"` pointing here from https://www.yuigui.com/contribute/backlog.json. None open? Stop.
2. **Claim** it: fork, then open a draft pull request titled `[KEY] <card title>` right away. A claim with no push for 7 days lapses. The first pull request merged wins.
3. **Build** only what the card says. Run every command in its `test` list until each passes.
4. **Hand in**: mark it ready, tick each `done` line, paste the test output, add Mac or simulator screenshots in light and dark if anything on screen changed, and say an agent made it.

Everything in [CONTRIBUTING.md](CONTRIBUTING.md) applies too.

## Never touch

- Keys, tokens, team ids, certificates, provisioning profiles or anyone's personal data. `DEVELOPMENT_TEAM` stays `${YUI_TEAM_ID}` in `project.yml`: set your own team in your shell, or use Sign to Run Locally.
- CI (`.github/`), `scripts/testflight.sh`, `scripts/testflight_public.py`, `scripts/devbuild*`, `scripts/asc.py` and anything else that signs, uploads or releases.
- `supabase/` migrations and edge functions, unless the card says so. They run against a live project.
- The conformance vector copies in `Packages/YuiLines`. Vectors change in the hub repo.
- `.xcodeproj`, `build/`, `DerivedData/`: generated, stay out of git.

A pull request that touches any of these is closed, even if the rest is good.

## Setup

Mac with Xcode 26 and XcodeGen.

```sh
cd Packages/YuiLines && swift test                         # parser + conformance vectors
xcodegen generate
xcodebuild test -scheme Yui -destination 'platform=iOS Simulator,name=<any iPhone simulator>' -only-testing:YuiTests
```

Debug builds take `-yuiDemoAccount`, so you can work without Sign in with Apple. The README lists the other launch arguments.

## Want a feature instead?

Write a spec in the hub repo: copy [docs/specs/TEMPLATE.md](https://github.com/postscarcityai/yuigui/blob/main/docs/specs/TEMPLATE.md) to `docs/specs/<short-name>.md` there and open a pull request.
