-- Native acquisition Shutdown validation with real PODs.
local control = require ("ao-control")
local owner = require ("ao-owner")
local acquisition = require ("ao-acquisition")

local requests, terminals = {}, 0
local response_header, response_payload, response_error
local request_callback, cancelled, duplicate = nil, false, false
local expected_deadline, defer

owner.request = function (client, operation, payload, deadline, callback)
  assert (client.profile == "pipewireao.rtc.calibration-lifecycle/1" or
      client.profile == "pipewireao.rtc.correction-lifecycle/1")
  assert (operation == 6, "Acquisition Shutdown must use operation 6")
  assert (#control.fields (payload) == 0, "Shutdown must have an empty request")
  assert (deadline == expected_deadline, "Shutdown changed the operation deadline")
  requests [#requests + 1] = { client = client, operation = operation }
  request_callback = callback
  if not defer then
    callback (response_header, response_payload, response_error)
    if duplicate then callback (response_header, response_payload, response_error) end
  end
  return function () cancelled = true end
end

local function source_for (profile)
  local node = { ["bound-id"] = 42, properties = {
    ["object.serial"] = "123456", ["node.name"] = "simulator-wfs",
    ["pipewireao.rtc-control.protocol"] = "pipewireao.rtc-control/1",
    ["pipewireao.rtc-control.profile"] = profile,
    ["pipewireao.rtc-control.instance"] = "987654",
    ["pipewireao.rtc-control.owner-pid"] = "1234",
  } }
  return acquisition.new (node, { ["control-protocol"] = profile,
    ["control-instance"] = 987654, ["control-node"] = "simulator-wfs", pid = 1234 },
    { global_id = 99, serial = 1, instance = 777 }, 1234)
end

local function snapshot (phase, running, held, restored)
  return Pod.Struct { Pod.Id (1), Pod.None (), Pod.None (), Pod.Boolean (running),
    Pod.Boolean (false), Pod.String (phase), Pod.Boolean (held), Pod.Boolean (restored),
    Pod.None () }
end

local function result (phase, running, held, restored, lifecycle, message)
  return Pod.Struct { Pod.Id (lifecycle or 5), snapshot (phase, running, held, restored),
    Pod.String (message or "") }
end

local function call (profile, payload, expected_error, header, error)
  response_payload, response_header, response_error = payload, header, error
  defer = false
  expected_deadline = Core.get_monotonic_time () + 60000000
  local source, value, failure = source_for (profile), nil, nil
  local before = terminals
  acquisition.shutdown (source, expected_deadline, function (answer, reason)
    terminals = terminals + 1
    value, failure = answer, reason
  end)
  assert (terminals == before + 1, "Shutdown callback did not finish exactly once")
  if expected_error then
    assert (value == nil and type (failure) == "string" and #failure > 0,
        "Invalid Shutdown was accepted")
  else assert (value and failure == nil, "Valid Shutdown was rejected") end
end

local calibration = "pipewireao.rtc.calibration-lifecycle/1"
local correction = "pipewireao.rtc.correction-lifecycle/1"
for _, profile in ipairs ({ calibration, correction }) do
  local completed_phase = profile == calibration and "released" or "restored"
  call (profile, result (completed_phase, false, false, true), false,
      { operation = 6, result = 0 })
  assert (requests [#requests].operation == 6)
  call (profile, result ("initial", false, false, false), false,
      { operation = 6, result = 0 })

  call (profile, result (completed_phase, false, false, true), true,
      { operation = 5, result = 0 })
  call (profile, result (completed_phase, false, false, true), true,
      { operation = 6, result = -1 })
  call (profile, result (completed_phase, false, false, true), true,
      { operation = 6, result = 0 }, "owner rejected shutdown")
  call (profile, result (completed_phase, false, false, true, 6), true,
      { operation = 6, result = 0 })
  call (profile, Pod.Struct { Pod.Id (5), Pod.None (), Pod.String ("") }, true,
      { operation = 6, result = 0 })
  call (profile, result (completed_phase, true, false, true), true,
      { operation = 6, result = 0 })
  call (profile, result (completed_phase, false, true, true), true,
      { operation = 6, result = 0 })
  call (profile, result (completed_phase, false, false, false), true,
      { operation = 6, result = 0 })
  call (profile, result ("not-a-phase", false, false, true), true,
      { operation = 6, result = 0 })
end

-- A duplicate terminal delivery cannot invoke the public completion twice.
response_payload, response_header, response_error = result ("released", false, false, true),
    { operation = 6, result = 0 }, nil
expected_deadline, duplicate = Core.get_monotonic_time () + 60000000, true
local duplicate_source, duplicate_count = source_for (calibration), 0
acquisition.shutdown (duplicate_source, expected_deadline, function () duplicate_count = duplicate_count + 1 end)
duplicate = false
assert (duplicate_count == 1, "Shutdown duplicate reply invoked callback more than once")

local function reject_source (node, declaration, pid)
  assert (not pcall (acquisition.new, node, declaration,
      { global_id = 99, serial = 1, instance = 777 }, pid),
      "Invalid acquisition source identity was accepted")
end
local identity_node = { ["bound-id"] = 42, properties = {
  ["object.serial"] = "123456", ["node.name"] = "simulator-wfs",
  ["pipewireao.rtc-control.protocol"] = "pipewireao.rtc-control/1",
  ["pipewireao.rtc-control.profile"] = calibration,
  ["pipewireao.rtc-control.instance"] = "987654",
  ["pipewireao.rtc-control.owner-pid"] = "1234",
} }
reject_source (identity_node, { ["control-protocol"] = "pipewireao.rtc.correction-lifecycle/1",
  ["control-instance"] = 987654, ["control-node"] = "simulator-wfs", pid = 1234 }, 1234)
reject_source (identity_node, { ["control-protocol"] = calibration,
  ["control-instance"] = 987655, ["control-node"] = "simulator-wfs", pid = 1234 }, 1234)
reject_source (identity_node, { ["control-protocol"] = calibration,
  ["control-instance"] = 987654, ["control-node"] = "simulator-wfs", pid = 1235 }, 1235)

-- The ordinary legacy simulator is shut down through its bootstrap owner.
local before = #requests
local legacy = source_for (calibration)
legacy.profile = "pipewireao.source-control/1"
local completed = false
acquisition.shutdown (legacy, Core.get_monotonic_time () + 60000000,
    function (value, failure) completed = value == nil and failure == nil end)
assert (completed and #requests == before, "Legacy shutdown issued an acquisition request")

-- Cancellation reaches the exact pending native request and fences its callback.
local source = source_for (calibration)
defer, cancelled = true, false
expected_deadline = Core.get_monotonic_time () + 60000000
local before_terminals = terminals
local cancel = acquisition.shutdown (source, expected_deadline, function () terminals = terminals + 1 end)
cancel ()
assert (cancelled, "Shutdown cancellation did not reach owner.request")
request_callback ({ operation = 6, result = 0 }, result ("released", false, false, true), nil)
assert (terminals == before_terminals, "Cancelled Shutdown callback was not fenced")

