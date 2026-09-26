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

local config = require("gitui.config")
local diff_api = require("gitui.git.diff")
local hunks_api = require("gitui.git.hunks")
local icons = require("gitui.utils.icons")
local notify = require("gitui.ui.notify")
local operations = require("gitui.operations")
local panel_lib = require("gitui.ui.panel")
local path_util = require("gitui.utils.path")
local store = require("gitui.state")
local text_util = require("gitui.utils.text")
local window = require("gitui.ui.window")

local M = {}

---@class GitUIDiffViewState
---@field repo GitRepository
---@field spec GitDiffSpec
---@field path string|nil  nil means "every changed file"
---@field diffs GitFileDiff[]
---@field loading boolean
---@field error GitError|nil
---@field entry GitFileEntry|nil

---@class GitUIDiffItem
---@field id string
---@field kind "file"|"hunk"|"line"|"info"|"binary"
---@field diff GitFileDiff|nil
---@field hunk GitHunk|nil
---@field body_index integer|nil
---@field line_kind string|nil
---@field old_ln integer|nil
---@field new_ln integer|nil

---@type GitUIPanel|nil
local panel = nil

---@type GitUIDiffViewState|nil
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

---@param canvas GitUICanvas
---@param diff GitFileDiff
---@param width integer
local function render_file_header(canvas, diff, width)
  local row = canvas:row({ id = "file:" .. diff.path, kind = "file", diff = diff })
  row:add(icons.get("file") ~= "" and (icons.get("file") .. " ") or "")
  row:add(diff.path, "GitUIDiffFileName", "open")
  if diff.old_path and diff.old_path ~= diff.path then
    row:add("  ← " .. diff.old_path, "GitUIDim")
  end

  local added, removed = 0, 0
  for _, hunk in ipairs(diff.hunks) do
    local a, r = hunks_api.counts(hunk)
    added, removed = added + a, removed + r
  end
  if width > 50 then
    row:right((" +%d −%d "):format(added, removed), "GitUIDim")
  end
end

---@param canvas GitUICanvas
---@param diff GitFileDiff
---@param opts { width: integer, show_numbers: boolean }
local function render_diff(canvas, diff, opts)
  if diff.binary then
    canvas:row({ id = "bin:" .. diff.path, kind = "binary", diff = diff })
      :add("  Binary file — no textual diff", "GitUIDim")
    return
  end

  if #diff.hunks == 0 then
    local message = diff.mode_change and "  Mode change only" or "  No changes"
    canvas:row({ id = "empty:" .. diff.path, kind = "info", diff = diff }):add(message, "GitUIDim")
    return
  end

  local highlights = require("gitui.ui.highlights")
  -- Line-number gutters make a unified diff far easier to correlate with the
  -- file, but they cost columns; `show_numbers` drops them on narrow windows.
  local rows = hunks_api.to_display(diff.hunks)

  for _, display in ipairs(rows) do
    ---@type GitUIDiffItem
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
      canvas:row(item):add(display.text, "GitUIDiffHunkHeader", "stage_hunk")
    else
      local row = canvas:row(item)
      if opts.show_numbers then
        local old_text = display.old_ln and tostring(display.old_ln) or ""
        local new_text = display.new_ln and tostring(display.new_ln) or ""
        row:add(text_util.lpad(old_text, 5) .. " ", "GitUIDiffLineNr")
        row:add(text_util.lpad(new_text, 4) .. " ", "GitUIDiffLineNr")
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

---@param self GitUIPanel
---@param canvas GitUICanvas
local function render_panel(self, canvas)
  local width = self:width()

  if not current then
    canvas:text("  No diff loaded", "GitUIDim")
    return
  end

  local caps = capabilities(current.spec)
  local header = canvas:row({ id = "header", kind = "info" })
  header:add("  ")
  header:add(diff_api.describe(current.spec), "GitUITitle")
  header:add("   ")
  header:add(caps.label, "GitUIDim")
  canvas:blank()

  if current.loading then
    canvas:text("  Loading diff…", "GitUIDim")
    return
  end

  if current.error then
    canvas:text("  " .. current.error.title, "GitUIError")
    canvas:text("  " .. (current.error.reason or ""), "GitUIDim")
    if current.error.hint then
      canvas:text("  " .. current.error.hint, "GitUIDim")
    end
    return
  end

  if #current.diffs == 0 then
    canvas:text("  No differences", "GitUIDim")
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
---@param item GitUIDiffItem|nil
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
---@param panel_instance GitUIPanel
---@param first integer
---@param last integer
---@return GitFileDiff|nil, GitHunk[]|nil
local function selection_to_hunks(panel_instance, first, last)
  local by_hunk = {}
  local order = {}
  local diff = nil

  for lnum = first, last do
    local item = panel_instance.canvas and panel_instance.canvas:item_at(lnum)
    ---@cast item GitUIDiffItem|nil
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

---@type table<string, fun(panel: GitUIPanel, item: GitUIDiffItem|nil)>
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
  local target = panel_instance.canvas and panel_instance.canvas:find(function(item, lnum)
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
  for _, lnum in ipairs(panel_instance.canvas:find_all(function(item)
    return item.kind == "hunk"
  end)) do
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
  local target = panel_instance.canvas and panel_instance.canvas:find(function(item, lnum)
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
  for _, lnum in ipairs(panel_instance.canvas:find_all(function(item)
    return item.kind == "file"
  end)) do
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

-- Kept as an alias so `:GitUIDiff!` and the context menu keep working.
actions.split = actions.toggle_view

---@type table<string, fun(panel: GitUIPanel, first: integer, last: integer)>
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

---@return GitUIPanel
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
  local events = require("gitui.utils.events")
  local unsubscribe = events.on(events.names.STATUS_CHANGED, function()
    if panel and panel:is_open() and current and not current.loading then
      vim.schedule(M.reload)
    end
  end)
  panel:on_destroy(unsubscribe)

  return panel
end

--- Loading ---------------------------------------------------------------------------

---@param instance GitUIPanel
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

---@class GitUIDiffOpenOpts
---@field path string|nil  a single file, or nil for every changed file
---@field spec GitDiffSpec
---@field entry GitFileEntry|nil
---@field from_panel GitUIPanel|nil
---@field focus boolean|nil
---@field view "unified"|"split"|nil  defaults to `config.diff.view`

---Open a diff.
---
---Honours `config.diff.view`, falling back to the unified patch whenever the
---side-by-side form does not apply — it shows one file at a time, so a
---whole-tree diff has no split form.
---@param repo GitRepository
---@param opts GitUIDiffOpenOpts
function M.open(repo, opts)
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
    return M.open_side_by_side(repo, opts.path, opts.spec)
  end

  if M.split_is_open() then
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
  local is_open = panel ~= nil and panel:is_open()

  if not is_open then
    if mode ~= "auto" then
      return
    end
    -- Opening without focus: the panel keeps the cursor, the editor area
    -- shows the diff.
    return M.open(repo, {
      path = entry.path,
      spec = { kind = kind },
      entry = entry,
      focus = false,
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

---Close any side-by-side diff this module opened.
local function close_side_by_side()
  for _, bufnr in ipairs(diff_buffers) do
    window.delete_buffer(bufnr)
  end
  diff_buffers = {}
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
local function map_split_buffer(bufnr, context)
  local keys = config.options.keymaps.diff

  local function map(lhs, rhs, desc)
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", key, rhs, {
        buffer = bufnr,
        nowait = true,
        silent = true,
        desc = "gitui: " .. desc,
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
  end, "close the split view")
end

---Open a true side-by-side diff using Neovim's own diff mode.
---
---This is a reading view: `]c`, `[c`, folding and `do`/`dp` all work because
---it is genuinely `:diffthis`, not an imitation of it.
---@param repo GitRepository
---@param path string
---@param spec GitDiffSpec
function M.open_side_by_side(repo, path, spec)
  close_side_by_side()

  local left_rev, right_rev = split_revisions(spec)
  if not left_rev then
    return notify.warn("This comparison has no side-by-side form; showing the unified patch instead")
  end

  local left_label, right_label = diff_api.side_labels(spec)
  local context = { repo = repo, path = path, spec = spec }
  -- "vertical" puts the sides beside each other, which needs a `vsplit`;
  -- "horizontal" stacks them.
  local horizontal = config.options.diff.layout == "horizontal"

  blob_buffer(repo, path, left_rev, left_label, function(left_bufnr)
    if not left_bufnr then
      return
    end

    local function finish(right_bufnr, use_file)
      local target = window.pick_editor_window()
      if target then
        vim.api.nvim_set_current_win(target)
      end

      if use_file then
        window.open_file(path_util.join(repo.root, path), { cmd = "edit" })
      else
        vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), right_bufnr)
      end
      local right_winid = vim.api.nvim_get_current_win()
      vim.cmd("diffthis")
      -- The right pane is the user's real file buffer, kept editable on
      -- purpose so `do`/`dp` work. gitui does not map keys on it — stealing
      -- <C-v> from a file buffer would cost blockwise visual mode — so its
      -- winbar names the command instead.
      vim.wo[right_winid].winbar = (" %s   ]c/[c hunks   :GitUIDiffView unified "):format(right_label:upper())

      vim.cmd(horizontal and "noautocmd leftabove split" or "noautocmd leftabove vsplit")
      local left_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_winid, left_bufnr)
      vim.cmd("diffthis")
      vim.wo[left_winid].winbar = (" %s   ]c/[c hunks   %s unified "):format(
        left_label:upper(),
        type(config.options.keymaps.diff.toggle_view) == "table"
            and config.options.keymaps.diff.toggle_view[1]
          or config.options.keymaps.diff.toggle_view
      )

      map_split_buffer(left_bufnr, context)
      if not use_file then
        map_split_buffer(right_bufnr, context)
      end

      -- Land on the right-hand (newer, editable) side, at the first change.
      vim.api.nvim_set_current_win(right_winid)
      pcall(vim.cmd, "normal! gg")
      pcall(vim.cmd, "normal! ]c")

      notify.info(("%s ↔ %s   ]c/[c jump hunks   :GitUIDiffView returns to the unified patch"):format(
        left_label,
        right_label
      ))
    end

    if right_rev then
      blob_buffer(repo, path, right_rev, right_label, function(right_bufnr)
        if right_bufnr then
          finish(right_bufnr, false)
        end
      end)
    else
      finish(nil, true)
    end
  end)
end

---@return boolean
function M.split_is_open()
  return #diff_buffers > 0
end

---Leave diff mode and drop the scratch buffers.
function M.close_side_by_side()
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
  if M.split_is_open() then
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
