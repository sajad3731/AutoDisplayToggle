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

- macOS (developed and tested on macOS 26.7, Intel MacBook Pro)
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

To start it automatically, add the app under
**System Settings → General → Login Items**.

## Usage

The app lives in the menu bar and needs no configuration — connect an external
monitor and the internal display goes dark within a few seconds.

Menu items:

| Item | What it does |
| --- | --- |
| **Pause / Resume Auto-Toggle** | Suspends automatic switching and restores the internal display |
| **Reset Displays (Panic)** | Pauses and force-restores the internal display |
| **Quit** | Restores the internal display, then exits |

Global shortcuts:

| Shortcut | Action |
| --- | --- |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>D</kbd> | Pause (disable auto-toggle) |
| <kbd>⌃</kbd><kbd>⌥</kbd><kbd>⌘</kbd><kbd>E</kbd> | Resume (enable auto-toggle) |

The shortcuts require **Accessibility** permission
(System Settings → Privacy & Security → Accessibility). Everything else works
without it.

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

- The binary is **unsigned**. Because macOS ties Accessibility permission to the
  binary's identity, you may need to re-grant Accessibility after each rebuild
  for the keyboard shortcuts to keep working.
- If the app starts while the internal display is already off at zero
  brightness, it cannot know your previous brightness level and restores to 50%.
- In clamshell mode the built-in display isn't enumerated at all, so the app
  correctly does nothing.

## License

MIT — see [LICENSE](LICENSE).
