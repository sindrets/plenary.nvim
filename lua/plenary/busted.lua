assert = require("luassert")

local Path = require("plenary.path")
local inspect = vim.inspect
local say = require("say")

local dirname = function(p)
  return vim.fn.fnamemodify(p, ":h")
end

--- @param p string|Path
local function basename(p)
  if type(p) == "string" then p = Path:new(p) end
  local parts = p:_split()

  return parts[#parts]
end

--- @class DebugInfoExtended : debuginfo
--- @field traceback string
--- @field message string

local function get_trace(element, level, msg)
  local function trimTrace(info)
    local index = info.traceback:find "\n%s*%[C]"
    info.traceback = info.traceback:sub(1, index)
    return info
  end
  level = level or 3

  local thisdir = dirname(debug.getinfo(1, "Sl").source)
  local info = debug.getinfo(level, "Sl") --[[@as DebugInfoExtended ]]
  while
    info.what == "C"
    or info.short_src:match "luassert[/\\].*%.lua$"
    or (info.source:sub(1, 1) == "@" and thisdir == dirname(info.source))
  do
    level = level + 1
    info = debug.getinfo(level, "Sl") --[[@as DebugInfoExtended ]]
  end

  info.traceback = debug.traceback("", level)
  info.message = msg

  -- local file = busted.getFile(element)
  local file = false
  return file and file.getTrace(file.name, info) or trimTrace(info)
end

local is_headless = require("plenary.nvim_meta").is_headless

-- We are shadowing print so people can reliably print messages
print = function(...)
  local args = {...}

  for i = 1, select("#", ...) do
    io.stdout:write(tostring(args[i]))
    io.stdout:write "\t"
  end

  io.stdout:write "\r\n"
end

local mod = {}

--- @class TestResults
--- @field pass TestResults.Item[]
--- @field fail TestResults.Item[]
--- @field errs TestResults.Item[]
--- @field snapshots TestResults.Snapshots

--- @class TestResults.Item
--- @field descriptions string[]
--- @field msg string

--- @class TestResults.Snapshots
--- @field updated integer
--- @field removed integer

local results --- @type TestResults
local current_file --- @type string
local current_description = {} --- @type string[]
local current_before_each = {} --- @type table<string, function[]>
local current_after_each = {} --- @type table<string, function[]>

--- @class SnapshotState.Entry
--- @field count integer
--- @field [string] SnapshotState.Entry

--- @class PendingSnapshot
--- @field key string
--- @field value string

local current_snapshot --- @type table<string, string>?
local snapshot_state = {} --- @type table<string, SnapshotState.Entry>
local update_snapshots = false --- @type boolean
local pending_snapshots = {} --- @type PendingSnapshot[]

local add_description = function(desc)
  table.insert(current_description, desc)

  return vim.deepcopy(current_description)
end

local pop_description = function()
  current_description[#current_description] = nil
end

local add_new_each = function()
  current_before_each[#current_description] = {}
  current_after_each[#current_description] = {}
end

local clear_last_each = function()
  current_before_each[#current_description] = nil
  current_after_each[#current_description] = nil
end

local call_inner = function(desc, func)
  local desc_stack = add_description(desc)
  add_new_each()
  local ok, msg = xpcall(func, function(msg)
    -- debug.traceback
    -- return vim.inspect(get_trace(nil, 3, msg))
    local trace = get_trace(nil, 3, msg)
    return trace.message .. "\n" .. trace.traceback
  end)
  clear_last_each()
  pop_description()

  return ok, msg, desc_stack
end

local color_table = {
  blue = 34,
  yellow = 33,
  green = 32,
  red = 31,
}

local color_string = function(color, str)
  if not is_headless then
    return str
  end

  return string.format("%s[%sm%s%s[%sm", string.char(27), color_table[color] or 0, str, string.char(27), 0)
end

local SUCCESS = color_string("green", "Success")
local FAIL = color_string("red", "Fail")
local PENDING = color_string("yellow", "Pending")

local HEADER = string.rep("=", 40)

--- @param res TestResults
mod.format_results = function(res)
  print ""
  print(color_string("green", "Success  : "), #res.pass)
  print(color_string("red", "Failed   : "), #res.fail)
  print(color_string("red", "Errors   : "), #res.errs)

  local snap_stats = {}

  if res.snapshots.updated > 0 then
    snap_stats[#snap_stats+1] = string.format("%d updated", res.snapshots.updated)
  end

  if res.snapshots.removed > 0 then
    snap_stats[#snap_stats+1] = string.format("%d removed", res.snapshots.removed)
  end

  if #snap_stats > 0 then
    print(color_string("blue", "Snapshots: "), table.concat(snap_stats, ", "))
  end

  print(HEADER)
end

--- @param desc string
--- @param func function
mod.describe = function(desc, func)
  if not results then
    results = {
      pass = {},
      fail = {},
      errs = {},
      snapshots = {
        updated = 0,
        removed = 0,
      },
    }
  end

  ---@diagnostic disable: lowercase-global
  describe = mod.inner_describe
  local ok, msg, desc_stack = call_inner(desc, func)
  describe = mod.describe
  ---@diagnostic enable: lowercase-global

  if not ok then
    table.insert(results.errs, {
      descriptions = desc_stack,
      msg = msg,
    })
  end
end

--- @param desc string
--- @param func function
mod.inner_describe = function(desc, func)
  local ok, msg, desc_stack = call_inner(desc, func)

  if not ok then
    table.insert(results.errs, {
      descriptions = desc_stack,
      msg = msg,
    })
  end
end

mod.before_each = function(fn)
  table.insert(current_before_each[#current_description], fn)
end

mod.after_each = function(fn)
  table.insert(current_after_each[#current_description], fn)
end

mod.clear = function()
  vim.api.nvim_buf_set_lines(0, 0, -1, false, {})
end

--- @return Path
local function snapshot_path()
  local cur_file_path = Path:new(current_file)
  local dir = cur_file_path:parent() / ".snapshots"
  local name = basename(cur_file_path) .. ".snap"

  return dir / name
end

--- @return string
local function next_snapshot_key()
  local ret = {}
  local cur = snapshot_state

  for i, desc in ipairs(current_description) do
    if not cur[desc] then cur[desc] = { count = 0 } end
    cur = cur[desc]
    if i == #current_description then cur.count = cur.count + 1 end
    ret[#ret+1] = string.format("%s %d", desc, cur.count)
  end

  return table.concat(ret, "###")
end

--- @return string?
local function next_snapshot_value()
  return current_snapshot and current_snapshot[next_snapshot_key()] or nil
end

--- @return table<string, string>
local function load_snapshot()
  local snap_path = snapshot_path()
  local chunk, err = loadfile(tostring(snap_path))

  if not chunk or err then
    error("Failed to load snapshot!\n" .. err)
  end

  local data = chunk()

  for k, v in pairs(data) do
    -- get rid of trailing newline
    data[k] = v:sub(1, -2)
  end

  return data
end

--- @return TestResults.Snapshots
local function write_snapshot()
  local has_snap, cur_snapshot = pcall(load_snapshot)
  if not has_snap then cur_snapshot = {} end

  if not pending_snapshots or #pending_snapshots == 0 then
    if has_snap then
      -- The test file no longer has any snapshot assertions. Delete its
      -- corresponding snapshot file.
      snapshot_path():rm()
    end

    return { updated = 0, removed = #vim.tbl_keys(cur_snapshot) }
  end

  local n_updated = 0
  local ret = {
    "local M = {}",
    "",
  }

  for _, snap in ipairs(pending_snapshots) do
    local s_key = snap.key
        :gsub([[\]], [[\\]])
        :gsub([["]], [[\"]])
    -- Ensure that the value doesn't terminate the string prematurely
    local s_value = snap.value:gsub("%]===%]", "]~~~]")
    if cur_snapshot[snap.key] ~= s_value then n_updated = n_updated + 1 end
    cur_snapshot[snap.key] = nil

    ret[#ret+1] = string.format('M["%s"] = [===[', s_key)
    ret[#ret+1] = s_value
    ret[#ret+1] = "]===]"
    ret[#ret+1] = ""
  end

  ret[#ret+1] = "return M"

  -- Any remaining unmatched keys correspond to snapshots that'll be removed.
  local n_removed = #vim.tbl_keys(cur_snapshot)

  -- Only update the file if something actually changed.
  if n_updated > 0 or n_removed > 0 then
    local snap_path = snapshot_path()
    local txt = table.concat(ret, "\n")
    snap_path:parent():mkdir({ parents = true, exists_ok = true })
    snap_path:write(txt, "w")
  end

  return { updated = n_updated, removed = n_removed }
end

--- @param state table
--- @param arguments table
--- @return boolean
local function match_snapshot(state, arguments)
  local s_actual = inspect(arguments[1])
  arguments[1] = s_actual

  if update_snapshots then
    local t1 = type(arguments[1])

    -- Assert that the value is something we can "serialize"
    assert(
      vim.tbl_contains({
        "nil",
        "number",
        "string",
        "boolean",
        "table",
      }, t1),
      string.format("Cannot create snapshot for value of type '%s'!", t1)
    )

    pending_snapshots[#pending_snapshots+1] = {
      key = next_snapshot_key(),
      value = s_actual,
    }

    return true
  else
    if not current_snapshot then
      local ok, data = pcall(load_snapshot)
      current_snapshot = ok and data or {}
    end

    local s_expected = next_snapshot_value() or nil
    arguments[2] = s_expected or "<snapshot unset>"

    if s_expected == nil then
      state.failure_message = "Missing snapshot! Update snapshots with 'PLENARY_UPDATE_SNAPSHOTS=1'."
      return not state.mod
    end

    return s_expected == s_actual
  end
end

say:set_namespace("en")
say:set("assertion.match_snapshot.positive", "Expected the object to match snapshot!\nPassed in:\n%s\nExpected:\n%s")
say:set("assertion.match_snapshot.negative", "Expected the object not to match snapshot!\nPassed in:\n%s\nExpected:\n%s")
-- ^ Using a negated snapshot assertion doesn't really make sense, but might as
-- well add it for the sake of completeness.
assert:register(
  "assertion",
  "match_snapshot",
  match_snapshot,
  "assertion.match_snapshot.positive",
  "assertion.match_snapshot.negative"
)

--- @class luassert.internal
--- @field match_snapshot fun(actual: any) # Assert that an object matches its corresponding snapshot.

local indent = function(msg, spaces)
  if spaces == nil then
    spaces = 4
  end

  local prefix = string.rep(" ", spaces)
  return prefix .. msg:gsub("\n", "\n" .. prefix)
end

local run_each = function(tbl)
  for _, v in ipairs(tbl) do
    for _, w in ipairs(v) do
      if type(w) == "function" then
        w()
      end
    end
  end
end

--- @param desc string
--- @param func function
mod.it = function(desc, func)
  run_each(current_before_each)
  local ok, msg, desc_stack = call_inner(desc, func)
  run_each(current_after_each)

  local test_result = {
    descriptions = desc_stack,
    msg = nil,
  }

  -- TODO: We should figure out how to determine whether
  -- and assert failed or whether it was an error...

  local to_insert
  if not ok then
    to_insert = results.fail
    test_result.msg = msg

    print(FAIL, "||", table.concat(test_result.descriptions, " "))
    print(indent(msg, 12))
  else
    to_insert = results.pass
    print(SUCCESS, "||", table.concat(test_result.descriptions, " "))
  end

  table.insert(to_insert, test_result)
end

mod.pending = function(desc, func)
  local curr_stack = vim.deepcopy(current_description)
  table.insert(curr_stack, desc)
  print(PENDING, "||", table.concat(curr_stack, " "))
end

_PlenaryBustedOldAssert = _PlenaryBustedOldAssert or assert

---@diagnostic disable: lowercase-global
describe = mod.describe
it = mod.it
pending = mod.pending
before_each = mod.before_each
after_each = mod.after_each
clear = mod.clear
---@diagnostic enable: lowercase-global

mod.run = function(file)
  file = file:gsub("\\", "/")
  current_file = file
  current_snapshot = nil
  snapshot_state = {}
  pending_snapshots = {}
  update_snapshots = vim.env.PLENARY_UPDATE_SNAPSHOTS == "1"

  print("\n" .. HEADER)
  print("Testing: ", file)

  local loaded, msg = loadfile(file)

  if not loaded then
    print(HEADER)
    print "FAILED TO LOAD FILE"
    print(color_string("red", msg))
    print(HEADER)
    if is_headless then
      return vim.cmd "2cq"
    end

    return
  end

  coroutine.wrap(function()
    loaded()

    -- If nothing runs (empty file without top level describe)
    if not results then
      if is_headless then
        return vim.cmd "0cq"
      end

      return
    end

    if update_snapshots then
      results.snapshots = write_snapshot()
    end

    mod.format_results(results)

    if #results.errs ~= 0 then
      print("We had an unexpected error: ", vim.inspect(results.errs), vim.inspect(results))
      if is_headless then
        return vim.cmd "2cq"
      end
    elseif #results.fail > 0 then
      print "Tests Failed. Exit: 1"

      if is_headless then
        return vim.cmd "1cq"
      end
    else
      if is_headless then
        return vim.cmd "0cq"
      end
    end
  end)()
end

return mod
