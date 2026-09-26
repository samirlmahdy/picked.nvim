---@brief A built-in fuzzy picker, with optional delegation.
---
---picked has no hard dependency on a picker framework, so it ships one: a
---prompt buffer plus a results buffer, filtering on every keystroke. When the
---user already has Snacks, Telescope or fzf-lua installed, the same call is
---routed there instead so the picker matches the rest of their editor.

local config = require("picked.config")
local render = require("picked.ui.render")
local text_util = require("picked.utils.text")
local window = require("picked.ui.window")

local M = {}

---@class PickedPickerItem
---@field text string  the string matched against the query
---@field display string|nil  what is drawn, defaults to `text`
---@field segments PickedSegment[]|nil  richer rendering, used instead of display
---@field value any  handed back to `on_select`

---@class PickedPickerOpts
---@field title string
---@field items PickedPickerItem[]
---@field on_select fun(value: any)
---@field on_cancel fun()|nil
---@field prompt string|nil
---@field initial_query string|nil
---@field actions table<string, fun(value: any, close: fun())>|nil  extra keys

--- Integration detection --------------------------------------------------------

---@param name string
---@return boolean
local function integration_enabled(name)
  local setting = config.options.integrations[name]
  if setting == false then
    return false
  end
  return true
end

---@param module string
---@return table|nil
local function try_require(module)
  local ok, loaded = pcall(require, module)
  return ok and loaded or nil
end

---Hand the picker off to the user's own picker if one is available.
---@param opts PickedPickerOpts
---@return boolean handled
local function delegate(opts)
  if integration_enabled("snacks") then
    local snacks = try_require("snacks")
    if snacks and snacks.picker then
      snacks.picker.pick({
        title = opts.title,
        items = vim.tbl_map(function(item)
          return { text = item.text, item = item }
        end, opts.items),
        format = function(picked)
          return { { picked.text } }
        end,
        confirm = function(picker, picked)
          picker:close()
          if picked and picked.item then
            opts.on_select(picked.item.value)
          end
        end,
      })
      return true
    end
  end

  if integration_enabled("fzf_lua") then
    local fzf = try_require("fzf-lua")
    if fzf then
      local lookup = {}
      local entries = {}
      for index, item in ipairs(opts.items) do
        local label = ("%d\t%s"):format(index, item.display or item.text)
        lookup[index] = item
        entries[#entries + 1] = label
      end
      fzf.fzf_exec(entries, {
        prompt = (opts.prompt or opts.title) .. "> ",
        actions = {
          ["default"] = function(selected)
            local index = tonumber((selected[1] or ""):match("^(%d+)\t"))
            local item = index and lookup[index]
            if item then
              opts.on_select(item.value)
            end
          end,
        },
      })
      return true
    end
  end

  return false
end

--- The built-in picker -----------------------------------------------------------

---@class PickedPickerSession
---@field prompt_bufnr integer
---@field prompt_winid integer
---@field list_bufnr integer
---@field list_winid integer
---@field results table[]
---@field selected integer
---@field canvas PickedCanvas|nil
---@field opts PickedPickerOpts
---@field closed boolean

---@type PickedPickerSession|nil
local session = nil

local list_namespace = vim.api.nvim_create_namespace("picked_picker")

local function close(cancelled)
  local current = session
  if not current or current.closed then
    return
  end
  current.closed = true
  session = nil

  vim.cmd("stopinsert")
  window.close(current.prompt_winid)
  window.close(current.list_winid)
  window.delete_buffer(current.prompt_bufnr)
  window.delete_buffer(current.list_bufnr)

  if cancelled and current.opts.on_cancel then
    vim.schedule(current.opts.on_cancel)
  end
end

---Rebuild the results list for the current query.
local function filter()
  local current = session
  if not current then
    return
  end

  local query = (vim.api.nvim_buf_get_lines(current.prompt_bufnr, 0, 1, false))[1] or ""
  current.results = text_util.fuzzy_filter(current.opts.items, query, function(item)
    return item.text
  end)
  current.selected = math.min(math.max(1, current.selected), math.max(1, #current.results))

  local canvas = render.new({ width = vim.api.nvim_win_get_width(current.list_winid) })

  if #current.results == 0 then
    canvas:text("  no matches", "PickedDim")
  else
    for index, result in ipairs(current.results) do
      local item = result.item
      local row = canvas:row({ index = index, value = item.value })
      local marker = index == current.selected and "▸ " or "  "
      row:add(marker, index == current.selected and "PickedKey" or nil, "select")

      if item.segments then
        for _, segment in ipairs(item.segments) do
          row:add(segment.text, segment.hl, "select")
        end
      else
        row:add(item.display or item.text, nil, "select")
      end

      if index == current.selected then
        row:highlight_line("PickedSelected")
      end
    end
  end

  current.canvas = canvas
  canvas:apply(current.list_bufnr, list_namespace)

  -- Highlight the characters that matched, so the reason a result is present
  -- is visible.
  for index, result in ipairs(current.results) do
    local item = result.item
    if not item.segments then
      local offset = 2
      for _, position in ipairs(result.positions or {}) do
        pcall(vim.api.nvim_buf_set_extmark, current.list_bufnr, list_namespace, index - 1, offset + position - 1, {
          end_col = offset + position,
          hl_group = "PickedMatch",
        })
      end
    end
  end

  if vim.api.nvim_win_is_valid(current.list_winid) and #current.results > 0 then
    pcall(vim.api.nvim_win_set_cursor, current.list_winid, { current.selected, 0 })
  end
end

---@param delta integer
local function move(delta)
  local current = session
  if not current or #current.results == 0 then
    return
  end
  local count = #current.results
  -- Wrapping is what every picker does and saves a long scroll back.
  current.selected = ((current.selected - 1 + delta) % count) + 1
  filter()
end

local function accept()
  local current = session
  if not current then
    return
  end
  local result = current.results[current.selected]
  if not result then
    return close(true)
  end
  local value = result.item.value
  local on_select = current.opts.on_select
  close(false)
  vim.schedule(function()
    on_select(value)
  end)
end

---Open the picker.
---@param opts PickedPickerOpts
function M.open(opts)
  if session then
    close(true)
  end

  if delegate(opts) then
    return
  end

  local geometry = window.centered_geometry({ width = 0.6, height = 0.5 })

  local prompt_bufnr = window.create_buffer({ name = "picker-prompt", filetype = "picked-picker", modifiable = true })
  vim.bo[prompt_bufnr].modifiable = true

  local list_bufnr = window.create_buffer({ name = "picker-list", filetype = "picked-picker-list" })

  local prompt_winid = window.open_float(prompt_bufnr, {
    title = opts.title,
    width = geometry.width,
    height = 1,
    row = geometry.row,
    col = geometry.col,
  })
  vim.wo[prompt_winid].cursorline = false

  local list_winid = window.open_float(list_bufnr, {
    width = geometry.width,
    height = math.max(3, geometry.height - 3),
    row = geometry.row + 3,
    col = geometry.col,
    enter = false,
    footer = "<CR> select   <C-n>/<C-p> move   <Esc> cancel",
  })
  vim.wo[list_winid].cursorline = false

  session = {
    prompt_bufnr = prompt_bufnr,
    prompt_winid = prompt_winid,
    list_bufnr = list_bufnr,
    list_winid = list_winid,
    results = {},
    selected = 1,
    opts = opts,
    closed = false,
  }

  if opts.initial_query and opts.initial_query ~= "" then
    vim.api.nvim_buf_set_lines(prompt_bufnr, 0, -1, false, { opts.initial_query })
  end

  vim.api.nvim_create_autocmd({ "TextChangedI", "TextChanged" }, {
    buffer = prompt_bufnr,
    callback = function()
      session.selected = 1
      filter()
    end,
  })

  local function map(lhs, handler)
    vim.keymap.set({ "i", "n" }, lhs, handler, { buffer = prompt_bufnr, silent = true, nowait = true })
  end

  map("<CR>", accept)
  map("<C-n>", function()
    move(1)
  end)
  map("<C-p>", function()
    move(-1)
  end)
  map("<Down>", function()
    move(1)
  end)
  map("<Up>", function()
    move(-1)
  end)
  map("<Esc>", function()
    close(true)
  end)
  map("<C-c>", function()
    close(true)
  end)

  for lhs, action in pairs(opts.actions or {}) do
    map(lhs, function()
      local result = session and session.results[session.selected]
      if result then
        action(result.item.value, function()
          close(false)
        end)
      end
    end)
  end

  if config.options.mouse.enabled then
    vim.keymap.set("n", "<LeftRelease>", function()
      local position = vim.fn.getmousepos()
      if not session or position.winid ~= session.list_winid then
        return
      end
      local item = session.canvas and session.canvas:item_at(position.line)
      if item then
        session.selected = item.index
        accept()
      end
    end, { buffer = list_bufnr, silent = true, nowait = true })
  end

  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = prompt_bufnr,
    once = true,
    callback = function()
      vim.schedule(function()
        close(true)
      end)
    end,
  })

  filter()
  vim.cmd("startinsert!")
end

--- Convenience pickers ---------------------------------------------------------

---Filter the files shown in a Source Control panel and jump to the chosen one.
---@param panel PickedPanel
function M.files(panel)
  local store = require("picked.state")
  local state = store.active()
  if not state or not state.status then
    return
  end

  local items = {}
  for _, entry in ipairs(state.status.files) do
    items[#items + 1] = {
      text = entry.path,
      segments = {
        { text = entry.status, hl = require("picked.ui.highlights").for_status(entry.status:sub(2, 2)) },
        { text = "  " },
        { text = entry.path },
      },
      value = entry,
    }
  end

  M.open({
    title = "Changed files",
    items = items,
    on_select = function(entry)
      panel:jump_to(function(item)
        return item.entry and item.entry.path == entry.path
      end)
    end,
  })
end

return M
