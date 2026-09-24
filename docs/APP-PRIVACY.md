# App Privacy answers (App Store Connect)

The answers for App Store Connect > App Privacy, kept in step with the public
policy at https://www.yuigui.com/privacy (source: yuigui `site/app/privacy/page.js`,
section "What we declare to Apple") and with the `yui_` tables in
`supabase/migrations`. Change all three together.

The privacy label is not in the public App Store Connect API, so it is entered
by hand in the web UI. TestFlight does not need it; the first App Store
submission does. Privacy policy URL (set through the API on the app info and
the beta localization): https://www.yuigui.com/privacy

## Do you or your third-party partners collect data from this app?

Yes.

## Data types

| Apple category | Apple type | What it is in Yui | Where it lives |
|---|---|---|---|
| Contact Info | Email Address | the email or Apple relay address from Sign in with Apple (optional) | `yui_users.email` |
| Identifiers | User ID | Apple's per-app user ID, and Yui's account ID | `yui_users.apple_sub`, `yui_users.id` |
| Identifiers | Device ID | the push notification token | `yui_devices.apns_token` |
| User Content | Photos or Videos | photos sent to an agent, pictures and videos agents send | bucket `yui-media` |
| User Content | Other User Content | messages with agents, agent names and looks | `yui_messages`, `yui_agents` |
| Usage Data | Product Interaction | which agent's thread is open (push presence), taps sent back to the agent | `yui_devices.active_*`, `yui_messages` (kind `event`) |

For every type above:

- Used for: **App Functionality** only. Not Analytics, not Advertising, not Product Personalization, not Developer's Advertising or Marketing, not Other.
- Linked to the user: **Yes** (everything belongs to the signed-in account).
- Used for tracking: **No**.

## Not collected

Location (precise or coarse), Contacts, Health and Fitness, Financial Info,
Sensitive Info, Browsing History, Search History, Purchases, Audio Data,
Gameplay Content, Customer Support, Crash Data, Performance Data, Other
Diagnostic Data, Advertising Data, Other Data Types.

Notes behind those answers:

- No analytics or crash SDK is in the app. TestFlight's own feedback and crash
  reports are Apple's, not ours.
- `yui_pair_attempts` keeps the IP address of a wrong pairing code for one day,
  only to stop code guessing. `yui_rate_buckets` keeps per-account counters for
  a day. Neither is used for location, analytics or tracking. The policy page
  lists both under "Keeping Yui safe".
- Host computer names (`yui_connectors.name`) and agent access keys
  (`yui_mgmt_tokens`, hashed) are account configuration, covered by Other User
  Content.
- Voice: the `mic` preset uses the keyboard's dictation today; Yui records no audio.
- Retention: messages 90 days (`yui_limits.message_retention_days`, cron
  `yui-media-sweep`), sessions 60 days idle, pairing codes 10 minutes. Deleting
  the account removes everything at once (`yui-delete`).
