---@brief The branch view.
---
---Local branches, remote-tracking branches and tags in one list, with the
---current branch stated in words as well as marked with a symbol so the view
---is readable without colour.

local git = require("gitui.git")
local icons = require("gitui.utils.icons")
local notify = require("gitui.ui.notify")
local operations = require("gitui.operations")
local panel_lib = require("gitui.ui.panel")
local render = require("gitui.ui.render")
local store = require("gitui.state")
local text_util = require("gitui.utils.text")

local M = {}

---@class GitUIBranchItem
---@field id string
---@field kind "branch"|"section"|"info"
---@field branch GitBranch|nil
---@field section string|nil

---@class GitUIBranchViewState
---@field repo GitRepository
---@field branches GitBranch[]
---@field loading boolean
---@field error GitError|nil
---@field filter string

---@type GitUIPanel|nil
local panel = nil

---@type GitUIBranchViewState|nil
local current = nil

--- Rendering -------------------------------------------------------------------

---@param canvas GitUICanvas
---@param branch GitBranch
---@param width integer
local function render_branch(canvas, branch, width)
  ---@type GitUIBranchItem
  local item = { id = branch.kind .. ":" .. branch.name, kind = "branch", branch = branch }
  local row = canvas:row(item)

  row:add("  ")
  -- The current branch is marked with a symbol, not just a colour.
  row:add(branch.is_head and icons.get("bullet") or " ", branch.is_head and "GitUIBranchCurrent" or nil, "switch")
  row:add(" ")

  local name_hl = branch.is_head and "GitUIBranchCurrent"
    or branch.kind == "remote" and "GitUIRemoteBranch"
    or branch.kind == "tag" and "GitUITag"
    or "GitUIBranch"

  local reserved = 0
  if branch.ahead > 0 or branch.behind > 0 or branch.gone then
    reserved = 12
  end
  row:add(text_util.truncate(branch.name, math.max(10, width - row:width() - reserved - 2)), name_hl, "switch")

  if branch.gone then
    row:add("  gone", "GitUIWarning")
  else
    if branch.ahead > 0 then
      row:add((" %s%d"):format(icons.get("arrow_up"), branch.ahead), "GitUIAhead")
    end
    if branch.behind > 0 then
      row:add((" %s%d"):format(icons.get("arrow_down"), branch.behind), "GitUIBehind")
    end
  end

  -- Metadata on the right only when the window is wide enough to carry it.
  if width >= 70 then
    local when = branch.date > 0 and text_util.relative_time_short(branch.date) or ""
    local detail = ("%s  %s "):format(text_util.truncate(branch.subject, 40), when)
    row:right(detail, "GitUIDim")
  end
end

---@param self GitUIPanel
---@param canvas GitUICanvas
local function render_panel(self, canvas)
  local width = self:width()

  if not current then
    canvas:text("  No repository", "GitUIDim")
    return
  end

  if current.loading then
    canvas:text("  Loading branches…", "GitUIDim")
    return
  end

  if current.error then
    canvas:text("  " .. current.error.title, "GitUIError")
    canvas:text("  " .. (current.error.reason or ""), "GitUIDim")
    return
  end

  local groups = { locals = {}, remotes = {}, tags = {} }
  local query = current.filter

  for _, branch in ipairs(current.branches) do
    local matches = query == "" or text_util.fuzzy_match(query, branch.name) ~= nil
    if matches then
      if branch.kind == "local" then
        groups.locals[#groups.locals + 1] = branch
      elseif branch.kind == "remote" then
        groups.remotes[#groups.remotes + 1] = branch
      else
        groups.tags[#groups.tags + 1] = branch
      end
    end
  end

  if query ~= "" then
    canvas:row({ id = "filter", kind = "info" })
      :add("  filter: ", "GitUIDim")
      :add(query, "GitUIMatch")
      :add("   (<Esc> clears)", "GitUIDim")
  end

  local sections = {
    { name = "locals", title = "LOCAL", list = groups.locals },
    { name = "remotes", title = "REMOTE", list = groups.remotes },
    { name = "tags", title = "TAGS", list = groups.tags },
  }

  local any = false
  for _, section in ipairs(sections) do
    if #section.list > 0 then
      any = true
      local collapsed = store.is_section_collapsed("branches:" .. section.name)
      canvas:blank()
      render.section_header(canvas, {
        title = section.title,
        count = #section.list,
        collapsed = collapsed,
        item = { id = "section:" .. section.name, kind = "section", section = section.name },
      })
      if not collapsed then
        for _, branch in ipairs(section.list) do
          render_branch(canvas, branch, width)
        end
      end
    end
  end

  if not any then
    canvas:blank()
    canvas:text(query ~= "" and "  No branches match" or "  No branches", "GitUIDim")
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
  git.branches.list(repo, { tags = true }, function(branches, err)
    if not current or current.repo ~= repo then
      return
    end
    current.loading = false
    current.branches = branches or {}
    current.error = err
    if panel and panel:is_open() then
      panel:redraw()
    end
  end)
end

--- Actions ----------------------------------------------------------------------

---@type table<string, fun(panel: GitUIPanel, item: GitUIBranchItem|nil)>
local actions = {}

---@param item GitUIBranchItem|nil
---@return GitBranch|nil
local function branch_of(item)
  return item and item.branch or nil
end

actions.switch = function(self, item)
  if item and item.kind == "section" and item.section then
    store.set_section_collapsed("branches:" .. item.section)
    return self:redraw()
  end

  local branch = branch_of(item)
  if not branch or not current then
    return
  end

  if branch.is_head then
    return notify.info(("Already on %s"):format(branch.name))
  end

  if branch.kind == "tag" then
    return require("gitui.ui.confirm").ask({
      title = ("Check out tag %s?"):format(branch.name),
      message = "Checking out a tag leaves HEAD detached.",
      confirm_label = "Checkout",
    }, function(confirmed)
      if confirmed then
        operations.mutate(current.repo, "checkout-tag", function(done)
          git.branches.switch(current.repo, branch.name, { detach = true }, done)
        end, { success = ("Checked out %s (detached HEAD)"):format(branch.name) })
      end
    end)
  end

  if branch.kind == "remote" then
    -- Checking out a remote branch by name creates a local tracking branch,
    -- which is almost always what was meant.
    local short = branch.remote and branch.name:sub(#branch.remote + 2) or branch.name
    return git.branches.exists(current.repo, short, function(exists)
      local target = exists and short or branch.name
      operations.switch_branch(current.repo, target)
    end)
  end

  operations.switch_branch(current.repo, branch.name)
end

actions.open = actions.switch

actions.create = function(_, item)
  if not current then
    return
  end
  local branch = branch_of(item)
  operations.create_branch(current.repo, { start_point = branch and branch.name or nil })
end

actions.delete = function(_, item)
  local branch = branch_of(item)
  if not branch or not current then
    return notify.warn("Select a branch to delete")
  end
  if branch.kind == "tag" then
    return notify.warn("Tags cannot be deleted from this view")
  end
  operations.delete_branch(current.repo, branch)
end

actions.rename = function(_, item)
  local branch = branch_of(item)
  if not branch or not current or branch.kind ~= "local" then
    return notify.warn("Select a local branch to rename")
  end
  operations.rename_branch(current.repo, branch)
end

actions.merge = function(_, item)
  local branch = branch_of(item)
  if not branch or not current then
    return
  end
  if branch.is_head then
    return notify.warn("Cannot merge a branch into itself")
  end
  operations.merge(current.repo, branch.name)
end

actions.rebase = function(_, item)
  local branch = branch_of(item)
  if not branch or not current then
    return
  end
  if branch.is_head then
    return notify.warn("Cannot rebase a branch onto itself")
  end
  operations.rebase(current.repo, branch.name)
end

actions.push = function(_, item)
  local branch = branch_of(item)
  if not current then
    return
  end
  operations.push(current.repo, branch and branch.kind == "local" and { branch = branch.name } or nil)
end

actions.fetch = function()
  if current then
    operations.fetch(current.repo, { all = true })
  end
end

actions.set_upstream = function(_, item)
  local branch = branch_of(item)
  if not branch or not current then
    return
  end

  local candidates = {}
  for _, other in ipairs(current.branches) do
    if other.kind == "remote" then
      candidates[#candidates + 1] = { text = other.name, value = other.name }
    end
  end
  if #candidates == 0 then
    return notify.warn("No remote branches to track")
  end

  require("gitui.ui.picker").open({
    title = ("Upstream for %s"):format(branch.name),
    items = candidates,
    on_select = function(upstream)
      operations.mutate(current.repo, "set-upstream", function(done)
        git.branches.set_upstream(current.repo, branch.name, upstream, done)
      end, { success = ("%s now tracks %s"):format(branch.name, upstream) })
    end,
  })
end

actions.log = function(_, item)
  local branch = branch_of(item)
  if not current then
    return
  end
  require("gitui.ui.log").open(current.repo, {
    revisions = branch and { branch.name } or nil,
    title = branch and ("HISTORY: " .. branch.name) or nil,
  })
end

actions.diff = function(_, item)
  local branch = branch_of(item)
  if not branch or not current then
    return
  end
  local state = store.get(current.repo.root)
  local head = state and state.head and state.head.branch or "HEAD"
  require("gitui.ui.diff_view").open(current.repo, {
    spec = { kind = "merge_base", from = branch.name, to = head },
  })
end

actions.refresh = function()
  load()
end

actions.search = function(self)
  local input = require("gitui.ui.input")
  input.ask({
    prompt = "Filter branches",
    default = current and current.filter or "",
    allow_empty = true,
  }, function(value)
    if current then
      current.filter = value or ""
      self:redraw()
    end
  end)
end

actions.close = function(self)
  if current and current.filter ~= "" then
    -- Escape clears the filter before it closes the panel.
    current.filter = ""
    return self:redraw()
  end
  self:close()
end

--- Panel -----------------------------------------------------------------------

---@return GitUIPanel
local function get_panel()
  if panel then
    return panel
  end

  panel = panel_lib.new({
    name = "branches",
    layout = "float",
    float = { width = 0.7, height = 0.7 },
    keymap_group = "branches",
    title = function()
      return current and ("BRANCHES — " .. current.repo.name) or "BRANCHES"
    end,
    render = render_panel,
    actions = actions,
    hints = {
      { key = "switch", label = "switch" },
      { key = "create", label = "create" },
      { key = "delete", label = "delete" },
      { key = "merge", label = "merge" },
      { key = "rebase", label = "rebase" },
      { key = "help", label = "help" },
    },
    context_menu = function(self, item)
      local branch = branch_of(item)
      if not branch then
        return {}
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
      add("Switch to branch", "switch")
      add("New branch from here", "create")
      entries[#entries + 1] = { separator = true }
      add("Merge into current", "merge")
      add("Rebase onto", "rebase")
      entries[#entries + 1] = { separator = true }
      add("Show history", "log")
      add("Diff against current", "diff")
      if branch.kind == "local" then
        entries[#entries + 1] = { separator = true }
        add("Rename", "rename")
        add("Set upstream", "set_upstream")
      end
      add("Delete", "delete", true)
      return entries
    end,
  })

  -- Branch state changes whenever the repository does.
  local events = require("gitui.utils.events")
  local unsubscribe = events.on_any({
    events.names.BRANCH_CHANGED,
    events.names.FETCH_FINISHED,
    events.names.PUSH_FINISHED,
    events.names.PULL_FINISHED,
    events.names.COMMIT_CREATED,
  }, function()
    if panel and panel:is_open() then
      vim.schedule(load)
    end
  end)
  panel:on_destroy(unsubscribe)

  return panel
end

---Open the branch view.
---@param repo GitRepository
function M.open(repo)
  local instance = get_panel()
  current = {
    repo = repo,
    branches = {},
    loading = true,
    error = nil,
    filter = "",
  }
  instance:open()
  load()

  -- Start on the current branch, which is the useful reference point.
  vim.schedule(function()
    instance:jump_to(function(item)
      return item.branch and item.branch.is_head
    end)
  end)
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

---A picker over branches, for the command palette and external integrations.
---@param repo GitRepository
---@param on_select fun(branch: GitBranch)
function M.pick(repo, on_select)
  git.branches.list(repo, { tags = false }, function(branches, err)
    if err then
      return notify.error(err)
    end
    local items = {}
    for _, branch in ipairs(branches or {}) do
      items[#items + 1] = {
        text = branch.name,
        segments = {
          { text = branch.is_head and (icons.get("bullet") .. " ") or "  ", hl = "GitUIBranchCurrent" },
          { text = branch.name, hl = branch.kind == "remote" and "GitUIRemoteBranch" or "GitUIBranch" },
          { text = "  " .. text_util.truncate(branch.subject, 50), hl = "GitUIDim" },
        },
        value = branch,
      }
    end
    require("gitui.ui.picker").open({
      title = "Branches",
      items = items,
      on_select = on_select,
    })
  end)
end

return M
