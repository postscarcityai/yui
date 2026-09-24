## Yui is installed

1. In the Yui app: **Agents > Add agent**, name it, tap **Get a pairing code**.
2. Pair this profile with the 6-digit code (it expires in 10 minutes):

   `hermes yui pair 123456`

   For a named profile: `hermes -p <profile> yui pair 123456`
3. Restart the gateway: `hermes gateway restart` (no service installed? `hermes gateway run`).

Say hi in the app. Guide: https://www.yuigui.com/start
