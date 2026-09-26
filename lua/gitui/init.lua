---@brief gitui.nvim — a VS Code-style Source Control experience, built from
---Neovim primitives.
---
---This module is the plugin's entire public surface. Everything else is
---internal and may change between releases; if you find yourself reaching into
---`gitui.ui.*` or `gitui.git.*` from a configuration, please open an issue
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
  return false,
    ("gitui.nvim requires Neovim %d.%d or newer"):format(MIN_NVIM[1], MIN_NVIM[2])
end

---The repository the user means right now: the active one, or whichever owns
---the current buffer.
---@param silent boolean|nil
---@return GitRepository|nil
local function resolve_repo(silent)
  local store = require("gitui.state")
  local state = store.active()
  if state then
    return state.repo
  end

  local repository = require("gitui.git.repository")
  local repo, err = repository.current()
  if repo then
    store.ensure(repo)
    store.set_active(repo)
    return repo
  end

  if not silent then
    require("gitui.ui.notify").error({
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
  local path_util = require("gitui.utils.path")
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
      require("gitui.utils.logger").debug("not overriding existing mapping", single, lhs)
    else
      vim.keymap.set(single, lhs, rhs, { silent = true, desc = "gitui: " .. desc })
    end
  end
end

local function install_default_keymaps()
  local config = require("gitui.config")
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
  local signs = require("gitui.ui.signs")
  safe_map("n", keys.next_hunk, signs.next_hunk, "Next hunk")
  safe_map("n", keys.prev_hunk, signs.prev_hunk, "Previous hunk")
  safe_map("n", keys.preview_hunk, signs.preview_hunk, "Preview hunk")
  safe_map("n", keys.blame_line, function()
    require("gitui.ui.blame").line()
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
---@param opts GitUIConfig|table|nil
---@return GitUIConfig
function M.setup(opts)
  local ok, message = check_version()
  if not ok then
    vim.notify(message, vim.log.levels.ERROR)
    return require("gitui.config").options
  end

  local config = require("gitui.config")
  local options = config.setup(opts)

  require("gitui.utils.logger").set_level(options.log_level)
  require("gitui.utils.icons").setup(options.icons)
  require("gitui.ui.highlights").setup()

  -- Re-running setup must not stack autocommands.
  if initialised then
    require("gitui.state.refresh").teardown()
    require("gitui.ui.signs").teardown()
  end

  require("gitui.state.refresh").setup_autocmds()
  require("gitui.ui.signs").setup()

  if options.blame.enabled and options.blame.virtual_text then
    require("gitui.ui.blame").enable_virtual_text()
  end

  install_default_keymaps()
  require("gitui.integrations").setup()

  initialised = true

  -- Detect the repository for the current context without forcing any UI.
  vim.schedule(function()
    local repo = resolve_repo(true)
    if repo then
      require("gitui.state.refresh").request(repo, "startup")
    end
    require("gitui.utils.events").emit(require("gitui.utils.events").names.READY, {})
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
  require("gitui.ui.source_control").open(opts)
end

---Close the Source Control panel.
function M.close()
  require("gitui.ui.source_control").close()
end

---Toggle the Source Control panel.
---@param opts table|nil
function M.toggle(opts)
  ensure_setup()
  require("gitui.ui.source_control").toggle(opts)
end

---Open the panel and move the cursor into it.
function M.focus()
  ensure_setup()
  require("gitui.ui.source_control").focus()
end

---Close every gitui window.
function M.close_all()
  require("gitui.ui.panel").close_all()
  require("gitui.ui.commit").close()
  require("gitui.ui.blame").close()
  require("gitui.ui.conflict").close()
  require("gitui.ui.output").close()
  require("gitui.ui.menu").close()
end

---Re-read repository state from git.
---@param opts { all: boolean|nil }|nil
function M.refresh(opts)
  ensure_setup()
  opts = opts or {}

  local refresh = require("gitui.state.refresh")
  local repository = require("gitui.git.repository")
  repository.invalidate()

  if opts.all then
    return refresh.all("manual")
  end

  local repo = resolve_repo()
  if repo then
    require("gitui.state").invalidate(repo.root)
    refresh.now(repo, { reason = "manual" })
    require("gitui.ui.source_control").load_stashes(repo)
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

  require("gitui.ui.diff_view").open(repo, {
    path = path,
    spec = spec,
    view = opts.split and "split" or nil,
  })
end

---Switch the open diff between the unified patch and the side-by-side view.
---
---Works from either pane of the split, including the one showing your real
---file, where gitui deliberately installs no mappings.
function M.toggle_diff_view()
  ensure_setup()
  require("gitui.ui.diff_view").toggle_view()
end

---Open the commit editor.
---@param opts GitUICommitOpenOpts|nil
function M.commit(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.ui.commit").open(repo, opts or {})
  end
end

---Open the branch view.
function M.branches()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.ui.branches").open(repo)
  end
end

---Open the commit history.
---@param opts GitUILogOpenOpts|nil
function M.log(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.ui.log").open(repo, opts or {})
  end
end

---Open the stash view.
function M.stash()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.ui.stash").open(repo)
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
    return require("gitui.ui.notify").warn("The current buffer is not a file in this repository")
  end
  require("gitui.ui.blame").open(repo, path)
end

---Toggle the current-line blame virtual text.
function M.toggle_line_blame()
  ensure_setup()
  require("gitui.ui.blame").toggle_virtual_text()
end

---History of the current file.
function M.file_history()
  ensure_setup()
  require("gitui.ui.file_history").current_file()
end

---History of the current line or visual selection.
---@param first integer|nil
---@param last integer|nil
function M.line_history(first, last)
  ensure_setup()
  require("gitui.ui.file_history").current_lines(first, last)
end

---Open the command palette.
function M.palette()
  ensure_setup()
  require("gitui.ui.palette").open()
end

---Pick which tracked repository is active.
function M.repositories()
  ensure_setup()
  require("gitui.ui.palette").repositories()
end

---Show the raw output of recent git commands.
function M.output()
  require("gitui.ui.output").toggle()
end

---Show gitui's own log.
function M.show_log()
  local logger = require("gitui.utils.logger")
  local window = require("gitui.ui.window")

  local lines = logger.lines()
  if #lines == 0 then
    lines = { "No log entries yet.", "", "Raise the level with require('gitui').setup({ log_level = 'debug' })." }
  end
  table.insert(lines, 1, "Log file: " .. logger.file())
  table.insert(lines, 2, "")

  local bufnr = window.create_buffer({ name = "log", filetype = "gitui-log" })
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false

  local winid = window.open_float(bufnr, { title = "GITUI LOG", width = 0.8, height = 0.7 })
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
    require("gitui.operations").push(repo, opts)
  end
end

---Force push, using --force-with-lease unless configured otherwise.
function M.force_push()
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.operations").force_push(repo)
  end
end

---@param opts GitNetworkOpts|nil
function M.pull(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.operations").pull(repo, opts)
  end
end

---@param opts GitNetworkOpts|nil
function M.fetch(opts)
  ensure_setup()
  local repo = resolve_repo()
  if repo then
    require("gitui.operations").fetch(repo, opts)
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
  require("gitui.operations").stage(repo, paths)
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
  require("gitui.operations").unstage(repo, paths)
end

--- Hunk actions ---------------------------------------------------------------------------

M.hunk = {
  next = function()
    require("gitui.ui.signs").next_hunk()
  end,
  prev = function()
    require("gitui.ui.signs").prev_hunk()
  end,
  stage = function(first, last)
    require("gitui.ui.signs").stage_hunk(first, last)
  end,
  unstage = function()
    require("gitui.ui.signs").unstage_hunk()
  end,
  discard = function(first, last)
    require("gitui.ui.signs").discard_hunk(first, last)
  end,
  preview = function()
    require("gitui.ui.signs").preview_hunk()
  end,
}

--- Status and statusline ---------------------------------------------------------------------

---@class GitUIStatusSummary
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
---@return GitUIStatusSummary
function M.get_status()
  local store = require("gitui.state")
  local state = store.active()

  ---@type GitUIStatusSummary
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

  local icons = require("gitui.utils.icons")
  local text_util = require("gitui.utils.text")
  local config = require("gitui.config")
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

  local progress = require("gitui.ui.notify").status()
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
  return require("gitui.ui.signs").summary(bufnr)
end

---Subscribe to a plugin event.
---@param name string  a value of `require("gitui.utils.events").names`
---@param callback fun(data: any)
---@return fun() unsubscribe
function M.on(name, callback)
  return require("gitui.utils.events").on(name, callback)
end

---Event names, for `M.on` and for `User GitUI<Name>` autocommands.
M.events = require("gitui.utils.events").names

--- Teardown ------------------------------------------------------------------------------

---Release every resource the plugin holds. Mostly useful for development and
---for the test suite.
function M.reset()
  M.close_all()

  require("gitui.ui.source_control").destroy()
  require("gitui.ui.diff_view").destroy()
  require("gitui.ui.branches").destroy()
  require("gitui.ui.log").destroy()
  require("gitui.ui.stash").destroy()

  require("gitui.state.refresh").teardown()
  require("gitui.ui.signs").teardown()
  require("gitui.ui.blame").disable_virtual_text()
  require("gitui.state").reset()
  require("gitui.git.repository").invalidate()
  require("gitui.utils.events").reset()

  initialised = false
end

return M
