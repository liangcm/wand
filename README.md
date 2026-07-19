[中文版本](README_CN.md)

# Wand

Turn your Apple Siri Remote into a controller for your Mac.

Wand is a macOS menu bar app that pairs with the Siri Remote you already own and maps every input on it — trackpad, buttons, gestures — to things you actually do on a Mac: move the cursor, click, scroll, fire keyboard shortcuts, type commands, launch apps.

> **Experimental.** Wand is built on two proprietary, reverse-engineered interfaces (the private `MultitouchSupport` framework and HID-level event interception) that Apple can change at any time. Expect rough edges.

## Features

**Trackpad**
- One-finger glide moves the cursor; two-finger glide scrolls
- Tap to click (can be disabled in the panel — then only a physical press clicks)
- Center press = mouse click, hold-to-drag included
- Edge clicks (up / down / left / right) nudge the cursor in that direction — step size adjustable via the *Mouse Sensitivity* slider
- Four swipe directions, each mappable to any action
- Multi-finger pinch opens the configuration panel

**Buttons**
- Every physical button is mappable, with separate single-click and double-click bindings
- Actions come in three groups, plus specials:
  - **Function keys** — Enter, Tab, Space, Backspace, Delete, Esc, arrows, left/right modifier taps, Fn, left/right mouse click
  - **F-keys** — F1–F12
  - **Combos** — Cmd+C/V/X/Z/Shift+Z/A/S/W/F, Ctrl+C, Shift+Tab, or *learn* any custom shortcut by pressing it
  - **Specials** — type arbitrary text or a slash command (with optional trailing Space/Enter), or open a chosen app

**Panel & system**
- Visual configuration panel: click any control on the remote diagram, pick its mapping
- Bilingual UI (English / 简体中文), follows the system language; light & dark mode
- HID seize: while Wand runs, macOS no longer double-handles the remote's media keys
- Volume revert guard: Bluetooth AVRCP volume changes triggered by remote presses are rolled back so your mapped action is the only effect

**Supported remotes:** Siri Remote 1st gen (A1513/A1962), 2nd gen (A2540), 3rd gen (A2854).

## Install

1. Build the app (see below) or open `Wand-<version>.dmg` and drag **Wand.app** to Applications
2. Launch Wand — a remote-shaped icon appears in the menu bar
3. Grant permissions in **System Settings → Privacy & Security**:
   - **Accessibility** — required to synthesize keyboard/mouse events
   - **Input Monitoring** — required to intercept the remote's media keys
4. Pair the Siri Remote with your Mac over Bluetooth
5. Open **Menu bar icon → Open Remote Panel…** to configure mappings

A diagnostic log is written to `/tmp/wand.log`.

## Building

```bash
./build.sh                # compile (links private MultitouchSupport framework)
./create_app_bundle.sh    # package + ad-hoc sign Wand.app
./create_dmg.sh           # full distributable: Developer ID sign + DMG
NOTARY_PROFILE=<profile> ./create_dmg.sh   # + notarize & staple (release build)
```

`create_dmg.sh` auto-detects a Developer ID certificate in your keychain and falls back to ad-hoc signing with a warning. See the script header for notarization credential setup.

## Origins

Wand began life as **Mavrick** — this project's earlier name and the source of its core ideas: seizing the Siri Remote at the HID level, driving the cursor through the private multitouch interface, and mapping remote inputs to desktop actions.

Mavrick itself was a fork of [HyperVibe](https://github.com/machinarii/hypervibe) by [Jinsoo An](https://github.com/machinarii) (MIT License), which in turn was built on [Remotastic](https://github.com/lauschue/Remotastic) by [@lauschue](https://github.com/lauschue). Remotastic provided the foundational Siri-Remote HID handling, MultitouchSupport integration, and menu-bar scaffolding; HyperVibe extended it with configurable workflows, keyboard shortcuts, and gesture support.

## License

MIT — see [LICENSE](LICENSE).
