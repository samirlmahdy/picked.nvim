---@brief Contextual menus.
---
---Menus are a convenience for mouse users and a discovery aid for everyone
---else; they are never the only route to an action. Each entry shows the
---keyboard mapping that performs the same thing, so using the menu teaches
---the key.

local render = require("gitui.ui.render")
local text_util = require("gitui.utils.text")
local window = require("gitui.ui.window")

local M = {}

---@class GitUIMenuEntry
---@field label string
---@field key string|nil  the equivalent keyboard mapping, shown on the right
---@field action fun()|nil
---@field separator boolean|nil
---@field disabled boolean|nil
---@field destructive boolean|nil

---@class GitUIMenuOpts
---@field title string|nil
---@field entries GitUIMenuEntry[]
---@field anchor { lnum: integer, col: integer, winid: integer }|nil

local open_winid = nil
local open_bufnr = nil

---Close any open menu.
function M.close()
  if open_winid then
    window.close(open_winid)
    open_winid = nil
  end
  if open_bufnr then
    window.delete_buffer(open_bufnr)
    open_bufnr = nil
  end
end

---Open a contextual menu.
---@param opts GitUIMenuOpts
function M.open(opts)
  M.close()

  local entries = vim.tbl_filter(function(entry)
    return entry ~= nil
  end, opts.entries or {})
  if #entries == 0 then
    return
  end

  local bufnr = window.create_buffer({ name = "menu", filetype = "gitui-menu" })
  local canvas = render.new({ width = 40 })

  local widest_label = 0
  local widest_key = 0
  for _, entry in ipairs(entries) do
    if not entry.separator then
      widest_label = math.max(widest_label, text_util.width(entry.label))
      widest_key = math.max(widest_key, text_util.width(entry.key or ""))
    end
  end

  for index, entry in ipairs(entries) do
    if entry.separator then
      canvas:row(nil):add(string.rep("─", widest_label + widest_key + 5), "GitUISeparator")
    else
      local row = canvas:row({ index = index, entry = entry })
      row:add(" ")
      local hl = entry.disabled and "GitUIDim" or (entry.destructive and "GitUIError" or nil)
      row:add(entry.label, hl, "activate")
      if entry.key then
        row:pad_to(widest_label + 3)
        row:add(entry.key, "GitUIKey", "activate")
      end
      row:add(" ")
    end
  end

  local namespace = vim.api.nvim_create_namespace("gitui_menu")
  canvas:apply(bufnr, namespace)

  local lines = canvas:lines()
  local width = 0
  for _, line in ipairs(lines) do
    width = math.max(width, text_util.width(line))
  end
  width = math.max(width + 1, 18)

  -- Anchor the menu under the pointer when we know where that was, clamped to
  -- stay on screen.
  local row, col
  if opts.anchor and vim.api.nvim_win_is_valid(opts.anchor.winid) then
    local position = vim.fn.screenpos(opts.anchor.winid, opts.anchor.lnum, opts.anchor.col + 1)
    row = position.row
    col = position.col
  end
  if not row or row == 0 then
    local geometry = window.centered_geometry({ width = width, height = #lines })
    row, col = geometry.row, geometry.col
  end
  row = math.min(row, math.max(0, vim.o.lines - vim.o.cmdheight - #lines - 2))
  col = math.min(col, math.max(0, vim.o.columns - width - 2))

  open_bufnr = bufnr
  open_winid = window.open_float(bufnr, {
    title = opts.title,
    width = width,
    height = #lines,
    min_height = 1,
    row = row,
    col = col,
    zindex = 200,
  })

  local function activate(item)
    if not item or not item.entry or item.entry.disabled or not item.entry.action then
      return
    end
    local action = item.entry.action
    M.close()
    vim.schedule(action)
  end

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(open_winid)
    activate(canvas:item_at(cursor[1]))
  end, { buffer = bufnr, nowait = true, silent = true })

  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, M.close, { buffer = bufnr, nowait = true, silent = true })
  end

  if require("gitui.config").options.mouse.enabled then
    vim.keymap.set("n", "<LeftRelease>", function()
      local position = vim.fn.getmousepos()
      if position.winid ~= open_winid then
        return M.close()
      end
      activate(canvas:item_at(position.line))
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  -- Assign each entry its own shortcut key so the menu stays keyboard-first.
  for index, entry in ipairs(entries) do
    if not entry.separator and not entry.disabled and index <= 9 then
      vim.keymap.set("n", tostring(index), function()
        activate({ entry = entry })
      end, { buffer = bufnr, nowait = true, silent = true })
    end
  end

  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      vim.schedule(M.close)
    end,
  })

  -- Land on the first actionable entry.
  local first = canvas:find(function(item)
    return item.entry and not item.entry.disabled
  end)
  if first then
    pcall(vim.api.nvim_win_set_cursor, open_winid, { first, 0 })
  end
end

return M
