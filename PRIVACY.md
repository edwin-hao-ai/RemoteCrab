# RemoteCrab — Privacy Policy

_Last updated: 2026-09-09_

RemoteCrab is a local-network utility that turns your iPhone or iPad into a
camera, microphone, trackpad and keyboard for your Mac. This page
describes what data the app handles and what it does **not** do.

## Summary

RemoteCrab is **local-first**. We do not run any servers. We do not
collect analytics. We do not require an account.

The only data the app handles is the live media and input stream
between your iPhone and your Mac, which flows over your local WiFi
network using Bonjour discovery and a direct TCP connection. **No
bytes ever leave your network.**

## What data flows between the iOS app and the Mac app

When you tap the streaming button in the iOS app, the following data
is sent to the Mac over your local WiFi:

| Stream | Format | Purpose |
|---|---|---|
| Camera | H.264 video (1080p, 30 fps) | Live preview on the Mac; virtual webcam when wired up |
| Microphone | PCM audio (48 kHz) | Streamed to Mac speakers (and virtual mic when wired up) |
| Touchpad | Touch coordinates + modifier flags | Drives the Mac cursor via `CGEventPost` |
| Keyboard | Key codes + UTF-8 text | Drives Mac input via `CGEventPost` |

All of this is encrypted only by your WiFi network's WPA2/WPA3
encryption. RemoteCrab itself adds no application-layer encryption (the
session is between two devices on the same trusted LAN).

## What RemoteCrab does **not** collect

- **No analytics** — no Firebase, no Mixpanel, no telemetry
- **No crash reporting** — the app does not phone home
- **No account** — no sign-up, no email, no user identifier
- **No remote server** — there is no RemoteCrab backend
- **No recording** — the app streams in real time only; nothing is
  saved to disk or cloud unless you do so explicitly through the
  receiving app (e.g. Zoom's "Record to cloud" toggle)

## Permissions requested by the iOS app

| Permission | Why we need it |
|---|---|
| **Camera** | Live iPhone feed to your Mac |
| **Microphone** | Live iPhone mic to your Mac |
| **Local Network** | Bonjour discovery of your Mac on the same WiFi |

You can revoke any of these at any time in **iOS Settings →
Privacy**. RemoteCrab will continue to work for the streams whose
permissions are still granted.

## Permissions requested by the Mac app

| Permission | Why we need it |
|---|---|
| **Accessibility** | Drive the Mac cursor + keyboard from your iPhone (`CGEventPost`) |
| **Microphone** (optional) | Future: when the virtual-microphone extension is enabled |
| **Camera** (optional) | Future: when the virtual-camera extension is enabled |

macOS will prompt for Accessibility on first launch with a clear
explanation. You can re-prompt anytime via **System Settings →
Privacy & Security → Accessibility**.

## Children

RemoteCrab is not directed to children under 13. We do not knowingly
collect any data from children. Because we do not collect any data at
all, this is largely moot.

## Changes to this policy

We may update this policy as the app evolves. Material changes will
be reflected by a new "Last updated" date at the top.

## Contact

If you have questions about this policy, contact us on GitHub at
[github.com/edwin-hao-ai/RemoteCrab](https://github.com/edwin-hao-ai/RemoteCrab).
