# Declared core-hosted endpoints — 2026-10-08

Baseline: `6557dcea`, clean `master`. Remediation worktree:
`wireplumber-core-endpoints`, branch `codex/core-owned-endpoints-20261008`.

## PH5-H004 — discovery excludes server-hosted SPA nodes

Severity P1; confidence high; confirmed by an installed registry snapshot and
one-shot cold startup markers. The Classic HEART bridge invocation
`ad8ecf4c3e9c4f2289e482d6c0bd422a` reached source preparation completion and
connection discovery, but never discovery completion. All four declared ports
were present. Both HEART SPA nodes lacked `client.id`; `connections.node`
returned nil because it required a Client for every node.

Affected code: `src/scripts/lib/ao-connections.lua`, its session caller and the
shared Julia configuration generator. HEART's binary and scientific artifacts
were unchanged. Zero frames before admission is expected; this observation
does not identify a HEART algorithm defect or measure its processing speed.

### Remediation and limits

The sealed configuration supplies an explicit core-node name list and the
verified systemd core PID. A separate lookup path accepts only those declared
names, matching remote `Core.get_info()` PID/cookie/name, and the server
`spa-node-factory` with Node interface. Client-backed nodes retain their Client
checks. A present but unresolved `client.id` never selects the core path.

Endpoint capture retains exact node, port and factory IDs/serials plus remote
core identity. Property changes and captured removals retain failure fencing.
No synthetic Client is created.

This proves declared hosting and registry incarnation, not the original
requester. Client-requested lingering SPA objects can also lack `client.id`.
The explicit sealed name/owner mapping is therefore required; absence alone
does not permit adoption. This policy is not a new authorization boundary for
untrusted clients sharing the same daemon.

## PH5-H005 — recheck the retained core before control effects

Severity P2; confidence high from source; no live metadata-mutation experiment
claimed. `Core.get_info()` receives mutable remote properties without requiring
a new connection signal. The first remediation checked identity during lookup
and link presence checks but omitted later admission/source-release boundaries.

Remediation rechecks before dispatch, effect issuance and asynchronous callbacks.
Observed mismatch faults the session and rejects the operation. Quit and fault
cleanup remain available. The immutable captured identity is never rebound.

## Verification

- Same cold resolver test fails against baseline `6557dcea` at the core-node
  acceptance assertion and passes with remediation.
- All 56 WirePlumber tests pass, including Client ownership, explicit core
  selection, rejected PID/cookie/name/factory changes and endpoint removal.
- Shared Julia configuration assertions prove the exact core name/PID mapping.
  Its strict package tests pass with the generator change.
- Fresh staged replay `393fa0b0b1bc49d6b305deea0dc67391` passes discovery,
  link negotiation, admission, start/stop, reset with native child generation
  1→2 and a new PID, restart and owned cleanup/unit-file removal. It uses the
  source patch and eight cold diagnostic markers; `/opt/pipewireao` was unchanged
  during that replay. The simulator recorded ten frames/commands in its final
  window. Public Quit still produces bootstrap-controller revocation and HEART
  SIGTERM/finalizer diagnostics; bounded cleanup does not prove graceful exits.
- Independent final source review found no remaining confirmed production gap.
  Live core-metadata mutation, scientific calibration/correction, allocation and
  latency qualification are not established by these tests.

Bounded failed-run receipts, registry snapshot, source review and original
shutdown outcomes live with the instrument in
`REVOLTRTC.jl/docs/validation/installed-classic-split-20261008/`. Raw build/test
logs remain under `~/.cache/rtc-julia-package-20261008/installed-checks`.
