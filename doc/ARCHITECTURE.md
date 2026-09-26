# Architecture

This document explains how gitui.nvim is put together and, more usefully, *why*
the non-obvious decisions were made. It is aimed at someone about to change the
code.

## Layers

```
┌──────────────────────────────────────────────────────────────┐
│ ui/            panels, rendering, keymaps, mouse             │
│                knows about windows; never constructs a git   │
│                argument and never writes to the repository   │
├──────────────────────────────────────────────────────────────┤
│ operations.lua confirmation, progress, error reporting,      │
│                invalidate-then-refresh                       │
├──────────────────────────────────────────────────────────────┤
│ state/         one store per repository, generation-tracked  │
│                knows nothing about colours or windows        │
├──────────────────────────────────────────────────────────────┤
│ git/           process execution and parsing                 │
│                knows nothing about Neovim's UI at all        │
└──────────────────────────────────────────────────────────────┘
```

The direction of dependency is strictly downward. `git/` never requires
anything from `ui/`. `state/` never requires anything from `ui/`. A UI
component that needs to change the repository calls `operations`, never
`git.*` directly — that is what guarantees confirmation and refresh cannot be
forgotten at a call site.

### Module map

| Path | Responsibility |
| --- | --- |
| `git/command.lua` | **The only module that spawns a process.** argv arrays, environment, timeouts, serialisation, error classification |
| `git/repository.lua` | Discovery, worktrees, submodules, HEAD, sequencer state |
| `git/status.lua` | `--porcelain=v2 -z` parsing |
| `git/diff.lua` | Diff specs → git arguments → `GitFileDiff` |
| `git/hunks.lua` | Hunk model, patch construction, partial selection |
| `git/staging.lua` | stage / unstage / discard, `git apply` |
| `git/branches.lua` `commits.lua` `remotes.lua` `stash.lua` `blame.lua` `conflicts.lua` | One git domain each |
| `git/browse.lua` | Remote URL → web URL |
| `git/graph.lua` | Commit graph lane assignment |
| `state/init.lua` | The store: repositories, generations, UI state |
| `state/refresh.lua` | Refresh orchestration, debouncing, file watching |
| `operations.lua` | Every user-initiated mutation |
| `ui/panel.lua` | Base class: buffer lifecycle, keymaps, cursor, teardown |
| `ui/render.lua` | Canvas: rows, segments, extmarks, row metadata |
| `ui/*.lua` | One view each |

## The three load-bearing rules

### 1. One process spawner, argv arrays only

Every git invocation goes through `git/command.lua`. Arguments are a Lua list
handed to `vim.system`; there is no shell, no string interpolation and
therefore no injection surface. A branch named `; rm -rf /` is just a branch
name.

The child environment is rebuilt from `vim.uv.os_environ()` with the git
variables stripped:

```lua
GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY
GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_PREFIX GIT_CONFIG GIT_CONFIG_PARAMETERS
```

This matters in a specific, real scenario: when Neovim is launched *by* git as
its editor (`git commit` with `core.editor=nvim`), those variables are set and
point at the repository git is currently operating on. Inheriting them would
silently redirect gitui's operations to a different index than the one it
resolved.

Three more environment settings prevent hangs rather than bugs:

```lua
GIT_TERMINAL_PROMPT = "0"   -- a credential prompt becomes an error, not a hang
GIT_EDITOR          = "true" -- `rebase --continue` cannot open an editor
GIT_SEQUENCE_EDITOR = "true"
```

Without the first, a push to a remote needing credentials waits forever on a
terminal that is not attached to anything.

### 2. Machine-readable formats only

| Data | Format | Why |
| --- | --- | --- |
| status | `--porcelain=v2 -z` | The only format git documents as stable. `-z` removes all quoting ambiguity |
| refs | `for-each-ref --format=…%00…` | Fields separated by NUL, which no refname or subject can contain |
| log | `log -z --format=…%x1f…` | NUL between commits, unit separator between fields, so a body with blank lines parses |
| blame | `blame --porcelain` | Commit metadata once per commit, not once per line |
| config | `config -z --get-regexp` | URLs may contain spaces |
| diff | unified, with forced `a/`/`b/` prefixes | `diff.noprefix` and `diff.mnemonicPrefix` would otherwise break parsing |

Two flags on every diff are easy to overlook and important: `--no-ext-diff`
and `--no-textconv`. Without them, a user's configured external difftool or
textconv filter replaces the content we are about to parse.

**`text = false` on every `vim.system` call.** Neovim's `text = true` rewrites
CRLF to LF. git always emits LF for its own output, so the option can only ever
corrupt payload bytes: the contents of a CRLF file from `git show`, or the
carriage returns inside a diff of one. This was caught by a test that stages a
hunk in a CRLF file and asserts the index content is byte-identical.

### 3. The newest observation wins

Every repository in the store carries a `generation` counter.

```
read starts        token = 3
user stages        generation → 4          (operations.mutate, before git runs)
read completes     store.update(root, …, token = 3)  →  dropped
refresh completes  store.update(root, …, token = 4)  →  applied
```

`operations.mutate` is the single place this is enforced:

```lua
store.invalidate(repo.root)   -- bump BEFORE the mutation
run(function(ok, err)
  ...
  refresh.after_mutation(repo, label)   -- bump again, then re-read
end)
```

Bumping *before* the git command matters: a status query that started while the
old state was true must not be applied afterwards, even if it finishes later.

Concurrent refreshes at the *same* generation are coalesced rather than
cancelled — a second `git status` started a millisecond after the first would
produce an identical answer, so the caller simply waits on the running one.
This also avoids reporting "cancelled" to a caller that did nothing wrong.

## Patch construction

Line-level staging is where correctness is hardest, so the rules are explicit.

### Where hunks come from

Two sources, one representation:

- `git diff` output, parsed by `hunks.parse`.
- `vim.diff(index_text, buffer_text, { result_type = "unified", ctxlen = 3 })`,
  parsed by the same function. This is what makes the sign column cost one
  in-process diff per keystroke instead of a subprocess.

Context lines are deliberately retained rather than using `--unidiff-zero`.
Context is what makes `git apply` *verify* it is patching the content we think
it is, so a stale patch produces a clean refusal rather than a corrupted file.
`staging_spec.lua` asserts exactly this.

### Partial selection

`hunks.select_body(hunk, selected)` rebuilds a hunk from a set of selected body
lines:

| Line | Selected | Result |
| --- | --- | --- |
| context | — | kept as context |
| `+` | yes | kept as `+` |
| `+` | no | **dropped** — it must not reach the target |
| `-` | yes | kept as `-` |
| `-` | no | **becomes context** — it must survive in the target |

A `\ No newline at end of file` marker travels with the line it belongs to.

The header is then recomputed from the body, never inherited. `hunks.to_patch`
recomputes `new_start` for each included hunk by accumulating the line delta of
the hunks before it, so taking hunk 3 alone still produces internally
consistent offsets.

### Mapping a buffer selection to patch lines

`hunks.body_indices_for_range(hunk, first, last)`:

- an addition is selected when its own new-side line number is in range;
- a deletion is selected when the line that now occupies its position is in
  range.

The second rule is the non-obvious one. In a change hunk git emits all `-`
lines before all `+` lines, so every deletion in the block shares one anchor:
the first new-side line of the replacement. Selecting that line takes the whole
replacement, which is what the gutter sign implies. This is documented at
`:help gitui-line-staging` because it is user-visible behaviour.

### Path quoting

`hunks.quote_path` mirrors git's `quote_c_style` exactly: a name is quoted only
when it contains a double quote, a backslash or a control character — notably
**not** for spaces. Matching git's behaviour precisely is what keeps generated
patches interchangeable with git's own, and `git apply` parses both forms
identically.

### Direction

| Operation | Hunk source | git invocation |
| --- | --- | --- |
| stage | index → worktree | `git apply --cached` |
| unstage | HEAD → index | `git apply --cached -R` |
| discard | index → worktree | `git apply -R` |

The diff view refuses a staging action that does not match the comparison on
screen and says which one does — staging from a HEAD↔index view is a category
error, not a silent no-op.

## Concurrency and locking

Mutating commands (`serialize = true`) are queued per repository so two of them
cannot race for `index.lock`. Read-only commands are not queued — a status
refresh must not wait behind a two-minute fetch.

Read-only commands instead pass `--no-optional-locks`. This was not a
theoretical concern: without it, gitui's background `git status` refreshes the
index stat cache, takes the index lock, and makes a concurrent `git stash` or
`git commit` fail with *"could not write index"*. The flag exists precisely for
tools that poll status alongside other git processes. The cost is that our
polling no longer refreshes the stat cache.

As a second line of defence, a command that fails with any lock-contention
message is retried up to three times with a short backoff, because the
contending process is usually the user's own terminal holding the lock for
milliseconds.

## Rendering

`ui/render.lua` builds a **canvas**: a list of rows, each a list of highlighted
segments, each carrying arbitrary metadata.

```lua
canvas:row(item)
  :add("M ", "GitUIModified", "open")   -- text, highlight, click action
  :add("src/api/users.lua")
  :right(" ← old.lua ", "GitUIDim")
```

Attaching metadata per row is what makes the whole UI uniform: a keymap asks
"what is under the cursor?", the mouse handler asks "what is under this cell?",
and both get the same plain Lua table back. No view parses its own rendered
text to work out what the user selected.

Applying a canvas clears the namespace, writes the lines with `modifiable`
flipped on for the duration of the write only, and sets one extmark per
highlighted segment. Buffers are never left modifiable, so a stray keystroke
cannot edit a panel.

### Redraw and the cursor

`Panel:redraw` remembers what the cursor was pointing *at*, not where it was.
After staging a file the row moves from CHANGES to STAGED CHANGES; following
the item is what a user expects, and following the line number is not.

### Responsive layout

Every render receives the panel's current width. Narrow panels drop
right-aligned metadata, switch the tree to a flat list, and omit the diff
line-number gutter. `VimResized` and `WinResized` trigger a redraw, so the
layout actually responds rather than being decided once at open time.

## Panel lifecycle

`ui/panel.lua` exists because buffer lifecycle is the thing that is easy to get
subtly wrong in eight separate places. It owns:

- buffer creation with the right options (`nofile`, unlisted, non-modifiable),
- keymap installation resolved from `config.keymaps[group]` with a fallback to
  `config.keymaps.common`,
- mouse dispatch,
- an augroup per panel, deleted on destroy,
- `on_destroy` hooks, used by every view to unsubscribe from the event bus.

`views_spec.lua` asserts that after `gitui.reset()` no buffer named
`gitui://…` survives.

## Mouse model

Deliberately conservative, because a sidebar that opens files on every stray
click is worse than one with no mouse support:

- single click on a **control** (a chevron, a `[+]` button) runs that control;
- single click anywhere else only moves the cursor;
- double click runs the row's primary action;
- right click opens the contextual menu.

Controls are declared by giving a segment an action name that matches a key in
the panel's `actions` table, so a mouse target can never drift out of sync with
its keyboard equivalent.

## Errors

`command.classify` turns a failed `GitResult` into a structured error that
answers three questions:

```lua
{
  kind   = "non_fast_forward",
  title  = "Push rejected",
  reason = "The remote branch contains commits that are not present locally.",
  hint   = "Pull (or rebase) first, then push again.",
  raw    = "<complete git output>",
}
```

`raw` is never discarded. It goes to `ui/output.lua`, and every error
notification says how to reach it. An unrecognised failure falls back to git's
own first line rather than inventing a message — and the classifier patterns
are matched case-insensitively against untranslated output, so a localised git
falls through to that generic case rather than being misclassified.

## Testing

```bash
./scripts/test.sh              # everything
./scripts/test.sh status_spec  # one file
```

| Spec | Covers |
| --- | --- |
| `status_spec` | porcelain v2 parsing, including awkward filenames |
| `hunks_spec` | parsing, recounting, partial selection, patch assembly |
| `staging_spec` | round-trips against real repositories: hunk, line, CRLF, no-EOL, quoted names, new files, stale patches |
| `parsers_spec` | branches, commits, remotes, stash, conflicts, blame, browse, graph |
| `ui_spec` | the panel: rendering, real keymaps, signs |
| `views_spec` | diff view, commit editor, log, branches, stash, help, confirmation, concurrency, lifecycle |
| `workflow_spec` | the complete acceptance loop against a real remote |

Fixtures in `tests/helpers/repo.lua` build real repositories with real git —
never through the plugin, so a bug in the command layer cannot make a fixture
silently wrong. `kitchen_sink()` covers every status code plus spaces, quotes,
Unicode, renames, nested directories and a binary file.

Parser tests feed exact byte sequences. If you change a parser, add the bytes
git actually produced, not a paraphrase of them.

## Adding a view

1. Define the data in `git/` — parsing only, no UI knowledge.
2. Add operations to `operations.lua` if it mutates anything.
3. Create `ui/<name>.lua` using `panel_lib.new`:

```lua
panel = panel_lib.new({
  name = "thing",
  layout = "float",          -- sidebar | float | split | editor | tab
  keymap_group = "thing",    -- section of config.keymaps
  title = function() … end,
  render = function(self, canvas) … end,
  actions = { open = …, refresh = … },
  hints = { { key = "open", label = "open" } },
  context_menu = function(self, item) … end,
})
```

4. Add the action names and a section to `ui/help.lua` so the generated help
   stays complete.
5. Add defaults to `config.keymaps.thing`.
6. Add a spec.

The help window is generated from the *configured* mappings, so forgetting
step 4 is visible immediately: the action exists but is undocumented.
