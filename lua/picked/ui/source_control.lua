---@brief The Source Control panel.
---
---The panel answers six questions at a glance, which is the whole point of the
---view: what changed, what is staged, what is unstaged, what is conflicted,
---what branch am I on, and what can I do next.
---
---Every row carries the entry it represents, so a keymap, a mouse click and a
---context menu all resolve to the same data without any of them knowing how
---the row was drawn.

local config = require("picked.config")
local events = require("picked.utils.events")
local git = require("picked.git")
local icons = require("picked.utils.icons")
local notify = require("picked.ui.notify")
local operations = require("picked.operations")
local panel_lib = require("picked.ui.panel")
local refresh = require("picked.state.refresh")
local render = require("picked.ui.render")
local repository = require("picked.git.repository")
local status_api = require("picked.git.status")
local store = require("picked.state")
local text_util = require("picked.utils.text")
local tree_lib = require("picked.ui.tree")
local window = require("picked.ui.window")

local M = {}

local PANEL_NAME = "source_control"

---@class PickedSourceControlItem
---@field id string
---@field kind "section"|"directory"|"file"|"stash"|"state"|"header"|"hint"|"empty"
---@field section string|nil
---@field side "index"|"worktree"|nil
---@field node PickedTreeNode|nil
---@field entry GitFileEntry|nil
---@field entries GitFileEntry[]|nil
---@field paths string[]|nil
---@field stash GitStash|nil

--- State access ----------------------------------------------------------------

---@return RepositoryState|nil
local function active()
  return store.active()
end

---@return GitRepository|nil
local function active_repo()
  local state = active()
  return state and state.repo or nil
end

--- Rendering -------------------------------------------------------------------

---@param panel PickedPanel
---@return boolean
local function compact(panel)
  return panel:width() < config.options.compact_width
end

---@param canvas PickedCanvas
---@param state RepositoryState
---@param panel PickedPanel
local function render_header(canvas, state, panel)
  local head = state.head or { branch = nil, detached = false, unborn = false }
  local branch_info = state.status and state.status.branch or nil
  local narrow = compact(panel)

  local row = canvas:row({ id = "header:branch", kind = "header" })
  row:add(icons.get("branch") .. " ", "PickedBranch", "branches")

  if head.unborn then
    row:add(head.branch or "main", "PickedBranchCurrent", "branches")
    row:add("  (no commits yet)", "PickedDim")
  elseif head.detached then
    row:add("HEAD detached", "PickedWarning", "branches")
    if head.short then
      row:add(" at " .. head.short, "PickedHash", "branches")
    end
  else
    row:add(head.branch or "?", "PickedBranchCurrent", "branches")
  end

  if branch_info then
    if branch_info.ahead > 0 then
      row:add(" " .. icons.get("arrow_up") .. tostring(branch_info.ahead), "PickedAhead", "push")
    end
    if branch_info.behind > 0 then
      row:add(" " .. icons.get("arrow_down") .. tostring(branch_info.behind), "PickedBehind", "pull")
    end
    if not branch_info.upstream and not head.detached and not head.unborn then
      if not narrow then
        row:add("  no upstream", "PickedDim")
      end
    end
  end

  if store.is_loading(state.repo.root, "status") then
    row:right(icons.get("spinner") or "", "PickedProgress")
  end

  -- An in-progress operation is the single most important thing on screen.
  local git_state = state.git_state
  if git_state and git_state.kind ~= "normal" then
    local state_row = canvas:row({ id = "header:state", kind = "state" })
    state_row:add(icons.get("warning") .. " ", "PickedWarning")
    state_row:add(git_state.label, "PickedWarning")
    if git_state.step and git_state.total then
      state_row:add((" %d/%d"):format(git_state.step, git_state.total), "PickedDim")
    end
    if git_state.head_name and git_state.head_name ~= "" and not narrow then
      state_row:add("  onto " .. git_state.head_name, "PickedDim")
    end

    local actions = canvas:row({ id = "header:state-actions", kind = "state" })
    actions:add("  ")
    actions:add("[c]", "PickedKey", "sequencer_continue")
    actions:add(" continue  ", nil, "sequencer_continue")
    actions:add("[s]", "PickedKey", "sequencer_skip")
    actions:add(" skip  ", nil, "sequencer_skip")
    actions:add("[a]", "PickedKey", "sequencer_abort")
    actions:add(" abort", "PickedError", "sequencer_abort")
  end

  if state.repo.is_linked_worktree and not narrow then
    canvas
      :row({ id = "header:worktree", kind = "header" })
      :add("  worktree: " .. require("picked.utils.path").tilde(state.repo.root), "PickedDim")
  end

  -- A summary line makes the counts legible without colour.
  local status = state.status
  if status and not narrow then
    local summary = canvas:row({ id = "header:summary", kind = "header" })
    summary:add("  ")
    summary:add(("Changes %d"):format(#status.unstaged), "PickedDim")
    summary:add("   ")
    summary:add(("Staged %d"):format(#status.staged), "PickedDim")
    if #status.conflicts > 0 then
      summary:add("   ")
      summary:add(("Conflicts %d"):format(#status.conflicts), "PickedConflict")
    end
  end
end

---Render one file row.
---@param canvas PickedCanvas
---@param node PickedTreeNode
---@param opts { section: string, side: "index"|"worktree", indent: integer, width: integer, narrow: boolean }
local function render_file(canvas, node, opts)
  local entry = node.entry
  assert(entry, "file nodes always carry an entry")

  local code = status_api.code_for(entry, opts.side)
  local highlights = require("picked.ui.highlights")

  ---@type PickedSourceControlItem
  local item = {
    id = opts.section .. ":" .. entry.path,
    kind = "file",
    section = opts.section,
    side = opts.side,
    node = node,
    entry = entry,
    entries = { entry },
    paths = { entry.path },
  }

  local row = canvas:row(item)
  row:add(string.rep("  ", opts.indent))

  -- The status letter comes first and is always present, so the view remains
  -- readable with no colour at all.
  row:add(code, highlights.for_status(code), "open")
  row:add(" ")

  if config.options.icons then
    local icon, icon_hl = icons.for_file(entry.path)
    if icon ~= "" then
      row:add(icon .. " ", icon_hl, "open")
    end
  end

  local name_hl = entry.conflicted and "PickedConflict"
    or entry.untracked and "PickedUntracked"
    or highlights.for_status(code)

  local available = opts.width - row:width() - 2
  row:add(text_util.truncate_left(node.name, math.max(8, available)), name_hl, "open")

  if entry.submodule then
    row:add(" " .. icons.get("submodule"), "PickedSubmodule")
  end

  -- A rename is only comprehensible if the old name is visible somewhere.
  if entry.orig_path and not opts.narrow then
    local from = require("picked.utils.path").basename(entry.orig_path)
    row:right(("← %s "):format(text_util.truncate(from, 20)), "PickedDim")
  elseif entry.conflicted and not opts.narrow then
    row:right((" %s "):format(entry.conflict_label or "conflict"), "PickedConflict")
  end
end

---@param canvas PickedCanvas
---@param nodes PickedTreeNode[]
---@param opts table
local function render_tree(canvas, nodes, opts)
  tree_lib.walk(nodes, function(node)
    return store.is_expanded(node.id)
  end, function(node, expanded)
    if node.kind == "directory" then
      ---@type PickedSourceControlItem
      local item = {
        id = opts.section .. ":dir:" .. node.path,
        kind = "directory",
        section = opts.section,
        side = opts.side,
        node = node,
        paths = node.paths,
      }
      local row = canvas:row(item)
      row:add(string.rep("  ", node.depth + opts.indent))
      row:add(expanded and icons.get("chevron_open") or icons.get("chevron_closed"), "PickedChevron", "toggle")
      row:add(" ")
      row:add(node.name .. "/", "PickedDirectory", "toggle")
      if not opts.narrow then
        row:right((" %d "):format(#node.paths), "PickedBadge")
      end
    else
      render_file(canvas, node, {
        section = opts.section,
        side = opts.side,
        indent = node.depth + opts.indent,
        width = opts.width,
        narrow = opts.narrow,
      })
    end
  end)
end

---@param canvas PickedCanvas
---@param panel PickedPanel
---@param opts { name: string, title: string, entries: GitFileEntry[], side: "index"|"worktree", actions: table[]|nil }
local function render_section(canvas, panel, opts)
  if #opts.entries == 0 then
    return
  end

  local collapsed = store.is_section_collapsed(opts.name)
  local narrow = compact(panel)

  ---@type PickedSourceControlItem
  local item = {
    id = "section:" .. opts.name,
    kind = "section",
    section = opts.name,
    side = opts.side,
    entries = opts.entries,
    paths = vim.tbl_map(function(entry)
      return entry.path
    end, opts.entries),
  }

  canvas:blank()
  render.section_header(canvas, {
    title = opts.title,
    count = #opts.entries,
    collapsed = collapsed,
    item = item,
    actions = (not narrow) and opts.actions or nil,
  })

  if collapsed then
    return
  end

  local use_tree = config.options.tree and not narrow
  local nodes = use_tree
      and tree_lib.build(opts.entries, {
        id_prefix = opts.name,
        flatten = config.options.tree_flatten,
      })
    or tree_lib.flat(opts.entries, { id_prefix = opts.name })

  render_tree(canvas, nodes, {
    section = opts.name,
    side = opts.side,
    indent = 1,
    width = panel:width(),
    narrow = narrow,
  })
end

---@param canvas PickedCanvas
---@param panel PickedPanel
---@param state RepositoryState
local function render_stashes(canvas, panel, state)
  local stashes = state.stashes
  if not stashes or #stashes == 0 then
    return
  end

  local collapsed = store.is_section_collapsed("stashes")
  canvas:blank()
  render.section_header(canvas, {
    title = "STASHES",
    count = #stashes,
    collapsed = collapsed,
    item = { id = "section:stashes", kind = "section", section = "stashes" },
  })

  if collapsed then
    return
  end

  local width = panel:width()
  for _, stash in ipairs(stashes) do
    local row = canvas:row({ id = "stash:" .. stash.selector, kind = "stash", stash = stash })
    row:add("  ")
    row:add(icons.get("stash") .. " ", "PickedStash", "open")
    row:add(stash.selector, "PickedHash", "open")
    row:add("  ")
    row:add(text_util.truncate(stash.message, math.max(10, width - row:width() - 2)), nil, "open")
  end
end

---@param panel PickedPanel
---@param canvas PickedCanvas
local function render_panel(panel, canvas)
  local state = active()

  if not state then
    canvas:blank()
    canvas:text("  No git repository", "PickedDim")
    canvas:blank()
    canvas:text("  Open a file inside a repository,", "PickedDim")
    canvas:text("  or run :PickedRefresh after cd.", "PickedDim")
    return
  end

  render_header(canvas, state, panel)

  if state.error then
    canvas:blank()
    canvas:text("  " .. state.error.title, "PickedError")
    canvas:text("  " .. (state.error.reason or ""), "PickedDim")
    if state.error.hint then
      canvas:text("  " .. state.error.hint, "PickedDim")
    end
    return
  end

  local status = state.status
  if not status then
    canvas:blank()
    canvas:text("  Reading repository…", "PickedDim")
    return
  end

  render_section(canvas, panel, {
    name = "conflicts",
    title = "MERGE CONFLICTS",
    entries = status.conflicts,
    side = "worktree",
    actions = { { text = "[resolve]", hl = "PickedKey", action = "resolve" } },
  })

  render_section(canvas, panel, {
    name = "staged",
    title = "STAGED CHANGES",
    entries = status.staged,
    side = "index",
    actions = { { text = "[-]", hl = "PickedKey", action = "unstage_all" } },
  })

  render_section(canvas, panel, {
    name = "unstaged",
    title = "CHANGES",
    entries = status.unstaged,
    side = "worktree",
    actions = { { text = "[+]", hl = "PickedKey", action = "stage_all" } },
  })

  render_stashes(canvas, panel, state)

  if status.clean then
    canvas:blank()
    canvas
      :row({ id = "empty", kind = "empty" })
      :add("  " .. icons.get("success") .. " ", "PickedSuccess")
      :add("No changes", "PickedDim")
  end

  panel:render_hints(canvas)
end

--- Item helpers -----------------------------------------------------------------

---Paths an action should apply to: the item under the cursor, or every path
---beneath it when it is a directory or a section header.
---@param item PickedSourceControlItem|nil
---@return string[]
local function paths_of(item)
  if not item then
    return {}
  end
  return item.paths or {}
end

---@param item PickedSourceControlItem|nil
---@return GitFileEntry[]
local function entries_of(item)
  if not item then
    return {}
  end
  if item.entries then
    return item.entries
  end

  -- A directory row carries paths; resolve them back to entries.
  local state = active()
  if not state or not state.status then
    return {}
  end
  local out = {}
  for _, path in ipairs(item.paths or {}) do
    local entry = state.status.by_path[path]
    if entry then
      out[#out + 1] = entry
    end
  end
  return out
end

---@param panel PickedPanel
---@return PickedSourceControlItem[]
local function selected_items(panel)
  local item = panel:item()
  return item and { item } or {}
end

--- Actions ------------------------------------------------------------------------

---@param panel PickedPanel
---@param item PickedSourceControlItem|nil
---@param cmd string
local function open_entry(panel, item, cmd)
  if not item then
    return
  end

  if item.kind == "directory" or item.kind == "section" then
    local id = item.kind == "section" and item.section or item.node.id
    if item.kind == "section" then
      store.set_section_collapsed(id)
    else
      store.set_collapsed(id)
    end
    return panel:redraw()
  end

  if item.kind == "stash" and item.stash then
    return require("picked.ui.stash").inspect(item.stash)
  end

  if item.kind ~= "file" or not item.entry then
    return
  end

  local state = active()
  if not state then
    return
  end

  if item.entry.conflicted then
    -- Opening a conflict goes straight to the resolution view; editing the
    -- raw markers is still possible from there.
    return require("picked.ui.conflict").open(state.repo, item.entry.path)
  end

  -- A side-by-side preview of this very file is already on screen, and <CR>
  -- means "take me there". Opening the file instead would tear the diff down
  -- and put a third window in its place, which is not what the user is
  -- looking at. The explicit split/vsplit/tab variants still open the file.
  if cmd == "edit" and require("picked.ui.diff_view").focus_split(item.entry.path) then
    return
  end

  local path_util = require("picked.utils.path")
  window.open_file(path_util.join(state.repo.root, item.entry.path), {
    cmd = cmd,
    exclude = { panel.winid },
  })
end

---@type table<string, fun(panel: PickedPanel, item: PickedSourceControlItem|nil)>
local actions = {}

actions.open = function(panel, item)
  open_entry(panel, item, "edit")
end
actions.open_split = function(panel, item)
  open_entry(panel, item, "split")
end
actions.open_vsplit = function(panel, item)
  open_entry(panel, item, "vsplit")
end
actions.open_tab = function(panel, item)
  open_entry(panel, item, "tabedit")
end

actions.toggle = function(panel, item)
  if not item then
    return
  end
  if item.kind == "section" and item.section then
    store.set_section_collapsed(item.section)
    return panel:redraw()
  end
  if item.kind == "directory" and item.node then
    store.set_collapsed(item.node.id)
    return panel:redraw()
  end
end

actions.toggle_all = function(panel)
  local ui = store.ui()
  -- If anything is collapsed, expand everything; otherwise collapse everything.
  local any_collapsed = false
  for _, value in pairs(ui.expanded) do
    if value == false then
      any_collapsed = true
      break
    end
  end
  if any_collapsed then
    ui.expanded = {}
  else
    local state = active()
    if state and state.status then
      for _, section in ipairs({ "staged", "unstaged", "conflicts" }) do
        local entries = state.status[section] or {}
        local nodes = tree_lib.build(entries, { id_prefix = section, flatten = config.options.tree_flatten })
        store.set_all_collapsed(tree_lib.directory_ids(nodes), true)
      end
    end
  end
  panel:redraw()
end

actions.stage = function(panel, item)
  local repo = active_repo()
  if not repo or not item then
    return
  end
  if item.section == "conflicts" then
    return operations.mark_resolved(repo, paths_of(item))
  end
  operations.stage(repo, paths_of(item))
end

actions.unstage = function(_, item)
  local repo = active_repo()
  if not repo or not item then
    return
  end
  operations.unstage(repo, paths_of(item))
end

actions.stage_all = function()
  local repo = active_repo()
  if repo then
    operations.stage_all(repo)
  end
end

actions.unstage_all = function()
  local repo = active_repo()
  if repo then
    operations.unstage_all(repo)
  end
end

actions.discard = function(_, item)
  local repo = active_repo()
  if not repo or not item then
    return
  end
  local entries = entries_of(item)
  -- Never offer to discard something that is only staged: unstaging is the
  -- reversible operation, and discarding staged-only work is rarely intended.
  local discardable = vim.tbl_filter(function(entry)
    return entry.unstaged or entry.untracked
  end, entries)
  if #discardable == 0 then
    return notify.warn("Nothing to discard here (try unstage)")
  end
  operations.discard(repo, discardable)
end

actions.diff = function(panel, item)
  local repo = active_repo()
  if not repo or not item or item.kind ~= "file" or not item.entry then
    return
  end
  require("picked.ui.diff_view").open(repo, {
    path = item.entry.path,
    spec = { kind = item.side == "index" and "index" or "worktree" },
    entry = item.entry,
    from_panel = panel,
  })
end

actions.diff_full = function(panel, item)
  local repo = active_repo()
  if not repo then
    return
  end
  local path = item and item.entry and item.entry.path or nil
  require("picked.ui.diff_view").open(repo, {
    path = path,
    spec = { kind = "head" },
    from_panel = panel,
  })
end

actions.refresh = function()
  local repo = active_repo()
  if repo then
    store.invalidate(repo.root)
    refresh.now(repo, { reason = "manual" })
    M.load_stashes(repo)
  end
end

actions.commit = function()
  local repo = active_repo()
  if repo then
    require("picked.ui.commit").open(repo, {})
  end
end

actions.commit_amend = function()
  local repo = active_repo()
  if repo then
    require("picked.ui.commit").open(repo, { amend = true })
  end
end

actions.commit_push = function()
  local repo = active_repo()
  if repo then
    require("picked.ui.commit").open(repo, { push = true })
  end
end

actions.push = function()
  local repo = active_repo()
  if repo then
    operations.push(repo)
  end
end

actions.pull = function()
  local repo = active_repo()
  if repo then
    operations.pull(repo)
  end
end

actions.fetch = function()
  local repo = active_repo()
  if repo then
    operations.fetch(repo)
  end
end

actions.branches = function()
  local repo = active_repo()
  if repo then
    require("picked.ui.branches").open(repo)
  end
end

actions.log = function(_, item)
  local repo = active_repo()
  if not repo then
    return
  end
  require("picked.ui.log").open(repo, {})
end

actions.stash = function()
  local repo = active_repo()
  if repo then
    require("picked.ui.stash").open(repo)
  end
end

actions.blame = function(panel, item)
  local repo = active_repo()
  if not repo or not item or not item.entry then
    return notify.warn("Select a file to blame")
  end
  require("picked.ui.blame").open(repo, item.entry.path)
end

actions.file_history = function(_, item)
  local repo = active_repo()
  if not repo or not item or not item.entry then
    return notify.warn("Select a file to see its history")
  end
  require("picked.ui.file_history").open(repo, item.entry.path)
end

actions.open_remote = function(_, item)
  local repo = active_repo()
  if not repo then
    return
  end
  local state = active()
  local branch = state and state.head and state.head.branch or "HEAD"
  if item and item.entry then
    return operations.browse(repo, { kind = "file", ref = branch, path = item.entry.path })
  end
  operations.browse(repo, { kind = "repo" })
end

actions.copy_path = function(_, item)
  local repo = active_repo()
  if not repo or not item or not item.entry then
    return
  end
  local path_util = require("picked.utils.path")
  local full = path_util.to_os(path_util.join(repo.root, item.entry.path))
  vim.fn.setreg(vim.v.register or "+", full)
  notify.info("Copied " .. full)
end

actions.copy_relative_path = function(_, item)
  if not item or not item.entry then
    return
  end
  vim.fn.setreg(vim.v.register or "+", item.entry.path)
  notify.info("Copied " .. item.entry.path)
end

actions.resolve = function(_, item)
  local repo = active_repo()
  if not repo or not item then
    return
  end
  local conflicted = vim.tbl_filter(function(entry)
    return entry.conflicted
  end, entries_of(item))
  if #conflicted == 0 then
    return notify.warn("No conflicted files selected")
  end
  if #conflicted == 1 then
    return require("picked.ui.conflict").open(repo, conflicted[1].path)
  end
  operations.mark_resolved(
    repo,
    vim.tbl_map(function(entry)
      return entry.path
    end, conflicted)
  )
end

actions.next_file = function(panel)
  local line = panel:cursor_line()
  local target = panel.canvas
    and panel.canvas:find(function(item, lnum)
      return item.kind == "file" and lnum > line
    end)
  if target then
    panel:set_cursor(target)
  end
end

actions.prev_file = function(panel)
  if not panel.canvas then
    return
  end
  local line = panel:cursor_line()
  local best = nil
  for _, lnum in
    ipairs(panel.canvas:find_all(function(item)
      return item.kind == "file"
    end))
  do
    if lnum < line then
      best = lnum
    end
  end
  if best then
    panel:set_cursor(best)
  end
end

actions.next_section = function(panel)
  local line = panel:cursor_line()
  local target = panel.canvas
    and panel.canvas:find(function(item, lnum)
      return item.kind == "section" and lnum > line
    end)
  panel:set_cursor(target or 1)
end

actions.prev_section = function(panel)
  if not panel.canvas then
    return
  end
  local line = panel:cursor_line()
  local best = nil
  for _, lnum in
    ipairs(panel.canvas:find_all(function(item)
      return item.kind == "section"
    end))
  do
    if lnum < line then
      best = lnum
    end
  end
  if best then
    panel:set_cursor(best)
  end
end

actions.search = function(panel)
  require("picked.ui.picker").files(panel)
end

actions.context_menu = function(panel, item)
  local entries = M.context_menu(panel, item)
  if entries and #entries > 0 then
    require("picked.ui.menu").open({ entries = entries })
  end
end

actions.sequencer_continue = function()
  local repo = active_repo()
  if repo then
    operations.sequencer(repo, "continue")
  end
end
actions.sequencer_skip = function()
  local repo = active_repo()
  if repo then
    operations.sequencer(repo, "skip")
  end
end
actions.sequencer_abort = function()
  local repo = active_repo()
  if repo then
    operations.sequencer(repo, "abort")
  end
end

--- Visual-mode actions --------------------------------------------------------------

---@type table<string, fun(panel: PickedPanel, first: integer, last: integer)>
local visual_actions = {}

---@param panel PickedPanel
---@param first integer
---@param last integer
---@return GitFileEntry[]
local function entries_in_range(panel, first, last)
  local seen, out = {}, {}
  for _, item in ipairs(panel:items_in_range(first, last)) do
    for _, entry in ipairs(entries_of(item)) do
      if not seen[entry.path] then
        seen[entry.path] = true
        out[#out + 1] = entry
      end
    end
  end
  return out
end

visual_actions.stage = function(panel, first, last)
  local repo = active_repo()
  if not repo then
    return
  end
  local entries = entries_in_range(panel, first, last)
  operations.stage(
    repo,
    vim.tbl_map(function(entry)
      return entry.path
    end, entries)
  )
end

visual_actions.unstage = function(panel, first, last)
  local repo = active_repo()
  if not repo then
    return
  end
  local entries = entries_in_range(panel, first, last)
  operations.unstage(
    repo,
    vim.tbl_map(function(entry)
      return entry.path
    end, entries)
  )
end

visual_actions.discard = function(panel, first, last)
  local repo = active_repo()
  if not repo then
    return
  end
  local entries = vim.tbl_filter(function(entry)
    return entry.unstaged or entry.untracked
  end, entries_in_range(panel, first, last))
  if #entries == 0 then
    return notify.warn("Nothing to discard in the selection")
  end
  operations.discard(repo, entries)
end

--- Context menu -----------------------------------------------------------------

---@param panel PickedPanel
---@param item PickedSourceControlItem|nil
---@return PickedMenuEntry[]
function M.context_menu(panel, item)
  if not item then
    return {}
  end

  ---@param action string
  ---@return string|nil
  local function key(action)
    local keys = panel:keys_for(action)
    return keys[1]
  end

  local entries = {}
  local function add(label, action, opts)
    opts = opts or {}
    entries[#entries + 1] = {
      label = label,
      key = key(action),
      destructive = opts.destructive,
      action = function()
        local handler = actions[action]
        if handler then
          handler(panel, item)
        end
      end,
    }
  end

  if item.kind == "file" and item.entry then
    add("Open", "open")
    add("Open in split", "open_split")
    entries[#entries + 1] = { separator = true }

    if item.entry.conflicted then
      add("Resolve conflict", "resolve")
      entries[#entries + 1] = { separator = true }
    else
      if item.side == "index" or item.entry.staged then
        add("Unstage", "unstage")
      end
      if item.entry.unstaged or item.entry.untracked then
        add("Stage", "stage")
        add("Discard changes", "discard", { destructive = true })
      end
      add("Diff", "diff")
      entries[#entries + 1] = { separator = true }
      add("Blame", "blame")
      add("File history", "file_history")
      add("Open on remote", "open_remote")
    end

    entries[#entries + 1] = { separator = true }
    add("Copy path", "copy_path")
    add("Copy relative path", "copy_relative_path")
  elseif item.kind == "directory" or item.kind == "section" then
    add("Expand / collapse", "toggle")
    entries[#entries + 1] = { separator = true }
    if item.section == "staged" then
      add("Unstage all in here", "unstage")
    else
      add("Stage all in here", "stage")
      add("Discard all in here", "discard", { destructive = true })
    end
  elseif item.kind == "stash" then
    add("Inspect", "open")
  end

  return entries
end

--- Panel definition ------------------------------------------------------------

---@type PickedPanel|nil
local panel = nil

---@return PickedPanel
local function get_panel()
  if panel then
    return panel
  end

  panel = panel_lib.new({
    name = PANEL_NAME,
    layout = config.options.position == "float" and "float" or "sidebar",
    float = { width = 0.5, height = 0.8 },
    keymap_group = "source_control",
    title = function()
      local state = active()
      if not state then
        return "SOURCE CONTROL"
      end
      return "SOURCE CONTROL — " .. state.repo.name
    end,
    render = render_panel,
    actions = actions,
    visual_actions = visual_actions,
    context_menu = M.context_menu,
    hints = {
      { key = "stage", label = "stage" },
      { key = "unstage", label = "unstage" },
      { key = "diff", label = "diff" },
      { key = "commit", label = "commit" },
      { key = "help", label = "help" },
    },
    on_cursor = function(_, item)
      if not config.options.diff.preview then
        return
      end
      -- Selecting a file shows its diff, the way VS Code does. `diff.preview`
      -- decides whether that opens a view or only retargets an open one.
      if item and item.kind == "file" and item.entry and not item.entry.conflicted then
        local repo = active_repo()
        if repo then
          require("picked.ui.diff_view").preview(repo, item.entry, item.side)
        end
      end
    end,
  })

  -- Redraw whenever the store changes, regardless of what caused it.
  local unsubscribe = events.on_any({
    events.names.STATUS_CHANGED,
    events.names.REPOSITORY_CHANGED,
    events.names.OPERATION_STARTED,
    events.names.OPERATION_FINISHED,
    events.names.STASH_CHANGED,
  }, function()
    if panel and panel:is_open() then
      vim.schedule(function()
        if panel and panel:is_open() then
          panel:redraw()
        end
      end)
    end
  end)
  panel:on_destroy(unsubscribe)

  return panel
end

---Load the stash list into the store; the panel renders it when present.
---@param repo GitRepository
function M.load_stashes(repo)
  local token = store.current_generation(repo.root)
  git.stash.list(repo, function(stashes, err)
    if err or not stashes then
      return
    end
    store.update(repo.root, { stashes = stashes }, token)
  end)
end

---Ensure a repository is active, detecting one if necessary.
---@return GitRepository|nil
local function ensure_repository()
  local state = active()
  if state then
    return state.repo
  end

  local repo, err = repository.current()
  if not repo then
    notify.error({
      kind = "no_repository",
      title = "No git repository",
      reason = err or "Neither the current file nor the working directory is inside a repository.",
      hint = "Open a file inside a repository, or `:cd` into one.",
      raw = "",
    })
    return nil
  end

  store.ensure(repo)
  store.set_active(repo)
  return repo
end

---@param opts { focus: boolean|nil }|nil
function M.open(opts)
  local instance = get_panel()
  local repo = ensure_repository()

  instance:open(opts)

  if repo then
    refresh.watch(repo)
    refresh.now(repo, { reason = "panel-open" })
    M.load_stashes(repo)
  end
end

function M.close()
  if panel then
    panel:close()
  end
end

---@param opts table|nil
function M.toggle(opts)
  if panel and panel:is_open() then
    panel:close()
  else
    M.open(opts)
  end
end

---@return boolean
function M.is_open()
  return panel ~= nil and panel:is_open()
end

function M.focus()
  if panel and panel:is_open() then
    panel:focus()
  else
    M.open({ focus = true })
  end
end

function M.redraw()
  if panel and panel:is_open() then
    panel:redraw()
  end
end

---Release the panel entirely. Used by `:PickedReset` and on teardown.
function M.destroy()
  if panel then
    panel:destroy()
    panel = nil
  end
end

---@return PickedPanel|nil
function M.panel()
  return panel
end

return M
