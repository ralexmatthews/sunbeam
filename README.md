# SunBeam

A small macOS utility app for controlling the RGB lighting on a **Razer Basilisk V3 Pro** mouse — set a static color, spectrum cycle, breathing, or turn it off, plus brightness.

It talks to the mouse **directly over IOKit HID**: no kernel extension, no root, and no OpenRazer daemon. The wire protocol was reverse-derived from the [OpenRazer](https://github.com/openrazer/openrazer) Linux driver. Effects are written to the mouse's onboard memory (`VARSTORE`), so a chosen effect **persists** across quitting the app and power-cycling the mouse.

## Features

- **Effects:** Static, Spectrum, Breathing, Off
- **Color:** pick from the macOS color wheel **or** type a value into the text field — accepts hex (`#FF0000`, `FF0000`, shorthand `F00`) or RGB (`255,0,0`, `255 0 0`, `rgb(0, 128, 255)`). The two stay in sync.
- **Brightness** slider
- **Apply button** — edits are staged and only sent to the mouse when you press **Apply**
- **Live connection status** — shows whether the mouse is reached wired or over the HyperSpeed dongle, and updates on hot-plug (unplug the cable and it falls back to wireless without a relaunch)
- Settings you pick are remembered between launches; the mouse itself remembers the active effect

## Requirements

- **macOS 26.5 or later** (the project's deployment target)
- **Xcode** (to build — there is no prebuilt release)
- A **Razer Basilisk V3 Pro**, connected either:
  - over the **HyperSpeed USB dongle** — VID `0x1532`, PID `0x00AB`, or
  - **wired / charging cable** — PID `0x00AA`

Only the Basilisk V3 Pro is recognized. Other Razer devices use different product IDs and command arguments and won't match.

## Building & running

```sh
open SunBeam.xcodeproj          # then press Cmd+R in Xcode
# or, from the command line:
xcodebuild -scheme SunBeam -configuration Debug build
```

There is a single target and scheme (`SunBeam`), Debug/Release configurations, and no tests. When building for the first time you may need to select your own **Development Team** under _Signing & Capabilities_ (the app uses a hardened runtime and is sandboxed with the USB device entitlement).

## Granting permission (important)

On first launch the app will ask for **Input Monitoring** permission:

> System Settings ▸ Privacy & Security ▸ Input Monitoring

Grant it to SunBeam and **relaunch the app**. This prompt is expected, not a bug — even though SunBeam only opens the mouse's _vendor control_ interface, the device advertises keyboard/mouse usage pages, so opening it trips the Input Monitoring gate. Until it's granted, the app can see the mouse but can't send it commands.

> The permission is tied to the app's identity (`ralexmatthews.SunBeam`), so if the bundle identifier changes you'll be prompted to grant it again.

## Usage

1. Launch SunBeam. The top of the window shows the connection status.
2. Pick an **effect**. For Static/Breathing, choose a **color** (wheel or text field). Adjust **brightness**.
3. Press **Apply** to send the settings to the mouse.
4. Closing the window quits the app.

If the status reads _"No Razer mouse found — plug in the dongle,"_ connect the dongle or cable; the app watches for it continuously.

## Distribution

1. Product → Archive → Distribute App → Custom → Direct Distribution
2. Xcode signs with Developer ID, uploads for notarization, and waits. When it's done, hit Export — you get a notarized .app
3. `ditto -c -k --sequesterRsrc --keepParent SunBeam.app SunBeam-X.Y.zip`
4. `gh release create vX.Y SunBeam-X.Y.zip --title "vX.Y" --notes "some notes"`

## How it works

The code is organized into four small, independently understandable files:

| File                    | Responsibility                                                                                                                                                                                             |
| ----------------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `RazerProtocol.swift`   | Pure data. Builds Razer's fixed 90-byte HID feature-report packet (XOR checksum, transaction id `0x1F`) and the per-effect command arguments. No IOKit.                                                    |
| `RazerController.swift` | All IOKit work — owns the `IOHIDManager`, opens the vendor control interface, tracks wired/wireless links, and serializes reports on a background queue. Exposes a small observable view-model to SwiftUI. |
| `ContentView.swift`     | The UI (effect picker, color picker + hex/RGB field, brightness, Apply) and the color parsing/formatting helpers.                                                                                          |
| `SunBeamApp.swift`      | The `@main` app shell — single content-sized window with a hidden title bar, and quit-on-last-window-closed.                                                                                               |

The vendor control interface is identified as the one HID interface whose maximum feature-report size is exactly 90 bytes. Rapid changes (color-wheel drags, slider ticks) are coalesced so only the newest state is sent.

## Credits

The Basilisk V3 Pro lighting protocol — packet layout and per-effect command arguments — was derived from the [OpenRazer](https://github.com/openrazer/openrazer) project (`razerchromacommon.c` / `razermouse_driver.c`). SunBeam reimplements just the pieces it needs, directly against macOS IOKit.

## Disclaimer

Not affiliated with or endorsed by Razer Inc. "Razer" and "Basilisk" are trademarks of their respective owner. Use at your own risk.
