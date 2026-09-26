---@brief Inline change signs and buffer-level hunk actions.
---
---Signs are recomputed with `vim.diff` against the file's *index* content, not
---by running `git diff` on every keystroke. The index blob is fetched once and
---re-fetched only when the index actually changes, so typing costs one
---in-process diff of two strings and nothing else.
---
---Because the comparison is index → buffer, the hunks it produces are exactly
---the ones `git apply --cached` needs: staging a hunk from a file buffer uses
---the same patch machinery as staging one from the diff view.

local config = require("picked.config")
local debounce = require("picked.utils.debounce")
local events = require("picked.utils.events")
local git = require("picked.git")
local hunks_api = require("picked.git.hunks")
local logger = require("picked.utils.logger")
local notify = require("picked.ui.notify")
local operations = require("picked.operations")
local path_util = require("picked.utils.path")
local repository = require("picked.git.repository")

local M = {}

---@class PickedSignAttachment
---@field bufnr integer
---@field repo GitRepository
---@field path string  repository-relative
---@field index_text string|nil
---@field hunks GitHunk[]
---@field untracked boolean
---@field generation integer
---@field detach fun()

---@type table<integer, PickedSignAttachment>
local attached = {}

local namespace = vim.api.nvim_create_namespace("picked_signs")
local augroup = nil

--- Sign definitions ----------------------------------------------------------

---@param kind string
---@return string text, string highlight
local function sign_for(kind)
  local icons = require("picked.utils.icons")
  local set = icons.nerd and config.options.signs.text or config.options.signs.ascii_text
  local highlights = {
    add = "PickedSignAdd",
    change = "PickedSignChange",
    delete = "PickedSignDelete",
    topdelete = "PickedSignTopDelete",
    changedelete = "PickedSignChangeDelete",
    untracked = "PickedSignUntracked",
  }
  return set[kind] or "|", highlights[kind] or "PickedSignChange"
end

--- Buffer text ----------------------------------------------------------------

---The buffer's content as git would see it on disk.
---
---`fileformat` matters: a DOS file is stored with CRLF in the index but held
---with LF in the buffer, and comparing the two directly would report every
---line as changed.
---@param bufnr integer
---@return string
local function buffer_text(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local separator = vim.bo[bufnr].fileformat == "dos" and "\r\n" or "\n"
  local text = table.concat(lines, separator)
  if vim.bo[bufnr].endofline then
    text = text .. separator
  end
  return text
end

--- Rendering -------------------------------------------------------------------

---@param attachment PickedSignAttachment
local function place_signs(attachment)
  local bufnr = attachment.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  if not config.options.signs.enabled then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local priority = config.options.signs.priority

  local function place(lnum, kind)
    if lnum < 1 or lnum > line_count then
      return
    end
    local text, hl = sign_for(kind)
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, lnum - 1, 0, {
      sign_text = text:sub(1, 2),
      sign_hl_group = hl,
      priority = priority,
    })
  end

  if attachment.untracked then
    for lnum = 1, line_count do
      place(lnum, "untracked")
    end
    return
  end

  for _, hunk in ipairs(attachment.hunks) do
    local added, removed = hunks_api.counts(hunk)

    if hunk.new_count == 0 then
      -- A pure deletion has no line of its own; mark the boundary.
      if hunk.new_start == 0 then
        place(1, "topdelete")
      else
        place(hunk.new_start, "delete")
      end
    else
      local kind
      if removed == 0 then
        kind = "add"
      elseif added >= removed then
        kind = "change"
      else
        kind = "changedelete"
      end

      -- Only the lines that actually differ get a sign; context lines inside
      -- the hunk are unchanged and must stay unmarked.
      local new_ln = hunk.new_start
      for _, line in ipairs(hunk.lines) do
        local prefix = line:sub(1, 1)
        if prefix == " " then
          new_ln = new_ln + 1
        elseif prefix == "+" then
          place(new_ln, kind == "changedelete" and "change" or kind)
          new_ln = new_ln + 1
        end
      end
    end
  end
end

--- Computation --------------------------------------------------------------------

---@param attachment PickedSignAttachment
local function recompute(attachment)
  if not vim.api.nvim_buf_is_valid(attachment.bufnr) then
    return
  end

  if attachment.untracked then
    attachment.hunks = {}
    return place_signs(attachment)
  end

  if attachment.index_text == nil then
    return
  end

  attachment.hunks = hunks_api.compute(attachment.index_text, buffer_text(attachment.bufnr), {
    context = config.options.diff.context,
    algorithm = config.options.diff.algorithm,
  })
  place_signs(attachment)
end

---Re-read the file's index content, then recompute.
---@param attachment PickedSignAttachment
local function reload_index(attachment)
  local generation = attachment.generation + 1
  attachment.generation = generation

  git.diff.index_blob(attachment.repo, attachment.path, function(content, err)
    -- A newer reload already started; this answer is stale.
    if attachment.generation ~= generation or not attached[attachment.bufnr] then
      return
    end

    if err then
      logger.debug("index blob failed for", attachment.path, err.reason)
      attachment.index_text = nil
      attachment.untracked = true
    else
      attachment.index_text = content
      attachment.untracked = content == "" and not vim.uv.fs_stat(attachment.path) or false
    end
    recompute(attachment)
  end)
end

--- Attachment ----------------------------------------------------------------------

---@param bufnr integer
---@return boolean
local function is_eligible(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return false
  end
  if vim.bo[bufnr].buftype ~= "" then
    return false
  end

  local file = path_util.buffer_path(bufnr)
  if not file then
    return false
  end

  local stat = vim.uv.fs_stat(path_util.to_os(file))
  if stat and stat.size > config.options.signs.max_filesize then
    logger.debug("skipping signs for large file", file)
    return false
  end

  return true
end

---Stop tracking a buffer and remove everything it owns.
---@param bufnr integer
function M.detach(bufnr)
  local attachment = attached[bufnr]
  if not attachment then
    return
  end
  attached[bufnr] = nil
  attachment.detach()
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  end
end

---Start tracking a buffer.
---@param bufnr integer
function M.attach(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()

  if attached[bufnr] or not config.options.signs.enabled or not config.options.signs.watch_buffers then
    return
  end
  if not is_eligible(bufnr) then
    return
  end

  local file = path_util.buffer_path(bufnr)
  if not file then
    return
  end

  local repo = repository.detect(path_util.dirname(file))
  if not repo then
    return
  end

  local relative = path_util.relative(file, repo.root)
  if not relative then
    return
  end

  ---@type PickedSignAttachment
  local attachment = {
    bufnr = bufnr,
    repo = repo,
    path = relative,
    index_text = nil,
    hunks = {},
    untracked = false,
    generation = 0,
    detach = function() end,
  }

  local update = debounce.trailing(function()
    if attached[bufnr] then
      recompute(attachment)
    end
  end, config.options.signs.debounce)

  local buffer_augroup = vim.api.nvim_create_augroup("PickedSigns_" .. bufnr, { clear = true })

  -- Buffer edits only need a re-diff; the index has not moved.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "InsertLeave" }, {
    group = buffer_augroup,
    buffer = bufnr,
    callback = update,
  })

  -- Writing the file, or any git operation, can move the index.
  vim.api.nvim_create_autocmd({ "BufWritePost", "BufReadPost" }, {
    group = buffer_augroup,
    buffer = bufnr,
    callback = function()
      reload_index(attachment)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
    group = buffer_augroup,
    buffer = bufnr,
    callback = function()
      M.detach(bufnr)
    end,
  })

  local unsubscribe = events.on(events.names.STATUS_CHANGED, function(data)
    if data and data.root == repo.root and attached[bufnr] then
      reload_index(attachment)
    end
  end)

  attachment.detach = function()
    pcall(vim.api.nvim_del_augroup_by_id, buffer_augroup)
    unsubscribe()
  end

  attached[bufnr] = attachment
  reload_index(attachment)
end

---@param bufnr integer|nil
---@return PickedSignAttachment|nil
function M.attachment(bufnr)
  return attached[bufnr or vim.api.nvim_get_current_buf()]
end

--- Hunk actions -------------------------------------------------------------------

---@return PickedSignAttachment|nil, GitHunk|nil
local function hunk_under_cursor()
  local attachment = M.attachment()
  if not attachment then
    notify.warn("git signs are not attached to this buffer")
    return nil, nil
  end
  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local hunk = hunks_api.at_line(attachment.hunks, lnum)
  if not hunk then
    notify.info("No change under the cursor")
    return attachment, nil
  end
  return attachment, hunk
end

---@param attachment PickedSignAttachment
---@return GitPartialOpts
local function patch_opts(attachment)
  return {
    new_file = attachment.untracked,
    context = config.options.diff.context,
  }
end

---Stage the hunk under the cursor, or every hunk overlapping a line range.
---@param first integer|nil
---@param last integer|nil
function M.stage_hunk(first, last)
  local attachment = M.attachment()
  if not attachment then
    return notify.warn("git signs are not attached to this buffer")
  end

  local selected
  if first then
    -- A visual selection stages exactly the lines inside it, which is the
    -- line-level staging path.
    selected = {}
    for _, hunk in ipairs(hunks_api.in_range(attachment.hunks, first, last or first)) do
      local partial = hunks_api.select_range(hunk, first, last or first)
      if partial then
        selected[#selected + 1] = partial
      end
    end
  else
    local _, hunk = hunk_under_cursor()
    selected = hunk and { hunk } or {}
  end

  if #selected == 0 then
    return notify.info("Nothing to stage here")
  end

  operations.stage_hunks(attachment.repo, attachment.path, selected, patch_opts(attachment))
end

---Discard the hunk under the cursor, or the selected lines.
---@param first integer|nil
---@param last integer|nil
function M.discard_hunk(first, last)
  local attachment = M.attachment()
  if not attachment then
    return notify.warn("git signs are not attached to this buffer")
  end

  local selected
  if first then
    selected = {}
    for _, hunk in ipairs(hunks_api.in_range(attachment.hunks, first, last or first)) do
      local partial = hunks_api.select_range(hunk, first, last or first)
      if partial then
        selected[#selected + 1] = partial
      end
    end
  else
    local _, hunk = hunk_under_cursor()
    selected = hunk and { hunk } or {}
  end

  if #selected == 0 then
    return notify.info("Nothing to discard here")
  end

  if vim.bo[attachment.bufnr].modified then
    return notify.warn("Save the file first — discarding rewrites it on disk")
  end

  operations.discard_hunks(attachment.repo, attachment.path, selected, patch_opts(attachment))
end

---Unstage the hunk under the cursor.
---
---Unstaging works on the HEAD → index diff, which is a different set of hunks
---from the ones in the sign column, so it is fetched on demand.
function M.unstage_hunk()
  local attachment = M.attachment()
  if not attachment then
    return notify.warn("git signs are not attached to this buffer")
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]

  git.diff.file(attachment.repo, attachment.path, { kind = "index" }, nil, function(diff, err)
    if err then
      return notify.error(err)
    end
    if not diff or #diff.hunks == 0 then
      return notify.info("Nothing staged for this file")
    end

    local hunk = hunks_api.at_line(diff.hunks, lnum)
    if not hunk then
      -- The staged hunks are positioned in the index, which may not line up
      -- with the buffer; unstage the whole file rather than guess.
      return notify.info("No staged hunk at this line — use the diff view to choose one")
    end

    operations.unstage_hunks(attachment.repo, attachment.path, { hunk }, { old_path = diff.old_path })
  end)
end

---Preview the hunk under the cursor in a floating window.
function M.preview_hunk()
  local attachment, hunk = hunk_under_cursor()
  if not attachment or not hunk then
    return
  end

  local window = require("picked.ui.window")
  local render = require("picked.ui.render")
  local highlights = require("picked.ui.highlights")

  local bufnr = window.create_buffer({ name = "hunk-preview", filetype = "diff" })
  local canvas = render.new({ width = 80 })

  canvas:text(hunks_api.header(hunk), "PickedDiffHunkHeader")
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    local kind = prefix == "+" and "add" or prefix == "-" and "delete" or "context"
    canvas:text(line, highlights.for_diff(kind))
  end

  canvas:apply(bufnr, vim.api.nvim_create_namespace("picked_hunk_preview"))

  local lines = canvas:lines()
  local winid = window.open_float(bufnr, {
    title = ("Hunk — %s"):format(attachment.path),
    footer = "q close",
    width = 1,
    height = #lines,
  })
  window.fit_float(winid, lines, { min_width = 40 })
  vim.wo[winid].cursorline = false

  local unregister
  local function close()
    if unregister then
      unregister()
      unregister = nil
    end
    window.close(winid)
    window.delete_buffer(bufnr)
  end
  unregister = require("picked.ui.floats").register(close)

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close, { buffer = bufnr, nowait = true, silent = true })
  end
end

---@param direction 1|-1
local function jump(direction)
  local attachment = M.attachment()
  if not attachment or #attachment.hunks == 0 then
    return notify.info("No changes in this buffer")
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  local target = nil

  if direction > 0 then
    for _, hunk in ipairs(attachment.hunks) do
      local first = hunks_api.new_range(hunk)
      if first > lnum then
        target = first
        break
      end
    end
    -- Wrap, matching how `]c` behaves in diff mode.
    target = target or hunks_api.new_range(attachment.hunks[1])
  else
    for _, hunk in ipairs(attachment.hunks) do
      local first = hunks_api.new_range(hunk)
      if first < lnum then
        target = first
      end
    end
    target = target or hunks_api.new_range(attachment.hunks[#attachment.hunks])
  end

  local count = vim.api.nvim_buf_line_count(0)
  vim.api.nvim_win_set_cursor(0, { math.max(1, math.min(target, count)), 0 })
  vim.cmd("normal! zz")
end

function M.next_hunk()
  jump(1)
end

function M.prev_hunk()
  jump(-1)
end

---Hunks currently known for a buffer, for statusline integrations.
---@param bufnr integer|nil
---@return { added: integer, changed: integer, removed: integer }
function M.summary(bufnr)
  local attachment = M.attachment(bufnr)
  local summary = { added = 0, changed = 0, removed = 0 }
  if not attachment then
    return summary
  end

  for _, hunk in ipairs(attachment.hunks) do
    local added, removed = hunks_api.counts(hunk)
    if removed == 0 then
      summary.added = summary.added + added
    elseif added == 0 then
      summary.removed = summary.removed + removed
    else
      summary.changed = summary.changed + math.max(added, removed)
    end
  end
  return summary
end

--- Lifecycle -----------------------------------------------------------------------

---Install the autocommands that attach signs to eligible buffers.
function M.setup()
  if augroup or not config.options.signs.enabled then
    return
  end
  augroup = vim.api.nvim_create_augroup("PickedSigns", { clear = true })

  vim.api.nvim_create_autocmd({ "BufReadPost", "BufNewFile", "BufFilePost" }, {
    group = augroup,
    callback = function(args)
      vim.schedule(function()
        M.attach(args.buf)
      end)
    end,
  })

  -- Buffers already open when picked loads.
  vim.schedule(function()
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      M.attach(bufnr)
    end
  end)
end

function M.teardown()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  for bufnr in pairs(attached) do
    M.detach(bufnr)
  end
end

---Toggle signs for the whole session.
function M.toggle()
  config.options.signs.enabled = not config.options.signs.enabled
  if config.options.signs.enabled then
    M.setup()
    notify.info("Git signs on")
  else
    M.teardown()
    notify.info("Git signs off")
  end
end

return M
