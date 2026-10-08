-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Cold control queries exist only while one operation has an absolute deadline.
-- A submitted mutation is never retried; frames and idle owners cause no polls.
local control = require ("ao-control")
local owner = {}
local token = 0
local REPLY = "pipewireao.rtc.control."
local CAP_FIELDS = { "version", "instance", "owner-pid", "lifecycle", "last-token", "controllers" }

local function next_token (minimum)
  token = math.max (token, minimum or 0)
  assert (math.type (token) == "integer" and token < math.maxinteger,
      "Owner control token space exhausted")
  token = token + 1
  return token
end
owner.next_token = next_token

local function stop_timers (pending)
  if pending.timer then pending.timer:destroy (); pending.timer = nil end
  if pending.expiry then pending.expiry:destroy (); pending.expiry = nil end
end

local function notify (callback, ...)
  local ok, error = pcall (callback, ...)
  if not ok then Log.warning ("AO control completion callback failed: " .. tostring (error)) end
end

local function exact_fields (values, namespace, names)
  local allowed, count = {}, 0
  for _, name in ipairs (names) do
    local key = namespace .. "." .. name
    assert (values [key], "Missing native control field: " .. key)
    allowed [key] = true
  end
  for key in pairs (values) do
    assert (allowed [key], "Unexpected native control field: " .. key)
    count = count + 1
  end
  assert (count == #names, "Incorrect native control field count")
end

local function positive_metadata (node, key)
  local value = node.properties [key]
  assert (type (value) == "string" and value:match ("^%d+$"),
      "Missing native identity property: " .. key)
  value = tonumber (value)
  assert (math.type (value) == "integer" and value > 0,
      "Invalid native identity property: " .. key)
  return value
end

function owner.new (node, namespace, instance, controller, owner_pid)
  assert (math.type (instance) == "integer" and instance > 0, "Invalid owner instance")
  assert (node.properties ["pipewireao.rtc-control.protocol"] == "pipewireao.rtc-control/1" and
      node.properties ["pipewireao.rtc-control.profile"] == namespace .. "/1",
      "Owner native profile mismatch")
  local pid = positive_metadata (node, "pipewireao.rtc-control.owner-pid")
  assert (pid < 0xffffffff and (owner_pid == nil or pid == owner_pid), "Owner PID mismatch")
  assert (positive_metadata (node, "pipewireao.rtc-control.instance") == instance,
      "Owner endpoint instance mismatch")
  return {
    node = node, identity = control.identity (node), namespace = namespace,
    instance = instance, owner_pid = pid, controller = controller,
    pending = nil, retired = false, profile = namespace .. "/1",
  }
end

function owner.cancel (client)
  client.retired = true
  if client.pending then stop_timers (client.pending) end
  client.pending = nil
end

local function current (client, pending)
  return not client.retired and client.pending == pending
end

local function finish (client, pending, header, payload, error)
  if client.pending ~= pending then return end
  client.pending = nil
  stop_timers (pending)
  notify (pending.callback, header, payload, error)
end

local function check_owner (client)
  assert (control.same_identity (client.node, client.identity), "Owner incarnation changed")
  assert (positive_metadata (client.node, "pipewireao.rtc-control.instance") == client.instance and
      positive_metadata (client.node, "pipewireao.rtc-control.owner-pid") == client.owner_pid and
      client.node.properties ["pipewireao.rtc-control.protocol"] == "pipewireao.rtc-control/1" and
      client.node.properties ["pipewireao.rtc-control.profile"] == client.profile,
      "Owner control identity changed")
end

local function matches (client, pending, header)
  local controller = client.controller
  return header.endpoint == client.instance and header.global_id == controller.global_id and
      header.serial == controller.serial and header.instance == controller.instance and
      header.token == pending.token and header.operation == pending.operation
end

local function capability (values, client)
  local namespace = client.namespace
  exact_fields (values, namespace, CAP_FIELDS)
  assert (control.scalar (values [namespace .. ".version"], "Int") == 1,
      "Unsupported owner control version")
  assert (control.scalar (values [namespace .. ".instance"], "Long") == client.instance and
      control.scalar (values [namespace .. ".owner-pid"], "Id") == client.owner_pid,
      "Owner capability identity mismatch")
  local lifecycle = control.scalar (values [namespace .. ".lifecycle"], "Id")
  assert (lifecycle > 0, "Invalid owner lifecycle")
  local last_token = control.scalar (values [namespace .. ".last-token"], "Long")
  assert (last_token >= 0, "Negative owner accepted token")
  local rows, registered, ids = control.fields (values [namespace .. ".controllers"]), false, {}
  assert (#rows <= 32, "Too many owner controller identities")
  for _, row in ipairs (rows) do
    local fields = control.fields (row, 3)
    local gid = control.scalar (fields [1], "Id")
    local serial = control.scalar (fields [2], "Long")
    local instance = control.scalar (fields [3], "Long")
    assert (gid > 0 and gid < 0xffffffff and serial ~= 0 and instance > 0 and not ids [gid],
        "Invalid or duplicate controller identity")
    ids [gid] = true
    local controller = client.controller
    registered = registered or (gid == controller.global_id and
        serial == controller.serial and instance == controller.instance)
  end
  return registered, last_token, lifecycle
end

local function owner_records (iterator, client, pending)
  assert (iterator, "Owner Props query returned no iterator")
  local registered, last_token, count, lifecycle = false, 0, 0, nil
  local reply_header, reply_payload, reply_error
  local kinds = {}
  for pod in iterator:iterate () do
    count = count + 1
    assert (count <= 3, "Owner published too many Props records")
    local values = control.named_params (pod)
    if values [client.namespace .. ".version"] then
      assert (not kinds.capability, "Duplicate owner capability record")
      kinds.capability = true
      local accepted
      registered, accepted, lifecycle = capability (values, client)
      last_token = math.max (last_token, accepted)
    else
      local kind = values [REPLY .. "completion.header"] and "completion" or
          values [REPLY .. "rejection.header"] and "rejection"
      assert (kind and not kinds [kind], "Unrecognized or duplicate owner Props record")
      kinds [kind] = true
      local header, payload = control.decode (pod, kind)
      assert (header.endpoint == client.instance, "Owner reply instance mismatch")
      last_token = math.max (last_token, header.token)
      -- Initial sentinels and historical records cannot complete an unsent request.
      if pending.submitted and matches (client, pending, header) then
        assert (not reply_header, "Owner published conflicting terminal replies")
        reply_header, reply_payload = header, payload:copy ()
        if kind == "rejection" or header.result < 0 then reply_error = "Owner rejected operation" end
      end
    end
  end
  assert (kinds.capability, "Owner capability record is unavailable")
  return registered, last_token, reply_header, reply_payload, reply_error, lifecycle
end

local function arm_expiry (pending, deadline, callback)
  assert (math.type (deadline) == "integer" and
      deadline - Core.get_monotonic_time () <= 60000000, "Invalid control deadline")
  control.remaining_ns (deadline)
  pending.expiry = Core.timeout_add (math.max (1,
      math.ceil ((deadline - Core.get_monotonic_time ()) / 1000)), callback)
end

local function schedule (pending, deadline, callback)
  local remaining = control.remaining_ns (deadline)
  pending.timer = Core.timeout_add (math.max (1, math.min (5, math.ceil (remaining / 1000000))),
      function () pending.timer = nil; callback (); return false end)
end

local poll
poll = function (client, pending)
  if not current (client, pending) then return end
  local healthy, identity_error = pcall (check_owner, client)
  if not healthy then
    client.retired = true
    finish (client, pending, nil, nil, tostring (identity_error)); return
  end
  if Core.get_monotonic_time () >= pending.deadline then
    finish (client, pending, nil, nil, pending.submitted and
        "Owner completion timed out; outcome unknown" or "Owner controller registration timed out")
    return
  end
  local queried, query_error = pcall (function ()
    client.node:enum_params ("Props", function (iterator, error)
      if not current (client, pending) then return end
      local ok, failure = pcall (function ()
        check_owner (client)
        control.remaining_ns (pending.deadline)
        assert (not error, tostring (error))
        local registered, last_token, header, payload, reply_error =
            owner_records (iterator, client, pending)
        if header then
          finish (client, pending, header, payload, reply_error)
          return
        end
        if not pending.submitted and registered then
          if pending.token <= last_token then pending.token = next_token (last_token) end
          local controller = client.controller
          local request = control.encode ("request", {
            endpoint = client.instance, global_id = controller.global_id,
            serial = controller.serial, instance = controller.instance,
            token = pending.token, operation = pending.operation,
            budget_ns = control.remaining_ns (pending.deadline),
          }, pending.payload)
          pending.submitted = true -- Even a send failure has an unknown outcome.
          client.node:set_param ("Props", request)
        end
        schedule (pending, pending.deadline, function () poll (client, pending) end)
      end)
      if not ok then finish (client, pending, nil, nil, tostring (failure)) end
    end)
  end)
  if not queried then finish (client, pending, nil, nil, tostring (query_error)) end
end

function owner.request (client, operation, payload, deadline, callback)
  assert (not client.retired and not client.pending, "Owner already has a pending operation or is retired")
  deadline = math.min (deadline, Core.get_monotonic_time () + 60000000)
  local pending = {
    operation = operation, payload = payload, deadline = deadline,
    callback = callback, submitted = false,
  }
  client.pending = pending
  local ok, error = pcall (function ()
    check_owner (client)
    pending.token = next_token ()
    arm_expiry (pending, deadline, function ()
      finish (client, pending, nil, nil, pending.submitted and
          "Owner operation expired; submitted outcome unknown" or "Owner registration expired")
      return false
    end)
    poll (client, pending)
  end)
  if not ok then finish (client, pending, nil, nil, tostring (error)) end
  return function ()
    if client.pending ~= pending then return end
    client.pending = nil
    stop_timers (pending)
  end
end

-- Read-only capability wait during cold construction. It never stages status
-- work on an owner that is still preparing science, and has one query in flight.
function owner.wait_prepared (client, deadline, callback)
  assert (not client.retired and not client.pending, "Owner already has a pending operation or is retired")
  local pending = { deadline = deadline, submitted = false }
  client.pending = pending
  local function done (lifecycle, error)
    if client.pending ~= pending then return end
    client.pending = nil
    stop_timers (pending)
    notify (callback, lifecycle, error)
  end
  local poll_ready
  poll_ready = function ()
    if not current (client, pending) then return end
    local ok, error = pcall (function ()
      check_owner (client)
      control.remaining_ns (deadline)
      client.node:enum_params ("Props", function (iterator, failure)
        if not current (client, pending) then return end
        local valid, error = pcall (function ()
          check_owner (client)
          control.remaining_ns (deadline)
          assert (not failure, tostring (failure))
          local registered, _, _, _, _, lifecycle = owner_records (iterator, client, pending)
          assert (lifecycle >= 1 and lifecycle <= 5, "Invalid cold owner lifecycle")
          assert (lifecycle ~= 3, "Cold owner unexpectedly Connected before preparation")
          assert (lifecycle ~= 4 and lifecycle ~= 5, "Cold owner preparation reached Fault or Stopped")
          if lifecycle == 2 and registered then done (lifecycle); return end
          schedule (pending, deadline, poll_ready)
        end)
        if not valid then done (nil, tostring (error)) end
      end)
    end)
    if not ok then done (nil, tostring (error)) end
  end
  local ok, error = pcall (function ()
    assert (math.type (deadline) == "integer" and
        deadline - Core.get_monotonic_time () <= 300000000, "Invalid preparation deadline")
    check_owner (client)
    control.remaining_ns (deadline)
    pending.expiry = Core.timeout_add (math.max (1,
        math.ceil ((deadline - Core.get_monotonic_time ()) / 1000)), function ()
      done (nil, "Owner preparation expired")
      return false
    end)
    poll_ready ()
  end)
  if not ok then done (nil, tostring (error)) end
  return function ()
    if client.pending ~= pending then return end
    client.pending = nil
    stop_timers (pending)
  end
end

local STATUS_FIELDS = { "version", "completed-token", "result" }
local RUN_FIELDS = { "version", "completed-token", "result", "actual-state" }
local SNAPSHOT_FIELDS = { "version", "instance", "kind", "completed-token", "result",
  "generation", "sequence", "running", "completed", "report-generation", "report-sequence" }

local function status_record (values, namespace, run)
  exact_fields (values, namespace, run and RUN_FIELDS or STATUS_FIELDS)
  local record = {
    params = values, token = control.scalar (values [namespace .. ".completed-token"], "Long"),
    result = control.scalar (values [namespace .. ".result"], "Int"),
  }
  assert (control.scalar (values [namespace .. ".version"], "Int") == 1 and
      record.token >= 0 and record.result <= 0, "Invalid native control status")
  if run then
    record.state = control.scalar (values [namespace .. ".actual-state"], "String")
    assert (record.state == "stopped" or record.state == "running" or record.state == "unknown",
        "Invalid native running state")
  end
  return record
end

local function snapshot_record (values, namespace, instance, rejection)
  exact_fields (values, namespace, SNAPSHOT_FIELDS)
  local record = { params = values }
  for _, name in ipairs (SNAPSHOT_FIELDS) do
    local scalar = (name == "running" or name == "completed") and "Bool" or
        ((name == "version" or name == "kind" or name == "result") and "Int" or "Long")
    record [name] = control.scalar (values [namespace .. "." .. name], scalar)
  end
  assert (record.version == 1 and record.instance == instance and instance > 0,
      "Source snapshot identity mismatch")
  assert (record.generation >= 1 and record.sequence >= 0 and record ["report-generation"] >= 1 and
      record ["report-sequence"] >= 0 and record ["report-generation"] <= record.generation and
      (record ["report-generation"] < record.generation or record ["report-sequence"] <= record.sequence) and
      not (record.running and record.completed), "Invalid source snapshot cursor")
  record.token = record ["completed-token"]
  if record.kind == 0 then
    assert (record.token == 0 and record.result == 0, "Invalid initial source snapshot")
  elseif rejection and record.kind == 4 then
    assert (record.token == 0 and record.result < 0, "Invalid malformed-request rejection")
  else
    assert (record.kind >= 1 and record.kind <= 3 and record.token > 0 and
        (rejection and record.result < 0 or not rejection and record.result <= 0),
        "Invalid source snapshot result")
  end
  return record
end

local function node_records (iterator, source_instance)
  assert (iterator, "Node Props query returned no iterator")
  local records, maximum, count = {}, 0, 0
  for pod in iterator:iterate () do
    count = count + 1
    assert (count <= (source_instance and 4 or 3), "Node published too many Props records")
    local values, kind, record = control.named_params (pod)
    if values ["pipewireao.run-control.version"] then
      kind, record = "run", status_record (values, "pipewireao.run-control", true)
      if source_instance then assert (record.state ~= "unknown", "Invalid source running state") end
    elseif values ["pipewireao.reset-control.version"] then
      kind, record = "reset", status_record (values, "pipewireao.reset-control", false)
    elseif source_instance and values ["pipewireao.source-snapshot.version"] then
      kind, record = "snapshot", snapshot_record (values, "pipewireao.source-snapshot", source_instance, false)
    elseif source_instance and values ["pipewireao.source-rejection.version"] then
      kind, record = "rejection", snapshot_record (values, "pipewireao.source-rejection", source_instance, true)
    else
      assert (not source_instance, "Unrecognized source control Props")
      for name in pairs (values) do
        assert (not name:match ("^pipewireao%.[a-z-]+%-control%.") and
            not name:match ("^pipewireao%.source%-"), "Unrecognized reserved node control field")
      end
    end
    if kind then
      assert (not records [kind], "Duplicate node control record")
      records [kind] = record
      maximum = math.max (maximum, record.token)
    end
  end
  if source_instance then assert (records.snapshot, "Source snapshot is unavailable") end
  return records, maximum
end

function owner.node_operation (node, kind, requested_state, deadline, callback)
  deadline = math.min (deadline, Core.get_monotonic_time () + 60000000)
  local pending = { done = false, submitted = false }
  local function finish_node (result, error)
    if pending.done then return end
    pending.done = true
    stop_timers (pending)
    notify (callback, result, error)
  end
  local identity, source_instance, source_pid, state, previous
  local namespace = kind == "query" and "pipewireao.source-query" or "pipewireao." .. tostring (kind) .. "-control"
  local function check_node ()
    assert (control.same_identity (node, identity), "Controlled node incarnation changed")
    if source_instance then
      assert (positive_metadata (node, "pipewireao.source-control.instance") == source_instance and
          positive_metadata (node, "pipewireao.source-control.owner-pid") == source_pid,
          "Source owner identity changed")
    end
  end
  local function matching (records)
    local record = records [kind]
    if source_instance then
      local snapshot = records.snapshot
      local expected_kind = kind == "run" and 1 or kind == "reset" and 2 or 3
      if snapshot.token > pending.token then error ("Source advanced past requested completion") end
      if snapshot.token == pending.token then
        assert (snapshot.kind == expected_kind, "Source completion kind mismatch")
        if kind ~= "query" then
          if not record or record.token ~= pending.token then return nil end
          assert (record.result == snapshot.result and (kind ~= "run" or
              (record.state == "running") == snapshot.running), "Native ACK and source snapshot disagree")
        else record = snapshot end
        assert (snapshot.generation >= previous.generation and
            (snapshot.generation > previous.generation or snapshot.sequence >= previous.sequence),
            "Source cursor moved backwards")
        if snapshot.result == 0 then
          if kind == "reset" then
            assert (previous.generation < math.maxinteger and snapshot.generation == previous.generation + 1 and
                snapshot.sequence == 0 and not snapshot.running and not snapshot.completed,
                "Source reset did not commit a new paused generation")
          end
          if kind == "reset" or snapshot.completed then
            assert (snapshot.generation == snapshot ["report-generation"] and
                snapshot.sequence == snapshot ["report-sequence"], "Source completed before report publication")
          end
        end
      else
        local rejected = records.rejection
        if rejected and rejected.kind == expected_kind and rejected.token == pending.token then
          error ("Source rejected control operation (" .. rejected.result .. ")")
        end
        return nil
      end
    elseif not record or record.token ~= pending.token then
      if record and record.token > pending.token then error ("Node advanced past requested completion") end
      return nil
    end
    assert (record.result == 0, "Node rejected control operation (" .. record.result .. ")")
    if kind == "run" then assert (record.state == state, "Node reported unexpected running state") end
    return record.params
  end
  local poll_node
  poll_node = function ()
    if pending.done then return end
    local healthy, identity_error = pcall (check_node)
    if not healthy then finish_node (nil, tostring (identity_error)); return end
    if Core.get_monotonic_time () >= deadline then
      finish_node (nil, "Node operation expired; outcome unknown"); return
    end
    local queried, query_error = pcall (function ()
      node:enum_params ("Props", function (iterator, error)
        if pending.done then return end
        local ok, failure = pcall (function ()
          check_node ()
          control.remaining_ns (deadline)
          assert (not error, tostring (error))
          local records, maximum = node_records (iterator, source_instance)
          if not pending.submitted then
            if source_instance then previous = records.snapshot end
            pending.token = next_token (maximum)
            local values = { namespace .. ".version", Pod.Int (1),
              namespace .. ".request-token", Pod.Long (pending.token) }
            if kind == "run" then
              values [#values + 1], values [#values + 2] = namespace .. ".requested-state", Pod.String (state)
            elseif kind == "query" then
              values [#values + 1], values [#values + 2] = namespace .. ".instance", Pod.Long (source_instance)
            end
            local request = Pod.Object { "Spa:Pod:Object:Param:Props", "Props", params = Pod.Struct (values) }
            control.remaining_ns (deadline)
            pending.submitted = true
            node:set_param ("Props", request)
          else
            local result = matching (records)
            if result then finish_node (result, nil); return end
          end
          schedule (pending, deadline, poll_node)
        end)
        if not ok then finish_node (nil, tostring (failure)) end
      end)
    end)
    if not queried then finish_node (nil, tostring (query_error)) end
  end
  local ok, error = pcall (function ()
    assert (kind == "run" or kind == "reset" or kind == "query", "Unknown node control")
    identity = control.identity (node)
    if node.properties ["pipewireao.source-control.instance"] then
      source_instance = positive_metadata (node, "pipewireao.source-control.instance")
      source_pid = positive_metadata (node, "pipewireao.source-control.owner-pid")
      assert (source_pid < 0xffffffff, "Invalid source owner PID")
    end
    if kind == "run" then
      state = requested_state == 1 and "stopped" or requested_state == 2 and "running" or requested_state
      assert (state == "stopped" or state == "running", "Invalid requested running state")
    elseif kind == "query" then
      assert (source_instance and source_instance == requested_state, "Source query instance mismatch")
    end
    arm_expiry (pending, deadline, function ()
      finish_node (nil, pending.submitted and "Node operation expired; submitted outcome unknown" or
          "Node control preparation expired")
      return false
    end)
    poll_node ()
  end)
  if not ok then finish_node (nil, tostring (error)) end
  return function ()
    if pending.done then return end
    pending.done = true
    stop_timers (pending)
  end
end

return owner
