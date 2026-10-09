-- WirePlumber
-- SPDX-License-Identifier: MIT

-- One session authority. systemd owns its scientific processes; this policy
-- admits exact prepared owners, connects declared ports and controls acquisition.
local control = require ("ao-control")
local owner = require ("ao-owner")
local acquisition = require ("ao-acquisition")
local connections = require ("ao-connections")
local ingress = require ("ao-session-control")
local args = (...):parse (16)
local spec = assert (args.session, "Session declaration missing")
local instance = assert (tonumber (args.instance), "Session incarnation missing")
assert (math.type (instance) == "integer" and instance > 0, "Invalid session incarnation")
assert (spec.authority == "none" and spec.profile == "development", "Unsupported physical authority")
assert (#spec.links > 0 and #spec.links <= 32, "Invalid declared connection count")
local endpoint = assert (Plugin.find (args ["endpoint.plugin"] or "ao-session-control"))
local controller_endpoint = assert (Plugin.find (args ["controller.plugin"] or "ao-session-controller"))
local state = { lifecycle = 2, epoch = 0, operation = nil, graphs = {}, groups = {},
  owners = {}, generation = 0, faulted = false, source = nil, controller = nil, warmed = false }
local api, catalog
local fault, dispatch

local function cancel_effects (operation)
  if not operation then return end
  if operation.expiry then operation.expiry:destroy () end
  for _, cancel in ipairs (operation.cancels or {}) do pcall (cancel) end
  operation.cancels = {}
end

local function effect (operation, action, ...)
  if catalog and operation.kind ~= 1 then connections.check_core (catalog) end
  local cancel = action (...)
  if type (cancel) == "function" then
    if state.operation == operation then
      operation.cancels [#operation.cancels + 1] = cancel
    else cancel () end
  end
end

local function publish ()
  if api then api.lifecycle = state.lifecycle; ingress.publish (api) end
end

local function guarded (operation, callback)
  return function (...)
    if state.operation ~= operation or state.epoch ~= operation.epoch or
        operation.session ~= instance then return end
    if Core.get_monotonic_time () >= operation.deadline then
      fault ("Internal session effect expired; outcome unknown")
      return
    end
    if operation.ticket then
      local valid, error = pcall (ingress.check_ticket, api, operation.ticket)
      if not valid then fault (tostring (error)); return end
    end
    if catalog and operation.kind ~= 1 then
      local valid, error = pcall (connections.check_core, catalog)
      if not valid then fault (tostring (error)); return end
    end
    local ok, error = pcall (callback, ...)
    if not ok then
      if operation.ticket and not operation.effects_issued then
        cancel_effects (operation)
        state.operation = nil
        ingress.complete (api, operation.ticket, 0, nil, tostring (error))
      else fault ("Session effect failed: " .. tostring (error)) end
    end
  end
end

local function begin (kind, ticket, group)
  assert (not state.operation, "Internal session effect already in flight")
  state.epoch = state.epoch + 1
  local operation = { epoch = state.epoch, session = instance, kind = kind,
    origin = state.lifecycle, group = group, ticket = ticket, cancels = {},
    deadline = ticket and math.min (ticket.deadline, Core.get_monotonic_time () + 5000000) or
        Core.get_monotonic_time () + (args ["startup.timeout-ms"] or 300000) * 1000 }
  state.operation = operation
  operation.expiry = Core.timeout_add (math.max (1, math.ceil (
      (operation.deadline - Core.get_monotonic_time ()) / 1000)), function ()
    if state.operation ~= operation then return false end
    if operation.ticket and not operation.effects_issued then
      cancel_effects (operation)
      state.operation = nil
      ingress.complete (api, operation.ticket, 0, nil, "Session query expired")
    else fault ("Internal session effect expired; outcome unknown") end
    return false
  end)
  return operation
end

local function complete (operation, outcome, details)
  assert (state.operation == operation, "Superseded session transition")
  cancel_effects (operation)
  state.operation = nil
  if operation.ticket then
    api.lifecycle = state.lifecycle
    ingress.complete (api, operation.ticket, outcome, details)
  else publish () end
end

local function sequence (operation, values, action, callback, index)
  index = index or 1
  if index > #values then callback (); return end
  action (values [index], guarded (operation, function (_, error)
    if error then fault (error); return end
    sequence (operation, values, action, callback, index + 1)
  end))
end

local function graph_list (group)
  if group then return assert (state.groups [group], "Unknown execution group").nodes end
  local result = {}
  for name in pairs (state.graphs) do result [#result + 1] = name end
  table.sort (result)
  return result
end

local function run_graphs (operation, running, group, callback)
  operation.effects_issued = true
  local names = graph_list (group)
  local members, depth, visiting, successors = {}, {}, {}, {}
  for _, name in ipairs (names) do members [name] = true end
  for _, link in ipairs (spec.links) do
    local from, to = link.output:match ("^([^:]+):"), link.input:match ("^([^:]+):")
    if members [from] and members [to] then
      successors [from] = successors [from] or {}
      successors [from] [to] = true
    end
  end
  local function rank (name)
    if depth [name] then return depth [name] end
    assert (not visiting [name], "Processing graph has a scheduling cycle")
    visiting [name] = true
    local result = 0
    for next_name in pairs (successors [name] or {}) do result = math.max (result, rank (next_name) + 1) end
    visiting [name], depth [name] = nil, result
    return result
  end
  table.sort (names, function (a, b)
    local da, db = rank (a), rank (b)
    if da == db then return a < b end
    return running and da < db or not running and da > db
  end)
  sequence (operation, names, function (name, done)
    effect (operation, owner.node_operation, state.graphs [name], "run",
        running and 2 or 1, operation.deadline, done)
  end, function ()
    if group then state.groups [group].running = running
    else for _, value in pairs (state.groups) do value.running = running end end
    callback ()
  end)
end

local function source_query (operation, callback)
  assert (state.source, "Held source was not captured")
  effect (operation, acquisition.operation, state.source, "query", nil,
      operation.deadline, guarded (operation, function (snapshot, error)
    if error then fault (error); return end
    state.source.snapshot = snapshot
    callback (snapshot)
  end))
end

local function hold_source (operation, callback)
  operation.effects_issued = true
  effect (operation, acquisition.operation, state.source, "run", 1, operation.deadline,
      guarded (operation, function (snapshot, error)
    if error then fault (error); return end
    assert (not snapshot.running, "Source remained running after hold")
    state.source.snapshot = snapshot
    callback (snapshot)
  end))
end

fault = function (reason)
  if state.faulted then return end
  state.faulted = true
  state.epoch = state.epoch + 1 -- Fence every superseded effect before cleanup.
  local previous = state.operation
  cancel_effects (previous)
  state.operation = nil
  state.lifecycle = 5
  pcall (publish)
  Log.warning ("AO session fault: " .. tostring (reason))
  local deadline = Core.get_monotonic_time () + 5000000
  local function withdraw ()
    connections.withdraw (catalog, deadline, function (_, error)
      if error then Log.warning ("AO session cleanup uncertain: " .. tostring (error)) end
      if previous and previous.ticket and api.pending == previous.ticket then
        pcall (ingress.complete, api, previous.ticket, 0, nil, tostring (reason))
      end
    end)
  end
  if not state.source then withdraw (); return end
  acquisition.operation (state.source, "run", 1, deadline, function (_, error)
    if error then
      Log.warning ("AO source hold uncertain; systemd emergency cleanup required: " .. tostring (error))
      endpoint:call ("disconnect")
      return
    end
    -- Only stop consumers after source hold acknowledgement.
    local names, index = graph_list (), 1
    local next_graph
    next_graph = function ()
      local name = names [index]
      if not name then withdraw (); return end
      index = index + 1
      owner.node_operation (state.graphs [name], "run", 1, deadline, function (_, error)
        if error then Log.warning ("AO graph hold uncertain: " .. tostring (error)) end
        next_graph ()
      end)
    end
    next_graph ()
  end)
end

-- HEART owns its child; Connect only acknowledges the declared native wrapper.
-- Its Ready snapshot is not an acquisition cursor or scientific run state.
local function heart_connected (result)
  local fields = control.fields (result, 3)
  assert (control.scalar (fields [1], "Id") == 2, "HEART wrapper did not remain Ready")
  local message = control.scalar (fields [3], "String")
  assert (#message <= 8192 and not message:find ("\0", 1, true), "Invalid HEART completion message")
  local snapshot = control.fields (fields [2], 9)
  assert (control.scalar (snapshot [1], "Long") >= 1, "Invalid Ready HEART generation")
  assert (control.scalar (snapshot [2], "Id") > 0, "Missing HEART child PID")
  assert (snapshot [3]:get_type_name () == "Spa:None", "Ready HEART child has a return code")
  assert (control.scalar (snapshot [4], "Bool"), "Ready HEART child is not alive")
  local ingress = control.scalar (snapshot [5], "Id")
  assert (ingress == 1 or ingress == 2, "Unknown HEART ingress mode")
  control.scalar (snapshot [6], "Bool") -- Placement facts stay available to admission.
  control.scalar (snapshot [7], "Bool")
  local path = control.scalar (snapshot [8], "String")
  local digest = control.scalar (snapshot [9], "String")
  assert (#path > 0 and #path <= 4096 and not path:find ("\0", 1, true),
      "Missing HEART generation report path")
  assert (#digest == 64 and digest:match ("^[0-9a-f]+$"), "Invalid HEART report SHA-256")
end

local function session_controlled (declaration, role)
  local ownership = declaration.ownership
  assert (ownership == nil or ownership == "runner" or ownership == "external", "Invalid node ownership")
  if ownership ~= "external" then
    assert (declaration ["run-control"] == nil, "Runner-owned node has an external run-control grant")
    return true
  end
  local grant = declaration ["run-control"]
  if role == "graphs" then
    assert (grant == "session" or grant == "application", "External graph requires an explicit run-control grant")
    return grant == "session"
  end
  assert (grant == nil or grant == "application", "External source or sink remains application controlled")
  return false
end

local function graph (name)
  return assert (state.graphs [name], "Undeclared scientific graph")
end

local function named_properties (operation, node, callback)
  node:enum_params ("Props", guarded (operation, function (iterator, error)
    assert (iterator and not error, error or "Missing owner Props reply")
    local values, count = {}, 0
    for pod in iterator:iterate () do
      count = count + 1
      assert (count <= 32, "Owner Props reply exceeds bound")
      local parsed = control.named_params (pod)
      for name, value in pairs (parsed) do
        assert (not values [name], "Duplicate owner property")
        values [name] = value
      end
    end
    callback (values)
  end))
end

local function operation_error (operation, message)
  if state.operation ~= operation then return end
  cancel_effects (operation)
  state.operation = nil
  api.lifecycle = state.lifecycle
  ingress.complete (api, operation.ticket, 0, nil, tostring (message))
end

local function property_update (operation, name, transaction)
  local updates, affected, names = {}, {}, {}
  local rows = control.fields (transaction)
  assert (#rows > 0 and #rows <= 42, "Invalid property transaction size")
  for _, row in ipairs (rows) do
    local fields = control.fields (row, 2)
    local key = control.scalar (fields [1], "String")
    local algorithm, property = key:match ("^([^:]+):(.+)$")
    assert (algorithm and property and not updates [key], "Invalid or duplicate qualified property")
    local kind = fields [2]:get_type_name ()
    assert (kind == "Spa:Bool" or kind == "Spa:Int" or kind == "Spa:Long" or
        kind == "Spa:Float" or kind == "Spa:Double" or kind == "Spa:Id" or kind == "Spa:String",
        "Property must be a native scalar")
    if kind == "Spa:Float" or kind == "Spa:Double" then
      local value = fields [2]:parse ()
      assert (value == value and math.abs (value) < math.huge, "Nonfinite property")
    end
    updates [key], affected [algorithm] = fields [2], true
  end
  for key in pairs (affected) do names [#names + 1] = key end
  table.sort (names)
  local node = graph (name)
  node:enum_params ("PropInfo", guarded (operation, function (iterator, error)
    assert (iterator and not error, error or "Property declarations missing")
    local declarations, count = {}, 0
    for pod in iterator:iterate () do
      count = count + 1
      assert (count <= 4096, "Property declaration count exceeds bound")
      assert (pod:get_type_name () == "Spa:Pod:Object:Param:PropInfo" and
          pod:parse ().object_id == "PropInfo", "Malformed property declaration")
      local fields, flags = {}, {}
      for property in pod:new_iterator ():iterate () do
        local key, value, property_flags = property:get_property ()
        assert (not fields [key], "Duplicate property declaration field")
        fields [key], flags [key] = value, property_flags
      end
      local key = control.scalar (fields.name, "String")
      assert (not declarations [key] and fields.type, "Duplicate/incomplete property declaration")
      local kind = fields.type:get_type_name ()
      if kind == "Spa:Pod:Choice" then kind = fields.type:parse ().value_type end
      declarations [key] = { kind = kind, writable = (flags.type & 1) == 0 }
    end
    for key, value in pairs (updates) do
      local declaration = declarations [key]
      if not declaration or not declaration.writable or declaration.kind ~= value:get_type_name () then
        operation_error (operation, "Undeclared, read-only or incompatible property: " .. key)
        return
      end
    end
    named_properties (operation, node, function (before)
      local baseline = {}
      local running = state.lifecycle == 4
      if running then
        for _, algorithm in ipairs (names) do
          baseline [algorithm] = control.scalar (before [algorithm .. ":requested-generation"], "Long")
        end
      end
      local fields = {}
      for _, row in ipairs (rows) do
        local values = control.fields (row, 2)
        fields [#fields + 1], fields [#fields + 2] = values [1], values [2]
      end
      operation.effects_issued = true
      node:set_param ("Props", Pod.Object { "Spa:Pod:Object:Param:Props", "Props",
        params = Pod.Struct (fields) })
      if not running then
        Core.sync (guarded (operation, function (error)
          if error then fault (error); return end
          local generations = {}
          for _, algorithm in ipairs (names) do
            generations [#generations + 1] = Pod.Struct { algorithm, Pod.None (), Pod.None () }
          end
          complete (operation, 6, Pod.Struct { name, Pod.Struct (generations), Pod.Boolean (false) })
        end))
        return
      end
      local observe
      observe = function ()
        named_properties (operation, node, function (after)
          local generations, adopted = {}, true
          for _, algorithm in ipairs (names) do
            local requested = control.scalar (after [algorithm .. ":requested-generation"], "Long")
            local active = control.scalar (after [algorithm .. ":active-generation"], "Long")
            adopted = adopted and requested > baseline [algorithm] and requested == active
            generations [#generations + 1] = Pod.Struct { algorithm, Pod.Long (requested), Pod.Long (active) }
          end
          if adopted then
            complete (operation, 5, Pod.Struct { name, Pod.Struct (generations), Pod.Boolean (true) })
          else
            Core.timeout_add (5, function ()
              if state.operation == operation then observe () end
              return false
            end)
          end
        end)
      end
      observe ()
    end)
  end))
end

local function parameter_update (operation, name, fields)
  local inlet = control.scalar (fields [2], "String")
  local declaration
  for _, source in ipairs (spec.sources) do
    if source.factory == "pipewireao.runtime-parameter" then
      for _, link in ipairs (spec.links) do
        if link.output == source ["node.name"] .. ":output_1" and
            link.input == name .. ":" .. inlet then
          assert (not declaration, "Ambiguous parameter source")
          declaration = source
        end
      end
    end
  end
  assert (declaration and state.parameters, "Parameter inlet has no captured publisher")
  operation.effects_issued = true
  effect (operation, owner.request, state.parameters, 14, operation.ticket.payload, operation.deadline,
      guarded (operation, function (_, payload, error)
    if error then fault (error); return end
    local result = control.fields (payload, 6)
    assert (control.scalar (result [1], "String") == name and
        control.scalar (result [2], "String") == inlet and
        control.scalar (result [3], "Long") > 0 and
        control.scalar (result [4], "Bool") and not control.scalar (result [5], "Bool"),
        "Parameter submission identity or result differs")
    control.scalar (result [6], "String")
    -- Transport submission is not proof of graph parameter adoption.
    complete (operation, 6, Pod.Struct { name, inlet, Pod.None (), Pod.Boolean (false) })
  end))
end

dispatch = function (ticket)
  local id, fields = ticket.header.operation, control.fields (ticket.payload)
  if id ~= 1 then
    local valid, reason = pcall (connections.check_core, catalog)
    if not valid then fault (tostring (reason)); error (reason) end
  end
  assert (id == 2 or id == 3 or id == 15 or id == 16 or state.lifecycle == 3 or state.lifecycle == 4,
      "Session is not admitted")
  local arity = ({ [1] = 0, [2] = 0, [3] = 0, [4] = 1, [5] = 2, [6] = 2,
    [7] = 1, [8] = 1, [9] = 0, [10] = 0, [11] = 0, [12] = 0, [13] = 2, [14] = 6,
    [15] = 0, [16] = 0 }) [id]
  assert (arity and #fields == arity, "Invalid session command fields")
  local group = (id == 7 or id == 8) and control.scalar (fields [1], "String") or nil
  if group then
    assert (state.groups [group], "Undeclared execution group")
    assert (state.lifecycle == 4, "Selective group control requires a running session")
  end
  if id == 12 then assert (state.lifecycle == 3, "Reset requires a stopped, admitted session") end
  api.lifecycle = state.lifecycle
  if id == 2 then
    local rows = {}
    for name, value in pairs (state.groups) do
      rows [#rows + 1] = Pod.Struct { name, Pod.Id (value.running and 2 or 1) }
    end
    ingress.complete (api, ticket, 2, Pod.Struct { Pod.Struct (rows) })
    return
  elseif id == 3 then
    ingress.complete (api, ticket, 2, Pod.Struct { Pod.Boolean (state.lifecycle == 4),
      Pod.Long (0), Pod.Long (catalog.cohort and #catalog.cohort.proxies or 0),
      Pod.Long (0), Pod.Struct {} })
    return
  elseif id == 15 or id == 16 then
    if id == 15 then assert (state.lifecycle == 2, "Warmup inspection requires Configuring") end
    assert (ticket.header.instance == tonumber (args ["admission.controller-instance"]),
        "Resource admission requires the invocation's launcher controller")
    local controller = ingress.check_ticket (api, ticket)
    if state.admission_controller then
      local previous = state.admission_controller
      assert (controller.global_id == previous.global_id and controller.serial == previous.serial and
          controller.instance == previous.instance and controller.pid == previous.pid,
          "Resource admission launcher incarnation changed")
    else
      assert (id == 15, "Resource admission requires prior warmup inspection")
      state.admission_controller = { global_id = controller.global_id, serial = controller.serial,
        instance = controller.instance, pid = controller.pid }
    end
    if id == 16 then
      assert (state.warmed and state.lifecycle == 2 and not state.operation,
          "Scientific warmup is not awaiting resource admission")
      state.lifecycle, api.lifecycle = 3, 3
    end
    ingress.complete_admin (api, ticket, state.lifecycle, state.warmed)
    return
  end
  local name
  if id == 4 or id == 5 or id == 6 or id == 13 or id == 14 then
    name = control.scalar (fields [1], "String")
    graph (name)
  end
  local operation = begin (id, ticket, group)
  if id == 1 then
    hold_source (operation, function ()
      run_graphs (operation, false, nil, function ()
        connections.withdraw (catalog, operation.deadline, guarded (operation, function (_, error)
          if error then fault (error); return end
          -- Held acquisition, stopped processing and absent owned links are
          -- proved before accepting shutdown. Processes remain systemd-owned.
          state.lifecycle = 1
          api.closing = true
          complete (operation, 1, Pod.Struct { Pod.Boolean (true) })
          if api.transport_lost then return end
          -- Preserve the application outcome if the publication fence fails;
          -- it cannot undo already acknowledged shutdown effects.
          local finished, expiry = false, nil
          local function quit (error)
            if finished then return end
            finished = true
            if expiry then expiry:destroy () end
            if error then Log.warning ("AO quit completion publication fence failed: " .. tostring (error)) end
            endpoint:call ("disconnect") -- Defers core disconnect until after this Lua callback.
          end
          local armed, error = pcall (function ()
            expiry = Core.timeout_add (math.max (1, math.ceil (
                (operation.deadline - Core.get_monotonic_time ()) / 1000)), function ()
              quit ("deadline expired")
              return false
            end)
            Core.sync (quit)
          end)
          if not armed then quit (error) end
        end))
      end)
    end)
  elseif id == 4 or id == 5 or id == 6 then
    local node = graph (name)
    named_properties (operation, node, function (values)
      if id == 4 then
        local rows = {}
        for key, value in pairs (values) do
          local kind = value:get_type_name ()
          if kind == "Spa:Bool" or kind == "Spa:Int" or kind == "Spa:Long" or
              kind == "Spa:Id" or kind == "Spa:Float" or kind == "Spa:Double" or kind == "Spa:String" then
            rows [#rows + 1] = Pod.Struct { key, value }
          end
        end
        complete (operation, 2, Pod.Struct { name, Pod.Struct (rows) })
      else
        local algorithm = control.scalar (fields [2], "String")
        local suffix = id == 5 and "generation" or "parameter-sequence"
        local requested, active = assert (values [algorithm .. ":requested-" .. suffix]),
            assert (values [algorithm .. ":active-" .. suffix])
        control.scalar (requested, "Long")
        if id ~= 5 or active:get_type_name () ~= "Spa:None" then control.scalar (active, "Long") end
        complete (operation, 2, Pod.Struct { name, algorithm, requested, active })
      end
    end)
  elseif id == 7 or id == 8 then
    run_graphs (operation, id == 8, group, function ()
      complete (operation, 3, Pod.Struct { group, Pod.Id (id == 8 and 2 or 1),
        Pod.Id (id == 8 and 2 or 1) })
    end)
  elseif id == 9 or id == 10 or id == 11 or id == 12 then
    if id == 10 then
      assert (state.lifecycle == 3, "Session already running")
      run_graphs (operation, true, nil, function ()
        effect (operation, acquisition.operation, state.source, "run", 2, operation.deadline,
            guarded (operation, function (snapshot, error)
          if error then fault (error); return end
          assert (snapshot.running and not snapshot.completed, "Source release was not observed")
          state.source.snapshot = snapshot
          state.lifecycle = 4
          complete (operation, 4, Pod.Struct { Pod.Id (state.lifecycle) })
        end))
      end)
    else
      local function stop ()
        hold_source (operation, function (before)
        state.lifecycle = 3
        run_graphs (operation, false, nil, function ()
          if id == 12 then
            effect (operation, acquisition.operation, state.source, "reset", nil, operation.deadline,
                guarded (operation, function (after, error)
              if error then fault (error); return end
                assert (not after.running and not after.completed and after.sequence == 0 and
                    after.generation ~= before.generation, "Reset cursor was not adopted")
                sequence (operation, graph_list (), function (name, done)
                  effect (operation, owner.node_operation, graph (name), "reset", nil, operation.deadline, done)
                end, function () complete (operation, 4, Pod.Struct { Pod.Id (state.lifecycle) }) end)
            end))
          else complete (operation, 4, Pod.Struct { Pod.Id (state.lifecycle) }) end
        end)
      end)
      end
      if id == 11 then
        source_query (operation, function (snapshot)
          assert (snapshot.completed and not snapshot.running, "Source end is not confirmed")
          stop ()
        end)
      else stop () end
    end
  elseif id == 13 then
    property_update (operation, name, fields [2])
  elseif id == 14 then
    parameter_update (operation, name, fields)
  else
    -- Unfinished cold owner integrations must not report successful effects.
    operation_error (operation, "Session operation is not implemented in this migration build")
  end
end

catalog = connections.new (spec, assert (args ["node.pids"], "Owner PID map missing"),
    fault, args ["core.owner"])
api = ingress.new (endpoint, instance, function (ticket)
  local previous = state.operation
  local valid, error = pcall (dispatch, ticket)
  if not valid then
    if state.operation ~= previous and state.operation and state.operation.ticket == ticket then
      if state.operation.effects_issued then fault (tostring (error))
      else operation_error (state.operation, error) end
    else ingress.complete (api, ticket, 0, nil, tostring (error)) end
  end
end, fault)
state.lifecycle = 2
publish ()

local startup = begin ("prepare")
local startup_timer
local function prepared ()
  local controller_node = catalog.nodes [controller_endpoint:call ("get-node-id")]
  if not controller_node then return end
  local controller_identity = control.identity (controller_node)
  controller_identity.instance = tonumber (args ["controller.instance"])
  assert (controller_identity.instance and controller_identity.instance > 0, "Controller incarnation missing")
  local bootstraps = {}
  for _, declaration in ipairs (args.owners) do
    if declaration ["bootstrap-node"] then
      local node = connections.node (catalog, declaration ["bootstrap-node"], declaration.pid)
      if not node then return end
      local client = owner.new (node, "pipewireao.rtc.owner-bootstrap",
          tonumber (declaration ["bootstrap-instance"]), controller_identity, declaration.pid)
      bootstraps [#bootstraps + 1] = { client = client, operation = 2 }
      connections.capture_control (catalog, node)
    end
    if declaration ["control-protocol"] == "pipewireao.rtc.heart/1" then
      local node = connections.node (catalog, declaration ["control-node"], declaration.pid)
      if not node then return end
      local client = owner.new (node, "pipewireao.rtc.heart",
          tonumber (declaration ["control-instance"]), controller_identity, declaration.pid)
      bootstraps [#bootstraps + 1] = { client = client, operation = 3 }
      connections.capture_control (catalog, node)
    end
  end
  assert (#bootstraps <= 32, "Too many declared cold owner controls")
  state.controller = controller_identity
  if startup_timer then startup_timer:destroy () end
  sequence (startup, bootstraps, function (bootstrap, done)
    local client = bootstrap.client
    effect (startup, owner.wait_prepared, client, startup.deadline, guarded (startup, function (_, error)
      if error then done (nil, error); return end
      startup.effects_issued = true
      effect (startup, owner.request, client, bootstrap.operation, Pod.Struct {}, startup.deadline,
          guarded (startup, function (_, result, error)
        if not error then
          if bootstrap.operation == 3 then heart_connected (result)
          else
            local fields = control.fields (result, 2)
            if control.scalar (fields [1], "Id") ~= 3 then error = "Owner did not connect" end
          end
        end
        done (result, error)
      end))
    end))
  end, function ()
    local publishers = {}
    for _, declaration in ipairs (args.owners) do
      if declaration ["control-protocol"] == "pipewireao.rtc.parameter-source/1" then
        publishers [#publishers + 1] = declaration
      end
    end
    assert (#publishers <= 1, "Multiple parameter publishers are unsupported")
    sequence (startup, publishers, function (declaration, done)
      connections.await_node (catalog, declaration ["control-node"], declaration.pid,
          startup.deadline, guarded (startup, function (node, error)
        if error then done (nil, error); return end
        state.parameters = owner.new (node, "pipewireao.rtc.parameter-source",
            tonumber (declaration ["control-instance"]), controller_identity, declaration.pid)
        connections.capture_control (catalog, node)
        done (true, nil)
      end))
    end, function ()
      local source = assert (args.source, "Source declaration missing")
      connections.await_node (catalog, source ["control-node"], source.pid,
          startup.deadline, guarded (startup, function (node, error)
        if error then fault (error); return end
        connections.capture_control (catalog, node)
        state.source = acquisition.new (node, source, controller_identity, source.pid)
        effect (startup, acquisition.prepare, state.source, startup.deadline,
            guarded (startup, function (_, error)
          if error then fault (error); return end
    connections.discover (catalog, startup.deadline, guarded (startup, function (rows, error)
      if error then fault (error); return end
      local declared, membership, required = {}, {}, {}
      local has_controlled_graph = false
      for _, role in ipairs ({ "sources", "graphs", "sinks" }) do
        for _, declaration in ipairs (spec [role] or {}) do
          local name = declaration ["node.name"]
          assert (declared [name] == nil, "Duplicate declared node")
          local controlled = session_controlled (declaration, role)
          declared [name] = controlled
          if role == "graphs" and controlled then
            has_controlled_graph = true
            required [name] = true
            -- Latest-hold is infrastructure, with no scientific run/reset control.
            if declaration.factory ~= "api.ndarray.latest-hold" then
              state.graphs [name] = assert (connections.node (catalog, name, args ["node.pids"] [name]))
            end
          elseif role == "sinks" and declaration.ownership ~= "external" then required [name] = true end
        end
      end
      local groups = spec ["execution-groups"] or {}
      assert (has_controlled_graph == (#groups > 0),
          "Execution groups require session-controlled graphs and vice versa")
      for _, group in ipairs (groups) do
        assert (type (group.name) == "string" and #group.name > 0 and
            not group.name:find ("\0", 1, true), "Invalid execution group name")
        assert (not state.groups [group.name], "Duplicate execution group")
        assert (#group.nodes > 0, "Execution group has no members")
        local graphs = {}
        for _, name in ipairs (group.nodes) do
          assert (declared [name] ~= nil and not membership [name], "Unknown or duplicate group member")
          assert (declared [name], "Application-controlled external node cannot belong to an execution group")
          membership [name] = group.name
          if state.graphs [name] then graphs [#graphs + 1] = name end
        end
        assert (#graphs > 0, "Execution group contains no session-controlled processing graph")
        state.groups [group.name] = { nodes = graphs, members = group.nodes, running = false }
      end
      if has_controlled_graph then
        for name in pairs (required) do
          assert (membership [name], "Eligible graph or nonexternal sink has no execution group")
        end
      end
      for _, declaration in ipairs (spec.links) do
        local output, input = declaration.output:match ("^([^:]+):"), declaration.input:match ("^([^:]+):")
        local from, to = membership [output], membership [input]
        assert (not from or not to or from == to, "Link crosses execution groups")
        assert ((not from and to and declaration.passive == true) or
            ((from or not to) and declaration.passive ~= true), "Invalid execution-group passive boundary")
      end
      hold_source (startup, function (snapshot)
        assert (snapshot.sequence == 0 and not snapshot.completed, "Initial source was not held before acquisition")
        connections.realize (catalog, rows, tostring (instance) .. "/1", startup.deadline,
            guarded (startup, function (_, error)
          if error then fault (error); return end
          run_graphs (startup, false, nil, function ()
            state.warmed = true
            complete (startup, 4, Pod.Struct { Pod.Id (state.lifecycle) })
          end)
        end))
      end)
    end))
        end))
      end))
    end)
  end)
end
startup_timer = Core.timeout_add (10, function ()
  if state.operation ~= startup then return false end
  if Core.get_monotonic_time () >= startup.deadline then fault ("Scientific preparation timed out"); return false end
  local ok, error = pcall (prepared)
  if not ok then fault (tostring (error)); return false end
  return state.operation == startup and not state.controller
end)
