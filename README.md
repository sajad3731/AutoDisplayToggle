# AutoDisplayToggle

A macOS menu bar utility that turns the MacBook's built-in display **completely
off** whenever an external monitor is connected, and brings it back when the
external monitor is disconnected.

Unlike closing the lid (clamshell mode), this keeps the laptop open and cool
with the internal panel fully dark — no glow, no wasted backlight.

## Why

macOS has no built-in way to disable the internal display while keeping the lid
open. The usual workarounds either require clamshell mode, or leave the panel
logically "off" while the backlight is still lit.

## What "completely off" means here

Turning the display off takes **two** independent steps, and skipping either one
leaves the job half done:

1. **Disabling the display** removes it from the desktop so no windows land on
   it — but the panel's backlight stays powered. Measured on an Intel MacBook
   Pro, a disabled internal display still reported a hardware backlight level of
   `113/1024` in the IORegistry. The screen is black but visibly glowing.
2. **Setting brightness to zero** actually powers the backlight down.

The backlight is independently settable *while* the display is disabled, which
also means it can come back on by itself — macOS restores it across sleep/wake,
and the ambient light sensor will happily brighten a display that is supposed to
be off. This app therefore treats zero brightness as state to be maintained, not
a one-time action.

## Requirements

- macOS 14 or later (developed and tested on macOS 26.7, Intel MacBook Pro)
- Xcode Command Line Tools, for `swiftc`:
  ```bash
  xcode-select --install
  ```

Apple Silicon is untested. The approach is not architecture-specific, but the
private APIs below may behave differently.

## Install

```bash
git clone https://github.com/sajad3731/auto_display_toggle.git
cd auto_display_toggle
./build.sh --install
```

`build.sh` compiles the binary; `--install` also packages it into
`/Applications/AutoDisplayToggle.app` and launches it. Without `--install` it
just builds into `build/`.

To start it automatically, use **Start at Login** in the app's own menu — it
registers the app with `SMAppService`, the same mechanism as System Settings →
General → Login Items. If macOS wants the login item approved, the row says
`Approve…` and clicking it opens that settings pane.

## App icon

The icon is built from `Icon/icon.png` — replace that file with your own to
change it, then re-run `./build.sh --install`:

- Use a **square** PNG, ideally 1024×1024. `build.sh` renders every size macOS
  asks for (`sips` + `iconutil`) into `Contents/Resources/AppIcon.icns`, so the
  icon stays sharp in Finder, in notifications and in the Privacy & Security
  permission lists. A non-square source gets stretched.
- If you already have a finished `.icns`, commit it as `Icon/AppIcon.icns` and
  it is used as-is, no conversion.
- macOS caches icons aggressively. `build.sh` touches the bundle after
  installing, but if Finder still shows the old one, log out and back in.

If you previously pasted an icon onto the app in Finder (⌘I → paste), that is
stored as a custom-icon resource **on the bundle** and overrides the bundled
one. `build.sh --install` removes it so the icon in this repo wins.

Notifications show the same icon. They are posted through the
`UserNotifications` framework under the app's own bundle identity; the previous
`osascript` route made every notification appear as **Script Editor**. If
notification permission is refused, or the binary is run directly out of
`build/` (no bundle), it falls back to `osascript` and the Script Editor icon
comes back.

The menu bar icon is separate — it stays an SF Symbol, which adapts to
light/dark menu bars the way a full-color icon can't. It has three states, so
the menu bar alone says what the app is doing:

| Icon | Meaning |
| --- | --- |
| `display.2` | Switching on, internal display lit |
| `display` | Switching on, internal display dark |
| `display`, dimmed | Switching off — the app is idle |

Hovering it shows the same summary as the top of the menu.

## Making permissions stick

macOS ties notification permission to the app's **code signing identity**, not
to its path. An unsigned or ad-hoc-signed app is identified by a hash of its own
bytes, so every rebuild is a different app as far as the system is concerned and
notifications fall back to `osascript` (which is why they show up as **Script
Editor**).

The keyboard shortcuts are not affected — they need no permission.

A self-signed certificate keeps the identity stable across rebuilds. Create one
once:

1. Open **Keychain Access → Certificate Assistant → Create a Certificate…**
2. Name: `AutoDisplayToggle Dev`, Identity Type: *Self Signed Root*,
   Certificate Type: **Code Signing**. Create it.

`build.sh --install` picks it up automatically by name; set `CODESIGN_IDENTITY`
to use a different one. Without it, the build falls back to an ad-hoc signature
and says so.

After switching identities, relaunch and allow notifications again — this time
it survives rebuilds.

If notifications still arrive as **Script Editor**, check
**System Settings → Notifications → AutoDisplayToggle** and allow them; the app
re-checks the setting as it runs, so there is no need to restart it. If the app
isn't listed there at all, it is not registered under its own identity — which
means the installed bundle is not the one this build produced.

## Usage

The app lives in the menu bar and needs no configuration — connect an external
monitor and the internal display goes dark within a few seconds. It is a
menu-bar-only agent (`LSUIElement`), so it has no Dock icon and no entry in the
app switcher.

Menu items:

| Item | What it does |
| --- | --- |
| *Status header* | Whether the internal display is lit, and how many external displays are connected |
| **Automatic switching** | Master switch — see below. The shortcut beside it is the one that does the same thing from the keyboard |
| **Restore brightness** | The level the internal panel comes back to |
| **Pause for 1 hour** | Switching off, resuming by itself an hour later |
| **Pause until displays change** | Switching off until a display is connected or disconnected |
| **Resume now** | Ends a pause early. Only shown while paused, with the time left beside it |
| *Display list* | Every connected display, built-in first, and whether it is on |
| **Notifications** | Silences the routine announcements. Warnings still come through |
| **Start at Login** | Registers/unregisters the app as a login item |
| **Reset Displays (Panic)** | Turns the app off and force-restores the internal display |
| **Quit** | Restores the internal display, then exits |

The switches are real switches and the brightness control is a real slider:
using one leaves the menu open, so the status header and the display list above
update in place instead of making you reopen the menu to see what happened. The
whole menu refreshes once a second for as long as it is open. Every other row
closes the menu as usual.

**Pausing** is switching off with an end in sight: the internal display comes
back, and switching resumes on its own — at the deadline, or the next time a
display is connected or disconnected, which is the one for handing your laptop
to a projector. Flipping the master switch by hand cancels a pause. A pause is
not remembered across a relaunch; the app always starts switching.

**Restore brightness** is the level the internal panel is set to when it comes
back on. The app learns it from the panel whenever it is lit, so the slider is
usually already where you want it; setting it by hand pins it. Unlike the
switches, it does not change the brightness of a display right now — it decides
where the internal panel lands when it is re-enabled.

Only two settings are remembered across launches: **Notifications** and
**Restore brightness**. They live in the app's own `UserDefaults`, so there is
no config file to edit.

Global shortcuts:

| Shortcut | Action |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>D</kbd> | Turn the app off |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> | Turn the app on |

**Off** means idle, not quit: the reconcile timer is stopped, the display
reconfiguration callback is unregistered, and the internal display is restored.
Only the menu bar item and the keyboard monitor stay alive — something has to
be running to hear <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd>, so the
shortcut cannot quit the app. Use **Quit** for that.

The shortcuts are registered with `RegisterEventHotKey`, which reserves them
system-wide and **needs no permissions at all** — no Accessibility grant, no
prompt. They are bound to hardware key codes rather than typed characters, so
they keep working with a non-Latin keyboard layout (Persian, Arabic, …)
selected.

If another app has already claimed ⌃⌥⌘D or ⌃⌥⌘E, registration fails and the
app says so in a notification — macOS gives the combination to whoever asked
first. The menu then stops printing the shortcut beside the switch, rather than
advertising one that belongs to someone else.

## How it works

The core is a **state reconciliation loop** rather than a chain of event
handlers. Every five seconds, and after every relevant system event, the app:

1. Re-resolves the built-in display's ID by scanning `CGGetOnlineDisplayList`
   for `CGDisplayIsBuiltin`.
2. Computes the desired state — internal off if any non-built-in display is
   active.
3. Compares it against the actual state (`CGDisplayIsActive`) and acts only on a
   mismatch.
4. If the internal display is meant to be off, enforces zero brightness
   regardless.

This design matters for two reasons.

**Display IDs are not stable.** macOS reassigns `CGDirectDisplayID` values across
sleep/wake. Caching the built-in display's ID at launch — the obvious
implementation — produces an app that works until the first wake, then silently
targets a dead ID forever, with only a relaunch to fix it. The ID cache is
dropped on every wake and every reconfiguration event.

**Idempotent, self-healing state.** Because every decision is a comparison
rather than a reaction, missed events and failed calls cannot wedge the app into
a wrong state; the next tick repairs it. Acting on events alone also invites
feedback loops, since disabling the internal display itself emits a display
reconfiguration event.

Other implementation notes:

- Display configuration calls are never made from inside
  `CGDisplayReconfigurationCallBack` — Apple documents this as unsupported, and
  it fails during the reconfiguration storm that follows a wake. The callback
  only schedules a debounced reconcile on the main queue.
- Brightness is saved before being zeroed and restored on re-enable, with a
  safety floor so a bad saved value can't leave you with a black screen.
- After six consecutive failed attempts the loop backs off for a minute and
  notifies you, then retries — it never stops permanently, so a transient
  refusal from the window server can't wedge the app until the next relaunch.
- The internal display is re-enabled on **every** exit path — the Quit menu
  item, `applicationWillTerminate`, and `SIGTERM`/`SIGINT`/`SIGHUP` handlers —
  so killing the process or logging out can't leave the panel dark and
  unreachable.

### Private APIs

This app depends on two undocumented Apple symbols:

- `CGSConfigureDisplayEnabled` (CoreGraphics) — enables/disables a display
- `DisplayServicesSetBrightness` / `DisplayServicesGetBrightness`
  (DisplayServices.framework, a private framework)

There is no public API for disabling a display, so this is unavoidable. It also
means **a future macOS release can break this app without warning.**

## Caveats

- The app is **not signed with a Developer ID**. Without the self-signed
  certificate described under *Making permissions stick*, it is signed ad-hoc
  and notification permission has to be granted again after every rebuild.
- If the app starts while the internal display is already off at zero
  brightness, it cannot read a brightness level from the panel, and falls back
  to the remembered **Restore brightness** value (50% on a first run).
- In clamshell mode the built-in display isn't enumerated at all, so the app
  correctly does nothing.

## License

MIT — see [LICENSE](LICENSE).
