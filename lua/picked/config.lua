---@brief Configuration defaults, validation and access for picked.nvim.
---
---The configuration is a plain table. `setup()` deep-merges the user table over
---the defaults below. No other module may mutate it after startup.

local M = {}

---@class PickedConfirmConfig
---@field discard boolean
---@field discard_hunk boolean
---@field reset_hard boolean
---@field reset_mixed boolean
---@field reset_soft boolean
---@field force_push boolean
---@field branch_delete boolean
---@field stash_drop boolean
---@field clean boolean
---@field revert boolean
---@field push boolean
---@field pull boolean

---@class PickedConfig
---@field position "left"|"right"|"float"
---@field width integer
---@field auto_refresh boolean
---@field refresh_debounce integer
---@field file_watch boolean
---@field timeout integer
---@field log_level "trace"|"debug"|"info"|"warn"|"error"|"off"
---@field icons boolean|"auto"
---@field tree boolean
---@field confirm PickedConfirmConfig

---Default configuration. Every behaviour that a user could reasonably want to
---change lives here.
---@type PickedConfig
local defaults = {
  --- Where the Source Control panel is displayed.
  ---@type "left"|"right"|"float"
  position = "left",

  --- Width of the sidebar in columns (clamped to the available UI width).
  width = 42,

  --- Minimum width below which the panel renders in "compact" mode.
  compact_width = 34,

  --- What the sidebar does when it would be the only window left, which
  --- happens as soon as you close the last file.
  ---
  ---   "keep_width"  hold the configured width by leaving an empty window
  ---                 beside it, so the panel never jumps to full screen.
  ---   "expand"      let Neovim stretch it across the screen, its default.
  ---   "close"       close the panel too.
  ---
  --- Under "keep_width", closing the empty window yourself is respected: the
  --- panel expands rather than conjuring another one, so `:q` still works.
  ---@type "keep_width"|"expand"|"close"
  last_window = "keep_width",

  --- Automatically refresh repository state on relevant events.
  auto_refresh = true,

  --- Milliseconds to coalesce refresh requests. Prevents `git status` storms.
  refresh_debounce = 250,

  --- Watch `.git` with libuv fs-events instead of polling. Falls back to
  --- autocmd-driven refreshes when unavailable.
  file_watch = true,

  --- Hard timeout (ms) for a single git invocation. Network operations use
  --- `network_timeout` instead.
  timeout = 20000,
  network_timeout = 120000,

  --- trace | debug | info | warn | error | off
  log_level = "warn",

  --- `true` forces nerd-font glyphs, `false` forces ASCII, "auto" probes.
  ---@type boolean|"auto"
  icons = "auto",

  --- Render changes as a collapsible directory tree instead of a flat list.
  tree = true,

  --- Collapse directories that contain a single child into one row ("a/b/c").
  tree_flatten = true,

  --- Show the one-line keybinding hint footer in panels.
  hints = true,

  --- Confirmation prompts for destructive operations. Disabling any of these
  --- is an explicit opt-in to an unsafe mode.
  confirm = {
    discard = true,
    discard_hunk = true,
    reset_hard = true,
    reset_mixed = false,
    reset_soft = false,
    force_push = true,
    branch_delete = true,
    stash_drop = true,
    clean = true,
    revert = true,
    push = false,
    pull = false,
  },

  --- Diff computation and presentation.
  diff = {
    --- Lines of context in generated diffs and patches.
    context = 3,
    --- git diff algorithm: myers | minimal | patience | histogram
    algorithm = "histogram",
    ignore_whitespace = false,
    --- Which presentation a diff opens in.
    ---
    ---   "unified"  one patch buffer with +/- lines. This is where staging
    ---              happens: hunk and line-level staging need a patch.
    ---   "split"    side-by-side, built on Neovim's own |:diffthis|, so
    ---              folding, ]c/[c and do/dp behave exactly as they do in any
    ---              other diff. A reading view.
    ---
    --- `<C-v>` toggles between them at any time, and `]c`/`[c` jump between
    --- hunks in both.
    ---@type "unified"|"split"
    view = "unified",

    --- Orientation of the split view: "vertical" places the two sides beside
    --- each other, "horizontal" stacks them.
    ---@type "vertical"|"horizontal"
    layout = "vertical",

    --- What moving the cursor onto a file in the Source Control panel does.
    ---
    ---   "auto"   open the diff in the editor area, keeping the cursor in the
    ---            panel. This is the VS Code behaviour: select a file, see its
    ---            added and removed lines immediately.
    ---   "follow" only update a diff view that is already open; never open one.
    ---   false    do nothing; the diff opens only on demand with `d`.
    ---
    --- `true` is accepted as a synonym for "auto".
    ---@type "auto"|"follow"|boolean
    preview = "auto",
    preview_delay = 120,
  },

  --- Inline change signs in ordinary file buffers.
  signs = {
    enabled = true,
    priority = 6,
    --- Show signs for the index->worktree diff of the current buffer.
    watch_buffers = true,
    --- Debounce (ms) for recomputing signs while typing.
    debounce = 150,
    --- Maximum buffer size (bytes) to track. Larger files are skipped.
    max_filesize = 2 * 1024 * 1024,
    text = {
      add = "┃",
      change = "┃",
      delete = "▁",
      topdelete = "▔",
      changedelete = "~",
      untracked = "┆",
    },
    ascii_text = {
      add = "+",
      change = "~",
      delete = "_",
      topdelete = "-",
      changedelete = "~",
      untracked = ":",
    },
  },

  --- Blame configuration.
  blame = {
    enabled = true,
    --- Virtual text at the end of the current line showing the last commit.
    virtual_text = false,
    virtual_text_delay = 400,
    --- Format used by the virtual text and the blame gutter.
    date_format = "%Y-%m-%d",
    --- Ignore whitespace-only changes when blaming.
    ignore_whitespace = true,

    --- Keep the code and the blame column scrolled and cursored together, in
    --- both directions. Implemented with Neovim's own 'scrollbind' and
    --- 'cursorbind', so mouse wheels, <C-e>, `zz` and search jumps are all
    --- carried across without picked having to emulate them.
    sync_cursor = true,

    --- Highlight every line that belongs to the same commit as the line under
    --- the cursor, in *both* panes. This is what makes it obvious which block
    --- of code a blame entry accounts for.
    highlight_block = true,

    --- Give each commit its own colour in the blame column, so adjacent
    --- commits are distinguishable at a glance.
    color_commits = true,
  },

  --- Commit history.
  log = {
    --- Commits fetched per page.
    page_size = 256,
    --- Draw the ASCII commit graph column.
    graph = true,
    date_format = "relative",
  },

  --- Commit UI behaviour.
  commit = {
    --- Warn when the subject line exceeds this many columns (0 disables).
    subject_length = 72,
    --- Warn when body lines exceed this many columns (0 disables).
    body_length = 0,
    --- Offer conventional-commit type completion in the commit buffer.
    conventional = false,
    --- Show the staged diff below the message buffer.
    show_diff = true,
    --- Sign commits. nil = inherit git config (recommended).
    ---@type boolean|nil
    sign = nil,
  },

  --- Push/pull/fetch behaviour.
  remote = {
    --- "merge" | "rebase" | "ff-only" | "ask"
    pull_strategy = "ask",
    --- Automatically add --set-upstream when the branch has no upstream.
    auto_set_upstream = true,
    --- Prune deleted remote branches on fetch.
    fetch_prune = false,
    --- Force-push style. "with-lease" is strongly recommended.
    ---@type "with-lease"|"force"
    force_push_mode = "with-lease",
  },

  --- Browser integration for "open on remote" actions.
  browse = {
    --- Command used to open URLs. nil = auto-detect (open/xdg-open/start).
    ---@type string[]|nil
    opener = nil,
    --- Extra host -> provider mappings for self-hosted forges, e.g.
    ---   { ["git.corp.internal"] = "gitlab" }
    ---@type table<string, "github"|"gitlab"|"bitbucket"|"gitea"|"sourcehut">
    hosts = {},
  },

  --- Optional integrations. "auto" enables them when the plugin is installed.
  integrations = {
    telescope = "auto",
    snacks = "auto",
    fzf_lua = "auto",
    which_key = "auto",
  },

  --- Install the default mappings. Existing user mappings are never
  --- overwritten, so anything already taken is simply skipped
  --- (`:checkhealth picked` lists what was skipped).
  default_keymaps = true,

  --- Prefix every global mapping shares.
  ---
  --- picked deliberately does *not* squat on `<leader>g`: distributions such as
  --- LazyVim already own most of it, and a silently skipped mapping is worse
  --- than an unfamiliar one. Everything lives under one prefix instead, so a
  --- single line moves the whole set:
  ---
  ---   require("picked").setup({ prefix = "<leader>gui" })
  prefix = "<leader>gu",

  --- Global mappings, installed when `default_keymaps` is true.
  ---
  --- `<prefix>` expands to the `prefix` option above. A value without the
  --- token is used verbatim, and `false` skips the mapping entirely.
  global_keymaps = {
    source_control = "<prefix>u",
    diff = "<prefix>d",
    branches = "<prefix>b",
    log = "<prefix>l",
    file_history = "<prefix>h",
    commit = "<prefix>c",
    push = "<prefix>p",
    pull = "<prefix>P",
    fetch = "<prefix>f",
    stash = "<prefix>s",
    blame = "<prefix>B",
    palette = "<prefix><space>",

    -- Hunk actions in ordinary file buffers. `]c`/`[c` fall through to
    -- Neovim's own diff-mode motions whenever the window is in diff mode.
    next_hunk = "]c",
    prev_hunk = "[c",
    stage_hunk = "<prefix>S",
    unstage_hunk = "<prefix>U",
    discard_hunk = "<prefix>X",
    preview_hunk = "<prefix>v",
    blame_line = "<prefix>L",
  },

  --- Per-view buffer-local mappings. Each value may be a string, a list of
  --- strings, or `false` to disable the action.
  keymaps = {
    --- Shared by every picked panel.
    common = {
      close = { "q", "<Esc>" },
      help = "?",
      refresh = "r",
      palette = "<C-p>",
      search = "/",
      next_section = "<Tab>",
      prev_section = "<S-Tab>",
    },

    source_control = {
      open = "<CR>",
      open_split = "<C-x>",
      open_vsplit = "<C-v>",
      open_tab = "<C-t>",
      stage = "s",
      stage_all = "S",
      unstage = "u",
      unstage_all = "U",
      discard = "x",
      diff = "d",
      diff_full = "D",
      toggle = "za",
      toggle_all = "zA",
      commit = "c",
      commit_amend = "ca",
      commit_push = "cP",
      push = "p",
      pull = "P",
      fetch = "f",
      branches = "b",
      log = "l",
      stash = "z",
      blame = "B",
      file_history = "h",
      open_remote = "o",
      copy_path = "yp",
      copy_relative_path = "yy",
      context_menu = "m",
      next_file = "]f",
      prev_file = "[f",
      resolve = "R",
    },

    diff = {
      stage_hunk = "s",
      unstage_hunk = "u",
      discard_hunk = "x",
      stage_lines = "s", -- visual mode
      discard_lines = "x", -- visual mode
      next_hunk = "]c",
      prev_hunk = "[c",
      next_file = "]f",
      prev_file = "[f",
      open_file = "<CR>",
      --- Switch between what is being compared: HEAD↔index and index↔worktree.
      toggle_side = "<Tab>",
      --- Switch between the unified patch and the side-by-side view.
      toggle_view = "<C-v>",
    },

    log = {
      open = "<CR>",
      diff = "d",
      cherry_pick = "c",
      revert = "v",
      branch = "b",
      reset = "R",
      copy_hash = "yy",
      open_remote = "o",
      checkout = "C",
      tag = "t",
      load_more = "L",
    },

    branches = {
      switch = "<CR>",
      create = "c",
      delete = "d",
      rename = "R",
      merge = "m",
      rebase = "r",
      push = "p",
      log = "l",
      diff = "D",
      fetch = "f",
      set_upstream = "u",
    },

    stash = {
      inspect = "<CR>",
      apply = "a",
      pop = "p",
      drop = "d",
      branch = "b",
      create = "c",
      diff = "D",
    },

    commit = {
      submit = { "<C-CR>", "<C-s>" },
      submit_push = "<C-p>",
      amend = "<C-a>",
      cancel = "<C-c>",
    },

    blame = {
      inspect = "<CR>",
      diff = "d",
      reblame = "R",
      copy_hash = "yy",
      open_remote = "o",
    },

    conflict = {
      ours = "o",
      theirs = "t",
      both = "b",
      base = "B",
      none = "n",
      next_conflict = "]x",
      prev_conflict = "[x",
      stage = "s",
    },
  },

  --- Enable mouse handling inside picked panels. Mouse support is strictly
  --- additive: every action also has a keyboard mapping.
  mouse = {
    enabled = true,
    --- Single left click activates the row (open file / expand folder).
    click = true,
    --- Right click opens the contextual menu.
    context_menu = true,
    --- Double click opens the diff.
    double_click = true,
  },

  --- Statusline provider tuning.
  statusline = {
    --- Maximum branch-name length before truncation.
    max_branch_length = 24,
  },

  --- Floating window appearance.
  float = {
    border = "rounded",
    --- Fractions of the editor size used as maximums for auto-sized floats.
    max_width = 0.9,
    max_height = 0.85,
    winblend = 0,
  },

  --- Performance guard rails.
  performance = {
    --- Above this many changed entries the panel stops rendering per-file
    --- decorations and collapses directories by default.
    large_status_threshold = 2000,
    --- Skip automatic diff/sign work for files larger than this (bytes).
    max_file_size = 10 * 1024 * 1024,
  },
}

---@type PickedConfig
M.options = vim.deepcopy(defaults)

---@return PickedConfig
function M.defaults()
  return vim.deepcopy(defaults)
end

local valid_positions = { left = true, right = true, float = true }
local valid_levels = { trace = true, debug = true, info = true, warn = true, error = true, off = true }
local valid_pull = { merge = true, rebase = true, ["ff-only"] = true, ask = true }

---Validate the merged options, emitting warnings and repairing bad values so a
---typo in a user config can never break the plugin.
---@param opts PickedConfig
---@return string[] problems
local function validate(opts)
  local problems = {}

  local function bad(field, value, expected)
    problems[#problems + 1] = ("picked: invalid `%s` (%s); expected %s"):format(field, vim.inspect(value), expected)
  end

  if not valid_positions[opts.position] then
    bad("position", opts.position, "'left', 'right' or 'float'")
    opts.position = defaults.position
  end

  if type(opts.width) ~= "number" or opts.width < 20 then
    bad("width", opts.width, "a number >= 20")
    opts.width = defaults.width
  end

  if not valid_levels[opts.log_level] then
    bad("log_level", opts.log_level, "a log level name")
    opts.log_level = defaults.log_level
  end

  if not valid_pull[opts.remote.pull_strategy] then
    bad("remote.pull_strategy", opts.remote.pull_strategy, "'merge', 'rebase', 'ff-only' or 'ask'")
    opts.remote.pull_strategy = defaults.remote.pull_strategy
  end

  if opts.remote.force_push_mode ~= "with-lease" and opts.remote.force_push_mode ~= "force" then
    bad("remote.force_push_mode", opts.remote.force_push_mode, "'with-lease' or 'force'")
    opts.remote.force_push_mode = defaults.remote.force_push_mode
  end

  if type(opts.diff.context) ~= "number" or opts.diff.context < 0 then
    bad("diff.context", opts.diff.context, "a non-negative number")
    opts.diff.context = defaults.diff.context
  end

  if opts.icons ~= true and opts.icons ~= false and opts.icons ~= "auto" then
    bad("icons", opts.icons, "true, false or 'auto'")
    opts.icons = defaults.icons
  end

  local valid_last_window = { keep_width = true, expand = true, close = true }
  if not valid_last_window[opts.last_window] then
    bad("last_window", opts.last_window, "'keep_width', 'expand' or 'close'")
    opts.last_window = defaults.last_window
  end

  if opts.diff.view ~= "unified" and opts.diff.view ~= "split" then
    bad("diff.view", opts.diff.view, "'unified' or 'split'")
    opts.diff.view = defaults.diff.view
  end

  if opts.diff.layout ~= "vertical" and opts.diff.layout ~= "horizontal" then
    bad("diff.layout", opts.diff.layout, "'vertical' or 'horizontal'")
    opts.diff.layout = defaults.diff.layout
  end

  -- `true` has always meant "preview the entry under the cursor", so keep it
  -- working now that the option names its modes.
  if opts.diff.preview == true then
    opts.diff.preview = "auto"
  end
  if opts.diff.preview ~= false and opts.diff.preview ~= "auto" and opts.diff.preview ~= "follow" then
    bad("diff.preview", opts.diff.preview, "'auto', 'follow' or false")
    opts.diff.preview = defaults.diff.preview
  end

  return problems
end

---Merge a user configuration over the defaults.
---@param user table|nil
---@return PickedConfig
function M.setup(user)
  local merged = vim.tbl_deep_extend("force", vim.deepcopy(defaults), user or {})

  -- `vim.tbl_deep_extend` merges list-like keymap values element-wise, which is
  -- wrong for `{ "q", "<Esc>" }` style entries: a user supplying `{ "q" }`
  -- means "only q". Re-apply those leaves verbatim.
  if user and user.keymaps then
    for view, maps in pairs(user.keymaps) do
      if type(maps) == "table" and merged.keymaps[view] then
        for action, lhs in pairs(maps) do
          merged.keymaps[view][action] = lhs
        end
      end
    end
  end
  if user and user.global_keymaps then
    for action, lhs in pairs(user.global_keymaps) do
      merged.global_keymaps[action] = lhs
    end
  end
  if user and user.browse and user.browse.opener then
    merged.browse.opener = user.browse.opener
  end

  -- Expand `<prefix>` before anything reads a mapping, so consumers only ever
  -- see final left-hand sides.
  --
  -- The replacement is escaped and parenthesised deliberately: `%` is special
  -- on the right-hand side of gsub, and an unparenthesised inner gsub would
  -- pass its match count as this gsub's `n` argument — which silently means
  -- "replace nothing".
  local prefix = merged.prefix or ""
  local escaped = (prefix:gsub("%%", "%%%%"))
  for action, lhs in pairs(merged.global_keymaps) do
    if type(lhs) == "string" then
      merged.global_keymaps[action] = (lhs:gsub("^<prefix>", escaped))
    end
  end

  local problems = validate(merged)
  M.options = merged

  for _, problem in ipairs(problems) do
    vim.notify(problem, vim.log.levels.WARN)
  end

  return M.options
end

---Convenience accessor: `config.get("diff.context")`.
---@param path string|nil dot-separated path
---@return any
function M.get(path)
  if not path then
    return M.options
  end
  local node = M.options
  for part in path:gmatch("[^.]+") do
    if type(node) ~= "table" then
      return nil
    end
    node = node[part]
  end
  return node
end

return M
