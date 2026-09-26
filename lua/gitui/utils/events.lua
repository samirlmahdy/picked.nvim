---@brief Event bus.
---
---Every event is published twice:
---  * as a `User` autocmd named `GitUI<Event>` so users can hook it from their
---    config without requiring the plugin,
---  * to in-process subscribers, which is how the plugin's own views stay in
---    sync without importing each other.

local logger = require("gitui.utils.logger")

local M = {}

---Canonical event names. Anything not listed here is still allowed, but these
---are the documented, stable ones.
M.names = {
  READY = "Ready",
  REPOSITORY_CHANGED = "RepositoryChanged",
  STATUS_CHANGED = "StatusChanged",
  OPERATION_STARTED = "OperationStarted",
  OPERATION_FINISHED = "OperationFinished",
  COMMIT_CREATED = "CommitCreated",
  BRANCH_CHANGED = "BranchChanged",
  PUSH_FINISHED = "PushFinished",
  PULL_FINISHED = "PullFinished",
  FETCH_FINISHED = "FetchFinished",
  STASH_CHANGED = "StashChanged",
  CONFLICT_STATE_CHANGED = "ConflictStateChanged",
  PANEL_OPENED = "PanelOpened",
  PANEL_CLOSED = "PanelClosed",
}

---@type table<string, table<integer, fun(data: any)>>
local subscribers = {}
local next_id = 0

---Subscribe to an event.
---@param name string
---@param callback fun(data: any)
---@return fun() unsubscribe
function M.on(name, callback)
  next_id = next_id + 1
  local id = next_id
  subscribers[name] = subscribers[name] or {}
  subscribers[name][id] = callback
  return function()
    if subscribers[name] then
      subscribers[name][id] = nil
    end
  end
end

---Subscribe to several events with one callback.
---@param names string[]
---@param callback fun(data: any, name: string)
---@return fun() unsubscribe
function M.on_any(names, callback)
  local unsubs = {}
  for _, name in ipairs(names) do
    unsubs[#unsubs + 1] = M.on(name, function(data)
      callback(data, name)
    end)
  end
  return function()
    for _, unsub in ipairs(unsubs) do
      unsub()
    end
  end
end

---Publish an event. Safe to call from a fast event context: delivery is
---deferred to the main loop so handlers may use the full API.
---@param name string
---@param data any|nil
function M.emit(name, data)
  logger.trace("event", name, data)

  local deliver = function()
    local listeners = subscribers[name]
    if listeners then
      -- Snapshot: a handler may unsubscribe itself during dispatch.
      local snapshot = {}
      for _, callback in pairs(listeners) do
        snapshot[#snapshot + 1] = callback
      end
      for _, callback in ipairs(snapshot) do
        local ok, err = pcall(callback, data)
        if not ok then
          logger.error("event handler for", name, "failed:", err)
        end
      end
    end

    pcall(vim.api.nvim_exec_autocmds, "User", {
      pattern = "GitUI" .. name,
      modeline = false,
      data = data,
    })
  end

  if vim.in_fast_event() then
    vim.schedule(deliver)
  else
    deliver()
  end
end

function M.reset()
  subscribers = {}
end

return M
