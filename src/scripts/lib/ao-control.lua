-- WirePlumber
-- SPDX-License-Identifier: MIT

-- Native control envelope shared by AO session policy and owner clients.
-- These helpers operate on control PODs; no frame buffers enter Lua.
local control = {}
local PREFIX = "pipewireao.rtc.control."
local PROPS = "Spa:Pod:Object:Param:Props"
local STRUCT = "Spa:Pod:Struct"

function control.scalar (pod, name)
  assert (pod:get_type_name () == "Spa:" .. name, "Incorrect control scalar type")
  local value = pod:parse ()
  if name == "String" then
    assert (utf8.len (value), "Invalid UTF-8 control string")
  end
  return value
end

function control.fields (pod, count)
  assert (pod:get_type_name () == STRUCT, "Expected a control Struct")
  local result = {}
  for child in pod:new_iterator ():iterate () do
    result [#result + 1] = child:copy ()
  end
  assert (count == nil or #result == count, "Incorrect control Struct arity")
  return result
end

function control.properties (pod)
  assert (pod:get_type_name () == PROPS, "Expected a Props parameter")
  assert (pod:parse ().object_id == "Props", "Incorrect Props object ID")
  local properties = {}
  for property in pod:new_iterator ():iterate () do
    local key, value, flags = property:get_property ()
    assert (key and not properties [key], "Duplicate control property")
    assert (flags == 0, "Unexpected control property flags")
    properties [key] = value
  end
  return properties
end

function control.params (pod)
  local properties = control.properties (pod)
  assert (properties.params, "Missing control params")
  for key in pairs (properties) do
    assert (key == "params", "Unexpected control property")
  end
  return control.fields (properties.params)
end

function control.named_params (pod)
  local fields, values = control.params (pod), {}
  assert (#fields % 2 == 0, "Incorrect named control fields")
  for index = 1, #fields, 2 do
    local name = control.scalar (fields [index], "String")
    assert (not values [name], "Duplicate control field")
    values [name] = fields [index + 1]
  end
  return values
end

local LEAVES = {
  ["Spa:None"] = true, ["Spa:Bool"] = true, ["Spa:Id"] = true,
  ["Spa:Int"] = true, ["Spa:Long"] = true, ["Spa:Float"] = true,
  ["Spa:Double"] = true, ["Spa:String"] = true, ["Spa:Bytes"] = true,
}

local function validate_payload (pod, depth)
  local name = pod:get_type_name ()
  if name == STRUCT then
    assert (depth <= 8, "Control payload nesting exceeds eight")
    for _, child in ipairs (control.fields (pod)) do
      validate_payload (child, depth + 1)
    end
  elseif name == "Spa:Array" then
    local parsed = pod:parse ()
    assert (parsed.value_type == "Spa:Bool" or parsed.value_type == "Spa:Id" or
        parsed.value_type == "Spa:Int" or parsed.value_type == "Spa:Long" or
        parsed.value_type == "Spa:Float" or parsed.value_type == "Spa:Double",
        "Unsupported control array element type")
  else
    assert (LEAVES [name], "Unsupported control payload type")
  end
end

function control.decode (pod, kind)
  assert (kind == "request" or kind == "completion" or kind == "rejection",
      "Unknown control record kind")
  local fields = control.params (pod)
  assert (#fields == 4, "Incorrect control envelope arity")
  assert (control.scalar (fields [1], "String") == PREFIX .. kind .. ".header" and
      control.scalar (fields [3], "String") == PREFIX .. kind .. ".payload",
      "Incorrect control envelope field names")
  local values = control.fields (fields [2], 8)
  local header = {
    version = control.scalar (values [1], "Int"),
    endpoint = control.scalar (values [2], "Long"),
    global_id = control.scalar (values [3], "Id"),
    serial = control.scalar (values [4], "Long"),
    instance = control.scalar (values [5], "Long"),
    token = control.scalar (values [6], "Long"),
    operation = control.scalar (values [7], "Id"),
  }
  header [kind == "request" and "budget_ns" or "result"] =
      control.scalar (values [8], kind == "request" and "Long" or "Int")
  assert (header.version == 1 and header.endpoint > 0, "Invalid control version/incarnation")
  local sentinel = kind ~= "request" and header.global_id == 0 and
      header.serial == 0 and header.instance == 0 and header.token == 0 and header.operation == 0
  assert (sentinel or (header.global_id > 0 and header.global_id < 0xffffffff and
      header.serial ~= 0 and header.instance > 0 and header.token > 0 and
      header.operation > 0), "Invalid control request identity")
  if kind == "request" then
    assert (header.budget_ns > 0, "Invalid control deadline")
  else
    assert (header.result <= 0, "Invalid control result")
    assert (kind ~= "rejection" or header.result < 0, "Rejection requires a negative result")
  end
  assert (fields [4]:get_type_name () == STRUCT, "Expected native control payload Struct")
  validate_payload (fields [4], 1)
  if sentinel then
    if kind == "completion" then
      assert (header.result == 0 and #control.fields (fields [4]) == 0,
          "Invalid initial completion sentinel")
    else
      assert (header.result < 0, "Invalid initial rejection sentinel")
    end
  end
  return header, fields [4]
end

function control.encode (kind, header, payload)
  assert (payload:get_type_name () == STRUCT, "Expected native control payload")
  local tail = kind == "request" and Pod.Long (header.budget_ns) or Pod.Int (header.result)
  return Pod.Object {
    PROPS, "Props", params = Pod.Struct {
      PREFIX .. kind .. ".header", Pod.Struct {
        Pod.Int (1), Pod.Long (header.endpoint), Pod.Id (header.global_id),
        Pod.Long (header.serial), Pod.Long (header.instance), Pod.Long (header.token),
        Pod.Id (header.operation), tail,
      },
      PREFIX .. kind .. ".payload", payload,
    },
  }
end

function control.identity (object)
  local properties = object ["properties"]
  local serial = properties ["object.serial"] or object ["global-properties"] ["object.serial"]
  assert (type (serial) == "string" and serial:match ("^%d+$"), "Missing object serial")
  assert (#serial <= 20 and (#serial < 20 or serial <= "18446744073709551615"),
      "Object serial exceeds UInt64")
  -- Preserve full UInt64 serial bits using Lua integer arithmetic rather than
  -- tonumber(), which may convert out-of-range integers to floating point.
  local bits = 0
  for digit in serial:gmatch (".") do bits = bits * 10 + tonumber (digit) end
  assert (bits ~= 0, "Invalid object serial")
  return { global_id = object ["bound-id"], serial = bits }
end

function control.same_identity (object, identity)
  if not object then return false end
  local current = control.identity (object)
  return current.global_id == identity.global_id and current.serial == identity.serial
end

function control.deadline (budget_ns)
  assert (math.type (budget_ns) == "integer" and budget_ns > 0 and
      budget_ns <= 60000000000, "Control budget exceeds sixty seconds")
  return Core.get_monotonic_time () + math.ceil (budget_ns / 1000)
end

function control.remaining_ns (deadline)
  local remaining = deadline - Core.get_monotonic_time ()
  assert (remaining > 0, "Control operation expired")
  return remaining * 1000
end

return control
