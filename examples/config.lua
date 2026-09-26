-- Example gitui.nvim configuration.
--
-- Every value shown is the default unless a comment says otherwise, so you can
-- delete anything you do not want to change. The shortest useful configuration
-- is `require("gitui").setup({})`.

require("gitui").setup({
  --- Layout ------------------------------------------------------------------

  position = "left", -- "left" | "right" | "float"
  width = 42,
  compact_width = 34, -- below this, the panel drops decorations

  --- Behaviour ---------------------------------------------------------------

  auto_refresh = true,
  refresh_debounce = 250, -- ms; raise this on a very large repository
  file_watch = true,

  timeout = 20000,
  network_timeout = 120000,

  log_level = "warn",
  icons = "auto", -- true | false | "auto"
  tree = true,
  tree_flatten = true,
  hints = true,

  --- Safety ------------------------------------------------------------------
  --
  -- Setting any of these to false is an explicit opt-in to an unsafe mode.
  -- `:checkhealth gitui` reports the ones you have turned off.

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

  --- Diffs -------------------------------------------------------------------

  diff = {
    context = 3,
    algorithm = "histogram",
    ignore_whitespace = false,

    -- What selecting a file in the panel does:
    --   "auto"   open its diff in the editor area, keeping the cursor in the
    --            panel. This is the VS Code behaviour.
    --   "follow" only retarget a diff that is already open.
    --   false    nothing; `d` opens the diff on demand.
    preview = "auto",
    preview_delay = 120,

    -- Which presentation a diff opens in. `<C-v>` toggles at any time, and
    -- `]c`/`[c` jump between hunks in both.
    view = "unified", -- "unified" | "split"
    layout = "vertical", -- orientation of the split view
  },

  --- Inline signs ------------------------------------------------------------
  --
  -- Set `enabled = false` to run gitui alongside gitsigns.nvim.

  signs = {
    enabled = true,
    priority = 6,
    debounce = 150,
    max_filesize = 2 * 1024 * 1024,
  },

  --- Blame -------------------------------------------------------------------

  blame = {
    enabled = true,
    virtual_text = false, -- set true for always-on current-line blame
    virtual_text_delay = 400,
    date_format = "%Y-%m-%d",

    -- The code and the blame column move together in both directions, using
    -- Neovim's own 'scrollbind'/'cursorbind'.
    sync_cursor = true,
    -- Light up every line of the current commit, in both panes.
    highlight_block = true,
    -- One colour per commit in the blame column.
    color_commits = true,
  },

  --- History -----------------------------------------------------------------

  log = {
    page_size = 256,
    graph = true,
  },

  --- Commit ------------------------------------------------------------------

  commit = {
    subject_length = 72, -- 0 disables the warning
    body_length = 0,
    sign = nil, -- nil inherits git's commit.gpgsign
  },

  --- Remotes -----------------------------------------------------------------

  remote = {
    pull_strategy = "ask", -- "merge" | "rebase" | "ff-only" | "ask"
    auto_set_upstream = true,
    fetch_prune = false,
    force_push_mode = "with-lease", -- "force" is a deliberate safety downgrade
  },

  browse = {
    opener = nil, -- nil auto-detects
    hosts = {
      -- Teach gitui the URL layout of a self-hosted forge:
      -- ["git.corp.internal"] = "gitlab",
    },
  },

  --- Mouse -------------------------------------------------------------------

  mouse = {
    enabled = true,
    click = true, -- single click activates controls only
    double_click = true, -- double click runs the row's primary action
    context_menu = true, -- right click
  },

  --- Keymaps -----------------------------------------------------------------
  --
  -- gitui never overwrites a mapping you already have; a default whose key is
  -- taken is skipped, and `:checkhealth gitui` lists the skips.

  default_keymaps = true,

  global_keymaps = {
    source_control = "<leader>gs",
    diff = "<leader>gd",
    branches = "<leader>gb",
    log = "<leader>gl",
    file_history = "<leader>gh",
    commit = "<leader>gc",
    push = "<leader>gp",
    pull = "<leader>gP",
    fetch = "<leader>gf",
    stash = "<leader>gS",
    blame = "<leader>gB",
    palette = "<leader>g<space>",

    -- Hunk actions in ordinary file buffers.
    next_hunk = "]c",
    prev_hunk = "[c",
    stage_hunk = "<leader>hs",
    unstage_hunk = "<leader>hu",
    discard_hunk = "<leader>hr",
    preview_hunk = "<leader>hp",
    blame_line = "<leader>hb",
  },

  -- Per-view mappings. A value may be a string, a list of strings, or `false`
  -- to disable the action entirely.
  keymaps = {
    source_control = {
      -- stage = "<Space>",
      -- unstage = "<BS>",
      -- discard = false,
    },
  },

  --- Integrations ------------------------------------------------------------
  --
  -- All optional, all detected at runtime. Set any to false to force gitui's
  -- own implementation.

  integrations = {
    telescope = "auto",
    snacks = "auto",
    fzf_lua = "auto",
    which_key = "auto",
  },
})

--- Statusline ----------------------------------------------------------------

-- lualine:
--
--   sections = {
--     lualine_b = { require("gitui.integrations").lualine() },
--   }
--
-- anything else:
--
--   require("gitui").statusline()      --> " feature/cart ↑2 ~3 +1"
--   require("gitui").get_status()      --> structured table
--   require("gitui").buffer_status()   --> { added, changed, removed }

--- Telescope -----------------------------------------------------------------

-- require("telescope").load_extension("gitui")
--   :Telescope gitui branches | commits | status | stashes

--- Events --------------------------------------------------------------------

-- vim.api.nvim_create_autocmd("User", {
--   pattern = "GitUIPushFinished",
--   callback = function(args)
--     vim.notify(args.data.ok and "pushed" or "push failed")
--   end,
-- })
