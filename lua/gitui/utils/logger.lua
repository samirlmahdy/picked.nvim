---@brief Leveled logger with an in-memory ring buffer and optional file sink.
---
---The ring buffer backs `:GitUILog`, so users can diagnose problems without
---restarting Neovim with a higher log level.

local M = {}

---@enum GitUILogLevel
local LEVELS = {
  trace = 1,
  debug = 2,
  info = 3,
  warn = 4,
  error = 5,
  off = 6,
}

local LEVEL_NAMES = { "TRACE", "DEBUG", "INFO", "WARN", "ERROR" }

local RING_CAPACITY = 500

---@class GitUILogEntry
---@field level integer
---@field time number
---@field message string

---@type GitUILogEntry[]
local ring = {}
local ring_start = 1
local ring_count = 0

local current_level = LEVELS.warn
local file_handle = nil
local file_path = nil

---@param level string
function M.set_level(level)
  current_level = LEVELS[level] or LEVELS.warn
end

---@return string
function M.get_level()
  for name, value in pairs(LEVELS) do
    if value == current_level then
      return name
    end
  end
  return "warn"
end

---@return string
function M.file()
  if not file_path then
    local dir = vim.fn.stdpath("log")
    if vim.fn.isdirectory(dir) == 0 then
      dir = vim.fn.stdpath("cache")
    end
    file_path = dir .. "/gitui.log"
  end
  return file_path
end

local function push(entry)
  local index = (ring_start + ring_count - 1) % RING_CAPACITY + 1
  if ring_count < RING_CAPACITY then
    ring_count = ring_count + 1
  else
    ring_start = ring_start % RING_CAPACITY + 1
  end
  ring[index] = entry
end

---Render a value for the log without the noise of full `vim.inspect` output on
---long tables.
---@param value any
---@return string
local function render(value)
  if type(value) == "string" then
    return value
  end
  local ok, text = pcall(vim.inspect, value, { newline = " ", indent = "" })
  if not ok then
    return tostring(value)
  end
  if #text > 600 then
    return text:sub(1, 600) .. "…"
  end
  return text
end

---@param level integer
---@param ... any
local function log(level, ...)
  if level < current_level then
    return
  end

  local parts = {}
  local argc = select("#", ...)
  for i = 1, argc do
    parts[#parts + 1] = render((select(i, ...)))
  end
  local message = table.concat(parts, " ")

  push({ level = level, time = os.time(), message = message })

  -- The file sink is only opened once something at or above `warn` is logged,
  -- or when the user explicitly raised the level.
  if level >= LEVELS.warn or current_level <= LEVELS.debug then
    if not file_handle then
      file_handle = io.open(M.file(), "a")
    end
    if file_handle then
      file_handle:write(
        ("%s [%s] %s\n"):format(os.date("%Y-%m-%d %H:%M:%S"), LEVEL_NAMES[level] or "?", message)
      )
      file_handle:flush()
    end
  end
end

function M.trace(...)
  log(LEVELS.trace, ...)
end
function M.debug(...)
  log(LEVELS.debug, ...)
end
function M.info(...)
  log(LEVELS.info, ...)
end
function M.warn(...)
  log(LEVELS.warn, ...)
end
function M.error(...)
  log(LEVELS.error, ...)
end

---All buffered entries, oldest first.
---@return string[]
function M.lines()
  local out = {}
  for i = 0, ring_count - 1 do
    local index = (ring_start + i - 1) % RING_CAPACITY + 1
    local entry = ring[index]
    if entry then
      out[#out + 1] = ("%s [%-5s] %s"):format(
        os.date("%H:%M:%S", entry.time),
        LEVEL_NAMES[entry.level] or "?",
        entry.message
      )
    end
  end
  return out
end

function M.clear()
  ring = {}
  ring_start = 1
  ring_count = 0
end

function M.close()
  if file_handle then
    file_handle:close()
    file_handle = nil
  end
end

return M
