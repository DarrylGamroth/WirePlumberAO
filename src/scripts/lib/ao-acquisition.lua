-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Acquisition controls target one owner incarnation, independent of its ports.
-- Scientific Hold/Release actions and HEART child supervision keep their own profiles.
local control = require ("ao-control")
local owner = require ("ao-owner")
local acquisition = {}
local LEGACY = "pipewireao.source-control/1"
local PROFILES = {
  ["pipewireao.rtc.calibration-lifecycle/1"] = {
    namespace = "pipewireao.rtc.calibration-lifecycle",
    phases = { initial = true, held = true, adopted = true, settled = true,
      collected = true, restoring = true, restored = true, released = true, fault = true },
    calibration = true,
  },
  ["pipewireao.rtc.correction-lifecycle/1"] = {
    namespace = "pipewireao.rtc.correction-lifecycle",
    phases = { initial = true, startup_run = true, correcting = true,
      restore_run = true, restored = true, fault = true },
  },
}

local function scalar (pod, kind)
  assert (pod, "Missing acquisition field")
  return control.scalar (pod, kind)
end

local function text (pod, maximum, ascii)
  local value = scalar (pod, "String")
  assert (#value <= maximum and not value:find ("%z"), "Oversized acquisition string")
  assert (not ascii or not value:find ("[\128-\255]"), "Non-ASCII acquisition phase")
  return value
end

local function optional (pod, decode)
  assert (pod, "Missing optional acquisition field")
  if pod:get_type_name () == "Spa:None" then return nil end
  return decode (pod)
end

local function cursor (pod)
  local values = control.fields (pod, 4)
  -- SPA Long transports UInt64 bits; negative Lua integers are valid here.
  return { domain = scalar (values [1], "Long"),
    generation = scalar (values [2], "Long"), sequence = scalar (values [3], "Long"),
    model_ns = scalar (values [4], "Long") }
end

local function metadata_integer (node, key)
  local raw = node.properties [key]
  assert (type (raw) == "string" and raw:match ("^%d+$"), "Missing acquisition identity: " .. key)
  local value = tonumber (raw)
  assert (math.type (value) == "integer" and value > 0, "Invalid acquisition identity: " .. key)
  return value
end

local function check (source)
  assert (not source.retired and control.same_identity (source.node, source.identity),
      "Acquisition owner incarnation changed")
  if source.profile == LEGACY then
    assert (metadata_integer (source.node, "pipewireao.source-control.instance") == source.instance and
        metadata_integer (source.node, "pipewireao.source-control.owner-pid") == source.pid,
        "Acquisition source identity changed")
  else
    assert (source.node.properties ["pipewireao.rtc-control.protocol"] == "pipewireao.rtc-control/1" and
        source.node.properties ["pipewireao.rtc-control.profile"] == source.profile and
        metadata_integer (source.node, "pipewireao.rtc-control.instance") == source.instance and
        metadata_integer (source.node, "pipewireao.rtc-control.owner-pid") == source.pid,
        "Acquisition owner profile or identity changed")
  end
end

function acquisition.new (node, declaration, controller, pid)
  local profile = assert (declaration ["control-protocol"], "Missing acquisition profile")
  assert (profile == LEGACY or PROFILES [profile],
      "Unsupported acquisition profile; HEART supervision is not acquisition control")
  local instance = tonumber (declaration ["control-instance"])
  local source = { node = node, identity = control.identity (node), profile = profile,
    pid = pid or declaration.pid, pending = nil, retired = false }
  assert (math.type (source.pid) == "integer" and source.pid > 0 and source.pid < 0xffffffff,
      "Invalid acquisition owner PID")
  assert (not declaration ["control-node"] or
      node.properties ["node.name"] == declaration ["control-node"], "Acquisition node name mismatch")
  if profile == LEGACY then
    source.instance = metadata_integer (node, "pipewireao.source-control.instance")
    -- The legacy owner creates this mailbox instance itself, separately from
    -- the saved cold lifecycle incarnation used by newer owners.
  else
    assert (math.type (instance) == "integer" and instance > 0, "Invalid acquisition instance")
    source.instance = instance
    source.client = owner.new (node, PROFILES [profile].namespace, instance, controller, source.pid)
  end
  local instrument = declaration.instrument
  if instrument ~= nil then
    source.instrument = ({ classic = 1, copper = 2, Classic = 1, Copper = 2 }) [instrument] or instrument
    assert (source.instrument == 1 or source.instrument == 2, "Invalid acquisition instrument")
  end
  check (source)
  return source
end

local LEGACY_FIELDS = { version = "Int", instance = "Long", kind = "Int",
  ["completed-token"] = "Long", result = "Int", generation = "Long", sequence = "Long",
  running = "Bool", completed = "Bool", ["report-generation"] = "Long", ["report-sequence"] = "Long" }

local function legacy_snapshot (source, values)
  local prefix, decoded, count = "pipewireao.source-snapshot.", {}, 0
  for name, kind in pairs (LEGACY_FIELDS) do
    decoded [name] = scalar (values [prefix .. name], kind)
  end
  for name in pairs (values) do
    assert (name:sub (1, #prefix) == prefix and LEGACY_FIELDS [name:sub (#prefix + 1)],
        "Unexpected source snapshot field")
    count = count + 1
  end
  assert (count == 11 and decoded.version == 1 and decoded.instance == source.instance and
      decoded.kind >= 0 and decoded.kind <= 3 and decoded.result == 0 and
      decoded ["completed-token"] >= 0 and decoded.generation > 0 and decoded.sequence >= 0 and
      decoded ["report-generation"] > 0 and decoded ["report-sequence"] >= 0 and
      not (decoded.running and decoded.completed), "Invalid legacy acquisition snapshot")
  assert (decoded ["report-generation"] <= decoded.generation and
      (decoded ["report-generation"] ~= decoded.generation or
        decoded ["report-sequence"] <= decoded.sequence), "Invalid legacy report cursor")
  return { generation = decoded.generation, sequence = decoded.sequence,
    running = decoded.running, completed = decoded.completed,
    cursor = { generation = decoded.generation, sequence = decoded.sequence },
    report_cursor = { generation = decoded ["report-generation"], sequence = decoded ["report-sequence"] },
    details = decoded }
end

-- result is a legacy named snapshot table or the cold completion payload POD.
function acquisition.snapshot (source, result)
  check (source)
  if source.profile == LEGACY then return legacy_snapshot (source, result) end
  local values = control.fields (result, 3)
  local lifecycle = scalar (values [1], "Id")
  assert (lifecycle >= 1 and lifecycle <= 5, "Invalid acquisition lifecycle")
  local message = text (values [3], 8192)
  if values [2]:get_type_name () == "Spa:None" then
    assert (lifecycle == 1 or lifecycle == 2, "Connected acquisition has no snapshot")
    return { details = { lifecycle = lifecycle, message = message } }
  end
  local fields = control.fields (values [2], 9)
  local instrument = scalar (fields [1], "Id")
  assert ((instrument == 1 or instrument == 2) and
      (source.instrument == nil or source.instrument == instrument), "Acquisition instrument changed")
  local current = optional (fields [2], cursor)
  local report = optional (fields [3], cursor)
  local running, completed = scalar (fields [4], "Bool"), scalar (fields [5], "Bool")
  local phase = text (fields [6], 64, true)
  local held, restored = scalar (fields [7], "Bool"), scalar (fields [8], "Bool")
  local window = optional (fields [9], function (pod) return scalar (pod, "Long") end)
  assert (not (running and completed) and PROFILES [source.profile].phases [phase],
      "Invalid acquisition state or phase")
  if lifecycle == 3 then
    assert (current and current.generation ~= 0, "Connected acquisition has no cursor generation")
    if not PROFILES [source.profile].calibration then
      assert (window ~= nil and window ~= 0, "Connected correction has no window")
    end
  end
  if PROFILES [source.profile].calibration then assert (window == nil, "Calibration has a correction window") end
  source.instrument = instrument
  return { generation = current and current.generation, sequence = current and current.sequence,
    running = running, completed = completed, cursor = current, report_cursor = report,
    details = { lifecycle = lifecycle, instrument = instrument, phase = phase,
      held = held, restored = restored, window = window, message = message } }
end

local function finish (source, pending, result, error)
  if source.pending ~= pending then return end
  source.pending = nil
  if pending.timer then pending.timer:destroy (); pending.timer = nil end
  if result then source.last_snapshot = result end
  local ok, failure = pcall (pending.callback, result, error)
  if not ok then Log.warning ("AO acquisition callback failed: " .. tostring (failure)) end
end

local function complete (source, pending, result, error)
  if source.pending ~= pending then return end
  if error then finish (source, pending, nil, error); return end
  local ok, snapshot = pcall (acquisition.snapshot, source, result)
  if not ok then finish (source, pending, nil, tostring (snapshot)); return end
  if source.profile ~= LEGACY and pending.kind ~= "query" and snapshot.details.lifecycle ~= 3 then
    finish (source, pending, nil, "Acquisition effect did not complete Connected"); return
  end
  if pending.kind == "run" then
    if snapshot.running ~= pending.running or (pending.running and snapshot.completed) then
      finish (source, pending, nil, "Acquisition run state was not acknowledged"); return
    end
  elseif pending.kind == "reset" then
    if snapshot.running or snapshot.completed or snapshot.sequence ~= 0 then
      finish (source, pending, nil, "Acquisition reset cursor was not acknowledged"); return
    end
  end
  finish (source, pending, snapshot)
end

local function begin (source, kind, argument, deadline, callback)
  assert (not source.pending, "Acquisition operation already pending")
  check (source)
  assert (math.type (deadline) == "integer", "Invalid acquisition deadline")
  -- Readiness may span the session startup budget; ao-owner caps each request.
  if kind ~= "prepare" then deadline = math.min (deadline, Core.get_monotonic_time () + 60000000) end
  control.remaining_ns (deadline)
  local pending = { kind = kind, deadline = deadline, callback = callback }
  if kind == "run" then
    assert (argument == 1 or argument == 2 or argument == "stopped" or argument == "running",
        "Invalid acquisition run state")
    pending.running = argument == 2 or argument == "running"
  end
  source.pending = pending
  return pending
end

local function cancel_current (source, pending)
  if not pending or source.pending ~= pending then return end
  source.pending = nil
  if pending.timer then pending.timer:destroy (); pending.timer = nil end
  if pending.cancel then pending.cancel () end
end

local function request (source, pending, operation, callback)
  local stage = {}
  pending.stage = stage
  local cancel = owner.request (source.client, operation, Pod.Struct {}, pending.deadline, callback)
  -- A synchronous callback may already have advanced to another exact request.
  if source.pending == pending and pending.stage == stage then pending.cancel = cancel end
end

local function node_operation (source, pending, kind, argument, callback)
  local stage = {}
  pending.stage = stage
  local cancel = owner.node_operation (source.node, kind, argument, pending.deadline, callback)
  if source.pending == pending and pending.stage == stage then pending.cancel = cancel end
end

function acquisition.operation (source, kind, argument, deadline, callback)
  local pending
  local ok, error = pcall (function ()
    assert (kind == "run" or kind == "query" or kind == "reset", "Invalid acquisition operation")
    pending = begin (source, kind, argument, deadline, callback)
    if source.profile == LEGACY then
      local function query ()
        if source.pending ~= pending then return end
        node_operation (source, pending, "query", source.instance,
            function (values, failure) complete (source, pending, values, failure) end)
      end
      if kind == "query" then query ()
      else
        node_operation (source, pending, kind,
            kind == "run" and (pending.running and 2 or 1) or nil, function (_, failure)
          if source.pending ~= pending then return end
          if failure then finish (source, pending, nil, failure) else query () end
        end)
      end
    else
      local operation = kind == "query" and 1 or kind == "reset" and 4 or pending.running and 3 or 2
      request (source, pending, operation,
          function (_, payload, failure) complete (source, pending, payload, failure) end)
    end
  end)
  if not ok then
    if pending then finish (source, pending, nil, tostring (error))
    else
      local called, failure = pcall (callback, nil, tostring (error))
      if not called then Log.warning ("AO acquisition callback failed: " .. tostring (failure)) end
    end
  end
  return function () cancel_current (source, pending) end
end

function acquisition.connect (source, deadline, callback)
  if source.profile == LEGACY then
    return acquisition.operation (source, "query", source.instance, deadline, callback)
  end
  local pending
  local ok, error = pcall (function ()
    pending = begin (source, "connect", nil, deadline, callback)
    request (source, pending, 5,
        function (_, payload, failure)
      if source.pending ~= pending then return end
      if failure then finish (source, pending, nil, failure); return end
      local decoded, snapshot = pcall (acquisition.snapshot, source, payload)
      if not decoded then finish (source, pending, nil, tostring (snapshot)); return end
      if snapshot.details.lifecycle ~= 3 then
        finish (source, pending, nil, "Acquisition Connect did not complete Connected"); return
      end
      finish (source, pending, snapshot)
    end)
  end)
  if not ok then
    if pending then finish (source, pending, nil, tostring (error)) else
      local called, failure = pcall (callback, nil, tostring (error))
      if not called then Log.warning ("AO acquisition callback failed: " .. tostring (failure)) end
    end
  end
  return function () cancel_current (source, pending) end
end

-- Capability readiness is read-only during science construction. Then verify
-- one fresh status and submit Connect once; no mutation is retried.
function acquisition.prepare (source, deadline, callback)
  if source.profile == LEGACY then
    return acquisition.operation (source, "query", source.instance, deadline, callback)
  end
  local pending
  local function response (payload, failure, connected)
    if source.pending ~= pending then return end
    if failure then finish (source, pending, nil, failure); return end
    local ok, snapshot = pcall (acquisition.snapshot, source, payload)
    if not ok then finish (source, pending, nil, tostring (snapshot)); return end
    if connected then
      if snapshot.details.lifecycle ~= 3 then
        finish (source, pending, nil, "Acquisition Connect did not complete Connected"); return
      end
      finish (source, pending, snapshot)
    else
      if snapshot.details.lifecycle ~= 2 then
        finish (source, pending, nil, "Acquisition owner changed Prepared readiness"); return
      end
      local issued, error = pcall (request, source, pending, 5,
          function (_, value, failure) response (value, failure, true) end)
      if not issued then finish (source, pending, nil, tostring (error)) end
    end
  end
  local ok, error = pcall (function ()
    pending = begin (source, "prepare", nil, deadline, callback)
    local stage = {}
    pending.stage = stage
    local cancel = owner.wait_prepared (source.client, pending.deadline, function (_, failure)
      if source.pending ~= pending then return end
      if failure then finish (source, pending, nil, failure); return end
      local issued, error = pcall (request, source, pending, 1,
          function (_, payload, failure) response (payload, failure, false) end)
      if not issued then finish (source, pending, nil, tostring (error)) end
    end)
    if source.pending == pending and pending.stage == stage then pending.cancel = cancel end
  end)
  if not ok then
    if pending then finish (source, pending, nil, tostring (error)) else
      local called, failure = pcall (callback, nil, tostring (error))
      if not called then Log.warning ("AO acquisition callback failed: " .. tostring (failure)) end
    end
  end
  return function () cancel_current (source, pending) end
end

function acquisition.cancel (source)
  source.retired = true
  cancel_current (source, source.pending)
  if source.client then owner.cancel (source.client) end
end

-- Cold sources own their science resources separately from graph bootstraps.
function acquisition.shutdown (source, deadline, callback)
  if source.profile == LEGACY then
    -- The ordinary simulator's bootstrap owns its cleanup. This mailbox has
    -- no Shutdown operation; preserve the existing bootstrap path.
    callback (nil, nil)
    return function () end
  end
  local pending
  local ok, error = pcall (function ()
    pending = begin (source, "shutdown", nil, deadline, callback)
    request (source, pending, 6, function (header, payload, failure)
      if source.pending ~= pending then return end
      if failure then finish (source, pending, nil, failure); return end
      local valid, snapshot = pcall (function ()
        assert (header and header.operation == 6 and header.result == 0,
            "Acquisition Shutdown completion failed")
        local value = acquisition.snapshot (source, payload)
        assert (value.details.lifecycle == 5 and value.details.message == "" and
            value.running == false and value.details.held == false,
            "Acquisition Shutdown did not complete Stopped and unheld")
        assert (value.details.phase == "initial" or value.details.restored == true,
            "Acquisition Shutdown has no restoration proof")
        return value
      end)
      if not valid then finish (source, pending, nil, tostring (snapshot)); return end
      finish (source, pending, snapshot)
    end)
  end)
  if not ok then
    if pending then finish (source, pending, nil, tostring (error)) else
      local called, failure = pcall (callback, nil, tostring (error))
      if not called then Log.warning ("AO acquisition callback failed: " .. tostring (failure)) end
    end
  end
  return function () cancel_current (source, pending) end
end

return acquisition
