---@brief The stash view.

local git = require("picked.git")
local icons = require("picked.utils.icons")
local notify = require("picked.ui.notify")
local operations = require("picked.operations")
local panel_lib = require("picked.ui.panel")
local text_util = require("picked.utils.text")

local M = {}

---@class PickedStashItem
---@field id string
---@field kind "stash"|"info"
---@field stash GitStash|nil

---@class PickedStashViewState
---@field repo GitRepository
---@field stashes GitStash[]
---@field loading boolean
---@field error GitError|nil

---@type PickedPanel|nil
local panel = nil

---@type PickedStashViewState|nil
local current = nil

--- Rendering -------------------------------------------------------------------

---@param self PickedPanel
---@param canvas PickedCanvas
local function render_panel(self, canvas)
  local width = self:width()

  if not current then
    canvas:text("  No repository", "PickedDim")
    return
  end

  if current.loading then
    canvas:text("  Loading stashes…", "PickedDim")
    return
  end

  if current.error then
    canvas:text("  " .. current.error.title, "PickedError")
    canvas:text("  " .. (current.error.reason or ""), "PickedDim")
    return
  end

  if #current.stashes == 0 then
    canvas:blank()
    canvas:text("  No stashes", "PickedDim")
    canvas:blank()
    local keys = self:keys_for("create")
    canvas
      :row({ id = "create", kind = "info" })
      :add("  ")
      :add(keys[1] or "c", "PickedKey", "create")
      :add("  stash the current changes", "PickedHint", "create")
    return
  end

  canvas:blank()
  for _, stash in ipairs(current.stashes) do
    local row = canvas:row({ id = stash.selector, kind = "stash", stash = stash })
    row:add("  ")
    row:add(icons.get("stash") .. " ", "PickedStash", "inspect")
    row:add(text_util.pad(stash.selector, 11), "PickedHash", "inspect")

    if stash.branch then
      row:add(text_util.pad("[" .. text_util.truncate(stash.branch, 16) .. "]", 19), "PickedBranch", "inspect")
    end

    local available = width - row:width() - (width >= 70 and 14 or 2)
    row:add(text_util.truncate(stash.message, math.max(10, available)), nil, "inspect")

    if width >= 70 then
      row:right((" %s "):format(text_util.relative_time_short(stash.date)), "PickedDim")
    end
  end

  self:render_hints(canvas)
end

--- Loading ---------------------------------------------------------------------

local function load()
  if not current or not panel then
    return
  end
  current.loading = true
  panel:redraw()

  local repo = current.repo
  git.stash.list(repo, function(stashes, err)
    if not current or current.repo ~= repo then
      return
    end
    current.loading = false
    current.stashes = stashes or {}
    current.error = err
    if panel and panel:is_open() then
      panel:redraw()
    end
  end)
end

--- Inspection -------------------------------------------------------------------

---Show a stash's contents as a diff.
---@param stash GitStash
function M.inspect(stash)
  local store = require("picked.state")
  local state = store.active()
  local repo = current and current.repo or (state and state.repo)
  if not repo then
    return
  end

  require("picked.ui.diff_view").open(repo, {
    spec = { kind = "range", from = stash.selector .. "^", to = stash.selector },
  })
end

--- Actions ------------------------------------------------------------------------

---@type table<string, fun(panel: PickedPanel, item: PickedStashItem|nil)>
local actions = {}

---@param item PickedStashItem|nil
---@return GitStash|nil
local function stash_of(item)
  return item and item.stash or nil
end

actions.inspect = function(_, item)
  local stash = stash_of(item)
  if stash then
    M.inspect(stash)
  end
end

actions.open = actions.inspect

actions.apply = function(_, item)
  local stash = stash_of(item)
  if stash and current then
    operations.stash_restore(current.repo, stash, "apply")
  end
end

actions.pop = function(_, item)
  local stash = stash_of(item)
  if stash and current then
    operations.stash_restore(current.repo, stash, "pop")
  end
end

actions.drop = function(_, item)
  local stash = stash_of(item)
  if stash and current then
    operations.stash_drop(current.repo, stash)
  end
end

actions.create = function()
  if current then
    operations.stash_push(current.repo)
  end
end

actions.branch = function(_, item)
  local stash = stash_of(item)
  if not stash or not current then
    return
  end
  require("picked.ui.input").branch_name({
    prompt = ("Branch from %s"):format(stash.selector),
  }, function(name)
    if not name then
      return
    end
    operations.mutate(current.repo, "stash-branch", function(done)
      git.stash.branch(current.repo, stash.selector, name, done)
    end, {
      success = ("Created %s from %s"):format(name, stash.selector),
      on_success = function()
        vim.cmd("checktime")
      end,
    })
  end)
end

actions.diff = actions.inspect

actions.refresh = function()
  load()
end

--- Panel --------------------------------------------------------------------------

---@return PickedPanel
local function get_panel()
  if panel then
    return panel
  end

  panel = panel_lib.new({
    name = "stash",
    layout = "float",
    float = { width = 0.7, height = 0.5 },
    keymap_group = "stash",
    title = function()
      return current and ("STASHES — " .. current.repo.name) or "STASHES"
    end,
    render = render_panel,
    actions = actions,
    hints = {
      { key = "inspect", label = "inspect" },
      { key = "apply", label = "apply" },
      { key = "pop", label = "pop" },
      { key = "drop", label = "drop" },
      { key = "create", label = "new" },
    },
    context_menu = function(self, item)
      if not stash_of(item) then
        return {
          {
            label = "Stash current changes",
            key = self:keys_for("create")[1],
            action = function()
              actions.create(self, item)
            end,
          },
        }
      end
      local entries = {}
      local function add(label, action, destructive)
        entries[#entries + 1] = {
          label = label,
          key = self:keys_for(action)[1],
          destructive = destructive,
          action = function()
            actions[action](self, item)
          end,
        }
      end
      add("Inspect", "inspect")
      entries[#entries + 1] = { separator = true }
      add("Apply (keep stash)", "apply")
      add("Pop (apply and remove)", "pop")
      add("Create branch from stash", "branch")
      entries[#entries + 1] = { separator = true }
      add("Drop", "drop", true)
      return entries
    end,
  })

  local events = require("picked.utils.events")
  local unsubscribe = events.on(events.names.STASH_CHANGED, function()
    if panel and panel:is_open() then
      vim.schedule(load)
    end
  end)
  panel:on_destroy(unsubscribe)

  return panel
end

---Open the stash view.
---@param repo GitRepository
function M.open(repo)
  local instance = get_panel()
  current = { repo = repo, stashes = {}, loading = true, error = nil }
  instance:open()
  load()
end

function M.close()
  if panel then
    panel:close()
  end
end

function M.destroy()
  if panel then
    panel:destroy()
    panel = nil
  end
  current = nil
end

---Stash the current changes without opening the view.
---@param repo GitRepository
function M.push(repo)
  operations.stash_push(repo)
end

---Pop the most recent stash without opening the view.
---@param repo GitRepository
function M.pop_latest(repo)
  git.stash.list(repo, function(stashes, err)
    if err then
      return notify.error(err)
    end
    if not stashes or #stashes == 0 then
      return notify.info("No stashes to pop")
    end
    operations.stash_restore(repo, stashes[1], "pop")
  end)
end

return M
