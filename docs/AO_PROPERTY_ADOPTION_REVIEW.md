# Final bounded WirePlumber adoption review

Date: 2026-10-09. Independent reviewer: Astra (`gpt-6-astra`).
Preferred implementation model acknowledged: Sol (`gpt-6.1-sol`).

Worktree: `/home/dgamroth/workspaces/codex/pipewire/wireplumber-registry-loss`.
Branch: `codex/ao-registry-loss-diagnostic-20261009`.
Starting commit: `f248ff5770c42d6d04c4745952cb4ce980072f5d`.
The five-file implementation/test diff already existed when review began. This
review changed no repository source, installed policy, service, or commit.

## Conclusion and exact scope

No open blocking defect found in the reviewed patch. The Running observer now
requires the requested native scalar values as well as newer paired property
generations before reporting active adoption. Registry removal diagnostics retain
captured object identity after the live proxy loses its properties and bound ID.

The intermittent JFG registry disappearance remains unresolved. One successful
diagnostic repeat does not establish its cause or fix it. The property observer
defect is independently established and corrected; it is a different finding.
The patch does not change FGN initial-property staging, Held Submitted semantics,
the acknowledgment protocol, data-frame scheduling, lifecycle guards, or C code.

## Reviewed source identities

| File | SHA-256 |
| --- | --- |
| `src/scripts/lib/ao-control.lua` | `aa799e238fa64f0ec6e1413b6164f25297db9613e07ef2f505a774afac459527` |
| `src/scripts/ao/session.lua` | `35b719ca898f0af56fa900931c5a4f23ed2a84032ac24da7e74d78d5d3daae7b` |
| `src/scripts/lib/ao-connections.lua` | `4a15f721d3beb21c3c5164d0764e8022b021ad4ad6e5c1e324fc309768decb92` |
| `tests/wplua/scripts/ao-owner.lua` | `a1981410748830cb970c5e1648932e752f29cfd78f8f02582e5ca24142b1ad43` |
| `tests/wplua/scripts/ao-connections.lua` | `4d888311301e180b69c1b1b072291c1260ec451e361c49bc9505b0e9ef83ec7c` |

## Findings and adjudication

### WPAR-001 — Unrelated initial generation could satisfy Running adoption

Severity: P1 for a false active-adoption claim. Confidence: high.
Disposition: confirmed predicate defect; resolved by the reviewed patch.
Affected code: `ao-control.lua:63` and `ao/session.lua:366`.

Observed: real native PODs with baseline generation 0, requested/active generation
1/1, configured gain −0.3 and pole/anti-windup 0.99 satisfy the former generation
predicate even when the requested values are all zero. An independent rerun of
the retained projection of that predicate failed at
`Unrequested initial configuration was reported adopted`, exit −6. Evidence:
`wp-adoption-final-fail-before.log` and the retained
`property-adoption-generation-only.lua`. This is a deterministic behavioral
counterexample; it is not a captured live execution of the Running race.

The final helper requires strictly newer requested generations equal to active
generations for every affected algorithm, equal native POD types, and equality
of every submitted scalar. Float and Double comparisons use packed native-width
representations, so signed zero and adjacent Float32 values cannot falsely match.
Finite Float32 values survive conversion to Lua's double representation exactly.
Other admitted scalar types use native POD equality. Nonfinite submissions are
already rejected by the property input path.

The expected PODs remain alive: `control.fields` copies each child; the `updates`
table retains those copies; the observer closure retains that table until the
operation completes or its callbacks become inactive. Both generation and value
checks read the same collected Props response. The change establishes observed
desired active state; it adds no correlated graph acceptance acknowledgment.

Validation: real-POD cases cover initial/configured values versus requested zeros,
matching values, unchanged and pending generations, multiple algorithms, missing
or mismatched scalars, wrong types, signed Float/Double zeros, adjacent Float32
values, and Int/Long/Id/Bool/String equality. The final full 57-test suite passed.
Fresh policy deployment checks are the primary agent's integration responsibility.

### WPAR-002 — Persistent mismatch retains the existing session fault policy

Severity: P2 operational consequence. Confidence: high, derived directly from
control flow. Disposition: explicitly accepted by primary-agent adjudication;
no remediation requested in this patch.
Affected code: `ao/session.lua:49`, `:80`, `:179`, and `:349–380`.

After sending Props, `operation.effects_issued` is true. If a newer settled
generation has wrong values, the new predicate returns false and observation
continues. At the original bounded deadline, existing `guarded`/`begin` handlers
invoke `fault`; it fences the operation, changes lifecycle, holds the source,
holds graphs and withdraws links. The outcome is therefore not merely a
nonfaulting unconfirmed property reply.

The primary explicitly retained this existing fail-closed behavior: an issued
gain change that cannot be verified must not return active success or continue
with a claimed configuration. This review accepts that scope decision. No new
busy-error, rejection, or acknowledgment protocol is implied. Held Submitted
continues to carry null generations and false active-adoption observation; it
does not prove graph admission. FGN-PROP-002's initial pending transaction remains
authoritative. An operation-specific nonfaulting mismatch policy would require
separate design and validation, and is outside this patch.

### WPAR-003 — Registry loss lacks a demonstrated root cause

Severity: P2 outstanding integration reliability issue. Confidence: high that
the retained incident exists; root cause remains a hypothesis.
Disposition: unresolved incident; diagnostic improvement accepted.
Affected code: `ao-connections.lua:19–62`, `:107–120`, `:162`, `:227`, `:505`.

The supplied incident ordering places captured-object removal before the later
C guard failure. That ordering does not identify which mechanism removed the
object. The added data saves kind, role, bound ID, serial, relevant names/IDs,
owner PIDs, path, and link endpoint IDs while the admitted object is still alive.
Removal uses the saved record rather than dereferencing a destroyed proxy.
The change does not prevent or repair object disappearance.

Owner association remains based on the existing validated endpoint catalog:
node/port records inherit their declared endpoint's client PID or verified core
PID; control records retain native RTC/source owner PID fields; links retain
their admitted input/output node and port IDs. A shared client/factory can retain
the first captured endpoint as context, not an exhaustive list of dependents.
`kind` and `role` distinguish that context from the removed object's own identity.
Captured values remain truthy everywhere the existing code tests membership;
replacement of Boolean values with metadata records does not weaken admission
or withdrawal checks.

Validation: cold registry tests clear proxy properties and bound IDs before
removal and confirm saved node/port/client/factory/control/link identities. These
are resolver/proxy doubles, not a reproduction of the intermittent live loss.
Required next evidence: on recurrence, retain the diagnostic identity, owner and
core lifecycle/registry ordering, and the preceding native error. Do not infer a
fixed incident from the successful 376×2 JFG diagnostic acquisition repeat.

## String formatting and diagnostic limits

Saved strings use Lua `%q`; quotes, backslashes, NUL and tabs are escaped rather
than interpolated as unquoted fields. A focused check with the same registered
Lua runtime passed and retained byte output in `wp-adoption-string-escaping.log`.
Lua formats newline as backslash followed by an actual newline; these messages
can span physical lines. No single-line parsing contract was found, so this is
a formatting limitation rather than a blocking defect. The native error remains
a structured string. It must not be presented as a stable machine-readable
key/value schema or an ownership proof independent of the admitted catalog.

## Independent validation

Command: `meson test -C build --no-rebuild --print-errorlogs`.
Result: 57/57 passed, zero failures, skips or timeouts, after the final scalar
patch. Summary log: `wp-adoption-final-tests.log`. Lua tests load the current
worktree modules through the registered Meson environment. Rebuilding was not
necessary because only Lua sources and scripts changed.

The independent fail-before experiment ran the same real-POD regression with the
retained projection of the former generation-only predicate, in the registered
script-tester environment, with core dumps disabled. The failure is expected and
recorded separately from the 57 passing final tests. `git diff --check` passed;
the final diff contains only the five reviewed Lua files.

The prior REVOLT review metadata already identifies Astra correctly. Its finite
driver source hash remains `1300082412b918444859f4c28e9f8222ad21ada9eb66d0dcc03255b2a60cd157`.
Primary-reported fresh FGN/JFG finite correction and Running property/matrix
adoption outcomes are separate integration evidence. This review does not
reclassify them as proof of the patched policy until the primary completes its
fresh runs. No cadence, maximum-rate, allocation, hardware, or physical-correction
claim follows from this review.
