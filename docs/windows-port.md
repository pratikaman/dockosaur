# Proposal: Dockosaur on Windows

Status: **draft for review**. Nothing here is built yet. This doc asks for a decision on the approach (see [Questions](#questions-for-review)) before any code is written.

## Goal

The same game, running on top of the **Windows taskbar** the way it runs on top of the macOS Dock:

- A transparent strip that sits on the taskbar's top edge, above every window, with clicks passing through to whatever is underneath.
- Play from any app without switching focus: a global key to jump (with hold-to-jump-higher), or a click on the strip that never steals focus.
- A tray icon with the same settings: dino, size, width, sound, autopilot, launch at login.
- Same physics, spawns, art and self-test as the Mac build. One game, not a fork that drifts apart.

Out of scope for v1: taskbars on the left, right or top edge (Windows 10 only); "match taskbar icons" width; a Microsoft Store/MSIX package.

## Where the Mac code is today

`Sources/main.swift` is one 1,700-line file. Counting AppKit/CoreGraphics/Core Animation symbols per section:

| Section | Lines | Mac APIs used | Portable? |
|---|---|---|---|
| Tunables, RNG, collision masks | ~110 | `CGRect`, `CGImage`, `CGContext` (mask extraction) | Yes, once images are plain RGBA buffers |
| Art (sprite loading, pixel sprites, sign, flames) | ~180 | `CGImage`, ImageIO, `CGContext` | Mostly. PNG decode is per-platform, everything else is buffers |
| **Game model** (physics, spawns, powers, pits, autopilot) | ~440 | 5 uses of `CGRect` | **Yes**. This is the game |
| Rendering (`Scene`, Core Animation layer tree) | ~285 | `CALayer`, `CATransaction`, `CGColor` | No. Rewrite per platform |
| Sound (square-wave synth → WAV) | ~60 | `AVAudioPlayer` (playback only) | Synth yes, playback per platform |
| Settings, window, global input | ~95 | `UserDefaults`, `NSPanel`, `CGEvent` tap, Carbon hot key | No |
| App controller, menu, Dock placement | ~315 | `NSStatusItem`, `NSMenu`, `CADisplayLink`, AX API, `SMAppService` | No |
| `--snapshot` / `--selftest` | ~180 | self-test: none; snapshot: renders the CA tree | Self-test yes |

So the first three rows, **about 45% of the file (~750 lines), can be shared**: the game model unchanged, and the helpers and art after replacing a handful of CoreGraphics types with plain structs. The rest (~950 lines) is the macOS shell, which has to exist per platform no matter which approach we pick.

## Approaches considered

| | A. Shared Swift core + native Win32 shell (**recommended**) | B. Port to another language (Rust / C# / C++) | C. Cross-platform wrapper (Electron, Tauri, SDL, Godot) |
|---|---|---|---|
| Game logic | One copy, shared by both platforms | Two copies. Every tweak (like the pit/fire work) is done twice | One copy, but the Mac app gets rewritten too |
| Fit for an always-on overlay | Native window, tiny footprint | Native, tiny | Electron: ~100 MB and a browser engine idling on the taskbar. SDL/Godot: transparent, click-through, no-focus windows fight the framework |
| Toolchain | Swift 6.4 for Windows (official, `winget install Swift.Toolchain`) + VS 2022 Build Tools | Mature, well-trodden | Mature |
| Risk | Swift-on-Windows GUI apps are still uncommon; runtime DLLs need to be shipped | Drift between versions | Big, heavy, and still needs Win32 escapes for the overlay behaviour |

**Recommendation: A.** The overlay behaviour (layered window, no-activate, global key hook, tray) is plain Win32 in any language. The real question is whether the game code is shared, and A is the only option that keeps the game logic as one copy without rewriting the Mac app. Swift has official Windows support (the toolchain ships a `WinSDK` module exposing the Win32 C API, and swift.org has had a Windows workgroup since Jan 2026). The risks are packaging and tooling, not capability, and phase 0 below is a cheap spike to retire them before we commit.

If the spike goes badly (toolchain pain, DLL size, antivirus trouble), fall back to **B with Rust** (`windows-rs`). We'd then keep the game rules in sync by porting the self-test as the shared spec.

## Architecture

```
Package.swift
Sources/
  DockosaurCore/      pure Swift, no Foundation-on-Apple-only APIs
    Tunables, RNG, Mask, Image (w, h, [UInt8] premultiplied RGBA)
    Art (sprites from decoded images, pixel sprites, sign, flames)
    Game (unchanged logic)
    Sprites.swift  -> Game.displayList(): [Sprite]   // image id, x, y, scale, rotation, opacity
    Synth          -> [Int16] PCM for each Sfx
    SelfTest
  DockosaurMac/       today's AppKit / Core Animation shell, consuming displayList()
  DockosaurWin/       new Win32 shell via `import WinSDK`
```

The key change is a **display list**. Today `Scene.update` reads the game state and positions `CALayer`s directly. Instead, the core produces a flat list of sprites to draw each frame (dino with scale/rotation/opacity, things, effects, HUD text, ground segments, holes), and each shell just draws that list. The Mac shell keeps its layer pool. The Windows shell blits the list into a bitmap. Rendering rules like the blink, the skate lift, the juice-box bob, ground gaps and edge fade then live in one place.

PNG decoding is the one thing the core can't do alone. ImageIO on Mac, **WIC** (Windows Imaging Component, built in) on Windows, both feeding `Image` buffers. (Alternative: pre-convert the art to raw RGBA at build time and drop the decoder entirely.)

## Windows shell design

### Mac → Windows mapping

| Mac today | Windows | Notes |
|---|---|---|
| `NSPanel`, borderless, `.floating`, non-activating | `CreateWindowEx` with `WS_POPUP`, `WS_EX_LAYERED \| WS_EX_TOPMOST \| WS_EX_TOOLWINDOW \| WS_EX_NOACTIVATE` | `TOOLWINDOW` keeps it out of Alt+Tab and the taskbar. Also return `MA_NOACTIVATE` from `WM_MOUSEACTIVATE` so clicks never take focus |
| `ignoresMouseEvents` toggled on hover | Toggle `WS_EX_TRANSPARENT` | Click-through by default. Poll the cursor (`GetCursorPos`) each frame like the Mac build does, and drop `WS_EX_TRANSPARENT` while it's over the strip |
| Core Animation layers (GPU) | Software compositor into a 32-bit premultiplied BGRA DIB + **`UpdateLayeredWindow`** | The strip is ~1440×220 device px at 2× scale, so a nearest-neighbour blit is a fraction of a millisecond, gives true per-pixel alpha and needs no GPU code. Upgrade path: DirectComposition + Direct2D if profiling ever says so |
| Dock top edge via `visibleFrame` / AX | `SHAppBarMessage(ABM_GETTASKBARPOS)` for the taskbar rect + `GetMonitorInfo` work area | Ground line = taskbar top. Re-query on `WM_SETTINGCHANGE`, `WM_DISPLAYCHANGE` and the registered `TaskbarCreated` message (Explorer restarts) |
| Auto-hidden Dock | `ABM_GETSTATE` → `ABS_AUTOHIDE` | Sit at the screen bottom (as the Mac build does without a Dock) |
| Right ⌥ via `CGEvent` tap (needs Input Monitoring) | **`WH_KEYBOARD_LL`** low-level hook on a dedicated thread, watching only `VK_RMENU` (and the `LLKHF_INJECTED` flag to ignore synthetic input) | Needs no permission prompt. Gives key-down **and** key-up, which hold-to-jump needs |
| ⌃⌥Space via Carbon `RegisterEventHotKey` | `RegisterHotKey(MOD_CONTROL \| MOD_ALT \| MOD_NOREPEAT, VK_SPACE)` | `WM_HOTKEY` has **no key-up**, so this path is tap-only (short hop), or poll `GetAsyncKeyState` after the press to detect release |
| `CADisplayLink`, 60 fps busy / 15 fps idle | Message loop + waitable timer (or `DwmFlush()` to sync to vblank); the same busy/idle rule | Fixed 1/120 s sub-steps stay as they are |
| `AVAudioPlayer` from synthesised WAV | `PlaySound(SND_MEMORY \| SND_ASYNC)` with the same WAV bytes | `PlaySound` plays one sound at a time; good enough for v1. XAudio2 if overlapping blips matter |
| `NSStatusItem` + `NSMenu` | `Shell_NotifyIcon` + `TrackPopupMenu` | Same menu: New Game, Dino ▸, Size ▸, Width ▸, Sound, Autopilot, Show Game, Launch at Login, Reset Best, About, Quit |
| `UserDefaults` | `HKCU\Software\Dockosaur` (or `%APPDATA%\Dockosaur\settings.json`) | |
| `SMAppService` launch at login | `HKCU\Software\Microsoft\Windows\CurrentVersion\Run` value | |
| Pause on lock / sleep | `WTSRegisterSessionNotification` → `WM_WTSSESSION_CHANGE`; `WM_POWERBROADCAST` | |
| Not shown on full-screen Spaces | `SHQueryUserNotificationState` (`QUNS_BUSY`, `QUNS_RUNNING_D3D_FULL_SCREEN`, `QUNS_PRESENTATION_MODE`) + a "foreground window covers the monitor" check for borderless full-screen games and video | Same approach Chromium uses |
| Retina `backingScaleFactor` | Per-Monitor-V2 DPI awareness in the manifest; `GetDpiForWindow`, `WM_DPICHANGED` | |

### Controls on Windows

- **Right Alt** is the default jump key, matching Right ⌥. Caveat: on many European layouts Right Alt is **AltGr** and is used for typing characters like `@` and `€`. We only *listen* (never swallow the key), so typing still works, but the dino would jump while you type those characters. Proposal: default to Right Alt on US layouts, and offer **Right Ctrl** / **Pause** / **Scroll Lock** as alternatives in the tray menu.
- **Ctrl+Alt+Space** works without any hook, but tap-only (see the table).
- **Click the strip**: full hold-to-jump support, never takes focus.

## Risks and open questions

1. **Antivirus / SmartScreen.** A low-level keyboard hook is exactly what keyloggers use, so heuristic engines may flag an unsigned exe with one. Mitigations: hook only `VK_RMENU` and return immediately; sign the binary (an Authenticode certificate costs money, so it's worth deciding early); allow running hook-free (hot key + click only). Unsigned downloads also get a SmartScreen "unknown publisher" warning on first run.
2. **Swift runtime size and packaging.** The app needs to ship the Swift runtime DLLs next to the exe. Keeping the Windows shell free of Foundation (stdlib + `WinSDK` only) should keep this small. The phase-0 spike will measure the zip size.
3. **Elevated windows.** Because of UIPI, a normal-integrity hook doesn't see keys while an admin app (Task Manager, an elevated terminal) is focused. Acceptable: document it.
4. **Virtual desktops.** A plain window belongs to one virtual desktop. Showing on all desktops has no documented API. Need to test whether a topmost tool window follows the user, otherwise document it as a limitation.
5. **Taskbar quirks.** The Windows 11 taskbar is bottom-only, but Windows 10 lets it sit on any edge. v1 only supports bottom and falls back to the screen bottom otherwise. Taskbar icons are centred by default on Windows 11; a "match icons" width (like "Match Dock") would need UI Automation, so it's deferred.
6. **Topmost wars.** The taskbar is itself topmost. We sit *above* it (in the work area), so there's no overlap, but full-screen detection matters so the dino doesn't float over games and video.

## Plan

| Phase | What | Exit criteria | Rough size |
|---|---|---|---|
| **0. Spike** | Swift on Windows: a layered, click-through, no-activate window above the taskbar showing one PNG via WIC + `UpdateLayeredWindow`, a `WH_KEYBOARD_LL` Right-Alt jump, built in GitHub Actions on `windows-latest` | Runs on Win 10 + 11; packaged zip size known; Defender quiet | 1–2 days |
| **1. Core split** (no behaviour change) | SwiftPM package; `DockosaurCore` with `Image`/`Mask` structs, display list, synth, self-test; Mac shell consumes it | Mac app identical (snapshot diff), self-test green on macOS **and** Windows CI | 2–3 days |
| **2. Windows MVP** | Placement, compositor, input (hook + hot key + click), tray menu, settings, sound, frame pacing, pause on lock | Playable end to end on Windows 11 | 4–6 days |
| **3. Polish** | DPI changes, multi-monitor, Explorer restarts, auto-hide, full-screen hide, launch at login, AltGr-safe key options | Survives a day of real use | 2–3 days |
| **4. Ship** | `build.ps1` (mirror of `build.sh`), release zip with runtime DLLs, optional signing, README "Windows" section, `winget` manifest later | One-paste install prompt, like the Mac one | 1–2 days |

## Questions for review

1. **Approach**: OK with A (shared Swift core + Win32 shell), with B/Rust as the fallback if the spike fails?
2. **Repo layout**: OK to move to a SwiftPM package with `Sources/DockosaurCore`, `DockosaurMac`, `DockosaurWin`? `build.sh` would keep working for the Mac app.
3. **Default jump key on Windows**: Right Alt (AltGr caveat) or Right Ctrl?
4. **Code signing**: is a paid signing certificate on the table, or do we ship unsigned and document the SmartScreen step?
5. **Scope**: any Windows-only features wanted for v1 (e.g. "match taskbar icons" width)?

## References

- Swift on Windows install (Swift 6.4, `winget install Swift.Toolchain`, VS 2022 requirements): https://www.swift.org/install/windows/
- `SHAppBarMessage` / `ABM_GETTASKBARPOS`: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/nf-shellapi-shappbarmessage
- `LowLevelKeyboardProc` (timeouts, run on a dedicated thread, raw input alternative): https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc
- `QUERY_USER_NOTIFICATION_STATE`: https://learn.microsoft.com/en-us/windows/win32/api/shellapi/ne-shellapi-query_user_notification_state
- Chromium's full-screen detection on Windows (`fullscreen_win.cc`): https://chromium.googlesource.com/chromium/src/+/7a66b24/chrome/browser/fullscreen_win.cc
- Layered windows and `UpdateLayeredWindow`: https://learn.microsoft.com/en-us/windows/win32/winmsg/window-features#layered-windows
