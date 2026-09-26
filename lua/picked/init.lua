---@brief picked.nvim — a VS Code-style Source Control experience, built from
---Neovim primitives.
---
---This module is the plugin's entire public surface. Everything else is
---internal and may change between releases; if you find yourself reaching into
---`picked.ui.*` or `picked.git.*` from a configuration, please open an issue
---instead so the need can be met here.

local M = {}

M.version = "1.0.0"

---Minimum Neovim this plugin supports. `vim.system`, `vim.uv` and
---extmark-based signs are all 0.10 features and are used unconditionally.
local MIN_NVIM = { 0, 10 }

local initialised = false

--- Internal helpers ------------------------------------------------------------

---@return boolean ok, string|nil message
local function check_version()
  if vim.fn.has("nvim-0.10") == 1 then
    return true, nil
  end
  return false, ("picked.nvim requires Neovim %d.%d or newer"):format(MIN_NVIM[1], MIN_NVIM[2])
end

---The repository the user means right now: the active one, or whichever owns
---the current buffer.
---@param silent boolean|nil
---@return GitRepository|nil
local function resolve_repo(silent)
  local store = require("picked.state")
  local state = store.active()
  if state then
    return state.repo
  end

  local repository = require("picked.git.repository")
  local repo, err = repository.current()
  if repo then
    store.ensure(repo)
    store.set_active(repo)
    return repo
  end

  if not silent then
    require("picked.ui.notify").error({
      kind = "no_repository",
      title = "No git repository",
      reason = err or "Neither the current file nor the working directory is inside a repository.",
      hint = "Open a file inside a repository, or `:cd` into one.",
      raw = "",
    })
  end
  return nil
end

M._resolve_repo = resolve_repo

---Repository-relative path of the current buffer, if it has one.
---@param repo GitRepository
---@return string|nil
local function current_relative_path(repo)
  local path_util = require("picked.utils.path")
  local file = path_util.buffer_path(0)
  if not file then
    return nil
  end
  return path_util.relative(file, repo.root)
end

--- Default keymaps --------------------------------------------------------------

---Install a mapping only if the user has not already bound that key.
---
---Silently stealing a key a user configured themselves is never acceptable, so
---existing mappings always win and the skip is logged rather than announced.
---@param mode string|string[]
---@param lhs string|false|nil
---@param rhs fun()
---@param desc string
local function safe_map(mode, lhs, rhs, desc)
  if not lhs or lhs == "" then
    return
  end

  local modes = type(mode) == "table" and mode or { mode }
  for _, single in ipairs(modes) do
    local existing = vim.fn.maparg(lhs, single)
    if existing ~= "" then
      require("picked.utils.logger").debug("not overriding existing mapping", single, lhs)
    else
      vim.keymap.set(single, lhs, rhs, { silent = true, desc = "picked: " .. desc })
    end
  end
end

local function install_default_keymaps()
  local config = require("picked.config")
  if not config.options.default_keymaps then
    return
  end

  local keys = config.options.global_keymaps

  safe_map("n", keys.source_control, M.toggle, "Source Control panel")
  safe_map("n", keys.diff, M.diff, "Diff the current file")
  safe_map("n", keys.branches, M.branches, "Branches")
  safe_map("n", keys.log, M.log, "Commit history")
  safe_map("n", keys.file_history, M.file_history, "History of the current file")
  safe_map("n", keys.commit, M.commit, "Commit")
  safe_map("n", keys.push, M.push, "Push")
  safe_map("n", keys.pull, M.pull, "Pull")
  safe_map("n", keys.fetch, M.fetch, "Fetch")
  safe_map("n", keys.stash, M.stash, "Stashes")
  safe_map("n", keys.blame, M.blame, "Blame the current file")
  safe_map("n", keys.palette, M.palette, "Command palette")

  -- Hunk actions inside ordinary file buffers.
  --
  -- `]c`/`[c` are Neovim's own diff-mode motions. Mapping them globally would
  -- shadow the builtin *inside* a diff — including picked's own side-by-side
  -- view — so in a diff window the builtin is invoked instead.
  local signs = require("picked.ui.signs")

  ---@param builtin string
  ---@param fallback fun()
  ---@return fun()
  local function diff_aware(builtin, fallback)
    return function()
      if vim.wo.diff then
        return vim.cmd("normal! " .. builtin)
      end
      fallback()
    end
  end

  safe_map("n", keys.next_hunk, diff_aware("]c", signs.next_hunk), "Next hunk")
  safe_map("n", keys.prev_hunk, diff_aware("[c", signs.prev_hunk), "Previous hunk")
  safe_map("n", keys.preview_hunk, signs.preview_hunk, "Preview hunk")
  safe_map("n", keys.blame_line, function()
    require("picked.ui.blame").line()
  end, "Blame the current line")

  safe_map("n", keys.stage_hunk, function()
    signs.stage_hunk()
  end, "Stage hunk")
  safe_map("n", keys.unstage_hunk, signs.unstage_hunk, "Unstage hunk")
  safe_map("n", keys.discard_hunk, function()
    signs.discard_hunk()
  end, "Discard hunk")

  -- The visual-mode variants operate on exactly the selected lines.
  safe_map("x", keys.stage_hunk, function()
    local first, last = M._visual_range()
    signs.stage_hunk(first, last)
  end, "Stage the selected lines")
  safe_map("x", keys.discard_hunk, function()
    local first, last = M._visual_range()
    signs.discard_hunk(first, last)
  end, "Discard the selected lines")
end

---@return integer first, integer last
function M._visual_range()
  local first = vim.fn.line("v")
  local last = vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
  return first, last
end

--- Setup ---------------------------------------------------------------------------

---Configure and start the plugin.
---
---Safe to call more than once; later calls re-apply configuration without
---leaking autocommands or windows.
---@param opts PickedConfig|table|nil
---@return PickedConfig
function M.setup(opts)
  local ok, message = check_version()
  if not ok then
    vim.notify(message, vim.log.levels.ERROR)
    return require("picked.config").options
  end

  local config = require("picked.config")
  local options = config.setup(opts)

  require("picked.utils.logger").set_level(options.log_level)
  require("picked.utils.icons").setup(options.icons)
  require("picked.ui.highlights").setup()

  -- Re-running setup must not stack autocommands.
  if initialised then
    require("picked.state.refresh").teardown()
    require("picked.ui.signs").teardown()
  end

  require("picked.state.refresh").setup_autocmds()
  require("picked.ui.signs").setup()

  if options.blame.enabled and options.blame.virtual_text then
    require("picked.ui.blame").enable_virtual_text()
  end

  install_default_keymaps()
  require("picked.integrations").setup()

  initialised = true

  -- Detect the repository for the current context without forcing any UI.
  vim.schedule(function()
    local repo = resolve_repo(true)
    if repo then
      require("picked.state.refresh").request(repo, "startup")
    end
    require("picked.utils.events").emit(require("picked.utils.events").names.READY, {})
  end)

  return options
end

---@return boolean
function M.is_setup()
  return initialised
end

---Ensure `setup()` has run, so the plugin works when a command is the first
---thing a user types.
local function ensure_setup()
  if not initialised then
    M.setup({})
  end
end

--- Panel control ---------------------------------------------------------------------

---Open the Source Control panel.
---@param opts { focus: boolean|nil }|nil
function M.open(opts)
  ensure_setup()
  require("picked.ui.source_control").open(opts)
end

---Close the Source Control panel.
function M.close()
  require("picked.ui.source_control").close()
end

---Toggle the Source Control panel.
---@param opts table|nil
function M.toggle(opts)
  ensure_setup()
  require("picked.ui.source_control").toggle(opts)
end

---Open the panel and move the cursor into it.
function M.focus()
  ensure_setup()
  require("picked.ui.source_control").focus()
end

---Close every picked window.
function M.close_all()
  require("picked.ui.panel").close_all()
  require("picked.ui.commit").close()
  require("picked.ui.blame").close()
  require("picked.ui.conflict").close()
  require("picked.ui.output").close()
  require("picked.ui.menu").close()
end

---Re-read repository state from git.
---@param opts { all: boolean|nil }|nil
function M.refresh(opts)
  ensure_setup()
  opts = opts or {}

  local refresh = require("picked.state.refresh")
  local repository = require("picked.git.repository")
  repository.invalidate()

  if opts.all then
    return refresh.all("manual")
  end

  local repo = resolve_repo()
  if repo then
    require("picked.state").invalidate(repo.root)
    refresh.now(repo, { reason = "manual" })
    require("picked.ui.source_control").load_stashes(repo)
  end
end

--- Views ------------------------------------------------------------------------------

---Diff the current file, or the whole working tree.
---@param opts { path: string|nil, all: boolean|nil, staged: boolean|nil, split: boolean|nil }|nil
function M.diff(opts)
  ensure_setup()
  opts = opts or {}

  local repo = resolve_repo()
  if not repo then
    return
  end

  local spec = { kind = opts.staged and "index" or "worktree" }
  local path = opts.path
  if not path and not opts.all then
    path = current_relative_path(repo)
  end

  require("picked.ui.diff_view").open(repo, {
    path = path,
    spec = spec,
    view = opts.split and "split" or nil,
  })
end

---Switch the open diff between the unified patch and the side-by-side view.
---
---Works from either pane of the split, including the one showing your real
---file, where picked deliberately installs no mappings.
function M.toggle_diff_view()
  ensure_setup()
  require("picked.ui.diff_view").toggle_view()
end

---Open the commit editor.
---@param opts PickedCommitOpenOpts|nil
function M.commit(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.ui.commit").open(repo, opts or {})
  end
end

---Open the branch view.
function M.branches()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.ui.branches").open(repo)
  end
end

---Open the commit history.
---@param opts PickedLogOpenOpts|nil
function M.log(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.ui.log").open(repo, opts or {})
  end
end

---Open the stash view.
function M.stash()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.ui.stash").open(repo)
  end
end

---Blame the current file.
---@param opts { path: string|nil }|nil
function M.blame(opts)
  ensure_setup()
  opts = opts or {}

  local repo = resolve_repo()
  if not repo then
    return
  end

  local path = opts.path or current_relative_path(repo)
  if not path then
    return require("picked.ui.notify").warn("The current buffer is not a file in this repository")
  end
  require("picked.ui.blame").open(repo, path)
end

---Toggle the current-line blame virtual text.
function M.toggle_line_blame()
  ensure_setup()
  require("picked.ui.blame").toggle_virtual_text()
end

---History of the current file.
function M.file_history()
  ensure_setup()
  require("picked.ui.file_history").current_file()
end

---History of the current line or visual selection.
---@param first integer|nil
---@param last integer|nil
function M.line_history(first, last)
  ensure_setup()
  require("picked.ui.file_history").current_lines(first, last)
end

---Open the command palette.
function M.palette()
  ensure_setup()
  require("picked.ui.palette").open()
end

---Pick which tracked repository is active.
function M.repositories()
  ensure_setup()
  require("picked.ui.palette").repositories()
end

---Show the raw output of recent git commands.
function M.output()
  require("picked.ui.output").toggle()
end

---Show picked's own log.
function M.show_log()
  local logger = require("picked.utils.logger")
  local window = require("picked.ui.window")

  local lines = logger.lines()
  if #lines == 0 then
    lines = { "No log entries yet.", "", "Raise the level with require('picked').setup({ log_level = 'debug' })." }
  end
  table.insert(lines, 1, "Log file: " .. logger.file())
  table.insert(lines, 2, "")

  local bufnr = window.create_buffer({ name = "log", filetype = "picked-log" })
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.open_float(bufnr, { title = "PICKED LOG", width = 0.8, height = 0.7 })
  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, function()
      window.close(winid)
      window.delete_buffer(bufnr)
    end, { buffer = bufnr, nowait = true, silent = true })
  end
end

--- Operations ---------------------------------------------------------------------------

---@param opts GitNetworkOpts|nil
function M.push(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.operations").push(repo, opts)
  end
end

---Force push, using --force-with-lease unless configured otherwise.
function M.force_push()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.operations").force_push(repo)
  end
end

---@param opts GitNetworkOpts|nil
function M.pull(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.operations").pull(repo, opts)
  end
end

---@param opts GitNetworkOpts|nil
function M.fetch(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("picked.operations").fetch(repo, opts)
  end
end

---Stage paths, or the current file when none are given.
---@param paths string[]|nil
function M.stage(paths)
  ensure_setup()
  local repo = resolve_repo()
  if not repo then
    return
  end
  paths = paths or { current_relative_path(repo) }
  paths = vim.tbl_filter(function(path)
    return path ~= nil
  end, paths)
  require("picked.operations").stage(repo, paths)
end

---Unstage paths, or the current file when none are given.
---@param paths string[]|nil
function M.unstage(paths)
  ensure_setup()
  local repo = resolve_repo()
  if not repo then
    return
  end
  paths = paths or { current_relative_path(repo) }
  paths = vim.tbl_filter(function(path)
    return path ~= nil
  end, paths)
  require("picked.operations").unstage(repo, paths)
end

--- Hunk actions ---------------------------------------------------------------------------

M.hunk = {
  next = function()
    require("picked.ui.signs").next_hunk()
  end,
  prev = function()
    require("picked.ui.signs").prev_hunk()
  end,
  stage = function(first, last)
    require("picked.ui.signs").stage_hunk(first, last)
  end,
  unstage = function()
    require("picked.ui.signs").unstage_hunk()
  end,
  discard = function(first, last)
    require("picked.ui.signs").discard_hunk(first, last)
  end,
  preview = function()
    require("picked.ui.signs").preview_hunk()
  end,
}

--- Status and statusline ---------------------------------------------------------------------

---@class PickedStatusSummary
---@field root string|nil
---@field name string|nil
---@field branch string|nil
---@field detached boolean
---@field unborn boolean
---@field upstream string|nil
---@field ahead integer
---@field behind integer
---@field staged integer
---@field unstaged integer
---@field untracked integer
---@field conflicts integer
---@field state string  "normal", "merge", "rebase", …
---@field busy boolean
---@field clean boolean

---A structured snapshot of the active repository, for statuslines and
---other integrations.
---
---Reads only from the store: it never runs git, so calling it on every
---statusline redraw is free.
---
---`branch` comes from HEAD on disk and is therefore available immediately,
---while the counts arrive with the first `git status`. During that window
---`busy` is true and every count is zero — that is how a consumer
---distinguishes "still reading" from "nothing changed".
---@return PickedStatusSummary
function M.get_status()
  local store = require("picked.state")
  local state = store.active()

  ---@type PickedStatusSummary
  local summary = {
    root = nil,
    name = nil,
    branch = nil,
    detached = false,
    unborn = false,
    upstream = nil,
    ahead = 0,
    behind = 0,
    staged = 0,
    unstaged = 0,
    untracked = 0,
    conflicts = 0,
    state = "normal",
    busy = false,
    clean = true,
  }

  if not state then
    return summary
  end

  summary.root = state.repo.root
  summary.name = state.repo.name
  summary.busy = store.is_loading(state.repo.root)

  if state.head then
    summary.branch = state.head.branch
    summary.detached = state.head.detached
    summary.unborn = state.head.unborn
    if state.head.detached and state.head.short then
      summary.branch = state.head.short
    end
  end

  if state.git_state then
    summary.state = state.git_state.kind
  end

  local status = state.status
  if status then
    summary.upstream = status.branch.upstream
    summary.ahead = status.branch.ahead
    summary.behind = status.branch.behind
    summary.staged = #status.staged
    summary.unstaged = #status.unstaged - #status.untracked
    summary.untracked = #status.untracked
    summary.conflicts = #status.conflicts
    summary.clean = status.clean
  end

  return summary
end

---A ready-made statusline component.
---
---Example: ` feature/cart ↑2 ~3 +1 !2`
---@param opts { icons: boolean|nil, max_length: integer|nil }|nil
---@return string
function M.statusline(opts)
  opts = opts or {}
  local summary = M.get_status()
  if not summary.branch then
    return ""
  end

  local icons = require("picked.utils.icons")
  local text_util = require("picked.utils.text")
  local config = require("picked.config")
  local use_icons = opts.icons ~= false

  local parts = {}
  local branch = text_util.truncate(summary.branch, opts.max_length or config.options.statusline.max_branch_length)
  parts[#parts + 1] = use_icons and (icons.get("branch") .. " " .. branch) or branch

  if summary.state ~= "normal" then
    parts[#parts + 1] = "[" .. summary.state:upper() .. "]"
  end

  if summary.ahead > 0 then
    parts[#parts + 1] = (use_icons and icons.get("arrow_up") or "^") .. summary.ahead
  end
  if summary.behind > 0 then
    parts[#parts + 1] = (use_icons and icons.get("arrow_down") or "v") .. summary.behind
  end
  if summary.staged > 0 then
    parts[#parts + 1] = "+" .. summary.staged
  end
  if summary.unstaged > 0 then
    parts[#parts + 1] = "~" .. summary.unstaged
  end
  if summary.untracked > 0 then
    parts[#parts + 1] = "?" .. summary.untracked
  end
  if summary.conflicts > 0 then
    parts[#parts + 1] = "!" .. summary.conflicts
  end

  local progress = require("picked.ui.notify").status()
  if progress ~= "" then
    parts[#parts + 1] = progress
  end

  return table.concat(parts, " ")
end

---Per-buffer change counts, for statuslines that show them next to the file
---name rather than the branch.
---@param bufnr integer|nil
---@return { added: integer, changed: integer, removed: integer }
function M.buffer_status(bufnr)
  return require("picked.ui.signs").summary(bufnr)
end

---Subscribe to a plugin event.
---@param name string  a value of `require("picked.utils.events").names`
---@param callback fun(data: any)
---@return fun() unsubscribe
function M.on(name, callback)
  return require("picked.utils.events").on(name, callback)
end

---Event names, for `M.on` and for `User Picked<Name>` autocommands.
M.events = require("picked.utils.events").names

--- Teardown ------------------------------------------------------------------------------

---Release every resource the plugin holds. Mostly useful for development and
---for the test suite.
function M.reset()
  M.close_all()

  require("picked.ui.source_control").destroy()
  require("picked.ui.diff_view").destroy()
  require("picked.ui.branches").destroy()
  require("picked.ui.log").destroy()
  require("picked.ui.stash").destroy()
  require("picked.ui.output").destroy()
  require("picked.ui.help").close()
  require("picked.ui.menu").close()

  require("picked.state.refresh").teardown()
  require("picked.ui.signs").teardown()
  require("picked.ui.blame").disable_virtual_text()
  require("picked.state").reset()
  require("picked.git.repository").invalidate()
  require("picked.utils.events").reset()

  initialised = false
end

return M
