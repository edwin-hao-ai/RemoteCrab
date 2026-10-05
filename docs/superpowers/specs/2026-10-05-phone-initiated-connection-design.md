# Phone-initiated connection (make "tap a computer" instant and reliable)

Date: 2026-10-05
Status: spec for review
Related: `docs/superpowers/specs/2026-10-05-computer-presence-design.md`,
`docs/superpowers/specs/2026-09-12-multi-mac-pairing-design.md`

## The problem, with evidence

Every connection symptom the user hit has one shape: **the phone is only ever
the TCP server, so it cannot start a connection.** The computer must dial, so:

- "tap a computer to connect" waits for that computer's retry loop (measured
  latency = the Mac's poll — currently 5 s after an `off`, 15 s after `busy`);
- "Disconnect" is undone by the computer's own reconnect loop unless the phone
  actively refuses every dial (the `off` reply — which works, but only because
  it is a refusal, not a close);
- when the phone backgrounds/locks, iOS can suspend the listener and the
  computer sees `Connection reset by peer` (device log 17:55:46, 17:56:03), and
  the whole reconnect depends on the phone's lifecycle.

Presence (`_remotecrab-computer._tcp`) already tells the phone which computers
are **online**; it does not give the phone a way to reach them.

## Goal

Tapping an online computer connects **immediately and deterministically**, and
disconnect means disconnect, with no dependence on the computer's retry poll or
on the phone's listener lifecycle.

## Non-goal

Replacing the phone-as-server model for the normal flow. The phone stays the
authority for pairing; this only adds the phone's ability to **open** the
socket.

## Approach: the socket initiator is independent of the protocol role

Today the computer both **opens** the TCP socket and **sends `clientHello`**;
the phone accepts and replies `sessionReply`. Those are two separate facts that
were accidentally coupled.

The fix decouples them:

- **Either side may open the socket.**
- **The computer always sends `clientHello`** (it owns the identity and token)
  and the **phone always replies `sessionReply`** (it owns the policy) — no
  matter who dialed.

So "the phone dials the computer" = the phone opens `NWConnection` to the
computer's advertised endpoint, then the computer — now the one **receiving** —
sends its `clientHello` on that connection, and the phone answers with the same
`PairingPolicy.decide` it uses today.

This means:

- **Tap to connect is instant**: the phone opens the socket.
- **Disconnect sticks**: the phone closes; the computer is the server, it waits
  for the next inbound connection and does not redial.
- **No polling**, so no "searching for 30 s".

## Components

### Presence TXT gains a `port` (both receivers)

The computer's presence advertisement already exists. Add:

| key | value |
|---|---|
| `port` | the TCP port the receiver listens on for inbound phone connections |

Additive: a phone that does not read `port` ignores it; a computer that does not
advertise it is simply not phone-dialable (the phone falls back to today's
"arm preferred + wait").

### Receiver: accept inbound connections and run the normal handshake

Each receiver already has an `NWListener` (the presence advertiser). It now
**accepts** inbound connections instead of cancelling them:

1. On accept, send `clientHello` (id/name/token/platform) — the same frame it
   sends on an outbound dial.
2. Await `sessionReply`; on `accepted`, become the streaming sender exactly as
   today; on `pending`, wait for approval as today; on `busy`/`off`/`denied`,
   close and do **not** auto-retry (the phone either owns the session elsewhere
   or asked for off — in both cases redialing is wrong).

The receiver keeps its **outbound** dial path too (auto-connect to a paired
phone, and the direct-IP fallback) for compatibility with phones that have not
updated.

### Phone: dial a chosen computer

`CaptureEngine.connect(toComputer:)`:

1. Open `NWConnection` to the computer's advertised `host:port` (from the
   presence resolve).
2. Register it as the candidate and run the **existing** `readHello` →
   `handleHello` → `sessionReply` path (the phone is still the policy side).
3. The picker's tap calls this instead of only arming a preference. Arming a
   preference stays as the fallback for a computer with no advertised `port`.

`disconnectCurrentMac()` unchanged: it closes the socket and records the `off`
state; with the computer no longer redialing, that state is now belt-and-braces.
The `off` reply is still sent if the computer dials anyway (older receiver).

### Resolve: how the phone learns host\:port

`NWBrowser` results are service endpoints; the address/port come from resolving.
Two options:

- **A. `port` in TXT (chosen).** The phone reads `port` from the browse result
  (`.bonjourWithTXTRecord`, already in use) and dials `service host + port`. The
  service host is the `.local.` name from the endpoint; `NWConnection` resolves
  it. Simple, no extra resolve round-trip.
- B. Resolve the service (`NWConnection` to the service endpoint) and read the
  resolved port. More moving parts; only if the TXT `port` proves unreliable.

### Windows parity

`rc-discovery::advertise` already publishes the TXT; add `port`. `rc-app`'s
existing listener (`rc-net` accept path) handles the inbound `clientHello`
handshake. This is Windows runtime work, so it is **handed off with a test
plan**, not implemented blind from the Mac (AGENTS cross-side rule).

## Data flow (new)

```
tap ComputerPicker row
      │
      ▼
CaptureEngine.connect(toComputer:)  ──opens NWConnection──▶  computer host:port
                                                                    │
                          computer (now the receiver) sends clientHello
                                                                    │
      phone: readHello → handleHello → PairingPolicy.decide ◀───────┘
      │
      ├─ accepted → sessionReply(accepted) → streaming (as today)
      ├─ pending  → sessionReply(pending)  → approval card (as today)
      └─ busy/off → sessionReply(...)        → close
```

## Edge cases

- **Computer advertises no `port`** (older build): phone falls back to
  "arm preferred + wait for its dial", exactly today's behaviour.
- **Two computers, one chosen**: the phone dials the chosen one; the other, if
  paired, is answered `busy` on its own dial.
- **Phone backgrounds mid-dial**: the dial fails; the connection is retried on
  foreground. No listener to suspend matters here — the phone is the client.
- **Both sides dial at once** (phone dials while the computer's auto-connect
  also dials): the phone's `handleHello` already arbitrates a second computer /
  same computer; the loser is told `busy`. Must be tested explicitly.
- **Security**: an inbound connection to a receiver triggers `clientHello`; the
  phone still gates with `PairingPolicy` (token/pending). A stranger dialing a
  computer gets the computer's clientHello and sends it to... the phone? No —
  the computer only sends clientHello to the phone (the phone is the only
  peer). An arbitrary LAN host connecting to the receiver's port would receive
  a clientHello; the receiver must require the phone's `sessionReply` before
  streaming, and must not emit any stream data until `accepted`. Same as
  today's outbound handshake.

## Testing

- **Core (pure)**: no change needed to `PairingPolicy`; add a test that the
  phone deciding on a `clientHello` it received on an *outbound* connection
  takes the same path (a seam type, not network).
- **Bonjour/TCP e2e**: a test receiver advertises `port`, a client dials it,
  receives `clientHello`, replies `sessionReply accepted`, and a frame flows.
- **Device e2e (rule 5)**: on iPhone + Mac, tap an online Mac → connected in
  < 1 s; tap Disconnect → stays disconnected; tap again → connected again.
  Repeat with the phone backgrounded at tap time.

## Rollout / risk

Additive and backward compatible: the new `port` TXT is ignored by old phones;
old receivers simply are not phone-dialable and fall back to the current
behaviour. The receiver's inbound path is new code but reuses the existing
`clientHello`/`sessionReply` state machine.

## Decisions already made (change any)

- `port` travels in the presence TXT (not a separate resolve).
- The phone dials; the computer still sends `clientHello` (roles unchanged,
  socket initiator decoupled).
