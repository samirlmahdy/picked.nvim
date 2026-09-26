---@brief Window and buffer construction helpers.
---
---All gitui windows are ordinary Neovim windows. Nothing here simulates a
---widget toolkit: a panel is a buffer in a split or a float, which means every
---Vim motion, `:wincmd`, window-picker plugin and terminal resize keeps
---working.

local config = require("gitui.config")

local M = {}

---Window-local options every gitui panel uses.
---@type table<string, any>
local PANEL_WINDOW_OPTIONS = {
  number = false,
  relativenumber = false,
  cursorline = true,
  cursorcolumn = false,
  foldcolumn = "0",
  spell = false,
  list = false,
  wrap = false,
  signcolumn = "no",
  colorcolumn = "",
  statuscolumn = "",
  winfixwidth = true,
  -- A panel is chrome, not content: dim it slightly relative to the editor.
  winhighlight = "Normal:GitUINormal,CursorLine:GitUICursorLine,FloatBorder:GitUIBorder",
}

---Create a scratch buffer configured for a read-only panel.
---@param opts { name: string, filetype: string, modifiable: boolean|nil, listed: boolean|nil }
---@return integer bufnr
function M.create_buffer(opts)
  local bufnr = vim.api.nvim_create_buf(opts.listed or false, true)

  vim.bo[bufnr].buftype = "nofile"
  vim.bo[bufnr].bufhidden = "hide"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].buflisted = opts.listed or false
  vim.bo[bufnr].modifiable = opts.modifiable or false
  vim.bo[bufnr].filetype = opts.filetype
  vim.bo[bufnr].undolevels = opts.modifiable and -1 or 100

  -- A unique name keeps `:ls` readable and lets users target the buffer.
  if opts.name then
    local unique = ("gitui://%s/%d"):format(opts.name, bufnr)
    pcall(vim.api.nvim_buf_set_name, bufnr, unique)
  end

  return bufnr
end

---Apply the standard panel window options.
---@param winid integer
---@param overrides table<string, any>|nil
function M.configure_window(winid, overrides)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  local options = vim.tbl_extend("force", PANEL_WINDOW_OPTIONS, overrides or {})
  for name, value in pairs(options) do
    pcall(function()
      vim.wo[winid][name] = value
    end)
  end
end

---Width the sidebar should use, clamped to something the terminal can show.
---@return integer
function M.sidebar_width()
  local requested = config.options.width
  local available = vim.o.columns
  -- Always leave room for a usable editor window beside the panel.
  return math.max(20, math.min(requested, math.floor(available * 0.6)))
end

---Open the sidebar split and put `bufnr` in it.
---@param bufnr integer
---@param opts { position: string|nil, width: integer|nil }|nil
---@return integer winid
function M.open_sidebar(bufnr, opts)
  opts = opts or {}
  local position = opts.position or config.options.position
  local width = opts.width or M.sidebar_width()

  -- `topleft`/`botright` place the split against the editor edge rather than
  -- splitting whatever window happens to be current.
  local modifier = position == "right" and "botright" or "topleft"
  vim.cmd(("noautocmd %s vertical %dsplit"):format(modifier, width))

  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  vim.api.nvim_win_set_width(winid, width)
  M.configure_window(winid)

  return winid
end

---Open a new window for editor content without ever splitting the sidebar.
---
---Splitting the sidebar would halve it and leave two narrow panels; the new
---window goes against the opposite edge instead, so the sidebar keeps its
---place and its width.
---@param bufnr integer
---@return integer winid
function M.open_beside_sidebar(bufnr)
  local modifier = config.options.position == "right" and "topleft" or "botright"
  vim.cmd(("noautocmd %s vertical split"):format(modifier))
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  return winid
end

---Undo the panel styling on a window that is being handed back to the user.
---@param winid integer
function M.restore_window(winid)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  for _, name in ipairs({ "winhighlight", "winbar", "statuscolumn", "colorcolumn" }) do
    pcall(function()
      vim.wo[winid][name] = ""
    end)
  end
  for name, value in pairs({
    number = vim.o.number,
    relativenumber = vim.o.relativenumber,
    cursorline = vim.o.cursorline,
    wrap = vim.o.wrap,
    list = vim.o.list,
    spell = vim.o.spell,
    signcolumn = vim.o.signcolumn,
    foldcolumn = vim.o.foldcolumn,
    winfixwidth = false,
  }) do
    pcall(function()
      vim.wo[winid][name] = value
    end)
  end
end

---Compute a centred floating-window geometry.
---@param opts { width: number|nil, height: number|nil, min_width: integer|nil, min_height: integer|nil }|nil
---@return { width: integer, height: integer, row: integer, col: integer }
function M.centered_geometry(opts)
  opts = opts or {}
  local float = config.options.float

  local columns = vim.o.columns
  local lines = vim.o.lines - vim.o.cmdheight - 1

  local function resolve(value, total, fallback, minimum)
    local resolved
    if not value then
      resolved = math.floor(total * fallback)
    elseif value <= 1 then
      resolved = math.floor(total * value)
    else
      resolved = math.floor(value)
    end
    return math.max(minimum or 1, math.min(resolved, total - 2))
  end

  local width = resolve(opts.width, columns, float.max_width, opts.min_width or 20)
  local height = resolve(opts.height, lines, float.max_height, opts.min_height or 3)

  return {
    width = width,
    height = height,
    row = math.max(0, math.floor((lines - height) / 2)),
    col = math.max(0, math.floor((columns - width) / 2)),
  }
end

---@class GitUIFloatOpts
---@field title string|nil
---@field footer string|nil
---@field width number|nil  absolute columns, or a fraction of the editor
---@field height number|nil
---@field min_width integer|nil
---@field min_height integer|nil
---@field row integer|nil
---@field col integer|nil
---@field border string|table|nil
---@field focusable boolean|nil
---@field zindex integer|nil
---@field relative string|nil
---@field style string|nil
---@field enter boolean|nil

---Open a floating window showing `bufnr`.
---@param bufnr integer
---@param opts GitUIFloatOpts|nil
---@return integer winid
function M.open_float(bufnr, opts)
  opts = opts or {}
  local geometry = M.centered_geometry(opts)

  ---@type vim.api.keyset.win_config
  local win_config = {
    relative = opts.relative or "editor",
    width = geometry.width,
    height = geometry.height,
    row = opts.row or geometry.row,
    col = opts.col or geometry.col,
    style = opts.style or "minimal",
    border = opts.border or config.options.float.border,
    focusable = opts.focusable ~= false,
    zindex = opts.zindex,
  }

  if opts.title then
    win_config.title = " " .. opts.title .. " "
    win_config.title_pos = "left"
  end
  if opts.footer then
    win_config.footer = " " .. opts.footer .. " "
    win_config.footer_pos = "right"
  end

  local winid = vim.api.nvim_open_win(bufnr, opts.enter ~= false, win_config)
  M.configure_window(winid, { winfixwidth = false })
  vim.wo[winid].winblend = config.options.float.winblend

  return winid
end

---Resize a float to fit its content, within the configured maximums.
---@param winid integer
---@param lines string[]
---@param opts { min_width: integer|nil, max_width: integer|nil, padding: integer|nil }|nil
function M.fit_float(winid, lines, opts)
  if not vim.api.nvim_win_is_valid(winid) then
    return
  end
  opts = opts or {}
  local text_util = require("gitui.utils.text")

  local widest = opts.min_width or 20
  for _, line in ipairs(lines) do
    widest = math.max(widest, text_util.width(line))
  end
  widest = widest + (opts.padding or 2)

  local max_width = opts.max_width or math.floor(vim.o.columns * config.options.float.max_width)
  local max_height = math.floor((vim.o.lines - vim.o.cmdheight - 2) * config.options.float.max_height)

  local width = math.min(widest, max_width)
  local height = math.min(math.max(#lines, 1), max_height)

  pcall(vim.api.nvim_win_set_config, winid, {
    relative = "editor",
    width = width,
    height = height,
    row = math.max(0, math.floor((vim.o.lines - vim.o.cmdheight - height) / 2)),
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
  })
end

---Close a window without disturbing the rest of the layout.
---@param winid integer|nil
function M.close(winid)
  if winid and vim.api.nvim_win_is_valid(winid) then
    -- `force = true` is safe here: gitui buffers are scratch buffers that
    -- never hold unsaved user work.
    pcall(vim.api.nvim_win_close, winid, true)
  end
end

---Delete a buffer and everything attached to it.
---@param bufnr integer|nil
function M.delete_buffer(bufnr)
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

---A window suitable for opening a file in: the most recently used ordinary
---window, never a gitui panel.
---
---This is what makes `<CR>` on a file feel native — the file lands where the
---user was editing, rather than replacing the panel.
---@param exclude integer[]|nil  window ids to skip
---@return integer|nil winid
function M.pick_editor_window(exclude)
  local excluded = {}
  for _, winid in ipairs(exclude or {}) do
    excluded[winid] = true
  end

  local function is_editor(winid)
    if excluded[winid] or not vim.api.nvim_win_is_valid(winid) then
      return false
    end
    if vim.api.nvim_win_get_config(winid).relative ~= "" then
      return false -- a float
    end
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local filetype = vim.bo[bufnr].filetype
    if filetype:match("^gitui") then
      return false
    end
    -- Sidebars belonging to other plugins are poor targets too.
    local buftype = vim.bo[bufnr].buftype
    return buftype == "" or buftype == "acwrite" or buftype == "help"
  end

  local current = vim.api.nvim_get_current_win()
  if is_editor(current) then
    return current
  end

  -- `wincmd p` order: prefer the window the user came from.
  local previous = vim.fn.win_getid(vim.fn.winnr("#"))
  if previous ~= 0 and is_editor(previous) then
    return previous
  end

  for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor(winid) then
      return winid
    end
  end

  return nil
end

---Open a file in an editor window, reusing an existing buffer and window where
---possible and preserving the user's layout.
---@param path string  absolute path
---@class GitUIOpenFileOpts
---@field cmd "edit"|"split"|"vsplit"|"tabedit"|nil
---@field lnum integer|nil
---@field col integer|nil
---@field exclude integer[]|nil  window ids that must not be reused
---@field focus boolean|nil  false returns the cursor to where it started
---@field dismiss_floats boolean|nil  false keeps floats open (rarely wanted)

---@param opts GitUIOpenFileOpts|nil
---@return integer|nil winid
function M.open_file(path, opts)
  opts = opts or {}

  -- A float would sit on top of the file we are about to show.
  if opts.dismiss_floats ~= false then
    require("gitui.ui.floats").close_all()
  end

  local path_util = require("gitui.utils.path")
  local target = path_util.to_os(path)
  local command = opts.cmd or "edit"

  local from = vim.api.nvim_get_current_win()
  local winid = M.pick_editor_window(opts.exclude)

  if not winid then
    -- Every window is a panel: make room beside the sidebar rather than
    -- splitting it in half.
    winid = M.open_beside_sidebar(vim.api.nvim_get_current_buf())
    command = "edit"
  end

  vim.api.nvim_set_current_win(winid)

  if command == "edit" then
    -- Reuse the buffer if it is already loaded, preserving its marks, undo
    -- history and cursor position.
    local existing = vim.fn.bufnr(target)
    if existing ~= -1 and vim.api.nvim_buf_is_loaded(existing) then
      vim.api.nvim_win_set_buf(winid, existing)
    else
      vim.cmd(("edit %s"):format(vim.fn.fnameescape(target)))
    end
  else
    vim.cmd(("%s %s"):format(command, vim.fn.fnameescape(target)))
    winid = vim.api.nvim_get_current_win()
  end

  if opts.lnum then
    local bufnr = vim.api.nvim_win_get_buf(winid)
    local last = vim.api.nvim_buf_line_count(bufnr)
    pcall(vim.api.nvim_win_set_cursor, winid, { math.min(opts.lnum, last), opts.col or 0 })
    vim.api.nvim_win_call(winid, function()
      vim.cmd("normal! zv")
    end)
  end

  if opts.focus == false and vim.api.nvim_win_is_valid(from) then
    vim.api.nvim_set_current_win(from)
  end

  return winid
end

---Is the terminal narrow enough that panels should drop decorations?
---@param width integer|nil
---@return boolean
function M.is_compact(width)
  return (width or vim.o.columns) < config.options.compact_width
end

return M
