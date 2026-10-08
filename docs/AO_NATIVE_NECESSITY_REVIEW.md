# Native support for the AO Lua session policy

Review date: 2026-10-07. Source revision: `9e33913893fac11351570bf4c333d8aeb576ab06`.
Compared with its parent `4c2648fa`; “existing” below refers to that source baseline,
not an assertion about later upstream releases.

Canonical source: `/home/dgamroth/workspaces/codex/pipewire/wireplumber`, branch
`master`, clean at review start. Review worktree:
`/home/dgamroth/workspaces/codex/pipewire/wireplumber-native-review`, branch
`review/ao-native-necessity-20261007`, same starting revision and clean before this
artifact. Read-only source review; no production edits, builds, runtime tests,
process control, or hardware validation. The running GUI/HIL session was not touched.

## Conclusion

Building against PipeWireAO supplies NDArray type definitions and transport support.
It does not add Lua access to every PipeWire or GLib operation. This commit also
moves session ownership into WirePlumber. Most native changes fill the resulting
Lua API gaps. The largest addition creates a local typed control endpoint that
Lua could not previously implement with the exposed APIs.

These changes are justified by the selected architecture and existing Node Props
control protocol. They are not all prerequisites for managing NDArray links in
general. A simpler policy that only creates links needs much less. The endpoint
is an AO-specific plugin; the rest is largely generic API support plus an unrelated
configuration parser fix. No scientific computation or frame processing was found
in the native additions.

Also, “linking against PipeWireAO” is slightly incomplete: WirePlumber compiles SPA
name/type tables from headers (`lib/wp/spa-type.c:12`, `:112`). It needs the matching
PipeWireAO development headers when built, not just a substituted shared library.

## Change-by-change evidence

| Native change | Actual consumer and reason | Existing equivalent and assessment |
| --- | --- | --- |
| `Core.get_monotonic_time()` in `modules/module-lua-scripting/api/api.c:198` | Absolute request deadlines throughout AO Lua; receipt time is captured in C at endpoint callback entry (`module-ao-control-endpoint.c:423`) so queueing consumes budget. | GLib already provides the clock; this is a missing binding. Lua has timers and sandboxed `os.clock`/`os.time`, but those do not provide the same monotonic elapsed-time clock. Small, generic addition. |
| Optional feature mask in `ObjectManager(...)`, `api.c:904` | `src/scripts/lib/ao-connections.lua:25` requests BOUND and INFO for discovery; `ao-session-control.lua:190` does the same for controller identity. | C already has `wp_object_manager_request_object_features`; old Lua forced ALL. Parameter features trigger enumeration/cache (`lib/wp/private/pipewire-object-mixin.c:648`) and refresh (`:783`). This exposes an existing control and avoids reading unrelated scientific parameters merely to discover nodes. |
| `wp_link_get_format()`, readable `format` property and notification in `lib/wp/link.c:291`, `:172`, `:188`; Lua method at `api.c:1330` | `ao-connections.lua:382` checks the actual negotiated format, and `:420` observes changes before/after admission. | PipeWire already supplies `pw_link_info.format`. WpLink cached it internally but exposed no corresponding typed getter/property. Port format inspection is not the identical per-link observation. New generic wrapper/accessor, not new negotiation. |
| POD iterator/copy/equality/property/choice bindings in `modules/module-lua-scripting/api/pod.c:1281`–`:1454` | `ao-control.lua:23` preserves typed fields; `:34` rejects duplicates/flags; `ao-owner.lua:159` keeps reply payload; `ao-session-control.lua:146` compares retransmissions. | C already has iterator, copy, equality and choice access. Existing Lua `parse()` recursively converts values to tables/scalars and overwrites duplicate property names (`pod.c:1176`–`:1186`); it loses information required by strict validation. These are mostly missing bindings. |
| POD size/object-ID/array metadata access in `pod.c:1320`, `:1329`, `:1362`, and numeric property-ID/flags helpers in `lib/wp/spa-pod.c:1743` | `ao-connections.lua:203` validates field widths, array rank, fixed choices and actual numeric SPA property IDs. Numeric keys avoid the Audio/NDArray `rate` short-name collision described at `:196`. | Existing C/SPA APIs expose much of the metadata, but Lua did not. Public WpSpaPod property-ID and flags accessors are new; the values already existed privately. Generic typed inspection support, not an NDArray computation engine. |
| `modules/module-ao-control-endpoint.c` and its Meson target | Generated configuration instantiates two endpoints: public session control and the manager's controller identity (`pipewireao-rtc/deployment/julia/wireplumber_configuration.jl:162`–`:180`). Lua consumes incoming `parameter`, errors and state (`ao-session-control.lua:218`) and publishes records (`:36`). | Existing `ImplNode` wraps a PipeWire factory (`api.c:1276`); it does not let Lua implement arbitrary incoming native parameter callbacks. `ImplMetadata` exists (`api.c:1031`) but uses metadata strings and would change the deployed typed Node Props protocol. Some native adapter is justified for this protocol; this exact AO plugin is an implementation choice. |
| Dependency string decoding in `lib/wp/private/internal-comp-loader.c:214`–`:255` | Generated component dependencies include `support.lua-scripting`, `ao.session-control`, `ao.session-controller` (configuration `:180`). | `wp_spa_json_to_string` copies raw JSON bytes (`lib/wp/spa-json.c:323`); `parse_string` decodes the value (`:755`). Quoted dependency names previously retained quotes, so they could differ from the provided feature names. Generic configuration correction; independent of NDArray and Lua policy. Using unquoted SPA configuration tokens could avoid this trigger without fixing the parser. |

`link:deactivate(Feature.Proxy.BOUND)` is **not a new native API in this commit**.
The inherited Lua Object method was already present (`api.c:517`, `:545`), as were
link creation, asynchronous object activation, and Core synchronization. The new
policy uses those existing operations for withdrawal (`ao-connections.lua:427`,
`:458`, `:474`).

## What the endpoint does

The endpoint creates an inactive, portless `pw_filter` (`module-ao-control-endpoint.c:542`,
`:554`). Its event table only contains destruction, state, and parameter callbacks
(`:440`); there is no process callback. It owns bounded copies of incoming PODs,
delivers them later to Lua, and publishes Lua-built Props records with
`pw_filter_update_params` (`:484`). One pending request and four events bound the
handoff (`:19`, `:192`), with 16 KiB request and 64 KiB publication limits (`:15`).
Structural POD validation accounts for much of the native code (`:223`–`:339`).

The module does not choose scientific operations, maintain the session lifecycle,
create the scientific graph, or process frames. Lua performs admission and lifecycle
coordination; scientific owners perform their respective work. This matches the
ownership decision in `pipewireao-rtc/docs/WIREPLUMBER_SESSION_DESIGN.md`.

The plugin also supplies deferred daemon disconnection for shutdown/fault cleanup
(`module-ao-control-endpoint.c:93`). Existing `Core.quit()` deliberately refuses to
quit a WirePlumber daemon (`api.c:253`–`:266`), so it is not a direct replacement.

## Minimality assessment and dispositions

### WPN-001 — AO protocol assumptions in the transport adapter

Classification: observed design coupling; optional improvement, not a demonstrated
behavioral defect. Severity: low. Confidence: high.

Evidence: native identity keys and protocol string (`module-ao-control-endpoint.c:106`,
`:673`), exactly one `Props.params` Struct with zero flags (`:319`–`:338`), and a
three-slot capabilities/completion/rejection publication method (`:457`). These are
more specific than a generic PipeWire-to-Lua callback bridge. Lua checks some of the
same outer envelope rules (`ao-control.lua:31`–`:49`). Thus “transport only” should
be read as “no lifecycle/scientific policy”, not “no protocol knowledge”.

Possible remediation: keep the AO protocol adapter as a separately packaged plugin
and upstream the generic bindings independently. Generalize the adapter only if
another real consumer needs it. Moving selected envelope checks into Lua would
need to retain native structural validation before any unsafe parser access.
Validation required before a refactor: malformed POD rejection, bounded overload,
record publication, endpoint teardown during callbacks, and existing lifecycle
qualification. Disposition: do not change during this explanation review.

### WPN-002 — The commit bundles independent layers

Classification: observed maintainability concern; optional improvement. Severity:
low. Confidence: high.

Evidence: a generic dependency parser correction, generic Lua/C accessors, the AO
endpoint plugin, and all AO Lua policy are introduced together. This obscures why
a fork is needed and makes upstreaming the small generic pieces harder to review.

Possible remediation: document/package these as four layers; use separate future
changes for generic APIs, parser fixes, endpoint transport, and policy. Do not
rewrite already merged history merely to split this commit. Validation required:
each layer's focused API/config tests and integrated session checks when changed.
Disposition: documentation recommendation; no history or source edits.

No new native behavioral defect was confirmed in this scoped source examination.
This is not a comprehensive memory-safety or concurrency proof. Existing runtime
qualification records were not reproduced, and findings above do not upgrade
scientific or timing qualification claims.
