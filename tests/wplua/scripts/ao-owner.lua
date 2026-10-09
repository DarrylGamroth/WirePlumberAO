-- Cold native shutdown validation using real PODs and a bounded request double.
local control = require ("ao-control")
local owner = require ("ao-owner")
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
