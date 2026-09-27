---@brief The diff viewer.
---
---Two complementary presentations, because they serve different jobs:
---
---  * a unified patch view, which is where staging happens. Every row knows
---    which hunk and which patch-body line it came from, so `s` on a line and
---    `s` over a visual selection both produce an exact patch.
---  * a side-by-side view built on Neovim's own diff mode, which is where
---    reading happens. It is real `:diffthis`, so folding, `]c`, `do`/`dp`
---    and the user's diff options all behave normally.
---
---The comparison is always stated in the window title. There is no such thing
---as "the diff" here: the view names both sides.

local config = require("picked.config")
local diff_api = require("picked.git.diff")
local hunks_api = require("picked.git.hunks")
local icons = require("picked.utils.icons")
local notify = require("picked.ui.notify")
local operations = require("picked.operations")
local panel_lib = require("picked.ui.panel")
local path_util = require("picked.utils.path")
local store = require("picked.state")
local text_util = require("picked.utils.text")
local window = require("picked.ui.window")
local winsize = require("picked.ui.winsize")

local M = {}

---@class PickedDiffViewState
---@field repo GitRepository
---@field spec GitDiffSpec
---@field path string|nil  nil means "every changed file"
---@field diffs GitFileDiff[]
---@field loading boolean
---@field error GitError|nil
---@field entry GitFileEntry|nil

---@class PickedDiffItem
---@field id string
---@field kind "file"|"hunk"|"line"|"info"|"binary"
---@field diff GitFileDiff|nil
---@field hunk GitHunk|nil
---@field body_index integer|nil
---@field line_kind string|nil
---@field old_ln integer|nil
---@field new_ln integer|nil

---@type PickedPanel|nil
local panel = nil

---@type PickedDiffViewState|nil
local current = nil

--- Direction ------------------------------------------------------------------

---What staging actions mean for a given comparison.
---
---`worktree` diffs the index against the working tree, so its hunks can be
---staged or discarded. `index` diffs HEAD against the index, so its hunks can
---only be unstaged. Everything else is history and is read-only.
---@param spec GitDiffSpec
---@return { stage: boolean, unstage: boolean, discard: boolean, label: string }
local function capabilities(spec)
  if spec.kind == "worktree" then
    return { stage = true, unstage = false, discard = true, label = "unstaged changes" }
  end
  if spec.kind == "index" then
    return { stage = false, unstage = true, discard = false, label = "staged changes" }
  end
  return { stage = false, unstage = false, discard = false, label = "read-only" }
end

--- Rendering -------------------------------------------------------------------

---@param canvas PickedCanvas
---@param diff GitFileDiff
---@param width integer
local function render_file_header(canvas, diff, width)
  local row = canvas:row({ id = "file:" .. diff.path, kind = "file", diff = diff })
  row:add(icons.get("file") ~= "" and (icons.get("file") .. " ") or "")
  row:add(diff.path, "PickedDiffFileName", "open")
  if diff.old_path and diff.old_path ~= diff.path then
    row:add("  ← " .. diff.old_path, "PickedDim")
  end

  local added, removed = 0, 0
  for _, hunk in ipairs(diff.hunks) do
    local a, r = hunks_api.counts(hunk)
    added, removed = added + a, removed + r
  end
  if width > 50 then
    row:right((" +%d −%d "):format(added, removed), "PickedDim")
  end
end

---@param canvas PickedCanvas
---@param diff GitFileDiff
---@param opts { width: integer, show_numbers: boolean }
local function render_diff(canvas, diff, opts)
  if diff.binary then
    canvas
      :row({ id = "bin:" .. diff.path, kind = "binary", diff = diff })
      :add("  Binary file — no textual diff", "PickedDim")
    return
  end

  if #diff.hunks == 0 then
    local message = diff.mode_change and "  Mode change only" or "  No changes"
    canvas:row({ id = "empty:" .. diff.path, kind = "info", diff = diff }):add(message, "PickedDim")
    return
  end

  local highlights = require("picked.ui.highlights")
  -- Line-number gutters make a unified diff far easier to correlate with the
  -- file, but they cost columns; `show_numbers` drops them on narrow windows.
  local rows = hunks_api.to_display(diff.hunks)

  for _, display in ipairs(rows) do
    ---@type PickedDiffItem
    local item = {
      id = ("%s:%d:%s"):format(diff.path, display.hunk.index, tostring(display.body_index or "h")),
      kind = display.kind == "header" and "hunk" or "line",
      diff = diff,
      hunk = display.hunk,
      body_index = display.body_index,
      line_kind = display.kind,
      old_ln = display.old_ln,
      new_ln = display.new_ln,
    }

    if display.kind == "header" then
      -- A blank line before each hunk header separates hunks visually without
      -- needing a rule.
      canvas:blank()
      canvas:row(item):add(display.text, "PickedDiffHunkHeader", "stage_hunk")
    else
      local row = canvas:row(item)
      if opts.show_numbers then
        local old_text = display.old_ln and tostring(display.old_ln) or ""
        local new_text = display.new_ln and tostring(display.new_ln) or ""
        row:add(text_util.lpad(old_text, 5) .. " ", "PickedDiffLineNr")
        row:add(text_util.lpad(new_text, 4) .. " ", "PickedDiffLineNr")
      end
      row:add(display.text, highlights.for_diff(display.kind), "stage_hunk")
      -- Extend the highlight across the rest of the line so added and removed
      -- rows read as blocks rather than ragged text.
      local padding = opts.width - row:width()
      if padding > 0 and (display.kind == "add" or display.kind == "delete") then
        row:add(string.rep(" ", padding), highlights.for_diff(display.kind))
      end
    end
  end
end

---@param self PickedPanel
---@param canvas PickedCanvas
local function render_panel(self, canvas)
  local width = self:width()

  if not current then
    canvas:text("  No diff loaded", "PickedDim")
    return
  end

  local caps = capabilities(current.spec)
  local header = canvas:row({ id = "header", kind = "info" })
  header:add("  ")
  header:add(diff_api.describe(current.spec), "PickedTitle")
  header:add("   ")
  header:add(caps.label, "PickedDim")
  canvas:blank()

  if current.loading then
    canvas:text("  Loading diff…", "PickedDim")
    return
  end

  if current.error then
    canvas:text("  " .. current.error.title, "PickedError")
    canvas:text("  " .. (current.error.reason or ""), "PickedDim")
    if current.error.hint then
      canvas:text("  " .. current.error.hint, "PickedDim")
    end
    return
  end

  if #current.diffs == 0 then
    canvas:text("  No differences", "PickedDim")
    return
  end

  local show_numbers = width >= 70
  for index, diff in ipairs(current.diffs) do
    if index > 1 then
      canvas:blank()
      canvas:rule()
    end
    render_file_header(canvas, diff, width)
    render_diff(canvas, diff, { width = width, show_numbers = show_numbers })
  end

  self:render_hints(canvas)
end

--- Hunk selection ---------------------------------------------------------------

---The hunk under the cursor.
---@param item PickedDiffItem|nil
---@return GitFileDiff|nil, GitHunk|nil
local function hunk_at(item)
  if not item or not item.diff or not item.hunk then
    return nil, nil
  end
  return item.diff, item.hunk
end

---Options describing the file, so a patch for a new or renamed file is built
---with the right headers.
---@param diff GitFileDiff
---@return GitPartialOpts
local function patch_opts(diff)
  local entry = current and current.entry
  local is_new = entry and (entry.untracked or entry.index_status == "A") or false
  -- A diff produced against an untracked file has no index side at all.
  return {
    old_path = diff.old_path,
    new_file = diff.raw:find("new file mode", 1, true) ~= nil or (is_new and current.spec.kind == "worktree"),
    context = config.options.diff.context,
  }
end

---Build a partial hunk from a visual selection over patch-body rows.
---@param panel_instance PickedPanel
---@param first integer
---@param last integer
---@return GitFileDiff|nil, GitHunk[]|nil
local function selection_to_hunks(panel_instance, first, last)
  local by_hunk = {}
  local order = {}
  local diff = nil

  for lnum = first, last do
    local item = panel_instance.canvas and panel_instance.canvas:item_at(lnum)
    ---@cast item PickedDiffItem|nil
    if item and item.kind == "line" and item.hunk and item.body_index then
      if diff and item.diff ~= diff then
        -- Refusing is better than silently staging part of another file.
        notify.warn("Select lines within a single file")
        return nil, nil
      end
      diff = item.diff
      local key = item.hunk
      if not by_hunk[key] then
        by_hunk[key] = {}
        order[#order + 1] = key
      end
      by_hunk[key][item.body_index] = true
    end
  end

  if not diff or #order == 0 then
    return nil, nil
  end

  local hunks = {}
  for _, hunk in ipairs(order) do
    local partial = hunks_api.select_body(hunk, by_hunk[hunk])
    if partial then
      hunks[#hunks + 1] = partial
    end
  end

  if #hunks == 0 then
    return nil, nil
  end
  return diff, hunks
end

--- Actions -----------------------------------------------------------------------

---@type table<string, fun(panel: PickedPanel, item: PickedDiffItem|nil)>
local actions = {}

---@param diff GitFileDiff
---@param hunks GitHunk[]
---@param mode "stage"|"unstage"|"discard"
local function apply_hunks(diff, hunks, mode)
  if not current then
    return
  end
  local caps = capabilities(current.spec)

  if mode == "stage" and not caps.stage then
    return notify.warn(
      current.spec.kind == "index" and "These changes are already staged — use unstage (u)"
        or "This view is read-only"
    )
  end
  if mode == "unstage" and not caps.unstage then
    return notify.warn(
      current.spec.kind == "worktree" and "These changes are not staged — use stage (s)" or "This view is read-only"
    )
  end
  if mode == "discard" and not caps.discard then
    return notify.warn("This view is read-only")
  end

  local opts = patch_opts(diff)
  if mode == "stage" then
    operations.stage_hunks(current.repo, diff.path, hunks, opts)
  elseif mode == "unstage" then
    operations.unstage_hunks(current.repo, diff.path, hunks, opts)
  else
    operations.discard_hunks(current.repo, diff.path, hunks, opts)
  end
end

actions.stage_hunk = function(_, item)
  local diff, hunk = hunk_at(item)
  if not diff or not hunk then
    return notify.warn("Put the cursor inside a hunk")
  end
  apply_hunks(diff, { hunk }, "stage")
end

actions.unstage_hunk = function(_, item)
  local diff, hunk = hunk_at(item)
  if not diff or not hunk then
    return notify.warn("Put the cursor inside a hunk")
  end
  apply_hunks(diff, { hunk }, "unstage")
end

actions.discard_hunk = function(_, item)
  local diff, hunk = hunk_at(item)
  if not diff or not hunk then
    return notify.warn("Put the cursor inside a hunk")
  end
  apply_hunks(diff, { hunk }, "discard")
end

actions.next_hunk = function(panel_instance)
  local line = panel_instance:cursor_line()
  local target = panel_instance.canvas
    and panel_instance.canvas:find(function(item, lnum)
      return item.kind == "hunk" and lnum > line
    end)
  if target then
    panel_instance:set_cursor(target)
  else
    notify.info("No more hunks")
  end
end

actions.prev_hunk = function(panel_instance)
  if not panel_instance.canvas then
    return
  end
  local line = panel_instance:cursor_line()
  local best = nil
  for _, lnum in
    ipairs(panel_instance.canvas:find_all(function(item)
      return item.kind == "hunk"
    end))
  do
    if lnum < line then
      best = lnum
    end
  end
  if best then
    panel_instance:set_cursor(best)
  end
end

actions.next_file = function(panel_instance)
  local line = panel_instance:cursor_line()
  local target = panel_instance.canvas
    and panel_instance.canvas:find(function(item, lnum)
      return item.kind == "file" and lnum > line
    end)
  if target then
    panel_instance:set_cursor(target)
  end
end

actions.prev_file = function(panel_instance)
  if not panel_instance.canvas then
    return
  end
  local line = panel_instance:cursor_line()
  local best = nil
  for _, lnum in
    ipairs(panel_instance.canvas:find_all(function(item)
      return item.kind == "file"
    end))
  do
    if lnum < line then
      best = lnum
    end
  end
  if best then
    panel_instance:set_cursor(best)
  end
end

---Jump from a diff row to the corresponding place in the real file.
actions.open_file = function(panel_instance, item)
  if not current or not item or not item.diff then
    return
  end
  local lnum = item.new_ln or item.old_ln
  if not lnum and item.hunk then
    lnum = item.hunk.new_start
  end
  window.open_file(path_util.join(current.repo.root, item.diff.path), {
    lnum = lnum,
    exclude = { panel_instance.winid },
  })
end

actions.open = actions.open_file

---Switch between the staged and unstaged view of the same file, which is the
---answer to "this file is MM, what exactly is in each?".
actions.toggle_side = function()
  if not current then
    return
  end
  local next_kind = current.spec.kind == "worktree" and "index" or "worktree"
  M.open(current.repo, {
    path = current.path,
    spec = { kind = next_kind },
    entry = current.entry,
  })
end

actions.refresh = function()
  M.reload()
end

actions.toggle_view = function()
  M.toggle_view()
end

-- Kept as an alias so `:PickedDiff!` and the context menu keep working.
actions.split = actions.toggle_view

---@type table<string, fun(panel: PickedPanel, first: integer, last: integer)>
local visual_actions = {}

visual_actions.stage_lines = function(panel_instance, first, last)
  local diff, hunks = selection_to_hunks(panel_instance, first, last)
  if not diff or not hunks then
    return notify.warn("Select added or removed lines to stage")
  end
  apply_hunks(diff, hunks, "stage")
end

visual_actions.discard_lines = function(panel_instance, first, last)
  local diff, hunks = selection_to_hunks(panel_instance, first, last)
  if not diff or not hunks then
    return notify.warn("Select added or removed lines to discard")
  end
  apply_hunks(diff, hunks, "discard")
end

visual_actions.unstage_hunk = function(panel_instance, first, last)
  local diff, hunks = selection_to_hunks(panel_instance, first, last)
  if not diff or not hunks then
    return notify.warn("Select added or removed lines to unstage")
  end
  apply_hunks(diff, hunks, "unstage")
end

--- Panel ---------------------------------------------------------------------------

---@return PickedPanel
local function get_panel()
  if panel then
    return panel
  end

  panel = panel_lib.new({
    name = "diff",
    layout = "editor",
    keymap_group = "diff",
    title = function()
      if not current then
        return "DIFF"
      end
      return "DIFF — " .. (current.path or "all files")
    end,
    render = render_panel,
    actions = actions,
    visual_actions = visual_actions,
    hints = {
      { key = "stage_hunk", label = "stage hunk" },
      { key = "unstage_hunk", label = "unstage" },
      { key = "discard_hunk", label = "discard" },
      { key = "next_hunk", label = "next hunk" },
      { key = "toggle_view", label = "split view" },
      { key = "help", label = "help" },
    },
    context_menu = function(panel_instance, item)
      if not item or not item.diff then
        return {}
      end
      local caps = current and capabilities(current.spec) or { stage = false, unstage = false, discard = false }
      local entries = {}
      if caps.stage then
        entries[#entries + 1] = {
          label = "Stage hunk",
          key = panel_instance:keys_for("stage_hunk")[1],
          action = function()
            actions.stage_hunk(panel_instance, item)
          end,
        }
      end
      if caps.unstage then
        entries[#entries + 1] = {
          label = "Unstage hunk",
          key = panel_instance:keys_for("unstage_hunk")[1],
          action = function()
            actions.unstage_hunk(panel_instance, item)
          end,
        }
      end
      if caps.discard then
        entries[#entries + 1] = {
          label = "Discard hunk",
          key = panel_instance:keys_for("discard_hunk")[1],
          destructive = true,
          action = function()
            actions.discard_hunk(panel_instance, item)
          end,
        }
      end
      entries[#entries + 1] = { separator = true }
      entries[#entries + 1] = {
        label = "Open file here",
        key = panel_instance:keys_for("open_file")[1],
        action = function()
          actions.open_file(panel_instance, item)
        end,
      }
      entries[#entries + 1] = {
        label = "Side-by-side view",
        key = panel_instance:keys_for("toggle_view")[1],
        action = actions.toggle_view,
      }
      return entries
    end,
  })

  -- Keep the diff honest: after any staging operation the patch on screen is
  -- stale, so reload it from git rather than guessing what changed.
  local events = require("picked.utils.events")
  local unsubscribe = events.on(events.names.STATUS_CHANGED, function()
    if panel and panel:is_open() and current and not current.loading then
      vim.schedule(M.reload)
    end
  end)
  panel:on_destroy(unsubscribe)

  return panel
end

--- Loading ---------------------------------------------------------------------------

---@param instance PickedPanel
local function load(instance)
  if not current then
    return
  end

  current.loading = true
  current.error = nil
  instance:redraw()

  local spec = vim.deepcopy(current.spec)
  local repo = current.repo
  local requested_path = current.path

  local function finish(diffs, err)
    -- Discard a response that a newer request has already superseded.
    if not current or current.repo ~= repo or current.path ~= requested_path then
      return
    end
    current.loading = false
    current.diffs = diffs or {}
    current.error = err
    if instance:is_open() then
      instance:redraw()
    end
    store.clear_cache(repo.root, "diff")
  end

  if requested_path then
    diff_api.file(repo, requested_path, spec, nil, function(diff, err)
      finish(diff and { diff } or {}, err)
    end)
  else
    diff_api.files(repo, spec, nil, finish)
  end
end

---Reload the current comparison from git.
function M.reload()
  if not current or not panel then
    return
  end
  load(panel)
end

--- Public API -----------------------------------------------------------------------

---@class PickedDiffOpenOpts
---@field path string|nil  a single file, or nil for every changed file
---@field spec GitDiffSpec
---@field entry GitFileEntry|nil
---@field from_panel PickedPanel|nil
---@field focus boolean|nil
---@field view "unified"|"split"|nil  defaults to `config.diff.view`
---@field silent boolean|nil  suppress the summary notification

---Open a diff.
---
---Honours `config.diff.view`, falling back to the unified patch whenever the
---side-by-side form does not apply — it shows one file at a time, so a
---whole-tree diff has no split form.
---@param repo GitRepository
---@param opts PickedDiffOpenOpts
function M.open(repo, opts)
  -- The diff lands in the editor area, underneath anything floating.
  require("picked.ui.floats").close_all()

  local view = opts.view or config.options.diff.view
  if view == "split" and M.splittable(opts.spec, opts.path) then
    -- Only one presentation at a time; leaving the patch panel open behind the
    -- split would double the windows and confuse every subsequent toggle.
    if panel and panel:is_open() then
      panel:close()
    end
    current = {
      repo = repo,
      spec = opts.spec,
      path = opts.path,
      diffs = {},
      loading = false,
      entry = opts.entry,
    }
    -- `focus` travels with it: the unified view honours it via `panel:open`,
    -- and the split must do the same or previewing would yank the cursor out
    -- of the list the user is browsing.
    return M.open_side_by_side(repo, opts.path, opts.spec, { silent = opts.silent, focus = opts.focus })
  end

  if M.split_active() then
    M.close_side_by_side()
  end

  local instance = get_panel()

  current = {
    repo = repo,
    spec = opts.spec,
    path = opts.path,
    diffs = {},
    loading = true,
    error = nil,
    entry = opts.entry,
  }

  instance:open({ focus = opts.focus ~= false })
  load(instance)
end

---Show the diff for the entry under the panel's cursor.
---
---In "auto" mode this opens the diff view if it is not already open, which is
---what makes selecting a file in the panel show its added and removed lines
---the way VS Code does. Focus always stays where it was — the panel — so
---cursor movement never pulls the user out of the list they are browsing.
---
---In "follow" mode an already-open diff is retargeted but none is opened.
---@param repo GitRepository
---@param entry GitFileEntry
---@param side "index"|"worktree"|nil
function M.preview(repo, entry, side)
  local mode = config.options.diff.preview
  if mode == false then
    return
  end

  local kind = side == "index" and "index" or "worktree"

  -- When the split is the configured presentation there is no single buffer
  -- to retarget, so previewing another file rebuilds it.
  if M.split_active() then
    if current and current.path == entry.path and current.spec.kind == kind then
      return
    end
    current = { repo = repo, spec = { kind = kind }, path = entry.path, diffs = {}, entry = entry }
    return M.open_side_by_side(repo, entry.path, { kind = kind }, { silent = true, focus = false })
  end

  local is_open = panel ~= nil and panel:is_open()

  if not is_open then
    if mode ~= "auto" then
      return
    end
    -- Opening without focus: the panel keeps the cursor, the editor area
    -- shows the diff. Silent, because a preview fires on every cursor move
    -- and a notification per keystroke is noise, not feedback.
    return M.open(repo, {
      path = entry.path,
      spec = { kind = kind },
      entry = entry,
      focus = false,
      silent = true,
    })
  end

  if current and current.path == entry.path and current.spec.kind == kind then
    return
  end

  current = current or { repo = repo, diffs = {}, loading = true }
  current.repo = repo
  current.path = entry.path
  current.entry = entry
  current.spec = { kind = kind }
  load(panel)
end

---Step aside because something else wants the editor area.
---
---Pressing <CR> on a file means "take me to the file"; the preview has served
---its purpose. Without this the diff keeps its window and the file has to be
---given a third one, which then never goes away.
function M.dismiss_for_editor()
  if M.split_active() then
    M.close_side_by_side()
  end
  if panel and panel:is_open() then
    panel:close()
  end
end

---@return boolean
function M.is_open()
  return panel ~= nil and panel:is_open()
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

--- Side-by-side view --------------------------------------------------------------

---@type integer[]
local diff_buffers = {}

---Buffers that are not ours but carry our mappings for as long as the split
---is up: the right-hand side of a worktree diff is the user's real file.
---@type integer[]
local borrowed_maps = {}

---@type integer|nil
local split_augroup = nil

---The two panes, once they exist. Openness is judged from these rather than
---from `diff_buffers`, because a buffer outlives the window showing it: after
---a plain `:close` the scratch buffers are still around, and counting them
---reported a split that was no longer on screen.
---@type { left: integer, right: integer, left_buf: integer }|nil
local split_panes = nil

---True between the request for a split and its windows existing. The blobs are
---fetched asynchronously, so for a moment there are no panes to find; without
---this a preview firing in that gap would decide no split was open and put the
---unified view up instead.
local split_pending = false

---Every key `map_split_buffer` installs, so they can be taken off a buffer
---that was only ever lent to us.
---@return string[]
local function split_mapped_keys()
  local keys = config.options.keymaps.diff
  local all = { "q" }
  for _, lhs in ipairs({ keys.toggle_view, keys.toggle_side }) do
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      all[#all + 1] = key
    end
  end
  return all
end

---Close any side-by-side diff this module opened.
local function close_side_by_side()
  -- Drop the watcher first. Left alive, it sees the windows going away, finds
  -- no split, and tears down the *replacement* being built in its place.
  if split_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, split_augroup)
    split_augroup = nil
  end
  -- Give the user their own keys back before anything else: `q` is macro
  -- recording, and leaving it shadowed in a file buffer would outlast the
  -- diff entirely.
  for _, bufnr in ipairs(borrowed_maps) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, lhs in ipairs(split_mapped_keys()) do
        pcall(vim.keymap.del, "n", lhs, { buffer = bufnr })
      end
    end
  end
  borrowed_maps = {}

  for _, bufnr in ipairs(diff_buffers) do
    window.delete_buffer(bufnr)
  end
  diff_buffers = {}
  split_panes = nil
  split_pending = false
end

---@param repo GitRepository
---@param path string
---@param rev string
---@param label string
---@param callback fun(bufnr: integer|nil)
local function blob_buffer(repo, path, rev, label, callback)
  diff_api.blob(repo, rev, path, function(content, err)
    if err then
      notify.error(err)
      return callback(nil)
    end
    local bufnr = window.create_buffer({
      name = ("%s:%s"):format(label, path),
      filetype = "",
    })
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
    -- Inherit the real file's filetype so syntax highlighting works.
    vim.bo[bufnr].filetype = vim.filetype.match({ filename = path, buf = bufnr }) or ""
    diff_buffers[#diff_buffers + 1] = bufnr
    callback(bufnr)
  end)
end

---Close ordinary editor windows so the split has the area to itself.
---
---A diff read two columns at a time needs width. Competing with the file
---windows that happened to be open leaves each side a third of the screen,
---which is not enough to read.
---
---Only windows are closed, never buffers: with 'hidden' — Neovim's default —
---a closed window leaves its buffer loaded and its unsaved changes intact,
---and under 'nohidden' the `force = false` close simply refuses and the
---window stays. Floats and picked's own panels are never touched.
---@return integer|nil kept  the editor window that survived, if any
local function collapse_editor_area()
  local editors = {}
  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_config(winid).relative == "" then
      local filetype = vim.bo[vim.api.nvim_win_get_buf(winid)].filetype
      if not filetype:match("^picked") then
        editors[#editors + 1] = winid
      end
    end
  end

  for index = 2, #editors do
    pcall(vim.api.nvim_win_close, editors[index], false)
  end
  return editors[1]
end

---Give the two sides an equal share of whatever space they jointly occupy.
---
---`wincmd =` would divide the space between *every* window instead, which is
---how the panes ended up narrower than the file window beside them.
---@param first integer
---@param second integer
local function balance_split(first, second)
  if not (vim.api.nvim_win_is_valid(first) and vim.api.nvim_win_is_valid(second)) then
    return
  end
  local horizontal = config.options.diff.layout == "horizontal"
  local get = horizontal and vim.api.nvim_win_get_height or vim.api.nvim_win_get_width
  local set = horizontal and vim.api.nvim_win_set_height or vim.api.nvim_win_set_width

  local total = get(first) + get(second)
  local half = math.floor(total / 2)

  -- Claim before resizing: with 'winwidth' still in force the resize is undone
  -- the moment it is made, and the focused pane swallows the other one.
  winsize.claim("diff-split", horizontal and "winheight" or "winwidth", half)
  pcall(set, first, half)
end

---Which revisions the two sides of a split view show.
---@param spec GitDiffSpec
---@return string|nil left, string|nil right  nil right means "the file on disk"
local function split_revisions(spec)
  if spec.kind == "worktree" then
    return ":0", nil
  elseif spec.kind == "index" then
    return "HEAD", ":0"
  elseif spec.kind == "head" then
    return "HEAD", nil
  elseif spec.kind == "commit" and spec.from then
    return spec.from .. "^", spec.from
  elseif spec.from then
    return spec.from, spec.to
  end
  return nil, nil
end

---Can this comparison be shown side by side?
---@param spec GitDiffSpec
---@param path string|nil
---@return boolean
function M.splittable(spec, path)
  if not path then
    return false
  end
  local left = split_revisions(spec)
  return left ~= nil
end

---Buffer-local keys for the two windows of a split view.
---
---`]c`/`[c` are Neovim's own diff-mode motions and need no help. What the
---split view *does* need is a way back: without it, switching presentation is
---a one-way door.
---@param bufnr integer
---@param context { repo: GitRepository, path: string, spec: GitDiffSpec }
---@param borrowed boolean|nil  true when `bufnr` is the user's own file buffer
---       rather than one of picked's scratch sides. Those mappings shadow the
---       user's own keys — `q` is macro recording — so they are recorded and
---       removed again when the split closes.
local function map_split_buffer(bufnr, context, borrowed)
  local keys = config.options.keymaps.diff

  if borrowed then
    borrowed_maps[#borrowed_maps + 1] = bufnr
  end

  local function map(lhs, rhs, desc)
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", key, rhs, {
        buffer = bufnr,
        nowait = true,
        silent = true,
        desc = "picked: " .. desc,
      })
    end
  end

  map(keys.toggle_view, function()
    M.close_side_by_side()
    M.open(context.repo, { path = context.path, spec = context.spec, view = "unified" })
  end, "unified view")

  map(keys.toggle_side, function()
    local next_kind = context.spec.kind == "worktree" and "index" or "worktree"
    M.close_side_by_side()
    M.open(context.repo, { path = context.path, spec = { kind = next_kind }, view = "split" })
  end, "switch compared sides")

  map("q", function()
    M.close_side_by_side()
    -- Back to the list that opened it. Closing a preview should return the
    -- cursor to where the user was browsing, not leave it in whatever window
    -- happened to inherit the space.
    local sidebar = panel_lib.get("source_control")
    if sidebar and sidebar:is_open() then
      sidebar:focus()
    end
  end, "close the split view")
end

---Open a true side-by-side diff using Neovim's own diff mode.
---
---This is a reading view: `]c`, `[c`, folding and `do`/`dp` all work because
---it is genuinely `:diffthis`, not an imitation of it.
---@param repo GitRepository
---@param path string
---@param spec GitDiffSpec
---@param opts { silent: boolean|nil, focus: boolean|nil }|nil
---       silent suppresses the summary notification, which would otherwise
---       fire on every cursor move when the split is being used as the
---       preview. focus = false builds the split and leaves the cursor where
---       it was, which is what browsing a file list wants: the diff appears
---       beside the list without the list losing the cursor.
function M.open_side_by_side(repo, path, spec, opts)
  opts = opts or {}
  -- Captured before `collapse_editor_area`, which closes windows and would
  -- otherwise take the one we mean to go back to with it.
  local origin_win = vim.api.nvim_get_current_win()
  require("picked.ui.floats").close_all()
  close_side_by_side()

  if config.options.diff.split_full_width then
    collapse_editor_area()
  end

  local left_rev, right_rev = split_revisions(spec)
  if not left_rev then
    return notify.warn("This comparison has no side-by-side form; showing the unified patch instead")
  end
  split_pending = true

  local left_label, right_label = diff_api.side_labels(spec)
  local context = { repo = repo, path = path, spec = spec }
  -- "vertical" puts the sides beside each other, which needs a `vsplit`;
  -- "horizontal" stacks them.
  local horizontal = config.options.diff.layout == "horizontal"

  blob_buffer(repo, path, left_rev, left_label, function(left_bufnr)
    if not left_bufnr then
      split_pending = false
      return
    end

    local function finish(right_bufnr, use_file)
      local target = window.pick_editor_window()
      if target then
        vim.api.nvim_set_current_win(target)
      end

      if use_file then
        -- Opting out: this call is part of *building* the diff, not leaving it.
        window.open_file(path_util.join(repo.root, path), { cmd = "edit", dismiss_diff = false })
      else
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), right_bufnr)
      end
      local right_winid = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")
      -- The right pane is the user's real file buffer, kept editable on
      -- purpose so `do`/`dp` work. picked does not map keys on it — stealing
      -- <C-v> from a file buffer would cost blockwise visual mode — so its
      -- winbar names the command instead.
      vim.wo[right_winid].winbar = (" %s   ]c/[c hunks   :PickedDiffView unified "):format(right_label:upper())

      vim.cmd(horizontal and "noautocmd leftabove split" or "noautocmd leftabove vsplit")
      local left_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_winid, left_bufnr)
      vim.cmd("diffthis")
      vim.wo[left_winid].winbar = (" %s   ]c/[c hunks   %s unified "):format(
        left_label:upper(),
        type(config.options.keymaps.diff.toggle_view) == "table" and config.options.keymaps.diff.toggle_view[1]
          or config.options.keymaps.diff.toggle_view
      )

      map_split_buffer(left_bufnr, context)
      map_split_buffer(use_file and vim.api.nvim_win_get_buf(right_winid) or right_bufnr, context, use_file)

      -- Start on the right-hand (newer, editable) side, at the first change,
      -- whether or not the cursor is going to stay there.
      vim.api.nvim_set_current_win(right_winid)
      pcall(vim.cmd, "normal! gg")
      pcall(vim.cmd, "normal! ]c")

      -- Balance *after* focusing: 'winwidth' expands whichever window becomes
      -- current to its minimum, which would silently undo an earlier split.
      -- Neovim still enforces that minimum, so on a terminal too narrow for
      -- two panes of 'winwidth' the sides cannot be exactly equal.
      balance_split(left_winid, right_winid)

      split_panes = { left = left_winid, right = right_winid, left_buf = left_bufnr }
      split_pending = false

      -- Hand the cursor back to whatever asked for the diff. Browsing a file
      -- list must not drag the cursor into the preview it opens; only an
      -- explicit "open this" does that.
      if opts.focus == false and vim.api.nvim_win_is_valid(origin_win) and origin_win ~= right_winid then
        vim.api.nvim_set_current_win(origin_win)
      end

      -- Opening or closing anything else makes Neovim redistribute columns,
      -- so hold the halves for as long as the split is up.
      split_augroup = vim.api.nvim_create_augroup("PickedSplitBalance", { clear = true })
      vim.api.nvim_create_autocmd({ "WinResized", "WinClosed", "WinNew", "VimResized" }, {
        group = split_augroup,
        callback = function()
          vim.schedule(function()
            if M.split_is_open() then
              balance_split(left_winid, right_winid)
            else
              -- A pane was closed by hand. Drop the other one and the scratch
              -- buffers now, so the next request for a diff starts from a
              -- clean slate instead of a split we only believe is still up.
              M.close_side_by_side()
            end
          end)
        end,
      })

      if not opts.silent then
        notify.info(
          ("%s ↔ %s   ]c/[c jump hunks   :PickedDiffView returns to the unified patch"):format(
            left_label,
            right_label
          )
        )
      end
    end

    if right_rev then
      blob_buffer(repo, path, right_rev, right_label, function(right_bufnr)
        if right_bufnr then
          finish(right_bufnr, false)
        else
          split_pending = false
        end
      end)
    else
      finish(nil, true)
    end
  end)
end

---Is the side-by-side view on screen *now*?
---
---Deliberately says nothing about a split still being built: callers that must
---also count one in flight use `split_active` below.
---@return boolean
function M.split_is_open()
  if not split_panes then
    return false
  end
  if not (vim.api.nvim_win_is_valid(split_panes.left) and vim.api.nvim_win_is_valid(split_panes.right)) then
    return false
  end
  -- A valid window is not enough: the pane may have been reused for something
  -- else, in which case the diff is gone even though the window remains.
  return vim.api.nvim_win_get_buf(split_panes.left) == split_panes.left_buf
end

---Put the cursor in the split, if one is already showing this file.
---
---This is what makes <CR> mean "take me into the diff I can see" while merely
---moving down the file list leaves the cursor in the list. Returns false when
---there is nothing to move into, so the caller can fall back to opening the
---file.
---@param path string|nil
---@return boolean focused
function M.focus_split(path)
  if not (M.split_is_open() and split_panes) then
    return false
  end
  if path and not (current and current.path == path) then
    return false
  end
  if not vim.api.nvim_win_is_valid(split_panes.right) then
    return false
  end
  vim.api.nvim_set_current_win(split_panes.right)
  return true
end

---Is a side-by-side view on screen, or on its way there?
---
---The blobs are fetched asynchronously, so for a moment a split has been asked
---for and has no windows yet. Anything deciding whether to *open* a view has
---to count that moment, or a preview firing inside it puts the unified view up
---over a split that is about to appear.
---@return boolean
function M.split_active()
  return split_pending or M.split_is_open()
end

---Leave diff mode and drop the scratch buffers.
function M.close_side_by_side()
  if split_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, split_augroup)
    split_augroup = nil
  end
  -- The panes no longer need protecting from 'winwidth', so give the user
  -- their setting back.
  winsize.release("diff-split")
  if #diff_buffers == 0 then
    return
  end
  -- `diffoff!` clears diff mode across the tab, including the window that is
  -- about to show the file again.
  pcall(vim.cmd, "diffoff!")
  for _, bufnr in ipairs(diff_buffers) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      -- Close any window still showing a scratch side, so the layout returns
      -- to what it was rather than leaving an empty split behind.
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(winid) == bufnr and #vim.api.nvim_tabpage_list_wins(0) > 1 then
          pcall(vim.api.nvim_win_close, winid, true)
        end
      end
    end
  end
  close_side_by_side()
end

---Switch the current diff between the unified patch and the side-by-side view.
function M.toggle_view()
  if M.split_active() then
    local context = current
    M.close_side_by_side()
    if context and context.repo then
      M.open(context.repo, { path = context.path, spec = context.spec, view = "unified" })
    end
    return
  end

  if not current then
    return notify.warn("No diff is open")
  end
  if not M.splittable(current.spec, current.path) then
    return notify.warn("The side-by-side view shows one file at a time; open a file's diff first")
  end

  local repo, path, spec = current.repo, current.path, current.spec
  M.close()
  M.open_side_by_side(repo, path, spec)
end

return M
