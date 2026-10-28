# Oyl

A macOS notch app, and Oyl, the little imp who lives in it.

Hover the notch for music (with a visualizer Oyl surfs, lyrics, and cover-art controls), timers and reminders, an Amphetamine-style keep-awake, the Oyls page, and an activity monitor that also counts Claude Code tokens. Out on the menu bar, an Oyl turns up for each thing going on: each Claude Code agent at work (in a pastel with an orange hat), the song, every timer and reminder, staying awake, a low battery, a late night, a fresh selfie. Right of the notch sits a calendar bar, with an Oyl acting out whatever's on now.

With the camera on, hand gestures over the open notch play, pause and skip, turn the volume (pinch and twist; add the pinky to scrub), take a selfie (✌️), keep the Mac awake (🤟), show the lyrics (pinky out), make the Oyls announce themselves (thumb holding the ring finger down), and line them up or send them off (tip the hand left or right).

## Building

Needs macOS 14.2 or later and the Xcode Command Line Tools. No Xcode project.

```sh
./build.sh          # builds build/Oyl.app
./build.sh --run    # builds, then (re)launches it
```

The first build makes a local signing certificate in its own keychain, so macOS keeps the app's permissions across rebuilds.

## Claude Code

Oyl follows Claude Code sessions through hooks, which it installs as scripts in `~/Library/Application Support/nott/` each time it starts. Point Claude Code's hooks at `agent-hook` for its events, and at `permission-hook` for `PermissionRequest` to answer approvals from the notch.

The calendar bar reads the Mac's calendars, so a Google calendar shows up once its account is added in System Settings › Internet Accounts.
