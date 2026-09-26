---@brief Notifications and progress reporting.
---
---Messages are short and say what happened, not how git was invoked. The full
---command output is never discarded: it is handed to the output buffer, and
---every error message says how to reach it.

local icons = require("picked.utils.icons")
local logger = require("picked.utils.logger")

local M = {}

local TITLE = "picked"

---@type table<string, boolean>
local spinner_active = {}

---Progress is also published here so statuslines can show it.
---@type table<string, string>
M.active = {}

---@param level integer
---@param message string
---@param opts table|nil
local function emit(level, message, opts)
  opts = vim.tbl_extend("force", { title = TITLE }, opts or {})
  vim.schedule(function()
    vim.notify(message, level, opts)
  end)
end

---@param message string
function M.info(message)
  emit(vim.log.levels.INFO, message)
end

---@param message string
function M.success(message)
  emit(vim.log.levels.INFO, ("%s %s"):format(icons.get("success"), message))
end

---@param message string
function M.warn(message)
  emit(vim.log.levels.WARN, ("%s %s"):format(icons.get("warning"), message))
end

---Report a failure.
---
---Every error answers three questions: what happened (`title`), why
---(`reason`), and what to do next (`hint`). The raw git output is kept so the
---user can inspect it.
---@param err GitError|string
---@param opts { context: string|nil, output: string|nil }|nil
function M.error(err, opts)
  opts = opts or {}

  if type(err) == "string" then
    emit(vim.log.levels.ERROR, ("%s %s"):format(icons.get("failure"), err))
    return
  end

  logger.warn("operation failed:", err.title, err.reason, err.raw)

  local lines = { ("%s %s"):format(icons.get("failure"), err.title) }
  if err.reason and err.reason ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = err.reason
  end
  if err.hint then
    lines[#lines + 1] = ""
    lines[#lines + 1] = err.hint
  end

  local raw = opts.output or err.raw
  if raw and raw ~= "" then
    require("picked.ui.output").store(opts.context or err.title, raw)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Run :PickedOutput to see the full git output."
  end

  emit(vim.log.levels.ERROR, table.concat(lines, "\n"))
end

--- Progress ------------------------------------------------------------------

---@class PickedProgress
---@field update fun(self: PickedProgress, detail: string)
---@field finish fun(self: PickedProgress, ok: boolean, message: string|nil, err: GitError|nil)

local Progress = {}
Progress.__index = Progress

---@param detail string
function Progress:update(detail)
  self.detail = detail
  M.active[self.key] = ("%s %s"):format(self.frame, self.title)
end

---@param ok boolean
---@param message string|nil
---@param err GitError|nil
function Progress:finish(ok, message, err)
  if self.done then
    return
  end
  self.done = true

  spinner_active[self.key] = nil
  M.active[self.key] = nil

  if self.timer then
    self.timer:stop()
    if not self.timer:is_closing() then
      self.timer:close()
    end
    self.timer = nil
  end

  if ok then
    M.success(message or (self.title .. " done"))
  elseif err then
    M.error(err, { context = self.title, output = self.output })
  elseif message then
    M.error(message)
  end

  local events = require("picked.utils.events")
  events.emit(events.names.OPERATION_FINISHED, {
    root = self.root,
    operation = self.key,
    ok = ok,
  })
end

---Start a long-running operation.
---
---Returns a handle whose `finish` must be called exactly once. The spinner is
---published to `M.active` for statusline integrations rather than repeatedly
---calling `vim.notify`, which would flood a plain notification history.
---@param title string  e.g. "Fetching origin"
---@param opts { key: string|nil, root: string|nil }|nil
---@return PickedProgress
function M.progress(title, opts)
  opts = opts or {}
  local key = opts.key or title

  local handle = setmetatable({
    title = title,
    key = key,
    root = opts.root,
    frame = icons.set.spinner[1],
    done = false,
    detail = nil,
    output = nil,
  }, Progress)

  M.active[key] = ("%s %s"):format(handle.frame, title)
  spinner_active[key] = true

  local frames = icons.set.spinner
  local index = 1
  local timer = vim.uv.new_timer()
  if timer then
    handle.timer = timer
    timer:start(
      80,
      80,
      vim.schedule_wrap(function()
        if not spinner_active[key] then
          return
        end
        index = index % #frames + 1
        handle.frame = frames[index]
        local label = handle.detail and ("%s: %s"):format(title, handle.detail) or title
        M.active[key] = ("%s %s"):format(handle.frame, label)
        -- Redraw the statusline so the spinner actually animates.
        pcall(vim.api.nvim__redraw, { statusline = true })
      end)
    )
  end

  local events = require("picked.utils.events")
  events.emit(events.names.OPERATION_STARTED, { root = opts.root, operation = key })

  return handle
end

---A one-line summary of everything currently running, for statuslines.
---@return string
function M.status()
  local parts = {}
  for _, text in pairs(M.active) do
    parts[#parts + 1] = text
  end
  table.sort(parts)
  return table.concat(parts, "  ")
end

---@return boolean
function M.busy()
  return next(M.active) ~= nil
end

return M
