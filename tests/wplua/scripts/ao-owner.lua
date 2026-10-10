-- Native property observation and cold shutdown validation with real PODs.
local control = require ("ao-control")
local owner = require ("ao-owner")

-- Cold compilation can require an explicitly longer, still bounded admission
-- budget. Exercise validation before identity checking; never issue a query.
local saved_identity = control.same_identity
control.same_identity = function () return false end
for _, duration in ipairs ({ 1000000, 300000000, 900000000, 3600000000 }) do
  local client, failure = {}, nil
  owner.wait_prepared (client, Core.get_monotonic_time () + duration,
      function (_, error) failure = error end)
  assert (failure and failure:find ("Owner incarnation changed", 1, true),
      "Valid cold preparation budget was rejected")
  assert (not client.pending, "Rejected owner retained a pending operation")
end
for _, deadline in ipairs ({ Core.get_monotonic_time () + 3601000000, 1000.5, "900000000" }) do
  local client, failure = {}, nil
  owner.wait_prepared (client, deadline, function (_, error) failure = error end)
  assert (failure and failure:find ("Invalid preparation deadline", 1, true))
  assert (not client.pending)
end
control.same_identity = saved_identity

-- The initial configuration can advance generations after rejecting a new update.
local baseline = { control = 0 }
local updates = { ["control:gain"] = Pod.Float (0), ["control:pole"] = Pod.Float (0),
  ["control:anti-windup-gain"] = Pod.Float (0), ["control:hidden-mode-gain"] = Pod.Float (0) }
local values = { ["control:requested-generation"] = Pod.Long (1),
  ["control:active-generation"] = Pod.Long (1), ["control:gain"] = Pod.Float (-0.3),
  ["control:pole"] = Pod.Float (0.99), ["control:anti-windup-gain"] = Pod.Float (0.99),
  ["control:hidden-mode-gain"] = Pod.Float (0) }
local requested = control.scalar (values ["control:requested-generation"], "Long")
local active = control.scalar (values ["control:active-generation"], "Long")
assert (requested > baseline.control and requested == active,
    "The counterexample must satisfy the previous generation-only predicate")
assert (not control.properties_adopted (values, baseline, updates),
    "Unrequested initial configuration was reported adopted")
for name, value in pairs (updates) do values [name] = value:copy () end
assert (control.properties_adopted (values, baseline, updates))
assert (not control.properties_adopted (values, { control = 1 }, updates))
values ["control:active-generation"] = Pod.Long (0)
assert (not control.properties_adopted (values, baseline, updates))
values ["control:active-generation"] = Pod.Long (1)
values ["control:pole"] = Pod.Float (0.99)
assert (not control.properties_adopted (values, baseline, updates))
values ["control:pole"] = Pod.Double (0)
assert (not control.properties_adopted (values, baseline, updates))
values ["control:pole"] = nil
assert (not control.properties_adopted (values, baseline, updates))
values ["control:pole"] = Pod.Float (0)

-- Native Float/Double observation must retain zero signs and representable bits.
for _, constructor in ipairs ({ Pod.Float, Pod.Double }) do
  updates ["control:gain"] = constructor (-0.0)
  values ["control:gain"] = constructor (0.0)
  assert (not control.properties_adopted (values, baseline, updates))
  values ["control:gain"] = constructor (-0.0)
  assert (control.properties_adopted (values, baseline, updates))
end
updates ["control:gain"] = Pod.Float (0.1)
values ["control:gain"] = Pod.Float (0.1)
assert (control.properties_adopted (values, baseline, updates))
values ["control:gain"] = Pod.Float (0.10000001)
assert (not control.properties_adopted (values, baseline, updates))

for name, case in pairs ({
    integer = { Pod.Int, 3, 4 }, long = { Pod.Long, 5, 6 }, id = { Pod.Id, 7, 8 },
    boolean = { Pod.Boolean, true, false }, string = { Pod.String, "accepted", "rejected" } }) do
  local key = "control:" .. name
  local assignment = { [key] = case [1] (case [2]) }
  values [key] = case [1] (case [2])
  assert (control.properties_adopted (values, baseline, assignment))
  values [key] = case [1] (case [3])
  assert (not control.properties_adopted (values, baseline, assignment))
end

updates ["control:gain"] = Pod.Float (0)
values ["control:gain"] = Pod.Float (0)
baseline.second = 2
updates ["second:gain"] = Pod.Float (0.5)
values ["second:gain"] = Pod.Float (0.5)
values ["second:requested-generation"] = Pod.Long (2)
values ["second:active-generation"] = Pod.Long (2)
assert (not control.properties_adopted (values, baseline, updates))
values ["second:requested-generation"] = Pod.Long (3)
values ["second:active-generation"] = Pod.Long (2)
assert (not control.properties_adopted (values, baseline, updates))
values ["second:active-generation"] = Pod.Long (3)
assert (control.properties_adopted (values, baseline, updates))

local bootstrap = { profile = "pipewireao.rtc.owner-bootstrap/1" }
local heart = { profile = "pipewireao.rtc.heart/1" }
local requests, terminals = {}, 0
local response, response_error, response_header
local cancelled = false

owner.request = function (client, operation, payload, deadline, callback)
  assert (#control.fields (payload) == 0, "Shutdown must have an empty request")
  assert (deadline == 123456, "Shutdown changed the operation deadline")
  requests [#requests + 1] = { client = client, operation = operation }
  callback (response_header or { operation = operation, result = 0 }, response, response_error)
  return function () cancelled = true end
end

local function call (client, payload, expected_error, header, error)
  response, response_header, response_error = payload, header, error
  local before = terminals
  local result, failure
  local cancel = owner.shutdown (client, 123456, function (value, error)
    terminals = terminals + 1
    result, failure = value, error
  end)
  assert (terminals == before + 1, "Shutdown did not finish exactly once")
  if expected_error then
    assert (result == nil and type (failure) == "string" and #failure > 0,
        "Invalid shutdown was accepted")
  else assert (result and failure == nil, "Valid shutdown was rejected") end
  return cancel
end

local function snapshot (alive)
  return Pod.Struct { Pod.Long (1), Pod.Id (1234), Pod.Int (0), Pod.Boolean (alive),
    Pod.Id (1), Pod.Boolean (true), Pod.Boolean (true), "report.json", string.rep ("a", 64) }
end
local function heart_result (alive)
  return Pod.Struct { Pod.Id (4), snapshot (alive), "" }
end

local source = { role = "simulator", kind = "bootstrap", client = bootstrap }
local graph = { role = "julia", kind = "bootstrap", client = bootstrap }
local wrapper = { role = "heart", kind = "heart", client = heart }
local records = { graph, source, wrapper }
local ordered = owner.shutdown_order (records, "simulator")
assert (#ordered == 3 and ordered [1] == source and ordered [2] == graph and ordered [3] == wrapper)
assert (records [1] == graph and records [2] == source, "Shutdown order mutated declarations")
ordered = owner.shutdown_order ({ graph, wrapper }, "simulator")
assert (#ordered == 2 and ordered [1] == graph and ordered [2] == wrapper,
    "Shutdown requires an undeclared source bootstrap")
assert (#owner.shutdown_order ({}, "simulator") == 0)
assert (not pcall (owner.shutdown_order, { source, source }, "simulator"))

local cancel = call (bootstrap, Pod.Struct { Pod.Id (5), "" }, false)
assert (requests [#requests].client == bootstrap and requests [#requests].operation == 3)
cancel ()
assert (cancelled, "Shutdown lost request cancellation")

call (heart, heart_result (false), false)
assert (requests [#requests].client == heart and requests [#requests].operation == 4)

-- The native HEART protocol permits an absent PID/return code in a stopped snapshot.
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (0), Pod.None (), Pod.None (),
    Pod.Boolean (false), Pod.Id (2), Pod.Boolean (false), Pod.Boolean (false), "", "" }, "" }, false)

call (bootstrap, Pod.Struct { Pod.Id (3), "still connected" }, true)
call (bootstrap, Pod.Struct { Pod.Id (5) }, true)
call (bootstrap, Pod.Struct { Pod.Int (5), "" }, true)
call (bootstrap, Pod.Struct { Pod.Id (5), string.rep ("x", 8193) }, true)
call (bootstrap, Pod.Struct { Pod.Id (5), "" }, true, { operation = 3, result = -110 })
call (bootstrap, Pod.Struct { Pod.Id (5), "" }, true, { operation = 4, result = 0 })
call (bootstrap, Pod.Struct { Pod.Id (5), "" }, true, {}, "Owner rejected operation")

call (heart, heart_result (true), true)
call (heart, Pod.Struct { Pod.Id (2), snapshot (false), "" }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.None (), "" }, true)
call (heart, Pod.Struct { Pod.Id (4), snapshot (false) }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (-1), Pod.Id (1), Pod.Int (0),
    Pod.Boolean (false), Pod.Id (1), Pod.Boolean (true), Pod.Boolean (true), "", "" }, "" }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (1), Pod.Id (0), Pod.Int (0),
    Pod.Boolean (false), Pod.Id (1), Pod.Boolean (true), Pod.Boolean (true), "", "" }, "" }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (1), Pod.Id (1), Pod.Long (0),
    Pod.Boolean (false), Pod.Id (1), Pod.Boolean (true), Pod.Boolean (true), "", "" }, "" }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (1), Pod.Id (1), Pod.Int (0),
    Pod.Boolean (false), Pod.Id (3), Pod.Boolean (true), Pod.Boolean (true), "", "" }, "" }, true)
call (heart, Pod.Struct { Pod.Id (4), Pod.Struct { Pod.Long (1), Pod.Id (1), Pod.Int (0),
    Pod.Boolean (false), Pod.Id (1), Pod.Boolean (true), Pod.Boolean (true), "", "wrong" }, "" }, true)
call (heart, heart_result (false), true, { operation = 4, result = -1 })

local before = #requests
assert (not pcall (owner.shutdown, { profile = "pipewireao.rtc.unknown/1" }, 123456, function ()
  error ("Unsupported owner dispatched a completion")
end))
assert (#requests == before, "Unsupported shutdown mutated an owner")
