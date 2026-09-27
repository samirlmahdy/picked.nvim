---@brief Base class for every picked panel.
---
---Owns the parts that must be identical everywhere and are easy to get subtly
---wrong in eight separate places: buffer options, keymap installation from the
---user's configuration, cursor preservation across redraws, mouse dispatch,
---and — most importantly — deterministic teardown. When a panel closes, its
---autocommands, keymaps, timers and extmarks go with it.

local config = require("picked.config")
local logger = require("picked.utils.logger")
local render = require("picked.ui.render")
local window = require("picked.ui.window")
local winsize = require("picked.ui.winsize")

local M = {}

---@class PickedPanelSpec
---@field name string  unique identifier, also used for the filetype
---@field title string|fun(self: PickedPanel): string
---@field layout "sidebar"|"float"|"split"|"tab"|"editor"
---@field keymap_group string|nil  section of `config.keymaps` to install
---@field float PickedFloatOpts|nil
---@field render fun(self: PickedPanel, canvas: PickedCanvas)
---@field actions table<string, fun(self: PickedPanel, item: any)>
---@field visual_actions table<string, fun(self: PickedPanel, first: integer, last: integer)>|nil
---@field hints { key: string, label: string }[]|fun(self: PickedPanel): table[]|nil
---@field on_open fun(self: PickedPanel)|nil
---@field on_close fun(self: PickedPanel)|nil
---@field on_cursor fun(self: PickedPanel, item: any)|nil
---@field context_menu fun(self: PickedPanel, item: any): table[]|nil

---@class PickedPanel
---@field spec PickedPanelSpec
---@field bufnr integer|nil
---@field winid integer|nil
---@field canvas PickedCanvas|nil
---@field namespace integer
---@field augroup integer|nil
---@field data table  view-specific state
local Panel = {}
Panel.__index = Panel

---@type table<string, PickedPanel>
local registry = {}

---@param spec PickedPanelSpec
---@return PickedPanel
function M.new(spec)
  local panel = setmetatable({
    spec = spec,
    bufnr = nil,
    winid = nil,
    canvas = nil,
    namespace = vim.api.nvim_create_namespace("picked_" .. spec.name),
    augroup = nil,
    data = {},
    _cleanup = {},
  }, Panel)

  registry[spec.name] = panel
  return panel
end

---@param name string
---@return PickedPanel|nil
function M.get(name)
  return registry[name]
end

---@return PickedPanel[]
function M.all()
  local panels = {}
  for _, panel in pairs(registry) do
    panels[#panels + 1] = panel
  end
  return panels
end

---Close every open panel. Used by `:PickedClose` and on teardown.
function M.close_all()
  for _, panel in pairs(registry) do
    if panel:is_open() then
      panel:close()
    end
  end
end

--- Lifecycle -----------------------------------------------------------------

---@return boolean
function Panel:is_open()
  return self.winid ~= nil and vim.api.nvim_win_is_valid(self.winid)
end

---@return boolean
function Panel:is_focused()
  return self:is_open() and vim.api.nvim_get_current_win() == self.winid
end

---@return string
function Panel:title()
  if type(self.spec.title) == "function" then
    return self.spec.title(self)
  end
  return self.spec.title or self.spec.name
end

---Width available for rendering.
---@return integer
function Panel:width()
  if self:is_open() then
    return vim.api.nvim_win_get_width(self.winid)
  end
  if self.spec.layout == "sidebar" then
    return window.sidebar_width()
  end
  return math.floor(vim.o.columns * 0.8)
end

---Create the buffer if it does not exist yet.
---@return integer bufnr
function Panel:ensure_buffer()
  if self.bufnr and vim.api.nvim_buf_is_valid(self.bufnr) then
    return self.bufnr
  end

  self.bufnr = window.create_buffer({
    name = self.spec.name,
    filetype = "picked-" .. self.spec.name:gsub("_", "-"),
  })

  self:install_keymaps()
  self:install_autocmds()

  return self.bufnr
end

---@param opts { focus: boolean|nil, position: string|nil }|nil
---@return PickedPanel
function Panel:open(opts)
  opts = opts or {}

  if self:is_open() then
    if opts.focus ~= false then
      self:focus()
    end
    return self
  end

  local bufnr = self:ensure_buffer()
  local previous_win = vim.api.nvim_get_current_win()

  if self.spec.layout == "float" then
    -- One float at a time. Stacking history on top of branches on top of a
    -- menu buries whichever one the user actually wants, and dismissing them
    -- one by one is nobody's idea of navigation.
    require("picked.ui.floats").close_all({ except = self })

    local float_opts = vim.tbl_extend("force", self.spec.float or {}, { title = self:title() })
    self.winid = window.open_float(bufnr, float_opts)
  elseif self.spec.layout == "tab" then
    vim.cmd("tabnew")
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, bufnr)
    window.configure_window(self.winid, { winfixwidth = false })
  elseif self.spec.layout == "split" then
    vim.cmd("botright split")
    self.winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(self.winid, bufnr)
    window.configure_window(self.winid, { winfixwidth = false })
  elseif self.spec.layout == "editor" then
    -- Take over the main editing area rather than adding more chrome: a diff
    -- wants the space, and the sidebar stays where it is.
    local target = window.pick_editor_window()
    if target then
      self.winid = target
      -- Borrowing someone's window means giving it back. Closing this panel
      -- must restore whatever was here, not destroy the window — that would
      -- leave the sidebar as the only window and stretched to full width.
      self.data.borrowed_buf = vim.api.nvim_win_get_buf(target)
      self.data.created_window = false
      vim.api.nvim_win_set_buf(target, bufnr)
    else
      self.winid = window.open_beside_sidebar(bufnr)
      self.data.borrowed_buf = nil
      self.data.created_window = true
    end
    window.configure_window(self.winid, { winfixwidth = false, number = false })
  else
    self.winid = window.open_sidebar(bufnr, { position = opts.position })
    self.data.width = self.data.width or window.sidebar_width()
    -- Claim before the window is ever focused: once 'winwidth' has stretched
    -- the sidebar, the stretched value is indistinguishable from a resize the
    -- user asked for.
    winsize.claim("panel:" .. self.spec.name, "winwidth", self.data.width)
    self.data.win_count = #vim.api.nvim_tabpage_list_wins(0)
  end

  self:redraw()

  if opts.focus == false and vim.api.nvim_win_is_valid(previous_win) then
    vim.api.nvim_set_current_win(previous_win)
  end

  if self.spec.on_open then
    self.spec.on_open(self)
  end

  local events = require("picked.utils.events")
  events.emit(events.names.PANEL_OPENED, { panel = self.spec.name })

  return self
end

function Panel:focus()
  if self:is_open() then
    vim.api.nvim_set_current_win(self.winid)
  end
end

---Close the panel's window, keeping its buffer so reopening is instant.
function Panel:close()
  if not self:is_open() then
    return
  end

  local winid = self.winid
  self.winid = nil
  winsize.release("panel:" .. self.spec.name)

  -- Remember where the user was so reopening lands in the same place.
  if vim.api.nvim_win_is_valid(winid) then
    local ok, cursor = pcall(vim.api.nvim_win_get_cursor, winid)
    if ok then
      self.data.last_cursor = cursor
    end
  end

  -- A borrowed window is handed back with its original buffer rather than
  -- closed: the user asked to dismiss a diff, not to lose the window they
  -- were editing in. Closing it would also leave the sidebar as the only
  -- window, stretched across the whole screen.
  local borrowed = self.data.borrowed_buf
  self.data.borrowed_buf = nil

  local returned = false
  if
    borrowed
    and not self.data.created_window
    and vim.api.nvim_win_is_valid(winid)
    and vim.api.nvim_buf_is_valid(borrowed)
  then
    returned = pcall(vim.api.nvim_win_set_buf, winid, borrowed)
    if returned then
      window.restore_window(winid)
    end
  end

  if not returned then
    -- Either we created the window, or the buffer that was here has been
    -- wiped while the diff was open.
    window.close(winid)
  end

  if self.spec.on_close then
    self.spec.on_close(self)
  end

  local events = require("picked.utils.events")
  events.emit(events.names.PANEL_CLOSED, { panel = self.spec.name })
end

---@param opts table|nil
function Panel:toggle(opts)
  if self:is_open() then
    self:close()
  else
    self:open(opts)
  end
end

---Release every resource this panel owns.
function Panel:destroy()
  self:close()

  for _, cleanup in ipairs(self._cleanup) do
    pcall(cleanup)
  end
  self._cleanup = {}

  if self.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, self.augroup)
    self.augroup = nil
  end

  window.delete_buffer(self.bufnr)
  self.bufnr = nil
  self.canvas = nil
end

---Register a function to run when the panel is destroyed.
---@param fn fun()
function Panel:on_destroy(fn)
  self._cleanup[#self._cleanup + 1] = fn
end

--- Rendering -----------------------------------------------------------------

---Rebuild and reapply the panel's contents, preserving the cursor.
function Panel:redraw()
  if not self.bufnr or not vim.api.nvim_buf_is_valid(self.bufnr) then
    return
  end

  local cursor = nil
  if self:is_open() then
    local ok, position = pcall(vim.api.nvim_win_get_cursor, self.winid)
    if ok then
      cursor = position
    end
  end
  cursor = cursor or self.data.last_cursor

  -- Remember what the cursor was pointing *at*, not just where it was: after a
  -- stage the row moves to another section, and following the item is what the
  -- user expects.
  local anchor = cursor and self.canvas and self.canvas:item_at(cursor[1]) or nil

  local canvas = render.new({ width = self:width() })
  local ok, err = pcall(self.spec.render, self, canvas)
  if not ok then
    logger.error("panel render failed for", self.spec.name, err)
    canvas = render.new({ width = self:width() })
    canvas:text("Rendering failed. See :PickedLog for details.", "PickedError")
  end

  self.canvas = canvas
  canvas:apply(self.bufnr, self.namespace)

  if self:is_open() then
    local target = nil
    if anchor and anchor.id then
      target = canvas:find(function(item)
        return item.id == anchor.id
      end)
    end
    target = target or (cursor and cursor[1]) or 1
    self:set_cursor(target)
  end
end

---Decide what to do when the sidebar is the only window on screen.
---
---Neovim has to give every column to something, so a lone sidebar is always
---full width. `last_window` chooses whether to accept that, park an empty
---window beside it, or close the panel.
function Panel:handle_last_window()
  local mode = config.options.last_window

  if mode == "close" then
    return vim.schedule(function()
      if self:is_open() and #vim.api.nvim_tabpage_list_wins(0) <= 1 then
        self:close()
      end
    end)
  end

  if mode ~= "keep_width" or self.data.suppress_placeholder then
    return
  end

  -- Never fight a quit: during exit there is nothing to preserve, and
  -- conjuring a window would stop `:q` from finishing.
  if vim.v.exiting ~= vim.NIL or self.data.placing then
    return
  end

  self.data.placing = true
  local previous = vim.api.nvim_get_current_win()

  local ok = pcall(function()
    -- A listed, ordinary empty buffer: the user can `:edit` straight into it.
    local empty = vim.api.nvim_create_buf(true, false)
    local modifier = config.options.position == "right" and "topleft" or "botright"
    vim.cmd(("noautocmd %s vertical split"):format(modifier))
    local placeholder = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(placeholder, empty)
    self.data.placeholder_win = placeholder
  end)

  if ok and vim.api.nvim_win_is_valid(previous) then
    vim.api.nvim_set_current_win(previous)
  end
  self.data.placing = false

  if ok then
    pcall(vim.api.nvim_win_set_width, self.winid, self.data.width)
    self.data.win_count = #vim.api.nvim_tabpage_list_wins(0)
  end
end

---Hold the sidebar at its configured width.
---
---Neovim redistributes space whenever a window opens or closes, and
---'winfixwidth' only limits that — it does not pin an exact value, so the
---sidebar drifts a column at a time and stretches to fill the screen whenever
---it is briefly the only window.
---
---A width change that happens *without* the window count changing is the user
---resizing deliberately, and is adopted rather than undone.
function Panel:enforce_width()
  if self.spec.layout ~= "sidebar" or not self:is_open() then
    return
  end

  local wins = #vim.api.nvim_tabpage_list_wins(0)
  local ok, actual = pcall(vim.api.nvim_win_get_width, self.winid)
  if not ok then
    return
  end

  self.data.width = self.data.width or window.sidebar_width()

  -- Without this the sidebar is stretched to 'winwidth' every time it is
  -- focused — with the common `winwidth=80` a 40-column panel became 80, and
  -- the branch below then mistook that for a deliberate resize and kept it.
  winsize.claim("panel:" .. self.spec.name, "winwidth", self.data.width)

  if wins <= 1 then
    -- Alone on screen there is nothing to take space from; do not record this
    -- width as the user's preference.
    self.data.win_count = wins
    self:handle_last_window()
    return
  end

  -- Another window exists again, so a placeholder is welcome next time.
  self.data.suppress_placeholder = false

  -- A width that exactly matches the user's 'winwidth' while the sidebar is
  -- the current window is Neovim widening it, not the user dragging it. Only
  -- reachable if 'winwidth' was raised after the panel opened — the claim
  -- above prevents it otherwise — but adopting it would make the stretch
  -- permanent, so it is worth ruling out.
  local stretched = actual == winsize.user_value("winwidth") and vim.api.nvim_get_current_win() == self.winid

  if wins == self.data.win_count and actual ~= self.data.width and not stretched then
    self.data.width = actual -- a deliberate resize
  elseif actual ~= self.data.width then
    pcall(vim.api.nvim_win_set_width, self.winid, self.data.width)
  end

  self.data.win_count = wins
end

---Move the cursor to a line, clamped to the buffer.
---
---A nil or out-of-range line is a no-op rather than an error: callers derive
---line numbers from canvas lookups that legitimately return nothing when the
---view is empty, and a panel must never take the editor down with it.
---@param lnum integer|nil
---@param col integer|nil
function Panel:set_cursor(lnum, col)
  if not self:is_open() or type(lnum) ~= "number" then
    return
  end
  local count = vim.api.nvim_buf_line_count(self.bufnr)
  lnum = math.max(1, math.min(lnum, count))
  pcall(vim.api.nvim_win_set_cursor, self.winid, { lnum, col or 0 })
  self.data.last_cursor = { lnum, col or 0 }
end

---Move the cursor to the first row whose item satisfies `predicate`.
---@param predicate fun(item: any): boolean
---@return boolean found
function Panel:jump_to(predicate)
  if not self.canvas then
    return false
  end
  local lnum = self.canvas:find(predicate)
  if lnum then
    self:set_cursor(lnum)
    return true
  end
  return false
end

---Item under the cursor.
---@return any|nil
function Panel:item()
  if not self:is_open() or not self.canvas then
    return nil
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, self.winid)
  if not ok then
    return nil
  end
  return self.canvas:item_at(cursor[1])
end

---@return integer lnum
function Panel:cursor_line()
  if not self:is_open() then
    return 1
  end
  local ok, cursor = pcall(vim.api.nvim_win_get_cursor, self.winid)
  return ok and cursor[1] or 1
end

---Items covered by a line range, deduplicated by identity.
---@param first integer
---@param last integer
---@return any[]
function Panel:items_in_range(first, last)
  if not self.canvas then
    return {}
  end
  local seen, out = {}, {}
  for lnum = first, last do
    local item = self.canvas:item_at(lnum)
    if item and not seen[item] then
      seen[item] = true
      out[#out + 1] = item
    end
  end
  return out
end

---The visual selection's line range, usable from a normal-mode mapping that
---was invoked with `:<C-u>`.
---@return integer first, integer last
function Panel:visual_range()
  local first = vim.fn.line("v")
  local last = vim.fn.line(".")
  if first > last then
    first, last = last, first
  end
  return first, last
end

--- Keymaps -------------------------------------------------------------------

---Resolve an action's configured left-hand sides.
---@param action string
---@return string[]
function Panel:keys_for(action)
  local keymaps = config.options.keymaps
  local group = self.spec.keymap_group and keymaps[self.spec.keymap_group] or nil

  local lhs = nil
  if group and group[action] ~= nil then
    lhs = group[action]
  elseif keymaps.common[action] ~= nil then
    lhs = keymaps.common[action]
  end

  if lhs == false or lhs == nil then
    return {}
  end
  if type(lhs) == "string" then
    return { lhs }
  end
  return lhs
end

---@param mode string|string[]
---@param lhs string
---@param rhs fun()
---@param desc string
function Panel:map(mode, lhs, rhs, desc)
  vim.keymap.set(mode, lhs, rhs, {
    buffer = self.bufnr,
    nowait = true,
    silent = true,
    desc = "picked: " .. desc,
  })
end

function Panel:install_keymaps()
  local actions = self.spec.actions or {}

  for action, handler in pairs(actions) do
    for _, lhs in ipairs(self:keys_for(action)) do
      self:map("n", lhs, function()
        handler(self, self:item())
      end, action:gsub("_", " "))
    end
  end

  for action, handler in pairs(self.spec.visual_actions or {}) do
    for _, lhs in ipairs(self:keys_for(action)) do
      self:map("x", lhs, function()
        local first, last = self:visual_range()
        -- Leave visual mode before acting so the operation's own prompts and
        -- window changes are not fighting the selection.
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<Esc>", true, false, true), "nx", false)
        handler(self, first, last)
      end, action:gsub("_", " "))
    end
  end

  -- Universal panel bindings. These are installed for every panel and are
  -- resolved from `keymaps.common`, so a user can rebind them once.
  if not actions.close then
    for _, lhs in ipairs(self:keys_for("close")) do
      self:map("n", lhs, function()
        self:close()
      end, "close")
    end
  end

  if not actions.help then
    for _, lhs in ipairs(self:keys_for("help")) do
      self:map("n", lhs, function()
        require("picked.ui.help").show(self)
      end, "help")
    end
  end

  for _, lhs in ipairs(self:keys_for("palette")) do
    self:map("n", lhs, function()
      require("picked.ui.palette").open()
    end, "command palette")
  end

  self:install_mouse()
end

function Panel:install_mouse()
  if not config.options.mouse.enabled then
    return
  end
  local mouse = require("picked.ui.mouse")
  mouse.attach(self)
end

--- Autocommands ---------------------------------------------------------------

function Panel:install_autocmds()
  self.augroup = vim.api.nvim_create_augroup("PickedPanel_" .. self.spec.name, { clear = true })

  -- Closing the window by any means (`:q`, `:only`, a window picker) must run
  -- the same teardown as `Panel:close()`.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = self.augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if closed and closed == self.winid then
        self.winid = nil
        if self.spec.on_close then
          self.spec.on_close(self)
        end
      end
      -- Closing the placeholder is the user saying they want the space back.
      -- Recreating it would make `:q` appear to do nothing.
      if closed and closed == self.data.placeholder_win then
        self.data.placeholder_win = nil
        self.data.suppress_placeholder = true
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWipeout", {
    group = self.augroup,
    buffer = self.bufnr,
    callback = function()
      self.bufnr = nil
      self.canvas = nil
    end,
  })

  -- Re-render on resize so the responsive layout actually responds.
  vim.api.nvim_create_autocmd({ "VimResized", "WinResized" }, {
    group = self.augroup,
    callback = function()
      if self:is_open() then
        vim.schedule(function()
          self:redraw()
        end)
      end
    end,
  })

  -- 'winfixwidth' is not enough on its own: closing the last other window
  -- stretches the sidebar across the screen, and the next split gives it back
  -- a column short. Re-assert the width whenever the layout changes.
  if self.spec.layout == "sidebar" then
    vim.api.nvim_create_autocmd({ "WinClosed", "WinNew", "WinResized", "VimResized", "TabEnter" }, {
      group = self.augroup,
      callback = function()
        vim.schedule(function()
          self:enforce_width()
        end)
      end,
    })
  end

  if self.spec.on_cursor then
    local debounce = require("picked.utils.debounce")
    local notify_cursor = debounce.trailing(function()
      if self:is_open() and self.spec.on_cursor then
        self.spec.on_cursor(self, self:item())
      end
    end, config.options.diff.preview_delay)

    vim.api.nvim_create_autocmd("CursorMoved", {
      group = self.augroup,
      buffer = self.bufnr,
      callback = notify_cursor,
    })
  end
end

--- Hints ----------------------------------------------------------------------

---The key hints to show in the footer, already resolved to configured keys.
---@return { key: string, label: string }[]
function Panel:hints()
  local hints = self.spec.hints
  if type(hints) == "function" then
    hints = hints(self)
  end
  if not hints then
    return {}
  end

  local resolved = {}
  for _, hint in ipairs(hints) do
    local keys = self:keys_for(hint.key)
    if #keys > 0 then
      resolved[#resolved + 1] = { key = keys[1], label = hint.label }
    end
  end
  return resolved
end

---Append the hint footer to a canvas, if hints are enabled and there is room.
---@param canvas PickedCanvas
function Panel:render_hints(canvas)
  if not config.options.hints then
    return
  end
  local hints = self:hints()
  if #hints == 0 then
    return
  end
  canvas:blank()
  render.hint_footer(canvas, hints, self:width())
end

M.Panel = Panel

return M
