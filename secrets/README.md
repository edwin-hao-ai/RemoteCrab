# secrets/

Release credentials. Tracked by an explicit decision (2026-09-16) — **this
repository must stay private.** If it is ever published or forked publicly,
rotate everything in here.

| File | What it is | What it can do |
|---|---|---|
| `windows-update-signing.pem` | Ed25519 private key | **Sign a Windows update that every install will accept and run.** |
| `windows-update-signing.pub.pem` | The matching public key, for reference | — |

## The Windows update key

The app pins the public key in its binary (`rc-app/src/updater.rs`,
`UPDATE_PUBLIC_KEY`) and refuses any MSI whose Ed25519 signature does not verify
against it. So:

- **Signing happens only at release time**, in `scripts/release-windows.sh`,
  with `openssl` — the private key is never compiled into anything and never
  needs to be on a machine that merely builds.
- **Whoever holds this file can push code to every Windows install.** It is the
  highest-value secret in the repository, above the VPS credentials: the VPS can
  be rebuilt, but a malicious update signed with this key is indistinguishable
  from a real one and runs as administrator.
- **If it leaks**: rotate by shipping a build that trusts *both* keys, wait for
  installs to move, then drop the old one. A build that only knows a new key
  cannot verify anything signed by the old one, so the two-key overlap is not
  optional.
- **Do not** put this in CI as a secret variable unless the CI is trusted to the
  same degree. Prefer signing on a machine the operator controls.

The public key, for comparison against the constant in `updater.rs`:

```
029565b90e7052a0f5837a40ec89052cda91c2ae3511704743440bbf333da40c
```

Rotating `UPDATE_PUBLIC_KEY` in the source without updating this file (or the
other way round) produces a build that refuses every update it is offered, with
`the update is not signed by this build's key` — which is the correct failure,
just a slow one to diagnose from the symptom "it never updates".
