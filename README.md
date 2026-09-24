# Yui | iOS app and Hermes plugin

Yui is a phone app for talking to your own AI agents. You chat like normal. When a button, a timer or a table would work better than text, the agent puts one on the screen, and your taps go straight back to it.

Yui brings no brain of its own. You bring the agent, and Yui gives it a face, a voice and a screen it can draw on. Hermes is the first agent it supports.

This repo holds the native SwiftUI app, the Swift Yui Lines parser, the Supabase backend and the Hermes plugin. The roadmap, the progress log and the Yui Lines spec live in the hub repo, [postscarcityai/yuigui](https://github.com/postscarcityai/yuigui), and at [yuigui.com](https://www.yuigui.com).

<p>
  <img src="docs/img/app-chat.png" width="260" alt="Yui chat screen on iPhone">
  <img src="docs/img/app-agents.png" width="260" alt="Yui agents screen on iPhone">
</p>

## What is in here

| Path | What it is |
| --- | --- |
| `Yui/` | The iOS app (SwiftUI, iOS 26, iPhone only) |
| `Packages/YuiLines/` | Swift parser for Yui Lines, no dependencies |
| `project.yml` | XcodeGen project. The `.xcodeproj` is generated, not committed |
| `hermes-plugin/` | The `yui` Hermes platform plugin |
| `supabase/` | Migrations, edge functions and live tests for accounts and agents |
| `scripts/` | TestFlight upload and App Store Connect helpers |

## Run the app

You need a Mac with Xcode 26 and [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`).

```sh
export YUI_TEAM_ID=<your Apple team id>   # or leave empty for the simulator
xcodegen generate
open Yui.xcodeproj
```

Pick an iPhone simulator and run. DEBUG builds take a few launch arguments for screenshots and offline work: `-yuiDemoAccount` (skip Sign in with Apple), `-yuiSignedOut`, `-yuiAgents`, `-yuiNoAgents`, `-yuiAddAgent`, `-yuiAddAgentCode`, `-yuiSettingsLarge`, `-yuiConfirmDelete`.

Parser tests:

```sh
cd Packages/YuiLines && swift test
```

The tests use Swift Testing, which needs full Xcode, not just the Command Line Tools. If `swift test` says `no such module 'Testing'`, run `sudo xcode-select -s /Applications/Xcode.app`. One test checks that the bundled conformance vectors match the hub repo. When the hub adds a vector, run `Packages/YuiLines/scripts/sync-vectors.sh` with yuigui checked out next to this repo.

The app points at our Supabase project (`Yui/Sources/Account/YuiBackend.swift`). The key in that file is a public client key. It grants only the anon role, which cannot read any `yui_` table. To run your own backend, create a Supabase project, apply `supabase/migrations/` in order, deploy the functions in `supabase/functions/`, and change the URL and key in that file.

## Connect Hermes

The `yui` plugin makes Yui a Hermes messaging platform, next to Telegram. Each Hermes profile you install it into gets its own thread in the app and keeps one memory across Yui and Telegram. It dials out to Supabase with a scoped connector token, so your machine opens no inbound ports.

1. In the app, go to Agents, tap Add agent, and note the six-digit code.
2. On the machine that runs Hermes:

   ```sh
   hermes-plugin/install.sh <profile>
   hermes -p <profile> yui pair <code>
   hermes -p <profile> gateway restart
   hermes -p <profile> yui status
   ```

3. The agent shows up in the app. Talk to it.

The plugin injects a short guide into each Yui turn so the agent knows it can put Yui Lines on screen (source: `yuigui/spec/CHANNEL.md`, synced by `hermes-plugin/sync_channel.py`). The connector credential lives at `~/.hermes/yui/connector.json`, outside the repo.

Without Hermes loaded, `python3 hermes-plugin/yui/connector.py pair <code> --profile <profile>` does the same pairing. How messages, events and credentials flow: `yuigui/spec/RELAY.md`.

A live round trip test (type, get a Yui Lines screen, tap, get a timer) runs against a real session and a running gateway: `TEST_RUNNER_YUI_RT=<refresh token> TEST_RUNNER_YUI_USER=<uuid> xcodebuild test -scheme Yui -only-testing:YuiUITests`. Without those it skips. Mint a fresh `yui_sessions` row for every run: yui-auth rotates refresh tokens, and replaying a spent one reads as a leak and signs the account out on every device.

## Backend notes

- Sign in with Apple only. Users never enter Supabase Auth: `yui-auth` verifies Apple's identity token and mints a 15-minute JWT with role `yui_user`, which can reach only `yui_*` rows keyed to that user. `yui-delete` revokes the Apple token and deletes the account. Every `yui_*` table cascades from `yui_users`.
- Agents are managed by the user, never hardcoded. Spec: `yuigui/spec/AGENTS.md`. `yui-agents` serves the app, `yui-connect` serves the host (pair, add, heartbeat).
- Relay (`supabase/migrations/20260924010000_yui_relay.sql`): the host trades its connector token at `yui-connect` for a 60-minute `yui_connector` JWT that can read and answer only the threads of agents bound to that host. Tests: `python3 supabase/tests/relay_test.py`.
- Our project is shared with other apps, so we apply migrations by hand. Never `supabase db push` or `config push` against it.
- Deploy a function: `supabase functions deploy <name> --project-ref <ref> --use-api --no-verify-jwt`. Secrets (`YUI_JWT_SECRET`, `YUI_SIWA_*`, `YUI_APPLE_TEAM_ID`) are edge function secrets and never live in the repo.
- Tests run live against a real project: `python3 supabase/tests/accounts_test.py` (RLS, cross-user isolation, create and delete) and `python3 supabase/tests/agents_test.py` (registry). Run both after any change to a migration or function.

## TestFlight

`scripts/testflight.sh` archives and uploads with an App Store Connect API key read from `~/.appstoreconnect/`. Never commit keys.

## Contributing

Issues and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md). Found a security problem? Please read [SECURITY.md](SECURITY.md) first.

## License

[Apache-2.0](LICENSE). Copyright 2026 PostScarcity AI.
