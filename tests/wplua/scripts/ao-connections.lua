-- Cold tests for the exact registry ownership used by ao-connections.

Feature = {
  Proxy = { BOUND = 1 },
  PipewireObject = { INFO = 2 },
}

local core_info = {
  properties = { ["application.process.id"] = "9000" },
  cookie = 1234,
  name = "test-core",
}

Core = {
  get_info = function () return core_info end,
  get_monotonic_time = function () return 1000 end,
  timeout_add = function (_, callback)
    return { destroy = function () end, callback = callback }
  end,
}

local function manager_new (interest)
  local manager = { kind = interest.type, handlers = {} }
  function manager:connect (signal, callback)
    self.handlers [signal] = callback
  end
  function manager:activate () end
  function manager:emit (signal, object)
    assert (self.handlers [signal], "Missing ObjectManager handler: " .. signal)
    self.handlers [signal] (self, object)
  end
  return manager
end

ObjectManager = manager_new
Interest = function (fields) return fields end

local control = require ("ao-control")
local connections = require ("ao-connections")

-- Required modules run in their own Lua environment. Replace only this
-- module's environment so its real resolver sees the cold ObjectManager/Core
-- doubles below; ao-control remains the production module.
local connections_env
for index = 1, 16 do
  local name, value = debug.getupvalue (connections.new, index)
  if not name then break end
  if name == "_ENV" then connections_env = value; break end
end
assert (connections_env, "ao-connections has no module environment upvalue")
local test_env = setmetatable ({}, { __index = connections_env })
test_env.ObjectManager = manager_new
test_env.Interest = Interest
test_env.Core = Core
test_env.Feature = Feature
for index = 1, 16 do
  local name = debug.getupvalue (connections.new, index)
  if not name then break end
  if name == "_ENV" then debug.setupvalue (connections.new, index, test_env); break end
end

local function object (id, serial, properties, direction)
  local value = {
    ["bound-id"] = id,
    properties = properties,
    _signals = {},
    _direction = direction,
    _input_ports = 0,
    _output_ports = 0,
  }
  function value:connect (signal, callback)
    self._signals [signal] = self._signals [signal] or {}
    table.insert (self._signals [signal], callback)
  end
  function value:emit (signal, ...)
    for _, callback in ipairs (self._signals [signal] or {}) do
      callback (self, ...)
    end
  end
  function value:get_direction () return self._direction end
  function value:get_n_input_ports () return self._input_ports end
  function value:get_n_output_ports () return self._output_ports end
  return value
end

local function spec_with (links, sources, sinks)
  return {
    links = links,
    sources = sources or {},
    sinks = sinks or {},
    graphs = {},
  }
end

local function client_node (name, node_id, port_id, client_id, pid, direction, port_name)
  local node = object (node_id, tostring (10000 + node_id), {
    ["object.serial"] = tostring (10000 + node_id),
    ["node.name"] = name,
    ["client.id"] = tostring (client_id),
  })
  local port = object (port_id, tostring (20000 + port_id), {
    ["object.serial"] = tostring (20000 + port_id),
    ["node.id"] = tostring (node_id),
    ["port.name"] = port_name,
    ["port.direction"] = direction == "output" and "out" or "in",
  }, direction)
  local client = object (client_id, tostring (30000 + client_id), {
    ["object.serial"] = tostring (30000 + client_id),
    ["application.process.id"] = tostring (pid),
  })
  return node, port, client
end

local function core_node (name, node_id, port_id, factory_id, direction, port_name)
  local node = object (node_id, tostring (40000 + node_id), {
    ["object.serial"] = tostring (40000 + node_id),
    ["node.name"] = name,
    ["factory.id"] = tostring (factory_id),
  })
  local port = object (port_id, tostring (50000 + port_id), {
    ["object.serial"] = tostring (50000 + port_id),
    ["node.id"] = tostring (node_id),
    ["port.name"] = port_name,
    ["port.direction"] = direction == "output" and "out" or "in",
  }, direction)
  local factory = object (factory_id, tostring (60000 + factory_id), {
    ["object.serial"] = tostring (60000 + factory_id),
    ["factory.name"] = "spa-node-factory",
    ["factory.type.name"] = "PipeWire:Interface:Node",
    ["module.id"] = "5",
  })
  return node, port, factory
end

local function add (catalog, kind, ...)
  -- The legacy resolver has no factory manager; let its core-node lookup
  -- reach the same acceptance assertion for the fail-before check.
  if kind == "factory" and not catalog.managers [kind] then return end
  for _, value in ipairs ({ ... }) do
    catalog.managers [kind]:emit ("object-added", value)
  end
end

local function raises (message, fn)
  local ok, err = pcall (fn)
  assert (not ok, "Expected failure: " .. message)
  assert (tostring (err):find (message, 1, true),
      "Expected error containing '" .. message .. "', got: " .. tostring (err))
end

local CORE_PID = 9000
local SIM_PID = 9001
local CORE_OWNER = { pid = CORE_PID, nodes = { "heart-sink" } }

-- Existing client-backed nodes keep using their owning PipeWire client.
do
  catalog_losses = {}
  local spec = spec_with ({}, {}, {})
  local catalog = connections.new (spec, { ["sim-node"] = SIM_PID }, function () end)
  local node, _, client = client_node ("sim-node", 10, 11, 12, SIM_PID, "output", "out")
  add (catalog, "client", client)
  add (catalog, "node", node)
  assert (connections.node (catalog, "sim-node", SIM_PID) == node)
end

-- Only an explicitly declared core node hosted by the server SPA factory may
-- use the remote core PID/cookie/name identity.
do
  catalog_losses = {}
  local spec = spec_with ({}, {}, {})
  local catalog = connections.new (spec, { ["heart-sink"] = CORE_PID }, function () end,
      CORE_OWNER)
  local node, _, factory = core_node ("heart-sink", 20, 21, 22, "input", "frame")
  add (catalog, "factory", factory)
  add (catalog, "node", node)
  assert (connections.node (catalog, "heart-sink", CORE_PID) == node)
  connections.check_core (catalog)

  local saved = core_info
  core_info = { properties = { ["application.process.id"] = "9001" }, cookie = 1234, name = "test-core" }
  raises ("Declared core incarnation changed", function ()
    connections.node (catalog, "heart-sink", CORE_PID)
  end)
  raises ("Declared core incarnation changed", function () connections.check_core (catalog) end)
  core_info = { properties = { ["application.process.id"] = "9000" }, cookie = 9999, name = "test-core" }
  raises ("Declared core incarnation changed", function ()
    connections.node (catalog, "heart-sink", CORE_PID)
  end)
  core_info = { properties = { ["application.process.id"] = "9000" }, cookie = 1234, name = "other-core" }
  raises ("Declared core incarnation changed", function ()
    connections.node (catalog, "heart-sink", CORE_PID)
  end)
  core_info = saved
  connections.check_core (catalog)

  local wrong_pid_owner = { pid = CORE_PID + 1, nodes = { "heart-sink" } }
  raises ("Declared core process differs from remote core", function ()
    connections.new (spec, { ["heart-sink"] = CORE_PID }, function () end, wrong_pid_owner)
  end)
end

-- Clientless nodes outside the explicit core allow-list are not adopted.
do
  catalog_losses = {}
  local spec = spec_with ({}, {}, {})
  local catalog = connections.new (spec,
      { ["heart-sink"] = CORE_PID, ["other-sink"] = CORE_PID }, function () end,
      { pid = CORE_PID, nodes = { "heart-sink" } })
  local node, _, factory = core_node ("other-sink", 30, 31, 32, "input", "frame")
  add (catalog, "factory", factory)
  add (catalog, "node", node)
  assert (connections.node (catalog, "other-sink", CORE_PID) == nil)
end

-- A present client.id that cannot be resolved must not fall back to the SPA
-- factory path, even when the node name is allow-listed.
do
  catalog_losses = {}
  local catalog = connections.new (spec_with ({}, {}, {}),
      { ["heart-sink"] = CORE_PID }, function () end, CORE_OWNER)
  local node, _, factory = core_node ("heart-sink", 40, 41, 42, "input", "frame")
  node.properties ["client.id"] = "77"
  add (catalog, "factory", factory)
  add (catalog, "node", node)
  assert (connections.node (catalog, "heart-sink", CORE_PID) == nil)
end

-- A client-backed node cannot claim another process, and an allow-listed core
-- node must resolve the exact server SPA factory.
do
  catalog_losses = {}
  local catalog = connections.new (spec_with ({}, {}, {}),
      { ["sim-node"] = SIM_PID }, function () end)
  local node, _, client = client_node ("sim-node", 50, 51, 52, SIM_PID + 1, "output", "out")
  add (catalog, "client", client)
  add (catalog, "node", node)
  raises ("Declared node has an unexpected process owner", function ()
    connections.node (catalog, "sim-node", SIM_PID)
  end)

  for _, bad in ipairs ({
      { name = "wrong-factory", type = "PipeWire:Interface:Node" },
      { name = "spa-node-factory", type = "PipeWire:Interface:Port" },
    }) do
    local core_catalog = connections.new (spec_with ({}, {}, {}),
        { ["heart-sink"] = CORE_PID }, function () end, CORE_OWNER)
    local core, _, spa = core_node ("heart-sink", 60, 61, 62, "input", "frame")
    spa.properties ["factory.name"] = bad.name
    spa.properties ["factory.type.name"] = bad.type
    add (core_catalog, "factory", spa)
    add (core_catalog, "node", core)
    raises ("Declared core node is not hosted by the server SPA factory", function ()
      connections.node (core_catalog, "heart-sink", CORE_PID)
    end)
  end
end

local function discovery_session ()
  catalog_losses = {}
  core_info = {
    properties = { ["application.process.id"] = tostring (CORE_PID) },
    cookie = 1234,
    name = "test-core",
  }
  local spec = spec_with ({
    { output = "sim-wfs:output_1", input = "heart-sink:frame", passive = false },
  }, {
    { ["node.name"] = "sim-wfs", ports = {
      { name = "output_1", direction = "output" },
    } },
  }, {
    { ["node.name"] = "heart-sink", ports = {
      { name = "frame", direction = "input" },
    } },
  })
  local catalog = connections.new (spec, {
    ["sim-wfs"] = SIM_PID,
    ["heart-sink"] = CORE_PID,
  }, function (reason) table.insert (catalog_losses, reason) end, CORE_OWNER)
  local sim, sim_port, client = client_node ("sim-wfs", 70, 71, 72, SIM_PID, "output", "output_1")
  local heart, heart_port, factory = core_node ("heart-sink", 80, 81, 82, "input", "frame")
  add (catalog, "client", client)
  add (catalog, "factory", factory)
  add (catalog, "node", sim, heart)
  add (catalog, "port", sim_port, heart_port)
  return catalog, { sim = sim, sim_port = sim_port, client = client,
    heart = heart, heart_port = heart_port, factory = factory }
end

local function discover (catalog)
  local result, failure
  connections.discover (catalog, 1000000, function (rows, error)
    result, failure = rows, error
  end)
  return result, failure
end

local function resolved_catalog ()
  local catalog, objects = discovery_session ()
  local rows, err = discover (catalog)
  assert (rows and not err, "Discovery failed: " .. tostring (err))
  assert (#rows == 1 and rows [1].passive == false)
  local output, input = rows [1].output, rows [1].input
  assert (output.node_identity.global_id == 70 and output.node_identity.serial == 10070)
  assert (output.port_identity.global_id == 71 and output.port_identity.serial == 20071)
  assert (output.client_identity.global_id == 72 and output.client_identity.serial == 30072)
  assert (input.node_identity.global_id == 80 and input.node_identity.serial == 40080)
  assert (input.port_identity.global_id == 81 and input.port_identity.serial == 50081)
  assert (input.factory_identity.global_id == 82 and input.factory_identity.serial == 60082)
  assert (input.core_identity.pid == CORE_PID and input.core_identity.cookie == 1234 and
      input.core_identity.name == "test-core")
  return catalog, objects, input
end

-- Discovery retains exact endpoint/factory identities and fails closed on
-- registry removal or identity property changes.
do
  local catalog, objects, input = resolved_catalog ()
  assert (input.factory == objects.factory)
  assert (control.identity (input.factory).global_id == input.factory_identity.global_id)
end

for _, case in ipairs ({
    { kind = "node", key = "heart", property = "node.name", value = "replacement" },
    { kind = "port", key = "heart_port", property = "port.name", value = "replacement" },
    { kind = "factory", key = "factory", property = "factory.name", value = "replacement" },
  }) do
  local catalog, objects = resolved_catalog ()
  local target = objects [case.key]
  target.properties [case.property] = case.value
  target:emit ("notify::properties")
  assert (#catalog_losses == 1, "Expected property-change loss for " .. case.kind)
end

for _, case in ipairs ({
    { kind = "node", key = "heart" },
    { kind = "port", key = "heart_port" },
    { kind = "factory", key = "factory" },
  }) do
  local catalog, objects = resolved_catalog ()
  catalog.managers [case.kind]:emit ("object-removed", objects [case.key])
  assert (#catalog_losses == 1 and catalog_losses [1] == "Required registry incarnation removed",
      "Expected removal loss for " .. case.kind)
end
