# Contributing to Yui

Thanks for looking. Yui is built in public, and help is welcome at any size: a bug report, a fix, a new preset, or a connector for an agent framework other than Hermes.

This repo holds the iOS app, the Swift Yui Lines parser, the Supabase backend and the Hermes plugin. The spec and roadmap live in [postscarcityai/yuigui](https://github.com/postscarcityai/yuigui). Spec changes start there.

## Good first contributions

- **Presets.** Each Yui Lines verb renders a SwiftUI preset. Polish, accessibility and Dynamic Type fixes are always welcome.
- **Connectors.** The Hermes plugin in `hermes-plugin/` is the first. A connector for another agent framework speaks the same protocol: see `yuigui/spec/AGENTS.md` and `yuigui/spec/CHANNEL.md`.
- **Bugs.** Anything in the issue tracker labeled `bug`.

## Setup

Mac with Xcode 26 and XcodeGen.

```sh
xcodegen generate && open Yui.xcodeproj    # run on an iPhone simulator
cd Packages/YuiLines && swift test        # parser + conformance tests
```

DEBUG builds accept `-yuiDemoAccount` so you can work without Sign in with Apple. The README lists the other launch arguments.

The Swift parser must pass the same vectors as every other parser. They are copied from the hub by `Packages/YuiLines/scripts/sync-vectors.sh`. Do not edit the copies here, change them in yuigui.

## Backend changes

Migrations and edge functions in `supabase/` run against a live project. If you change them, test against your own Supabase project and include the output of `python3 supabase/tests/accounts_test.py` and `agents_test.py` in the pull request. Every `yui_*` table must stay locked to its owner by row level security, and must cascade from `yui_users` so account deletion stays complete.

## Pull requests

- One change per pull request.
- Tests pass.
- Anything on screen comes with a simulator screenshot, light and dark.
- Never include keys, tokens, team ids or anyone's personal data. `.xcodeproj`, `build/` and `DerivedData/` stay out of git.
- By opening a pull request you agree your work is licensed under Apache-2.0, the same as the rest of the repo.

## Conduct

Everyone here follows the [Code of Conduct](CODE_OF_CONDUCT.md).
