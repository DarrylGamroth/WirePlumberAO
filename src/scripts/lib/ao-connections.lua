-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Declared session connections. Scientific graph scheduling remains in its
-- owner. Discovery captures registry incarnations once; a replacement with the
-- same name cannot inherit an admitted session.
local control = require ("ao-control")
local connections = {}
local INFO = Feature.Proxy.BOUND | Feature.PipewireObject.INFO

local function same (a, b)
  return a.global_id == b.global_id and a.serial == b.serial
end

local function properties (object)
  return object ["properties"] or object ["global-properties"]
end

local function saved_identity (object, kind, role, endpoint, peer)
  local props = properties (object) or {}
  local identity = { kind = kind, role = role,
    id = object ["bound-id"], serial = props ["object.serial"],
    node_name = props ["node.name"], node_id = props ["node.id"],
    port_name = props ["port.name"], client_id = props ["client.id"],
    pid = props ["application.process.id"], path = props ["object.path"],
    rtc_owner_pid = props ["pipewireao.rtc-control.owner-pid"],
    source_owner_pid = props ["pipewireao.source-control.owner-pid"],
    output_node = props ["link.output.node"], output_port = props ["link.output.port"],
    input_node = props ["link.input.node"], input_port = props ["link.input.port"] }
  identity.pid = identity.pid or identity.rtc_owner_pid or identity.source_owner_pid
  if endpoint and role == "endpoint" then
    identity.node_name = identity.node_name or properties (endpoint.node) ["node.name"]
    identity.node_id = identity.node_id or endpoint.node_identity.global_id
    identity.port_name = identity.port_name or properties (endpoint.port) ["port.name"]
    identity.client_id = identity.client_id or properties (endpoint.node) ["client.id"]
    identity.pid = identity.pid or (endpoint.client and
        properties (endpoint.client) ["application.process.id"]) or
        (endpoint.core_identity and endpoint.core_identity.pid)
  elseif endpoint then
    identity.output_node = identity.output_node or endpoint.node_identity.global_id
    identity.output_port = identity.output_port or endpoint.port_identity.global_id
  end
  if peer then
    identity.input_node = identity.input_node or peer.node_identity.global_id
    identity.input_port = identity.input_port or peer.port_identity.global_id
  end
  return identity
end

local function identity_text (identity)
  local fields = { "kind", "role", "id", "serial", "node_name", "node_id",
    "port_name", "client_id", "pid", "rtc_owner_pid", "source_owner_pid",
    "path", "output_node", "output_port",
    "input_node", "input_port" }
  local parts = {}
  for _, field in ipairs (fields) do
    if identity [field] ~= nil then
      local value = identity [field]
      parts [#parts + 1] = field .. "=" ..
          (type (value) == "string" and string.format ("%q", value) or tostring (value))
    end
  end
  return table.concat (parts, " ")
end

local function remote_core_identity ()
  local info = Core.get_info ()
  return { pid = tonumber (info.properties ["application.process.id"]),
    cookie = info.cookie, name = info.name }
end

local function same_core (a, b)
  return a and b and a.pid == b.pid and a.cookie == b.cookie and a.name == b.name
end

function connections.check_core (catalog)
  assert (not catalog.core_identity or
      same_core (catalog.core_identity, remote_core_identity ()),
      "Declared core incarnation changed")
end

function connections.new (spec, expected_pids, lost, core_owner)
  local catalog = { spec = spec, expected_pids = expected_pids,
    nodes = {}, ports = {}, clients = {}, factories = {}, links = {},
    captured = {}, lost = lost, core_nodes = {} }
  if core_owner then
    local identity = remote_core_identity ()
    assert (math.type (core_owner.pid) == "integer" and core_owner.pid > 0 and
        identity.pid == core_owner.pid, "Declared core process differs from remote core")
    for _, name in ipairs (core_owner.nodes) do
      assert (expected_pids [name] == core_owner.pid and not catalog.core_nodes [name],
          "Invalid declared core node")
      catalog.core_nodes [name] = true
    end
    catalog.core_identity = identity
  end
  catalog.managers = {}
  for kind, objects in pairs ({ node = catalog.nodes, port = catalog.ports,
      client = catalog.clients, factory = catalog.factories, link = catalog.links }) do
    local manager = ObjectManager ({ Interest { type = kind } }, INFO)
    manager:connect ("object-added", function (_, object)
      objects [object ["bound-id"]] = object
      if catalog.waiting then catalog.waiting () end
    end)
    manager:connect ("object-removed", function (_, object)
      -- Signal arguments have fresh userdata wrappers. GObject equality works
      -- through ==; table indexing does not. The live bound ID may be invalid.
      for id, retained in pairs (objects) do
        if retained == object then objects [id] = nil; break end
      end
      local required
      for captured, identity in pairs (catalog.captured) do
        if captured == object then
          catalog.captured [captured] = nil
          required = identity
        end
      end
      if required and not catalog.withdrawing then
        catalog.lost ("Required registry incarnation removed " .. identity_text (required))
      end
    end)
    catalog.managers [kind] = manager
    manager:activate ()
  end
  return catalog
end

-- Clientless linger objects do not identify their original requester. Only
-- explicitly declared core-hosted SPA nodes may use the remote core identity.
local function core_factory (catalog, node, name, expected_pid)
  if not catalog.core_nodes [name] then return nil end
  assert (expected_pid == catalog.core_identity.pid and
      same_core (catalog.core_identity, remote_core_identity ()),
      "Declared core incarnation changed")
  local factory = catalog.factories [tonumber (properties (node) ["factory.id"])]
  if not factory then return nil end
  local props = properties (factory)
  assert (props ["client.id"] == nil and props ["factory.name"] == "spa-node-factory" and
      props ["factory.type.name"] == "PipeWire:Interface:Node",
      "Declared core node is not hosted by the server SPA factory")
  return factory
end

function connections.node (catalog, name, expected_pid)
  local result
  for _, node in pairs (catalog.nodes) do
    local props = properties (node)
    if props ["node.name"] == name then
      assert (not result, "Ambiguous declared node " .. name)
      if props ["client.id"] ~= nil then
        local client = catalog.clients [tonumber (props ["client.id"])]
        if not client then return nil end
        local pid = tonumber (properties (client) ["application.process.id"])
        assert (pid and expected_pid and pid == expected_pid,
            "Declared node has an unexpected process owner: " .. name)
      elseif not core_factory (catalog, node, name, expected_pid) then return nil end
      result = node
    end
  end
  return result
end

function connections.capture_control (catalog, node)
  if catalog.captured [node] then return end
  catalog.captured [node] = saved_identity (node, "node", "control")
  local keys = { "object.serial", "node.name", "client.id",
    "pipewireao.rtc-control.protocol", "pipewireao.rtc-control.profile",
    "pipewireao.rtc-control.instance", "pipewireao.rtc-control.owner-pid",
    "pipewireao.source-control.protocol", "pipewireao.source-control.instance",
    "pipewireao.source-control.owner-pid" }
  local frozen = {}
  for _, key in ipairs (keys) do frozen [key] = properties (node) [key] end
  node:connect ("notify::properties", function ()
    if catalog.withdrawing or not catalog.captured [node] then return end
    for _, key in ipairs (keys) do
      if properties (node) [key] ~= frozen [key] then
        catalog.lost ("Required owner control identity changed")
        return
      end
    end
  end)
end

local function endpoint (catalog, address, direction)
  local name, port_name = address:match ("^([^:]+):(.+)$")
  assert (name and port_name, "Invalid declared endpoint")
  local node = connections.node (catalog, name, catalog.expected_pids [name])
  if not node then return nil end
  local port, contract
  for _, object in pairs (catalog.ports) do
    local props = properties (object)
    if tonumber (props ["node.id"]) == node ["bound-id"] and
        props ["port.name"] == port_name and object:get_direction () == direction then
      assert (not port, "Ambiguous declared port " .. address)
      port = object
    end
  end
  if not port then return nil end
  for _, role in ipairs ({ "sources", "graphs", "sinks" }) do
    for _, declaration in ipairs (catalog.spec [role] or {}) do
      if declaration ["node.name"] == name then
        for _, value in ipairs (declaration.ports or {}) do
          if value.name == port_name and value.direction == direction then contract = value end
        end
      end
    end
  end
  assert (contract, "Port contract missing for " .. address)
  local client = catalog.clients [tonumber (properties (node) ["client.id"])]
  local factory = not client and core_factory (catalog, node, name, catalog.expected_pids [name])
  return { node = node, port = port, client = client, contract = contract,
    node_identity = control.identity (node), port_identity = control.identity (port),
    client_identity = client and control.identity (client), factory = factory,
    factory_identity = factory and control.identity (factory),
    core_identity = factory and catalog.core_identity }
end

local function present (catalog, value)
  return control.same_identity (catalog.nodes [value.node_identity.global_id], value.node_identity) and
      control.same_identity (catalog.ports [value.port_identity.global_id], value.port_identity) and
      ((value.client_identity and control.same_identity (
          catalog.clients [value.client_identity.global_id], value.client_identity)) or
        (value.core_identity and same_core (value.core_identity, remote_core_identity ()) and
          control.same_identity (catalog.factories [value.factory_identity.global_id], value.factory_identity)))
end

local function capture_endpoint (catalog, value)
  for _, object in ipairs ({ value.node, value.port, value.client or value.factory }) do
    if not catalog.captured [object] then
      catalog.captured [object] = saved_identity (object,
          object == value.node and "node" or object == value.port and "port" or
          object == value.client and "client" or "factory", "endpoint", value)
      local props = properties (object)
      local keys = { "object.serial", "node.name", "client.id", "node.id",
          "port.name", "port.direction", "application.process.id", "factory.id",
          "factory.name", "factory.type.name", "module.id" }
      local frozen = {}
      for _, name in ipairs (keys) do
        frozen [name] = props [name]
      end
      object:connect ("notify::properties", function ()
        if catalog.withdrawing or not catalog.captured [object] then return end
        local current = properties (object)
        for _, name in ipairs (keys) do
          if current [name] ~= frozen [name] then catalog.lost ("Required endpoint properties changed"); return end
        end
        if not present (catalog, value) then catalog.lost ("Required endpoint incarnation changed") end
      end)
      if object == value.node then
        local inputs, outputs = object:get_n_input_ports (), object:get_n_output_ports ()
        local function changed ()
          if catalog.withdrawing or not catalog.captured [object] then return end
          if object:get_n_input_ports () ~= inputs or object:get_n_output_ports () ~= outputs then
            catalog.lost ("Required node port inventory changed")
          end
        end
        object:connect ("notify::n-input-ports", changed)
        object:connect ("notify::n-output-ports", changed)
        object:connect ("state-changed", function (_, _, state)
          if state == "error" and not catalog.withdrawing and catalog.captured [object] then
            catalog.lost ("Required node entered error state")
          end
        end)
      end
    end
  end
end

-- Ordering is derived from endpoint dependencies, not declaration order.
local function downstream_order (rows)
  local successors, depth, visiting = {}, {}, {}
  for _, row in ipairs (rows) do
    local output, input = row.output.node_identity.global_id, row.input.node_identity.global_id
    successors [output] = successors [output] or {}
    successors [output] [input] = true
  end
  local function rank (id)
    if depth [id] then return depth [id] end
    assert (not visiting [id], "Session links contain an unbroken scheduling cycle")
    visiting [id] = true
    local result = 0
    for next_id in pairs (successors [id] or {}) do result = math.max (result, rank (next_id) + 1) end
    visiting [id], depth [id] = nil, result
    return result
  end
  local order = {}
  for index, row in ipairs (rows) do
    rank (row.output.node_identity.global_id)
    order [#order + 1] = index
  end
  table.sort (order, function (a, b)
    local da, db = rank (rows [a].input.node_identity.global_id), rank (rows [b].input.node_identity.global_id)
    return da == db and a < b or da < db
  end)
  return order
end

-- SPA Format field IDs are public ABI (format.h). Numeric keys avoid the
-- Audio:rate / NDArray:rate short-name collision in the generic Lua builder.
local FORMAT_FIELDS = {
  [1] = "Id", [2] = "Id", [0x1000001] = "Id", [0x1000002] = "Array",
  [0x1000003] = "Id", [0x1000004] = "Fraction", [0x1000005] = "String",
}

local function validate_format (pod, contract)
  assert (pod:get_size () >= 16 and pod:get_size () <= 65536, "Invalid Format size")
  assert (pod:get_type_name () == "Spa:Pod:Object:Param:Format", "Expected native Format object")
  local object_id = pod:get_object_id ()
  assert (object_id == "Format" or object_id == "EnumFormat", "Invalid Format ID")
  -- Inspect only metadata until selected primitive extents are proved. Fixed
  -- Choice.None may retain trailing alternatives; only its default is active.
  -- The negotiated POD and its property/choice flags are never changed.
  local values, ids, selected, count = { "Spa:Pod:Object:Param:Format", object_id }, {}, {}, 0
  local schema_size
  for property in pod:new_iterator ():iterate () do
    count = count + 1
    assert (count <= 32, "Too many negotiated Format fields")
    local _, value, _, id = property:get_property ()
    assert (id and not ids [id], "Duplicate negotiated Format field")
    ids [id] = true
    local expected = FORMAT_FIELDS [id]
    if expected then
      assert (value:get_size () >= 8 and value:get_size () <= 65536, "Invalid Format field size")
      if value:get_type_name () == "Spa:Pod:Choice" then
        assert (value:get_choice_type () == "None", "Negotiated Format retains an unfixed choice")
        local child, n_values = value:get_choice_child ()
        assert (child and n_values >= 1, "Negotiated Format choice has no complete default")
        value = child
      end
      assert (value:get_type_name () == "Spa:" .. expected, "Incorrect native Format field type")
      if expected == "Id" then
        assert (value:get_size () == 12, "Invalid Format Id width")
      elseif expected == "Fraction" then
        assert (value:get_size () == 16, "Invalid Format Fraction width")
      elseif expected == "String" then
        assert (value:get_size () >= 9 and value:get_size () <= 4105, "Invalid Format schema extent")
        schema_size = value:get_size ()
      elseif expected == "Array" then
        local kind, width, n_values = value:get_array_info ()
        assert (kind == "Spa:Int" and width == 4 and n_values and n_values > 0 and
            n_values <= 32 and n_values == #contract.shape, "Invalid ndarray shape extent")
      end
      selected [id] = true
      values [string.format ("id-%08x", id)] = value
    end -- Unused top-level fields are never recursively parsed.
  end
  local format = Pod.Object (values):parse ().properties
  if selected [0x1000005] then
    assert (type (format.schema) == "string" and #format.schema == schema_size - 9 and
        utf8.len (format.schema) and
        not format.schema:find ("\0", 1, true), "Invalid ndarray schema String")
  end
  assert (format.mediaType == "application" and format.mediaSubtype == "ndarray",
      "Expected ndarray Format")
  assert (format.elementType == contract ["element-type"] and format.schema == contract.schema,
      "Negotiated ndarray element type/schema differs from declaration")
  assert (format.layout == "ROW_MAJOR" or format.layout == "COLUMN_MAJOR", "Unsupported ndarray layout")
  if contract.layout then assert (format.layout == contract.layout, "Unexpected ndarray layout") end
  assert (type (format.shape) == "table" and format.shape.pod_type == "Array" and
      format.shape.value_type == "Spa:Int", "Expected native ndarray shape Int array")
  assert (#format.shape == #contract.shape, "Unexpected ndarray rank")
  for index, dimension in ipairs (contract.shape) do
    assert (format.shape [index] > 0 and format.shape [index] == dimension, "Unexpected ndarray shape")
  end
  if contract.rate then
    local num, denom = contract.rate:match ("^(%d+)/(%d+)$")
    assert (num and tonumber (num) > 0 and tonumber (denom) > 0 and
        type (format.rate) == "table" and format.rate.pod_type == "Fraction" and
        format.rate.num > 0 and format.rate.denom > 0 and
        format.rate.num * tonumber (denom) == tonumber (num) * format.rate.denom,
        "Unexpected ndarray rate")
  end
end

local function bounded (deadline, callback)
  local done, timer = false, nil
  local function finish (...)
    if done then return end
    done = true
    if timer then timer:destroy () end
    if select (1, ...) ~= nil and Core.get_monotonic_time () >= deadline then
      callback (nil, "Connection operation completed after its deadline")
    else callback (...) end
  end
  timer = Core.timeout_add (math.max (1, math.ceil (
      (deadline - Core.get_monotonic_time ()) / 1000)), function ()
    finish (nil, "Connection operation expired; outcome unknown")
    return false
  end)
  return finish, function ()
    if not done and Core.get_monotonic_time () >= deadline then
      finish (nil, "Connection operation expired; outcome unknown")
    end
    return done
  end, function () done = true; if timer then timer:destroy () end end
end

function connections.discover (catalog, deadline, callback)
  assert (not catalog.waiting and not catalog.cohort, "Connection discovery already active")
  local finish, done, cancel = bounded (deadline, function (rows, error)
    catalog.waiting = nil
    catalog.cancel_discovery = nil
    callback (rows, error)
  end)
  catalog.cancel_discovery = cancel
  catalog.waiting = function ()
    if done () then return end
    local ok, rows = pcall (function ()
      local rows = {}
      for index, declaration in ipairs (catalog.spec.links) do
        local output = endpoint (catalog, declaration.output, "output")
        local input = endpoint (catalog, declaration.input, "input")
        if not output or not input then return nil end
        rows [index] = { output = output, input = input, passive = declaration.passive == true }
      end
      return rows
    end)
    if not ok then finish (nil, tostring (rows)); return end
    if not rows then return end
    for _, row in ipairs (rows) do
      for _, value in ipairs ({ row.output, row.input }) do
        capture_endpoint (catalog, value)
      end
    end
    finish (rows, nil)
  end
  catalog.waiting ()
end

function connections.await_node (catalog, name, pid, deadline, callback)
  assert (not catalog.waiting, "Another discovery operation is pending")
  local finish, done, cancel = bounded (deadline, function (node, error)
    catalog.waiting, catalog.cancel_discovery = nil, nil
    callback (node, error)
  end)
  catalog.cancel_discovery = cancel
  catalog.waiting = function ()
    if done () then return end
    local ok, node = pcall (connections.node, catalog, name, pid)
    if not ok then finish (nil, tostring (node))
    elseif node then finish (node, nil) end
  end
  catalog.waiting ()
end

-- Create downstream first. A cohort includes pending proxy activations, so
-- withdrawal cannot confuse an empty registry snapshot with completed cleanup.
function connections.realize (catalog, rows, generation, deadline, callback)
  assert (not catalog.cohort and not catalog.withdrawing, "Old connection cohort remains")
  local order = downstream_order (rows)
  local cohort = { proxies = {}, ids = {}, pending = 0, terminal = false,
    generation = generation, path = "pipewireao/session/" .. generation .. "/" }
  catalog.cohort = cohort
  local finish, done, cancel = bounded (deadline, callback)
  cohort.cancel_realization = cancel
  local next_link
  next_link = function (index)
    if done () or cohort.terminal then return end
    if index > #order then finish (cohort, nil); return end
    local row = rows [order [index]]
    if not present (catalog, row.output) or not present (catalog, row.input) then
      finish (nil, "Endpoint lost during connection realization"); return
    end
    local ok, link = pcall (Link, "link-factory", {
      ["link.output.node"] = row.output.node_identity.global_id,
      ["link.output.port"] = row.output.port_identity.global_id,
      ["link.input.node"] = row.input.node_identity.global_id,
      ["link.input.port"] = row.input.port_identity.global_id,
      ["link.passive"] = row.passive, ["object.linger"] = false,
      ["object.path"] = cohort.path .. order [index],
    })
    if not ok or not link then finish (nil, "Link factory failed"); return end
    cohort.proxies [#cohort.proxies + 1] = link
    local activated, advanced = false, false
    local function inspect ()
      if cohort.terminal or not activated then return end
      if not advanced and done () then return end
      local state = link ["state"]
      if state == "error" or state == "unlinked" then finish (nil, "Link failed"); return end
      if state ~= "paused" and state ~= "active" then
        if advanced then catalog.lost ("Admitted link left negotiated state") end
        return
      end
      local format = link:get_format ()
      if not format then
        if advanced then catalog.lost ("Admitted link lost its negotiated Format") end
        return
      end
      local valid, error = pcall (function ()
        local props = properties (link)
        assert (tonumber (props ["link.output.node"]) == row.output.node_identity.global_id and
            tonumber (props ["link.output.port"]) == row.output.port_identity.global_id and
            tonumber (props ["link.input.node"]) == row.input.node_identity.global_id and
            tonumber (props ["link.input.port"]) == row.input.port_identity.global_id and
            tonumber (props ["client.id"]) == Core.get_own_bound_id (), "Link provenance differs")
        assert ((props ["link.passive"] == "true") == row.passive, "Link passive setting differs")
        validate_format (format, row.output.contract)
        validate_format (format, row.input.contract)
      end)
      if not valid then
        if advanced then catalog.lost ("Admitted link contract changed: " .. tostring (error))
        else finish (nil, tostring (error)) end
        return
      end
      if advanced then return end
      local identity = control.identity (link)
      cohort.ids [identity.global_id] = identity
      catalog.captured [link] = saved_identity (link, "link", "link", row.output, row.input)
      advanced = true
      next_link (index + 1)
    end
    link:connect ("state-changed", function (_, _, state)
      if cohort.terminal then return end
      if state == "error" or state == "unlinked" then
        if done () then catalog.lost ("Required session link failed")
        else finish (nil, "Link failed during realization") end
      else inspect () end
    end)
    link:connect ("pw-proxy-destroyed", function ()
      if not cohort.terminal then catalog.lost ("Required session link destroyed") end
    end)
    link:connect ("notify::format", inspect)
    link:connect ("notify::properties", inspect)
    cohort.pending = cohort.pending + 1
    local started, error = pcall (function ()
      link:activate (INFO, function (_, activation_error)
        cohort.pending = cohort.pending - 1
        if cohort.terminal then
          link:deactivate (Feature.Proxy.BOUND)
          if cohort.cleanup then cohort.cleanup () end
        elseif activation_error then finish (nil, activation_error)
        else activated = true; inspect () end
      end)
    end)
    if not started then
      -- A thrown activation cannot establish whether a completion is queued.
      finish (nil, "Link activation outcome unknown: " .. tostring (error))
    end
  end
  next_link (1)
end

function connections.withdraw (catalog, deadline, callback)
  catalog.withdrawing = true
  catalog.waiting = nil
  if catalog.cancel_discovery then catalog.cancel_discovery (); catalog.cancel_discovery = nil end
  local cohort = catalog.cohort
  if not cohort then
    catalog.captured, catalog.withdrawing = {}, false
    callback (true, nil)
    return
  end
  cohort.terminal = true
  if cohort.cancel_realization then cohort.cancel_realization () end
  local finish, done = bounded (deadline, callback)
  local syncing = false
  cohort.cleanup = function ()
    if done () or syncing or cohort.pending ~= 0 then return end
    syncing = true
    for _, proxy in ipairs (cohort.proxies) do proxy:deactivate (Feature.Proxy.BOUND) end
    Core.sync (function (error)
      if done () then return end
      if error then finish (nil, error); return end
      local absent = true
      for _, link in pairs (catalog.links) do
        local path = properties (link) ["object.path"]
        local identity = cohort.ids [link ["bound-id"]]
        if (identity and same (control.identity (link), identity)) or
            (path and path:sub (1, #cohort.path) == cohort.path) then absent = false end
      end
      if not absent then finish (nil, "Correlated links remain after cleanup fence"); return end
      catalog.cohort, catalog.captured, catalog.withdrawing = nil, {}, false
      finish (true, nil)
    end)
  end
  for _, proxy in ipairs (cohort.proxies) do proxy:deactivate (Feature.Proxy.BOUND) end
  cohort.cleanup ()
end

return connections
