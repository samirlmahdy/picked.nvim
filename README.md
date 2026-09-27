# picked.nvim

[![CI](https://github.com/samirlmahdy/picked.nvim/actions/workflows/ci.yml/badge.svg)](https://github.com/samirlmahdy/picked.nvim/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)

**Pick exactly what goes into your next commit.**

A complete Git workflow environment for Neovim, modelled on the VS Code Source
Control experience but built entirely from Neovim primitives — buffers,
windows, extmarks, signs, keymaps and async jobs.

The name is the thesis: staging is an act of selection. picked stages by file,
by hunk, or by individual line, and the patch it hands to `git apply` is exactly
the one you chose.

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
- True side-by-side view using Neovim's own `:diffthis` — `<C-v>` toggles
- `]c` / `[c` jump between hunks in **both** views
- Every comparison names both sides — index ↔ working tree, HEAD ↔ index,
  HEAD ↔ working tree, commit ↔ parent, branch ↔ branch
- Inline change signs in ordinary file buffers, with hunk actions

**History**
- Paged commit log with a computed commit graph
- Commit details: metadata, message, changed files with line counts
- File history (following renames) and line history
- Blame view bound to the file in both directions, with the current line and
  its whole commit block highlighted in both panes and a colour per commit

**Operations**
- Commit in a real `gitcommit` buffer, amend, commit & push, with optional
  GitHub Copilot CLI message suggestions
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

Nerd fonts are optional. picked probes for glyph support and falls back to ASCII
automatically; the UI is designed to be readable either way, and never
communicates state with colour alone.

GitHub Copilot CLI is optional and is only needed for AI commit-message
suggestions.

---

## Installation

### lazy.nvim

```lua
{
  "samirlmahdy/picked.nvim",
  cmd = { "Picked", "PickedOpen", "PickedToggle", "PickedLog", "PickedBranch", "PickedBlame" },
  keys = {
    { "<leader>guu", "<cmd>PickedToggle<cr>", desc = "Source Control" },
    { "<leader>guc", "<cmd>PickedCommit<cr>", desc = "Commit" },
    { "<leader>gul", "<cmd>PickedLog<cr>", desc = "Commit history" },
  },
  opts = {},
}
```

### packer.nvim

```lua
use({
  "samirlmahdy/picked.nvim",
  config = function()
    require("picked").setup({})
  end,
})
```

### vim-plug

```vim
Plug 'samirlmahdy/picked.nvim'
lua require('picked').setup({})
```

`setup()` is optional — the commands self-initialise — but calling it is how you
change any of the configuration below.

---

## Quick start

1. Open a file inside a repository.
2. `<leader>gs` opens the Source Control panel.
3. `j`/`k` to move. **Selecting a file shows its diff** — added and removed
   lines with `+`/`-`, in green and red — while the cursor stays in the list.
4. `s` stages, `u` unstages, `x` discards. In the diff, `s` stages one hunk,
   or exactly the lines you select in visual mode.
5. `c` opens the commit editor; write a message, or press `<C-g>` to ask the
   optional GitHub Copilot CLI for an editable suggestion. Press `<C-s>` (or
   `:w`) to commit.
6. `p` pushes. `?` shows every key, generated from *your* configuration.

If you would rather browse the list without diffs opening, set
`diff = { preview = false }` and use `d` on demand.

---

## Keybindings

`?` in any panel shows the current mappings. Everything below is configurable.

### Global

Everything lives under one prefix, `<leader>gu` by default. picked deliberately
does **not** squat on `<leader>g`: distributions like LazyVim already own most
of it, and a silently skipped mapping is worse than an unfamiliar one. One line
moves the whole set:

```lua
require("picked").setup({ prefix = "<leader>gui" })
```

| Key | Action |
| --- | --- |
| `<leader>guu` | Toggle the Source Control panel |
| `<leader>gud` | Diff the current file |
| `<leader>gub` | Branches |
| `<leader>gul` | Commit history |
| `<leader>guh` | History of the current file |
| `<leader>guc` | Commit |
| `<leader>gup` / `<leader>guP` | Push / Pull |
| `<leader>guf` | Fetch |
| `<leader>gus` | Stashes |
| `<leader>guB` | Blame the current file |
| `<leader>gu<space>` | Command palette |

### In any file buffer

| Key | Action |
| --- | --- |
| `]c` / `[c` | Next / previous hunk — falls through to Neovim's own diff motions inside a diff |
| `<leader>guS` | Stage the hunk (or, in visual mode, the selected lines) |
| `<leader>guU` | Unstage the hunk |
| `<leader>guX` | Discard the hunk (or the selected lines) |
| `<leader>guv` | Preview the hunk |
| `<leader>guL` | Blame the current line |

### Source Control panel

| Key | Action |
| --- | --- |
| *(cursor)* | Selecting a file shows its diff automatically |
| `<CR>` | Open the file for editing / expand the row |
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

`q` closes whichever picked pane you are in, including the sidebar. Dismissing a
diff hands your editor window back with the buffer that was in it — picked
borrows the window, it does not take it. Closing the sidebar closes the
side-by-side split too: the diff belongs to the list that opened it.

Previews are not debounced. `preview_delay` is 0, so the diff is requested on
the cursor move itself; answers you have already scrolled past are thrown away
as they arrive. Set it to a number of milliseconds if you would rather trade
that responsiveness for fewer git calls.

Opening a file with `<CR>` takes that window back from the diff, so the two
never pile up: you get the sidebar and one editor window, showing whichever of
the file or its diff you last asked for.

Floating views get out of the way on their own. Opening a diff, a file or a
commit from the history dismisses the float that launched it, so the thing you
asked for is never hidden underneath it, and only one picked float is ever on
screen at a time.

Visual mode works in the panel: select several rows and press `s`, `u` or `x`.

### Diff view

| Key | Action |
| --- | --- |
| `s` / `u` / `x` | Stage / unstage / discard the hunk |
| `s` / `x` *(visual)* | Stage / discard exactly the selected lines |
| `]c` / `[c` | Next / previous hunk |
| `]f` / `[f` | Next / previous file |
| `<Tab>` | Switch what is compared (HEAD↔index / index↔worktree) |
| `<C-v>` | Switch presentation (unified patch ↔ side-by-side) |
| `<CR>` | Open the real file at this line |

### Commit editor

| Key | Action |
| --- | --- |
| `<C-g>` | Suggest an editable message with GitHub Copilot CLI |
| `<C-s>` / `:w` | Commit |
| `<C-p>` | Commit and push |
| `<C-a>` | Toggle amend |
| `<C-c>` / `<Esc>` | Cancel and keep the message as a draft |

In the side-by-side view `]c` / `[c` are Neovim's own diff motions, so folding
and `do` / `dp` work too. picked installs no mappings on your real file buffer
there — `:PickedDiffView` returns to the unified patch from either pane.

### Unified or side-by-side

Three ways to choose, depending on how permanent you want it:

```vim
<C-v>              " toggle the diff you are looking at, either direction
:PickedDiffView    " same, and works from the split's real-file pane
:PickedDiff!       " open straight into side-by-side
```

```lua
require("picked").setup({
  diff = {
    view = "unified",        -- "unified" | "split" — what a diff opens as
    layout = "vertical",     -- "vertical" | "horizontal" — how it is arranged
    split_full_width = true, -- give the split the whole editor area
  },
})
```

The two sides each get **half the width left after the sidebar**, and stay that
way as windows come and go. `split_full_width` is what makes that possible: it
closes other ordinary file windows first, because otherwise the panes compete
with them and end up a third of the screen each — too narrow to read a diff in.
Only windows close; buffers stay loaded with any unsaved changes. Set it to
`false` to keep every window and let Neovim divide the space.

`view = "split"` applies to previews too, so moving down the file list shows
each change side by side. The cursor stays in the list while you browse;
`<CR>` moves it into the diff, and `q` in either pane closes the split and
returns the cursor to the file you were on. Both presentations support `]c` /
`[c`; only the unified one can stage, because hunk and line staging need a
patch.

`'winwidth'` would otherwise fight this — it widens the focused window at its
neighbours' expense, stretching the sidebar and crushing one pane — so picked
lowers it to fit while it holds those windows and hands your value back
afterwards.

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
| `:Picked`, `:PickedToggle` | Toggle the Source Control panel |
| `:PickedOpen`, `:PickedFocus`, `:PickedClose` | Open / focus / close |
| `:PickedRefresh[!]` | Re-read state (`!` refreshes every repository) |
| `:PickedDiff [all\|staged][!]` | Diff (`!` uses the side-by-side view) |
| `:PickedDiffView` | Toggle unified ↔ side-by-side |
| `:PickedCommit[!] [message]` | Commit (`!` amends) |
| `:PickedCommitSuggest` | Suggest a message with GitHub Copilot CLI |
| `:PickedPush[!]` | Push (`!` force-pushes with lease) |
| `:PickedPull`, `:PickedFetch[!]` | Pull / fetch (`!` fetches all remotes) |
| `:PickedLog[!]`, `:PickedBranch`, `:PickedStash` | History / branches / stashes |
| `:PickedBlame`, `:PickedBlameLine` | Blame the file / toggle line blame |
| `:[range]PickedHistory` | File history, or line history for a range |
| `:PickedStage`, `:PickedUnstage` | Stage / unstage paths |
| `:[range]PickedStageHunk`, `:PickedUnstageHunk`, `:[range]PickedDiscardHunk` | Hunk actions |
| `:PickedNextHunk`, `:PickedPrevHunk`, `:PickedPreviewHunk` | Hunk navigation |
| `:PickedConflict[!]` | Next conflict (`!` opens the three-way view) |
| `:PickedPalette`, `:PickedRepositories` | Palette / repository picker |
| `:PickedOutput`, `:PickedDebugLog`, `:PickedHealth` | Diagnostics |

---

## Configuration

Every value below is a default; pass only what you want to change.

```lua
require("picked").setup({
  position = "left",          -- "left" | "right" | "float"
  width = 42,
  compact_width = 34,         -- below this, the panel drops decorations

  -- What the sidebar does when it would be the only window left:
  --   "keep_width"  hold its width, parking an empty window beside it
  --   "expand"      let Neovim stretch it (its default behaviour)
  --   "close"       close the panel too
  last_window = "keep_width",

  prefix = "<leader>gu",      -- every global mapping lives under this

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
    -- What selecting a file in the panel does:
    --   "auto"   open its diff in the editor area (VS Code behaviour)
    --   "follow" only retarget a diff that is already open
    --   false    nothing; `d` opens the diff on demand
    preview = "auto",
    preview_delay = 0,
    view = "unified",         -- "unified" | "split"; <C-v> toggles
    layout = "vertical",      -- orientation of the split view
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
    sync_cursor = true,       -- code and blame move together, both directions
    highlight_block = true,   -- light up the commit's lines in both panes
    color_commits = true,     -- a colour per commit in the blame column
  },

  log = { page_size = 256, graph = true },

  commit = {
    subject_length = 72,      -- 0 disables the warning
    body_length = 0,
    show_diff = true,
    sign = nil,               -- nil inherits git's commit.gpgsign
    copilot = true,           -- optional Copilot CLI message suggestions
    copilot_max_diff = 100000,
    copilot_timeout = 120000,
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
  global_keymaps = { --[[ `<prefix>` expands to `prefix`; see :help picked-keymaps ]] },
  keymaps = { --[[ per-view; see :help picked-keymaps ]] },
})
```

### Rebinding

Per-view mappings live under `keymaps.<view>`. A value may be a string, a list
of strings, or `false` to disable the action.

```lua
require("picked").setup({
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

picked **never overwrites a mapping you already have.** A default global mapping
whose key is taken is silently skipped; `:checkhealth picked` lists them.

---

## Integrations

All optional, all detected at runtime.

**Statusline** — no plugin dependency:

```lua
-- lualine
sections = { lualine_b = { require("picked.integrations").lualine() } }

-- anything else
require("picked").statusline()      -- " feature/cart ↑2 ~3 +1"
require("picked").get_status()      -- structured table
require("picked").buffer_status()   -- { added, changed, removed } for a buffer
```

These read only from the store and never run git, so calling them on every
redraw is free. The branch name is available immediately; the counts arrive
with the first `git status`. While that is in flight `busy` is true and the
counts are zero, which is how you tell "still reading" from "nothing changed".

**Telescope**:

```lua
require("telescope").load_extension("picked")
-- :Telescope picked branches | commits | status | stashes
```

**Snacks / fzf-lua** — if either is installed, picked's pickers route through it
automatically. Otherwise the built-in fuzzy picker is used.

**which-key** — prefix group names are registered when which-key is present.

**GitHub Copilot CLI** — when the `copilot` executable is installed and
authenticated, press `<C-g>` in the commit editor (or run
`:PickedCommitSuggest`) to generate a message from the staged diff. The result
is inserted for review and is never committed automatically. picked denies the
Copilot process shell, file, and web tools; it can only return text. Disable the
action with `commit = { copilot = false }`.

### Events

```lua
require("picked").on("PushFinished", function(data)
  print(data.ok and "pushed" or "push failed")
end)
```

Also published as `User Picked<Name>` autocommands. Names: `Ready`,
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

**`:checkhealth picked`** first — it covers the common causes.

| Symptom | Cause |
| --- | --- |
| Boxes instead of icons | Set `icons = false`, or `vim.g.have_nerd_font = false` |
| "Authentication required" on push | Terminal prompts are disabled inside Neovim by design. Use a credential helper, an SSH agent, or an SSH remote. |
| A default mapping does nothing | Something else already owns that key; picked never overwrites. `:checkhealth picked` lists the skips — change `prefix` to move the whole set. |
| The sidebar goes full width | It was briefly the only window. `last_window = "keep_width"` (the default) parks an empty window beside it; `"close"` closes the panel instead. |
| `<C-s>` does not commit | Your terminal is eating it for flow control. Use `:w`. |
| Panel is empty | The buffer may be outside the repository. `:PickedRefresh` |
| Slow on a huge repository | Raise `refresh_debounce`, or set `auto_refresh = false` |

`:PickedOutput` shows the raw output of recent git commands — nothing is ever
swallowed. `:PickedDebugLog` shows picked's own log; raise `log_level` to
`"debug"` for more.

---

## FAQ

**Does this replace gitsigns / fugitive / diffview / neogit?**
It covers what they cover, in one plugin, with one configuration. If you like
your current setup, keep it — set `signs.enabled = false` to run picked
alongside gitsigns, for example.

**Why is there no `git rebase -i` todo editor?**
Interactive rebase is started here and driven by continue/skip/abort, but the
todo list is not yet editable inside picked. See *Known limitations*.

**Does it work over SSH / in a plain terminal?**
Yes. ASCII fallback, no image protocols, no font requirements.

**Can I use it without any keybindings?**
`default_keymaps = false`, then use the commands or the palette.

---

## Known limitations

These are genuinely not implemented, rather than partially implemented:

- **Interactive rebase todo editing.** `git rebase -i` runs and can be
  continued, skipped or aborted, but reordering or squashing commits from a
  todo list inside picked is not supported.
- **Submodules are detected, not managed.** They are shown and identified;
  picked never updates, initialises or commits inside one.
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
./scripts/fmt.sh               # format
./scripts/fmt.sh --check       # exactly what CI checks
```

`fmt.sh` uses a `stylua` already on your PATH, and otherwise fetches one into
`.tests/` rather than installing anything system wide.

Tests create real temporary repositories and run real git. If you touch a
parser, add a case to the relevant `*_spec.lua` with the exact bytes git
produces.

---

## License

MIT
