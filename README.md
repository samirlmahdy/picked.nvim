# gitui.nvim

A complete Git workflow environment for Neovim, modelled on the VS Code Source
Control experience but built entirely from Neovim primitives — buffers,
windows, extmarks, signs, keymaps and async jobs.

The goal is narrow and concrete:

> You should never need to open VS Code, or leave Neovim for a terminal, just
> to do something with Git.

Keyboard-first, fully usable with a mouse, asynchronous throughout, and safe
with destructive operations by default.

---

## Features

**Source Control panel**
- Staged, unstaged, untracked and conflicted changes in one view
- Collapsible directory tree, or a flat list
- Stage, unstage and discard by file, directory, section or visual selection
- Live branch, upstream ahead/behind, and in-progress operation state

**Diffs**
- Unified patch view with hunk and **line-level** staging
- True side-by-side view using Neovim's own `:diffthis`
- Every comparison names both sides — index ↔ working tree, HEAD ↔ index,
  HEAD ↔ working tree, commit ↔ parent, branch ↔ branch
- Inline change signs in ordinary file buffers, with hunk actions

**History**
- Paged commit log with a computed commit graph
- Commit details: metadata, message, changed files with line counts
- File history (following renames) and line history
- Blame view scroll-bound to the file, plus current-line virtual text

**Operations**
- Commit in a real `gitcommit` buffer, amend, commit & push
- Push, pull (merge / rebase / ff-only), fetch, prune
- Branch create, switch, rename, delete, merge, rebase, set upstream
- Stash push/apply/pop/drop/branch
- Cherry-pick, revert, reset, tag
- Merge conflict resolution with ours/theirs/both/base, and a three-way view
- Continue, skip or abort any in-progress merge, rebase, cherry-pick or revert
- Open the repository, a file, a line range or a commit on GitHub, GitLab,
  Bitbucket, Gitea, SourceHut or a self-hosted forge

**Everything else**
- Command palette, contextual menus, generated help
- Responsive from 80 to 200+ columns
- Multi-repository and worktree aware
- Statusline API with no plugin dependency
- No hard dependencies beyond Neovim and git

---

## Requirements

- Neovim **0.10+** (uses `vim.system`, `vim.uv`, extmark signs)
- git **2.20+** (2.23+ recommended, for `git switch`/`restore`)

Nerd fonts are optional. gitui probes for glyph support and falls back to ASCII
automatically; the UI is designed to be readable either way, and never
communicates state with colour alone.

---

## Installation

### lazy.nvim

```lua
{
  "samirlmahdy/gitui.nvim",
  cmd = { "GitUI", "GitUIOpen", "GitUIToggle", "GitUILog", "GitUIBranch", "GitUIBlame" },
  keys = {
    { "<leader>gs", "<cmd>GitUIToggle<cr>", desc = "Source Control" },
    { "<leader>gc", "<cmd>GitUICommit<cr>", desc = "Commit" },
    { "<leader>gl", "<cmd>GitUILog<cr>", desc = "Commit history" },
  },
  opts = {},
}
```

### packer.nvim

```lua
use({
  "samirlmahdy/gitui.nvim",
  config = function()
    require("gitui").setup({})
  end,
})
```

### vim-plug

```vim
Plug 'samirlmahdy/gitui.nvim'
lua require('gitui').setup({})
```

`setup()` is optional — the commands self-initialise — but calling it is how you
change any of the configuration below.

---

## Quick start

1. Open a file inside a repository.
2. `<leader>gs` opens the Source Control panel.
3. `j`/`k` to move, `s` to stage, `u` to unstage, `d` to see the diff.
4. `c` opens the commit editor; write a message and press `<C-s>` (or `:w`).
5. `p` pushes. `?` shows every key, generated from *your* configuration.

---

## Keybindings

`?` in any panel shows the current mappings. Everything below is configurable.

### Global

| Key | Action |
| --- | --- |
| `<leader>gs` | Toggle the Source Control panel |
| `<leader>gd` | Diff the current file |
| `<leader>gb` | Branches |
| `<leader>gl` | Commit history |
| `<leader>gh` | History of the current file |
| `<leader>gc` | Commit |
| `<leader>gp` / `<leader>gP` | Push / Pull |
| `<leader>gf` | Fetch |
| `<leader>gS` | Stashes |
| `<leader>gB` | Blame the current file |
| `<leader>g<space>` | Command palette |

### In any file buffer

| Key | Action |
| --- | --- |
| `]c` / `[c` | Next / previous hunk |
| `<leader>hs` | Stage the hunk (or, in visual mode, the selected lines) |
| `<leader>hu` | Unstage the hunk |
| `<leader>hr` | Discard the hunk (or the selected lines) |
| `<leader>hp` | Preview the hunk |
| `<leader>hb` | Blame the current line |

### Source Control panel

| Key | Action |
| --- | --- |
| `<CR>` | Open the file / expand the row |
| `s` / `u` / `x` | Stage / unstage / discard |
| `S` / `U` | Stage all / unstage all |
| `d` / `D` | Diff this entry / diff everything against HEAD |
| `c` / `ca` / `cP` | Commit / amend / commit & push |
| `p` / `P` / `f` | Push / pull / fetch |
| `b` / `l` / `z` | Branches / log / stashes |
| `B` / `h` | Blame / file history |
| `o` | Open on the remote's website |
| `za` / `zA` | Toggle this node / everything |
| `]f` / `[f` | Next / previous file |
| `m` | Contextual menu |
| `r` / `?` / `q` | Refresh / help / close |

Visual mode works in the panel: select several rows and press `s`, `u` or `x`.

### Diff view

| Key | Action |
| --- | --- |
| `s` / `u` / `x` | Stage / unstage / discard the hunk |
| `s` / `x` *(visual)* | Stage / discard exactly the selected lines |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `<Tab>` | Switch between the staged and unstaged view |
| `<CR>` | Open the real file at this line |

### Conflicts

| Key | Action |
| --- | --- |
| `o` / `t` / `b` | Keep ours / theirs / both |
| `B` / `n` | Keep the merge base / neither |
| `]x` / `[x` | Next / previous conflict |
| `s` | Stage the file as resolved |

---

## Commands

| Command | Description |
| --- | --- |
| `:GitUI`, `:GitUIToggle` | Toggle the Source Control panel |
| `:GitUIOpen`, `:GitUIFocus`, `:GitUIClose` | Open / focus / close |
| `:GitUIRefresh[!]` | Re-read state (`!` refreshes every repository) |
| `:GitUIDiff [all\|staged][!]` | Diff (`!` uses the side-by-side view) |
| `:GitUICommit[!] [message]` | Commit (`!` amends) |
| `:GitUIPush[!]` | Push (`!` force-pushes with lease) |
| `:GitUIPull`, `:GitUIFetch[!]` | Pull / fetch (`!` fetches all remotes) |
| `:GitUILog[!]`, `:GitUIBranch`, `:GitUIStash` | History / branches / stashes |
| `:GitUIBlame`, `:GitUIBlameLine` | Blame the file / toggle line blame |
| `:[range]GitUIHistory` | File history, or line history for a range |
| `:GitUIStage`, `:GitUIUnstage` | Stage / unstage paths |
| `:[range]GitUIStageHunk`, `:GitUIUnstageHunk`, `:[range]GitUIDiscardHunk` | Hunk actions |
| `:GitUINextHunk`, `:GitUIPrevHunk`, `:GitUIPreviewHunk` | Hunk navigation |
| `:GitUIConflict[!]` | Next conflict (`!` opens the three-way view) |
| `:GitUIPalette`, `:GitUIRepositories` | Palette / repository picker |
| `:GitUIOutput`, `:GitUIDebugLog`, `:GitUIHealth` | Diagnostics |

---

## Configuration

Every value below is a default; pass only what you want to change.

```lua
require("gitui").setup({
  position = "left",          -- "left" | "right" | "float"
  width = 42,
  compact_width = 34,         -- below this, the panel drops decorations

  auto_refresh = true,
  refresh_debounce = 250,
  file_watch = true,

  timeout = 20000,            -- ms, ordinary commands
  network_timeout = 120000,   -- ms, push/pull/fetch

  log_level = "warn",         -- trace | debug | info | warn | error | off
  icons = "auto",             -- true | false | "auto"
  tree = true,                -- tree vs flat list
  tree_flatten = true,        -- collapse single-child directories
  hints = true,               -- key hint footer

  -- Disabling any of these is an explicit opt-in to an unsafe mode.
  confirm = {
    discard = true, discard_hunk = true,
    reset_hard = true, reset_mixed = false, reset_soft = false,
    force_push = true, branch_delete = true, stash_drop = true,
    clean = true, revert = true, push = false, pull = false,
  },

  diff = {
    context = 3,
    algorithm = "histogram",
    ignore_whitespace = false,
    preview = true,           -- follow the panel cursor in an open diff
    preview_delay = 120,
  },

  signs = {
    enabled = true,
    priority = 6,
    watch_buffers = true,
    debounce = 150,
    max_filesize = 2 * 1024 * 1024,
    text = { add = "┃", change = "┃", delete = "▁", topdelete = "▔",
             changedelete = "~", untracked = "┆" },
  },

  blame = {
    enabled = true,
    virtual_text = false,     -- current-line blame as virtual text
    virtual_text_delay = 400,
    date_format = "%Y-%m-%d",
    ignore_whitespace = true,
  },

  log = { page_size = 256, graph = true },

  commit = {
    subject_length = 72,      -- 0 disables the warning
    body_length = 0,
    show_diff = true,
    sign = nil,               -- nil inherits git's commit.gpgsign
  },

  remote = {
    pull_strategy = "ask",    -- "merge" | "rebase" | "ff-only" | "ask"
    auto_set_upstream = true,
    fetch_prune = false,
    force_push_mode = "with-lease",
  },

  browse = {
    opener = nil,             -- nil auto-detects
    hosts = {},               -- ["git.corp.internal"] = "gitlab"
  },

  mouse = { enabled = true, click = true, double_click = true, context_menu = true },

  integrations = {
    telescope = "auto", snacks = "auto", fzf_lua = "auto", which_key = "auto",
  },

  default_keymaps = true,
  global_keymaps = { --[[ see :help gitui-keymaps ]] },
  keymaps = { --[[ per-view; see :help gitui-keymaps ]] },
})
```

### Rebinding

Per-view mappings live under `keymaps.<view>`. A value may be a string, a list
of strings, or `false` to disable the action.

```lua
require("gitui").setup({
  keymaps = {
    source_control = {
      stage = "<Space>",
      unstage = "<BS>",
      discard = false,        -- disable entirely
      close = { "q", "<Esc>" },
    },
  },
})
```

gitui **never overwrites a mapping you already have.** A default global mapping
whose key is taken is silently skipped; `:checkhealth gitui` lists them.

---

## Integrations

All optional, all detected at runtime.

**Statusline** — no plugin dependency:

```lua
-- lualine
sections = { lualine_b = { require("gitui.integrations").lualine() } }

-- anything else
require("gitui").statusline()      -- " feature/cart ↑2 ~3 +1"
require("gitui").get_status()      -- structured table
require("gitui").buffer_status()   -- { added, changed, removed } for a buffer
```

These read only from the store and never run git, so calling them on every
redraw is free. The branch name is available immediately; the counts arrive
with the first `git status`. While that is in flight `busy` is true and the
counts are zero, which is how you tell "still reading" from "nothing changed".

**Telescope**:

```lua
require("telescope").load_extension("gitui")
-- :Telescope gitui branches | commits | status | stashes
```

**Snacks / fzf-lua** — if either is installed, gitui's pickers route through it
automatically. Otherwise the built-in fuzzy picker is used.

**which-key** — prefix group names are registered when which-key is present.

### Events

```lua
require("gitui").on("PushFinished", function(data)
  print(data.ok and "pushed" or "push failed")
end)
```

Also published as `User GitUI<Name>` autocommands. Names: `Ready`,
`RepositoryChanged`, `StatusChanged`, `OperationStarted`, `OperationFinished`,
`CommitCreated`, `BranchChanged`, `PushFinished`, `PullFinished`,
`FetchFinished`, `StashChanged`, `ConflictStateChanged`, `PanelOpened`,
`PanelClosed`.

---

## Architecture

```
git       parses git output, spawns processes, knows nothing about windows
  ↓
state     one store per repository, generation-tracked
  ↓
operations  confirmation, progress, error reporting, refresh
  ↓
ui        panels, rendering, keymaps, mouse
```

Three rules hold the design together:

1. **Only `git/command.lua` spawns a process.** Arguments are always an argv
   array — no shell, no interpolation, no injection surface.
2. **Only machine-readable git formats are parsed.** `--porcelain=v2 -z`,
   `for-each-ref --format`, `log -z`, `blame --porcelain`. A filename
   containing a space, a quote, a newline or an emoji round-trips intact.
3. **The newest observation wins.** Every repository carries a generation
   counter; a mutation bumps it, and a status read started beforehand is
   discarded rather than allowed to overwrite fresher state.

See `doc/ARCHITECTURE.md` for the full design, including the patch-construction
rules behind line-level staging.

---

## Safety

Destructive operations require confirmation by default, and each dialog states
what will change, what is lost, and how to decline. `<Esc>`, `q` and `n` all
cancel; `<CR>` never confirms a destructive action.

- Discard, reset `--hard`, `clean`, branch delete, stash drop and rebase all
  confirm before running.
- Force push defaults to `--force-with-lease` (plus `--force-if-includes`);
  plain `--force` must be configured explicitly.
- `git clean` shows the exact list of files it would delete first.
- Git hooks run normally. Bypassing them is never implicit.
- Commit signing is left entirely to your git configuration.
- Conflict markers left in a file are detected before it can be staged as
  resolved.

---

## Troubleshooting

**`:checkhealth gitui`** first — it covers the common causes.

| Symptom | Cause |
| --- | --- |
| Boxes instead of icons | Set `icons = false`, or `vim.g.have_nerd_font = false` |
| "Authentication required" on push | Terminal prompts are disabled inside Neovim by design. Use a credential helper, an SSH agent, or an SSH remote. |
| A default mapping does nothing | Something else already owns that key; gitui never overwrites. `:checkhealth gitui` lists the skips. |
| `<C-s>` does not commit | Your terminal is eating it for flow control. Use `:w`. |
| Panel is empty | The buffer may be outside the repository. `:GitUIRefresh` |
| Slow on a huge repository | Raise `refresh_debounce`, or set `auto_refresh = false` |

`:GitUIOutput` shows the raw output of recent git commands — nothing is ever
swallowed. `:GitUIDebugLog` shows gitui's own log; raise `log_level` to
`"debug"` for more.

---

## FAQ

**Does this replace gitsigns / fugitive / diffview / neogit?**
It covers what they cover, in one plugin, with one configuration. If you like
your current setup, keep it — set `signs.enabled = false` to run gitui
alongside gitsigns, for example.

**Why is there no `git rebase -i` todo editor?**
Interactive rebase is started here and driven by continue/skip/abort, but the
todo list is not yet editable inside gitui. See *Known limitations*.

**Does it work over SSH / in a plain terminal?**
Yes. ASCII fallback, no image protocols, no font requirements.

**Can I use it without any keybindings?**
`default_keymaps = false`, then use the commands or the palette.

---

## Known limitations

These are genuinely not implemented, rather than partially implemented:

- **Interactive rebase todo editing.** `git rebase -i` runs and can be
  continued, skipped or aborted, but reordering or squashing commits from a
  todo list inside gitui is not supported.
- **Submodules are detected, not managed.** They are shown and identified;
  gitui never updates, initialises or commits inside one.
- **`git bisect`** is detected as a repository state but has no UI.
- **Word-level diff highlighting** is not implemented; diffs are line-based.
- **Partial staging of binary files** is impossible by construction; binary
  files can only be staged whole.
- **`git add --patch`-style splitting of a hunk into smaller hunks** is not
  offered; line-level selection covers the same need differently.

---

## Contributing

```bash
./scripts/test.sh              # the whole suite
./scripts/test.sh status_spec  # one file
stylua lua/ tests/ plugin/
```

Tests create real temporary repositories and run real git. If you touch a
parser, add a case to the relevant `*_spec.lua` with the exact bytes git
produces.

---

## License

MIT
