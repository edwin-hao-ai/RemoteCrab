# Computer presence + a real "choose computer" experience

Date: 2026-10-05
Status: approved approach (B), spec for review
Related: `docs/superpowers/specs/2026-09-12-multi-mac-pairing-design.md`,
`docs/superpowers/specs/2026-09-29-windows-connection-reliability-design.md`

## The problem, with evidence

The iPhone's "choose computer" sheet lists `MacPairingStore.seenComputers` —
every computer the phone has **ever** been paired with or seen, including ones
that are unplugged and asleep. There is no way to tell which are actually on,
and tapping one does not connect: it arms a preference and the phone waits for
that computer to dial back, which never happens if the computer is off.

The root cause is architectural, not cosmetic. **Today only the iPhone
advertises Bonjour.** It is the TCP server (it must be: the iPhone is the
reliable rendezvous point on a home LAN), and both receivers only *browse* for
it:

- `RemoteCrabCapture/CaptureEngine.swift` publishes `_remotecrab._tcp`
  (`NWListener`).
- `RemoteCrabReceiver/BonjourBrowser.swift` browses `_remotecrab._tcp`.
- `windows/crates/rc-discovery/src/lib.rs` browses `_remotecrab._tcp.local.`.

So the phone has no signal at all about which computers exist right now.
`AGENTS.md` calls the fix an architecture change (iOS-side browser + persisted
targets) and budgets 2–3 days.

User report (2026-10-05): "会显示一堆已经连接的电脑…哪台电脑在线完全不知道…
点击一下就能连接…经常连不上，也不知道什么原因…连接电脑这个体验太差了。"

## Goals

1. The picker shows **which computers are online right now**, Mac and Windows,
   and which are known-but-offline (with when they were last seen).
2. Tapping an **online** computer connects to it within ~1 s.
3. When it does not connect, the row says **what happened and what to do**
   (AGENTS rule 1) — not a bare spinner.
4. The picker and the connection/waiting states look intentional and use the
   RemoteCrab mascot, not a stock spinner.

## Non-goals

- Full role reversal (the phone dialing the computer). That is approach A,
  deliberately deferred; nothing here forecloses it.
- Showing *other iPhones*.
- Any change to the data-path wire protocol.

## Architecture (approach B: computers announce, phone browses)

The phone stays the TCP server. Each receiver additionally **announces its own
presence** on a **second, distinct** Bonjour service so the phone can browse
computers without confusing them with iPhones.

**Service type: `_remotecrab-computer._tcp`.** It must NOT reuse
`_remotecrab._tcp`: the Mac browses that type for iPhones, and reusing it would
make every Mac see itself and every other computer as an iPhone to dial
(lesson-class: a discovery result is not a promise about what it is).

TXT record fields (all non-sensitive; no token, no id used for auth):

| key | value | notes |
|---|---|---|
| `id` | stable machine id | same value the receiver already sends in `clientHello` (`macId` / Windows `pc_id`) |
| `name` | display name | user-visible |
| `platform` | `macos` \| `windows` | for the row's OS icon |

The announcement lives only while the receiver process is running and able to
accept a session; quitting the receiver removes it (Bonjour goodbye / TTL).
Nothing about a stopped computer is announced — that is the whole point.

The phone only **browses**; it still accepts the eventual TCP connection from
the chosen computer exactly as today. Tapping an online computer arms the
existing `preferred` mechanism and drops the current owner; because the
computer is announcing, it is running and its reconnect loop dials the phone
within ~1 s. No new wire kind, no change to pairing or `PairingPolicy`.

### Why this is enough for "tap to connect"

The user's requirement is "点一下能连上", not "the phone opens the socket".
With presence, the phone knows the chosen computer is alive, so the existing
preference mechanism resolves in about one reconnect interval instead of
waiting for a machine that may be off. The common failure the user hit —
tapping a computer that is not running and getting a silent wait — becomes
either an immediate "offline, last seen …" row or a fast, successful connect.

## Components

### Core (`RemoteCrabCore`) — pure, testable

- `ComputerPresence` (`State/`): `id`, `name`, `platform`, `lastSeen`.
  `Codable, Sendable, Equatable, Identifiable`.
- `ComputerRoster` (pure policy): merges the live browse results with
  `seenComputers` into the rows the UI renders.
  - Dedupe by **id**, never by name (lesson 135: two computers sharing a
    hostname must not collapse).
  - Live announcement wins over history for the same id.
  - Order: online first, then most-recently-seen offline.
  - `state(for:) -> .online | .offline(lastSeen:)` — the only place "online"
    is decided, so it can be tested without a network.
  - An announcement gone from the browser results is `offline`, not deleted:
    history stays.
- `IBServiceType.computer = "_remotecrab-computer._tcp"` (alongside `.tcp`).

### Mac (`RemoteCrabReceiver`)

- `PresenceAdvertiser`: publishes `_remotecrab-computer._tcp` with the TXT
  record above, using `NWListener` on a dynamic port — the same Network-
  framework path the iOS publisher already uses, so there is one pattern. It
  accepts and immediately cancels any connection (this is an announcement, not
  a service). Started with the receiver, stopped on quit. A failure to
  advertise is logged and never blocks a session.

### Windows (`rc-discovery`)

- `advertise(service_type, id, name, platform)` using `ServiceDaemon::register`,
  paired with an `unregister` on shutdown. Same TXT keys, byte-for-byte, as the
  Mac — the phone parses one format.

### iOS (`RemoteCrabCapture`)

- `ComputerBrowser`: a second `NWBrowser` for `_remotecrab-computer._tcp`
  inside `CaptureEngine` (the existing listener is untouched). Publishes
  `onlineComputers: [ComputerPresence]` (`@Published`, MainActor).
  - Runs while the app is foregrounded and the picker can be opened; the local
    network permission is already required and already requested.
  - Losing an announcement moves that id to offline, does not remove history.
- Filter: never show the phone's own advertisement (there is none, but guard by
  `id != self.id` defensively).

### UI (`MacPickerView` → `ComputerPickerView`)

- One list, two groups: **Online** (green dot, OS icon) then **Offline**
  (grey, "last seen …"). The armed `preferred` and the current session stay as
  their own banners at the top, unchanged.
- Tap online → arm preference + drop owner, with a `CrabLoading` "connecting
  to <name>…" state.
- Tap offline → still allowed (it will connect when it returns), but the row
  says so.
- Every non-working state is a sentence with a next step, reusing the existing
  `preferredOutcome` reasons (denied / busy / waitingApproval) plus the new
  `offline(lastSeen:)` and `onlineButNotDialedYet`.

### Loading states

`CrabMascot` / `CrabLoading` already exist (`Components/CrabMascot.swift`) but
are barely used — most waits render a stock `ProgressView`. This work:
- Uses `CrabLoading` for the picker's connect/wait states and the connection
  pill's "connecting" state.
- Adds a small **inline** crab variant (claw snap, no bob) for tight rows.
- Audits the remaining `ProgressView` sites and replaces the ones that are
  user-facing waits (not, e.g., a determinate progress bar).

## Data flow

```
Mac/Windows receiver  ──announce──▶  _remotecrab-computer._tcp
                                            │ bonjour
iPhone NWBrowser ──▶ onlineComputers ──┐
                                       ├─▶ ComputerRoster ──▶ ComputerPickerView
seenComputers (persisted history) ─────┘                         │ tap
                                                                 ▼
                                              MacPairingStore.setPreferred(id)
                                              drop current owner
                                                                 │
                       chosen computer's reconnect loop dials ───┘  ~1 s
```

## Edge cases

- **Same name, different id**: kept separate (dedupe by id).
- **Receiver restarts with a new id** (Windows reinstall): the roster shows two
  rows until history pruning (already in `pruneSeenComputers`) collapses them;
  presence itself is id-keyed and honest.
- **Announcement stale/lost**: TTL/browse-removed → offline; never a crash.
- **Two phones**: not addressed; each phone browses independently.
- **Multicast blocked** (hotspot/VPN): the receiver's direct-dial path and the
  phone's current manual-IP fallback still exist; presence simply shows fewer
  online rows. This is honest, not a new failure.

## Privacy / security

- TXT carries id, name, platform only — the same identity already broadcast in
  the handshake and already visible to anyone on the LAN.
- No new wire kind, no new permission. The local-network permission the phone
  already requests covers browsing.

## Testing

- `ComputerRoster` unit tests: dedupe by id (not name), live beats history,
  online-first ordering, offline lastSeen, empty both.
- mDNS end-to-end: advertise `_remotecrab-computer._tcp` and assert a browser
  finds it with the right TXT (mirrors `BonjourEndToEndTests`).
- Windows: `rc-discovery` register→browse round-trip test (host-buildable).
- Device e2e: Mac announces, phone shows it online; quit the Mac, phone shows
  it offline; relaunch, online again. Windows validated by the Windows session
  against the shared TXT contract.
- UI: a screenshot pass of the picker (online + offline) and the crab loading.

## Decisions already made (change any of these)

- Service type `_remotecrab-computer._tcp`.
- The crab loading **reuses the existing `CrabMascot`** (already the icon
  character), not a new drawing.

## Rollout / risk

Additive: a receiver that does not advertise simply never appears "online", the
phone still lists it from history and the preference mechanism still works
exactly as before. An older phone ignores the new service type entirely.
