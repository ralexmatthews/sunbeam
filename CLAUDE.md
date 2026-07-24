# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

**SunBeam** is a small macOS SwiftUI single-window app that sets the RGB lighting on a **Razer Basilisk V3 Pro** mouse (static color, spectrum, breathing, off, plus brightness). It talks to the mouse directly over IOKit HID — no kernel extension, no root, no OpenRazer daemon. The wire protocol was reverse-derived from the OpenRazer Linux driver.

## Build & run

```sh
open SunBeam.xcodeproj                                    # develop in Xcode; Cmd+R to run
xcodebuild -scheme SunBeam -configuration Debug build     # command-line build
```

There is a single target and scheme (`SunBeam`), Debug/Release configurations, and **no test target** — nothing to run for tests yet. If you add one, `RazerProtocol.swift` is pure data and is the natural first thing to unit-test.

## Runtime requirements (read before assuming a bug)

- **Input Monitoring permission.** Even though we only open the *vendor* control interface, the mouse advertises keyboard/mouse usage pages, so `IOHIDDeviceOpen` triggers the Input Monitoring TCC prompt (System Settings ▸ Privacy & Security ▸ Input Monitoring). The user must grant it **and relaunch** the app. A fresh build hitting this prompt is expected, not a defect. (TCC is keyed to the bundle id `ralexmatthews.SunBeam`; changing the id forces a re-grant.)
- **Hardware.** Only the Basilisk V3 Pro is recognized: VID `0x1532`, PID `0x00AB` (HyperSpeed dongle) or `0x00AA` (wired). If no matching device appears within ~2s of launch the UI says so.
- **Sandbox.** App-sandboxed with `com.apple.security.device.usb` (see `SunBeam/SunBeam.entitlements`) plus hardened runtime. That combination is sufficient — the sandbox does **not** need disabling.

## Architecture

Four files, layered so that app shell, UI, device I/O, and protocol are independently understandable:

- **`RazerProtocol.swift`** — pure data, no IOKit. `RazerReport` builds Razer's fixed **90-byte** feature-report packet (XOR checksum over bytes `2...87`, transaction id `0x1F`). Factory methods (`staticColor`, `spectrum`, `breathing`, `off`, `brightness`) encode the command arguments. `RazerIDs` and `RazerMode` also live here. Writes use `VARSTORE`, so the mouse persists the effect across quit/power-cycle.
- **`RazerController.swift`** — two types:
  - `RazerController`: `@Observable` MainActor view-model SwiftUI binds to (`isConnected`, `statusText`, `lastError`). A thin republishing surface.
  - `RazerDeviceLink`: **all** IOKit work. Owns the `IOHIDManager`, opens every vendor control interface via device-added/removed callbacks on the main run loop, and sends reports on a background dispatch queue. It keeps the set of currently-present control interfaces (`controls`) and `updateActiveDevice()` derives the active `device` from it, preferring the wired interface — so the status re-checks on hot-plug (unplugging the cable falls back to the dongle without a relaunch).
- **`ContentView.swift`** — the UI (effect picker, color picker + hex/RGB text field, brightness slider, Apply button) plus the `Color` ⇄ hex/`rgbBytes` helpers and the `Color.hex(fromUserInput:)` parser. State is `@AppStorage`-persisted so the window reopens with the last values. Edits are **staged only** — nothing is sent to the mouse until **Apply** is pressed; the app never re-applies on launch (the mouse already remembers via VARSTORE).
- **`SunBeamApp.swift`** — the `@main` entry. Owns the single `RazerController` and configures the window: `.windowStyle(.hiddenTitleBar)` (no title bar or divider; the traffic-light buttons float over the content, which is why `ContentView` carries an extra top inset) and `.windowResizability(.contentSize)` (the window is exactly the content size). An `AppDelegate` returns `applicationShouldTerminateAfterLastWindowClosed == true`, so closing the single window quits the app.

Data flow: `ContentView` edits stage `@AppStorage` values → **Apply** → `applyCurrent()` → `controller.apply(...)` → `link.apply(DesiredState)`.

### Key mechanisms to preserve when editing

- **`SWIFT_DEFAULT_ACTOR_ISOLATION = MainActor`.** The whole project is MainActor-isolated by default. That is why `RazerDeviceLink` and the `RazerProtocol` types are explicitly marked `nonisolated` — their background-queue send loop and main-run-loop HID callbacks must not be forced onto the main actor. New IOKit-touching code needs the same treatment.
- **Identifying the control interface.** The mouse/dongle exposes several HID interfaces; the vendor control one is the *only* one whose `kIOHIDMaxFeatureReportSizeKey == 90`. `deviceAdded` ignores everything else. Don't match on interface number.
- **Coalescing.** `apply()` stores a single `pending` `DesiredState` and a background `drain()` loop always sends the newest, dropping intermediates. This keeps color-wheel drags and slider ticks from queueing hundreds of reports — keep applies idempotent and cheap.
- **Send/ack timing.** `send()` writes with `IOHIDDeviceSetReport`, sleeps ~31ms, then reads the reply; status `0x01` means "busy" and is retried once. A missing/unreadable GetReport response is treated as success (some dongle firmware doesn't reply). Don't tighten these sleeps without hardware testing.
- **Locking.** `RazerDeviceLink` guards `device`/`controls`/`pending`/`draining`/`connected`/`label` with a single `NSLock`; state changes are pushed to the UI via `stateHandler` on the main queue.

## Adding lighting features

New effects/settings are usually two edits: a `RazerReport` factory in `RazerProtocol.swift` (argument bytes come from OpenRazer's `razerchromacommon.c` / `razermouse_driver.c`), wired into `RazerDeviceLink.reports(for:)` and surfaced in `ContentView`. New transports (DPI, polling rate, per-zone color) reuse the same `send()` path.
