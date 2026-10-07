# Current computer — one iPhone, many computers, no fighting

Date: 2026-10-07
Status: spec for review
Related: `docs/superpowers/specs/2026-10-05-computer-presence-design.md`,
`docs/superpowers/specs/2026-10-05-phone-initiated-connection-design.md`,
`docs/superpowers/specs/2026-09-12-multi-mac-pairing-design.md`

## The problem, with evidence

A user with **two computers** (a Mac and a Windows PC) running RemoteCrab hits a
fight they cannot win. Observed on real hardware (2026-10-07):

- Both computers are TCP clients that **auto-dial and auto-retry** (Mac every 3 s;
  Windows similar).
- The phone is a passive server: **first-come wins**, the loser is answered
  `busy`, and the loser keeps retrying (Mac 15 s on `busy`, 5 s on `off`).
- Any release — the app relaunching, the phone's owner watchdog — starts a
  **race**, and the first computer to re-dial wins. In the observed run the
  Windows PC won repeatedly and the Mac was refused `busy owner=EDWIN` for
  minutes.
- The only way to choose is a buried "Choose a Computer" that arms a
  **temporary** preference (30 s grace, 10-minute TTL). When it lapses, the race
  resumes.

Root cause: **"which computer" is decided by a race, not by the user.** The phone
has no persisted notion of "this is my computer"; ownership lives only for the
life of a socket.

## Goals

1. The phone serves **one remembered computer** ("the current computer"), and it
   wins deterministically every time it dials.
2. A non-current computer **stands by** — it stops fighting and says what to do.
3. Switching is **one obvious tap on the phone**, connected in ~1 s.
4. Disconnect means **paused** — nobody grabs the phone until the user picks again.
5. The common case (one computer) is **zero-config**: nothing to learn.
6. Backward compatible: an older receiver degrades to today's slow poll; nothing
   breaks on the day this ships.

## Non-goals

- Role reversal (the phone dials the computer as the primary model). That is the
  eventual architecture (`phone-initiated-connection-design.md`) and is
  deliberately not required here; nothing in this spec forecloses it.
- Any change to the data-path wire protocol. **No new wire kind.**
- Encryption (TLS). Unrelated.
- Multiple phones.

## Architecture

The phone already has the two ingredients this needs, used ephemerally:

- **a preference** (`MacPairingStore.preferred`, armed by the picker), and
- **a knock channel** (receivers listen on the fixed port `IBServiceType.knockPort`
  = 8766; the phone dials it once and the receiver dials back — `knockComputer`).

This spec makes the choice **persistent** and makes a non-current computer
**stand by** instead of retrying.

### 1. Persist "the current computer" on the phone

`MacPairingStore` gains `currentId: String?` / `currentName: String?`
(additive, defaulted — AGENTS rule 2; a build without the key reads `nil`).

- Set on **first approval** of a computer (TOFU) — so a single-computer user
  gets it with no action.
- Set when an armed `preferred` is **granted** (the user tapped it).
- Cleared by **Forget** of that computer, and by an explicit "use any computer"
  reset (a picker action, see UI).

`preferred` keeps its meaning (a switch the user just asked for) but becomes the
**override**; once granted it is promoted to `current`.

### 2. `PairingPolicy.decide` prefers the current computer

Add a `current: PairedMac?` parameter (or id/name). Order:

1. `disconnected` (the user paused this computer) → `.off`.
2. `current == hello.id` **or** `preferred == hello.id` → `.accept` (then the
   normal peer-auth challenge runs — see `HANDOFF-IOS-PEER-AUTH.md`).
3. otherwise → `.busy(ownerName: current?.name ?? ...)`.

Note this **also closes an accidental-hijack path**: a stranger dialing while a
current computer exists now gets `busy`, not an approval card. To pair a *new*
computer the user picks it on the phone (arming `preferred`), which is the only
way it can reach the approval step.

`PairingDecision` is unchanged (`busy` already means "someone else has it"); no
new enum case, no new wire result.

### 3. Receivers stand by on `busy` / `off`

Both receivers already stop the fast loop on `busy`/`off` and schedule a slow
retry. Change:

- On `busy` (a non-current computer): **stand by** — stop retrying, keep only a
  **60 s safety-net** re-dial, and show a status that names the situation and the
  action. **The shipped copy is `IBLocale.Error.iphoneBusy`** — *"This iPhone is
  being used by <X> — pick this computer in the iPhone's Choose a Computer list.
  Retry on its own will keep failing."* (an earlier draft here said *"This iPhone
  is set to <X>…"*; that was **not adopted**, because the shipped line is pinned
  by `testTheBusyMessageSaysWhereTheActionLives` and names both the action and
  why Retry fails). The knock (`retryNow`) still dials immediately and is the
  fast path.
- On `off` (the user paused this computer): same standby, no auto-resume.

The 60 s safety net exists because "standby" is otherwise only escapable by a
knock, and a knock needs presence/Bonjour to be reachable. If Bonjour is blocked
(VPN / client isolation / hotspot), the safety net is what stops a computer from
being stranded forever. It is not "fighting": the phone deterministically
answers `busy`, so the poll costs one refused dial per minute and never steals
the session.

### 4. Switching = tap → arm → knock → promote

The picker row tap already calls `setPreferredComputer(id:)` (arm `preferred` +
drop owner + `knockComputer`). Add: when the chosen computer is granted,
`CaptureEngine.grant` promotes `preferred` to persistent `current` (and clears
`preferred`). No new UI mechanics; the existing flow just becomes sticky.

### 5. Disconnect = pause

`disconnectCurrentMac()` keeps `current` set but marks it `disconnected`
(existing `off` semantics) and closes the socket. While paused, **every**
computer — including the current one — is answered `off`/`busy`, so nothing
reconnects on its own. The user resumes by tapping a computer in the picker
(arming `preferred`, which clears the pause for that computer). This is the fix
for "断开又自动连上": the phone holds the door rather than letting a retry loop
walk back in.

## Data flow

```
first run, one computer
  computer ──dial──▶ phone: no current → pending → user Allow
                                            └─▶ current = this computer (persisted)

second computer appears
  PC ──dial──▶ phone: not current → busy("<current>") ──▶ PC stands by (60 s safety net)

user switches on the phone
  picker tap ──▶ preferred = PC + knock(PC) ──▶ PC dials
  phone: preferred == PC → accept (peer-auth challenge) ──▶ current = PC (persisted)
  Mac (now non-current): next dial → busy → stands by

phone app relaunches (owner cleared, current persists)
  both dial ──▶ phone accepts current, busy the other   ← deterministic, no race
```

## Components

### Core (`RemoteCrabCore`) — pure, testable

- `MacPairingStore`: `currentId` / `currentName` persisted; `setCurrent`,
  `clearCurrent`; cleared by `forget(id)` when it matches.
- `PairingPolicy.decide`: new `current` input; the ordering above.
- Tests: current wins over a stranger; `preferred` overrides current; stranger
  gets `busy(current.name)`; no-current → first-come; forget clears current;
  old blob without the key loads (rule 2).

### iOS (`RemoteCrabCapture`)

- `CaptureEngine.grant`: promote granted `preferred` → `current`.
- `disconnectCurrentMac`: keep `current`, set paused.
- `ComputerPickerView`: mark the current computer clearly ("This iPhone"), and
  make the switch affordance the obvious action. Add a **"Release this iPhone"**
  row that clears `current` (back to first-come) — the escape hatch for "I want
  whichever computer, not a fixed one".
- Copy: honest, action-bearing strings (AGENTS rule 1) for "current", "in use by
  X", and "paused".

### Mac (`RemoteCrabReceiver`)

- `ReceiverSession`: `busy`/`off` → standby (stop loop; 60 s safety net; knock
  dials immediately); status line says what happened and what to do.

### Windows (`rc-net` / `rc-app`)

- Same standby behavior and copy; handed off with a test plan (cross-side rule —
  cannot be built/verified from macOS).

## Edge cases

- **Current computer off/asleep:** phone shows "waiting for <name>"; others stay
  quiet; the user can re-pick any online computer.
- **Current computer forgotten or reinstalled (new id):** Forget clears
  `current`; a reinstall leaves a stale id, so the picker lets the user pick the
  new row (and the roster's id-dedupe already handles the old one).
- **No current yet (fresh install):** first-come → approval → becomes current.
- **Two computers dial simultaneously at relaunch:** deterministic — the phone
  compares ids, not arrival order.
- **Older receiver:** no standby understanding → keeps its 15 s poll; slow but
  never wrong.
- **Bonjour blocked:** the 60 s safety net re-dials; presence-dependent knock is
  the fast path only.
- **Two phones:** independent.

## Error handling / honesty

Every non-working state is a sentence with a next step (AGENTS rule 1): a
non-current computer does not show a bare "searching" — it says the phone is set
to another computer and that tapping it on the phone switches. A paused phone
says it is paused.

## Testing

- **Core (pure):** `PairingPolicy` ordering and `MacPairingStore` persistence +
  migration (previous blob loads, nothing lost).
- **Mac:** a `busy` reply stops the loop and schedules the safety net; a knock
  dials immediately; `off` does not auto-resume.
- **Windows:** mirrored supervisor test (handoff).
- **Device e2e (rule 5):** two computers — pair one, confirm the other stands by
  and shows the honest line; switch on the phone → connected < 2 s; Disconnect →
  stays disconnected; relaunch the phone app → the current computer reconnects
  and the other stays quiet.

## Rollout / risk

Additive and backward compatible. The new `current` field defaults to nil, so an
updated phone behaves like today until a computer is approved (then it becomes
current — the intended single-computer path). Older receivers keep their poll.
The only behavioral change users notice is the intended one: no more fighting.

## Decisions already made (change any)

- Reuse `busy` for "not current" rather than a new `standby` wire result
  (old-receiver safety).
- Non-current = stand by with a **60 s** safety-net re-dial, not a hard stop.
- Disconnect = **pause**; only the user resumes.
- The current computer is **per phone**, persisted on the phone.
- No new wire kind; no data-path change.
