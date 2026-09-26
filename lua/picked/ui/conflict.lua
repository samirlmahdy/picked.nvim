---@brief Merge conflict resolution.
---
---picked never resolves a conflict for the user. It makes the three versions
---visible, makes each choice one keystroke, and makes the result an ordinary
---buffer edit so `u` undoes a wrong choice.
---
---Two modes:
---  * inline — the conflicted file itself, with each region highlighted and
---    labelled. This is the default because the markers are the real content
---    and editing them by hand must always stay possible.
---  * three-way — `ours`, the result, and `theirs` side by side, with the
---    merge base one keystroke away.

local config = require("picked.config")
local git = require("picked.git")
local notify = require("picked.ui.notify")
local operations = require("picked.operations")
local path_util = require("picked.utils.path")
local window = require("picked.ui.window")

local M = {}

---@class PickedConflictSession
---@field repo GitRepository
---@field path string
---@field bufnr integer
---@field winid integer
---@field regions GitConflictRegion[]
---@field augroup integer
---@field side_buffers integer[]
---@field side_winids integer[]

---@type PickedConflictSession|nil
local session = nil

local namespace = vim.api.nvim_create_namespace("picked_conflict")

--- Decoration -------------------------------------------------------------------

---@param current PickedConflictSession
local function decorate(current)
  if not vim.api.nvim_buf_is_valid(current.bufnr) then
    return
  end

  vim.api.nvim_buf_clear_namespace(current.bufnr, namespace, 0, -1)
  current.regions = git.conflicts.in_buffer(current.bufnr)

  for index, region in ipairs(current.regions) do
    local function line_marks(first, last, hl)
      for lnum = first, last do
        if lnum >= 1 then
          pcall(vim.api.nvim_buf_set_extmark, current.bufnr, namespace, lnum - 1, 0, {
            line_hl_group = hl,
          })
        end
      end
    end

    -- Each block is labelled in words as well as highlighted, so the view
    -- survives a monochrome terminal.
    pcall(vim.api.nvim_buf_set_extmark, current.bufnr, namespace, region.ours_start - 1, 0, {
      line_hl_group = "PickedConflictMarker",
      virt_text = {
        { ("  ⟨%d/%d⟩ "):format(index, #current.regions), "PickedDim" },
        { " OURS — " .. region.ours_label .. " ", "PickedConflictLabel" },
        { "  [o]urs [t]heirs [b]oth [n]one ", "PickedKey" },
      },
      virt_text_pos = "eol",
    })
    line_marks(region.ours_start + 1, region.ours_end, "PickedConflictOurs")

    if region.base_start and region.base_end then
      pcall(vim.api.nvim_buf_set_extmark, current.bufnr, namespace, region.base_start - 2, 0, {
        line_hl_group = "PickedConflictMarker",
        virt_text = { { "  BASE ", "PickedConflictLabel" } },
        virt_text_pos = "eol",
      })
      line_marks(region.base_start, region.base_end, "PickedConflictBase")
    end

    pcall(vim.api.nvim_buf_set_extmark, current.bufnr, namespace, region.separator - 1, 0, {
      line_hl_group = "PickedConflictMarker",
    })
    line_marks(region.theirs_start, region.theirs_end - 1, "PickedConflictTheirs")

    pcall(vim.api.nvim_buf_set_extmark, current.bufnr, namespace, region.theirs_end - 1, 0, {
      line_hl_group = "PickedConflictMarker",
      virt_text = { { " THEIRS — " .. (region.theirs_label or "incoming") .. " ", "PickedConflictLabel" } },
      virt_text_pos = "eol",
    })
  end
end

--- Navigation --------------------------------------------------------------------

---@param current PickedConflictSession
---@return GitConflictRegion|nil
local function region_at_cursor(current)
  local lnum = vim.api.nvim_win_get_cursor(current.winid)[1]
  return git.conflicts.at_line(current.regions, lnum)
end

---@param current PickedConflictSession
---@param direction 1|-1
local function jump(current, direction)
  if #current.regions == 0 then
    return notify.info("No conflicts remain in this file")
  end

  local lnum = vim.api.nvim_win_get_cursor(current.winid)[1]
  local target = nil

  if direction > 0 then
    for _, region in ipairs(current.regions) do
      if region.ours_start > lnum then
        target = region
        break
      end
    end
    target = target or current.regions[1]
  else
    for _, region in ipairs(current.regions) do
      if region.ours_start < lnum then
        target = region
      end
    end
    target = target or current.regions[#current.regions]
  end

  vim.api.nvim_win_set_cursor(current.winid, { target.ours_start, 0 })
  vim.cmd("normal! zz")
end

--- Resolution ---------------------------------------------------------------------

---@param current PickedConflictSession
---@param choice GitConflictChoice
local function resolve(current, choice)
  local region = region_at_cursor(current)
  if not region then
    return notify.warn("Put the cursor inside a conflict region")
  end

  if choice == "base" and not region.base then
    return notify.warn("No merge base recorded — re-open with the 3-way view to see it")
  end

  if not git.conflicts.resolve_in_buffer(current.bufnr, region, choice) then
    return notify.warn("The buffer is not modifiable")
  end

  decorate(current)

  if #current.regions == 0 then
    notify.success(("All conflicts resolved in %s — write the file and stage it"):format(current.path))
  else
    notify.info(("%d conflict%s remaining"):format(#current.regions, #current.regions == 1 and "" or "s"))
    jump(current, 1)
  end
end

---Stage the file as resolved, writing it first.
---@param current PickedConflictSession
local function stage(current)
  if #current.regions > 0 then
    return notify.warn(("%d conflict%s still unresolved"):format(#current.regions, #current.regions == 1 and "" or "s"))
  end

  if vim.bo[current.bufnr].modified then
    vim.api.nvim_buf_call(current.bufnr, function()
      vim.cmd("silent write")
    end)
  end

  operations.mark_resolved(current.repo, { current.path })
end

--- Session -----------------------------------------------------------------------

local function close_sides()
  local current = session
  if not current then
    return
  end
  for _, winid in ipairs(current.side_winids) do
    window.close(winid)
  end
  for _, bufnr in ipairs(current.side_buffers) do
    window.delete_buffer(bufnr)
  end
  current.side_winids = {}
  current.side_buffers = {}
end

local function close_session()
  local current = session
  if not current then
    return
  end
  session = nil

  close_sides()
  pcall(vim.api.nvim_del_augroup_by_id, current.augroup)
  if vim.api.nvim_buf_is_valid(current.bufnr) then
    vim.api.nvim_buf_clear_namespace(current.bufnr, namespace, 0, -1)
  end
end

---@param current PickedConflictSession
local function install_keymaps(current)
  local keys = config.options.keymaps.conflict

  local function map(action, handler)
    local lhs = keys[action]
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", key, handler, {
        buffer = current.bufnr,
        nowait = true,
        silent = true,
        desc = "picked: conflict " .. action,
      })
    end
  end

  map("ours", function()
    resolve(current, "ours")
  end)
  map("theirs", function()
    resolve(current, "theirs")
  end)
  map("both", function()
    resolve(current, "both")
  end)
  map("base", function()
    resolve(current, "base")
  end)
  map("none", function()
    resolve(current, "none")
  end)
  map("next_conflict", function()
    jump(current, 1)
  end)
  map("prev_conflict", function()
    jump(current, -1)
  end)
  map("stage", function()
    stage(current)
  end)
end

--- Public API -----------------------------------------------------------------------

---Open a conflicted file for resolution.
---@param repo GitRepository
---@param path string  repository-relative
function M.open(repo, path)
  if session then
    close_session()
  end

  local winid = window.open_file(path_util.join(repo.root, path), { cmd = "edit" })
  if not winid then
    return notify.error("Could not open " .. path)
  end
  local bufnr = vim.api.nvim_win_get_buf(winid)

  local augroup = vim.api.nvim_create_augroup("PickedConflictSession", { clear = true })

  session = {
    repo = repo,
    path = path,
    bufnr = bufnr,
    winid = winid,
    regions = {},
    augroup = augroup,
    side_buffers = {},
    side_winids = {},
  }

  install_keymaps(session)
  decorate(session)

  -- The markers change as the user resolves or edits; keep the decoration and
  -- the region list in step.
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
    group = augroup,
    buffer = bufnr,
    callback = function()
      if session then
        decorate(session)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = augroup,
    buffer = bufnr,
    callback = close_session,
  })

  if #session.regions == 0 then
    notify.info(("No conflict markers in %s — stage it if it is resolved"):format(path))
  else
    notify.info(
      ("%d conflict%s: o ours, t theirs, b both, ]x next, s stage"):format(
        #session.regions,
        #session.regions == 1 and "" or "s"
      )
    )
    vim.api.nvim_win_set_cursor(winid, { session.regions[1].ours_start, 0 })
  end
end

---Open the three-way view: ours and theirs flanking the working copy.
---
---The side panes are read-only snapshots from the index, so there is no doubt
---about which text came from which side.
---@param repo GitRepository
---@param path string
function M.three_way(repo, path)
  M.open(repo, path)
  local current = session
  if not current then
    return
  end

  git.conflicts.stages(repo, path, function(stages)
    if session ~= current or not vim.api.nvim_win_is_valid(current.winid) then
      return
    end

    close_sides()

    ---@param label string
    ---@param content string|nil
    ---@param placement "left"|"right"
    local function pane(label, content, placement)
      local side_bufnr = window.create_buffer({
        name = ("%s-%s"):format(label, path_util.basename(path)),
        filetype = "",
      })
      vim.bo[side_bufnr].modifiable = true
      vim.api.nvim_buf_set_lines(
        side_bufnr,
        0,
        -1,
        false,
        content and vim.split(content, "\n", { plain = true }) or { "(file absent on this side)" }
      )
      vim.bo[side_bufnr].modifiable = false
      vim.bo[side_bufnr].filetype = vim.filetype.match({ filename = path, buf = side_bufnr }) or ""

      vim.api.nvim_set_current_win(current.winid)
      vim.cmd(placement == "left" and "noautocmd leftabove vsplit" or "noautocmd rightbelow vsplit")
      local side_winid = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(side_winid, side_bufnr)
      vim.wo[side_winid].number = true
      vim.wo[side_winid].winbar = " " .. label:upper() .. " "

      vim.keymap.set("n", "q", function()
        close_sides()
      end, { buffer = side_bufnr, nowait = true, silent = true })

      current.side_buffers[#current.side_buffers + 1] = side_bufnr
      current.side_winids[#current.side_winids + 1] = side_winid
      return side_winid
    end

    pane("ours", stages.ours, "left")
    pane("theirs", stages.theirs, "right")

    vim.api.nvim_set_current_win(current.winid)
    vim.wo[current.winid].winbar = " RESULT — " .. path .. " "

    local hint = stages.base and "  B shows the merge base" or "  (no merge base: add/add conflict)"
    notify.info("Three-way view: OURS | RESULT | THEIRS" .. hint)
  end)
end

---Show the merge base of the conflicted file in a floating window.
function M.show_base()
  local current = session
  if not current then
    return notify.warn("No conflict session is open")
  end

  git.conflicts.stages(current.repo, current.path, function(stages)
    if not stages.base then
      return notify.info("This conflict has no merge base (both sides added the file)")
    end

    local bufnr = window.create_buffer({ name = "merge-base", filetype = "" })
    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(stages.base, "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = vim.filetype.match({ filename = current.path, buf = bufnr }) or ""

    local winid = window.open_float(bufnr, { title = "MERGE BASE — " .. current.path, width = 0.7, height = 0.6 })
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", lhs, function()
        window.close(winid)
        window.delete_buffer(bufnr)
      end, { buffer = bufnr, nowait = true, silent = true })
    end
  end)
end

---Rewrite the conflicted file using diff3 markers, so the base is visible
---inline even when the merge was recorded with the plain two-way style.
function M.show_base_inline()
  local current = session
  if not current then
    return notify.warn("No conflict session is open")
  end

  if vim.bo[current.bufnr].modified then
    return notify.warn("Save or undo your edits first")
  end

  git.conflicts.rematerialize(current.repo, current.path, "diff3", function(content, err)
    if err then
      return notify.error(err)
    end
    if not vim.api.nvim_buf_is_valid(current.bufnr) then
      return
    end
    vim.api.nvim_buf_set_lines(current.bufnr, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    decorate(current)
    notify.info("Rebuilt with diff3 markers — the merge base is now shown inline")
  end)
end

---Open the next conflicted file in the repository.
---@param repo GitRepository
function M.next_file(repo)
  git.conflicts.unmerged_paths(repo, function(paths, err)
    if err then
      return notify.error(err)
    end
    if not paths or #paths == 0 then
      return notify.success("No conflicts remain")
    end

    local currently = session and session.path or nil
    local target = paths[1]
    if currently then
      for index, path in ipairs(paths) do
        if path == currently then
          target = paths[index + 1] or paths[1]
          break
        end
      end
    end
    M.open(repo, target)
  end)
end

function M.close()
  close_session()
end

---@return boolean
function M.is_open()
  return session ~= nil
end

return M
