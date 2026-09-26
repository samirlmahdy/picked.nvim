---@brief Confirmation dialogs for destructive operations.
---
---A confirmation must make three things obvious: what will change, that it
---cannot be undone, and how to say no. The default answer is always "no", and
---`<Esc>`, `q` and `n` all cancel — there is no way to destroy work by
---mashing Enter.

local icons = require("picked.utils.icons")
local render = require("picked.ui.render")
local text_util = require("picked.utils.text")
local window = require("picked.ui.window")

local M = {}

---@class PickedConfirmOpts
---@field title string  what is about to happen
---@field message string|nil  one-line explanation
---@field details string[]|nil  the concrete items affected
---@field warning string|nil  the consequence, e.g. "This cannot be undone."
---@field confirm_label string|nil  defaults to "Yes"
---@field cancel_label string|nil  defaults to "No"
---@field destructive boolean|nil  styles the dialog as dangerous
---@field default boolean|nil  true makes Enter confirm; defaults to false

local MAX_DETAILS = 12

---Ask the user to confirm.
---@param opts PickedConfirmOpts
---@param callback fun(confirmed: boolean)
function M.ask(opts, callback)
  local bufnr = window.create_buffer({ name = "confirm", filetype = "picked-confirm" })
  local canvas = render.new({ width = 60 })

  local confirm_label = opts.confirm_label or "Yes"
  local cancel_label = opts.cancel_label or "No"

  canvas:blank()
  canvas:row(nil):add("  "):add(opts.title, opts.destructive and "PickedError" or "PickedTitle")

  if opts.message then
    canvas:blank()
    for _, line in ipairs(vim.split(opts.message, "\n", { plain = true })) do
      canvas:row(nil):add("  "):add(line)
    end
  end

  if opts.details and #opts.details > 0 then
    canvas:blank()
    for index, detail in ipairs(opts.details) do
      if index > MAX_DETAILS then
        canvas:row(nil):add("  "):add(("… and %d more"):format(#opts.details - MAX_DETAILS), "PickedDim")
        break
      end
      canvas:row(nil):add("  "):add(icons.get("bullet"), "PickedDim"):add(" "):add(detail, "PickedModified")
    end
  end

  if opts.warning then
    canvas:blank()
    canvas:row(nil):add("  "):add(icons.get("warning") .. " ", "PickedWarning"):add(opts.warning, "PickedWarning")
  end

  canvas:blank()
  local buttons = canvas:row(nil)
  buttons:add("  ")
  buttons:add("[y]", "PickedKey", "confirm")
  buttons:add(" " .. confirm_label, opts.destructive and "PickedError" or "PickedNormal", "confirm")
  buttons:add("   ")
  buttons:add("[n]", "PickedKey", "cancel")
  buttons:add(" " .. cancel_label, nil, "cancel")
  buttons:add("   ")
  buttons:add("<Esc>", "PickedDim", "cancel")
  buttons:add(" cancel", "PickedDim", "cancel")
  canvas:blank()

  local namespace = vim.api.nvim_create_namespace("picked_confirm")
  canvas:apply(bufnr, namespace)

  local lines = canvas:lines()
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, text_util.width(line) + 4)
  end
  width = math.min(width, math.floor(vim.o.columns * 0.8))

  local winid = window.open_float(bufnr, {
    title = opts.destructive and "Confirm" or "Confirm",
    width = width,
    height = #lines,
    min_height = 3,
    border = "rounded",
  })
  vim.wo[winid].cursorline = false

  local answered = false
  local function answer(value)
    if answered then
      return
    end
    answered = true
    window.close(winid)
    window.delete_buffer(bufnr)
    vim.schedule(function()
      callback(value)
    end)
  end

  local function map(lhs, value)
    vim.keymap.set("n", lhs, function()
      answer(value)
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  map("y", true)
  map("Y", true)
  map("n", false)
  map("N", false)
  map("q", false)
  map("<Esc>", false)
  -- Enter follows the declared default, which is "no" unless stated otherwise.
  map("<CR>", opts.default == true)

  if require("picked.config").options.mouse.enabled then
    vim.keymap.set("n", "<LeftRelease>", function()
      local position = vim.fn.getmousepos()
      if position.winid ~= winid then
        return
      end
      local action = canvas:action_at(position.line, math.max(0, position.column - 1))
      if action == "confirm" then
        answer(true)
      elseif action == "cancel" then
        answer(false)
      end
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  -- Leaving the dialog by any route counts as declining.
  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      answer(false)
    end,
  })
end

---Confirm only when the corresponding `confirm.*` option is enabled.
---
---Disabling a confirmation is an explicit opt-in to an unsafe mode, so the
---check lives here rather than being duplicated at every call site.
---@param key string  a key of `config.options.confirm`
---@param opts PickedConfirmOpts
---@param callback fun(confirmed: boolean)
function M.guard(key, opts, callback)
  local config = require("picked.config")
  if config.options.confirm[key] == false then
    return callback(true)
  end
  M.ask(opts, callback)
end

---Choose one of several options.
---
---Used where a yes/no answer would hide a meaningful decision, such as the
---merge-versus-rebase choice when pulling.
---@alias PickedChoice { key: string, label: string, description: string|nil, value: any }
---@param opts { title: string, message: string|nil, choices: PickedChoice[] }
---@param callback fun(value: any|nil)
function M.choose(opts, callback)
  local bufnr = window.create_buffer({ name = "choose", filetype = "picked-choose" })
  local canvas = render.new({ width = 60 })

  canvas:blank()
  canvas:row(nil):add("  "):add(opts.title, "PickedTitle")
  if opts.message then
    canvas:blank()
    canvas:row(nil):add("  "):add(opts.message, "PickedDim")
  end
  canvas:blank()

  for index, choice in ipairs(opts.choices) do
    local row = canvas:row({ index = index, value = choice.value })
    row:add("  ")
    row:add("[" .. choice.key .. "]", "PickedKey", "choose")
    row:add(" ")
    row:add(choice.label, "PickedNormal", "choose")
    if choice.description then
      row:add("  ")
      row:add(choice.description, "PickedDim", "choose")
    end
  end
  canvas:blank()
  canvas:row(nil):add("  "):add("<Esc>", "PickedDim"):add(" cancel", "PickedDim")
  canvas:blank()

  local namespace = vim.api.nvim_create_namespace("picked_choose")
  canvas:apply(bufnr, namespace)

  local lines = canvas:lines()
  local width = 40
  for _, line in ipairs(lines) do
    width = math.max(width, text_util.width(line) + 4)
  end

  local winid = window.open_float(bufnr, {
    title = "Choose",
    width = math.min(width, math.floor(vim.o.columns * 0.8)),
    height = #lines,
    min_height = 3,
  })

  local answered = false
  local function answer(value)
    if answered then
      return
    end
    answered = true
    window.close(winid)
    window.delete_buffer(bufnr)
    vim.schedule(function()
      callback(value)
    end)
  end

  for _, choice in ipairs(opts.choices) do
    vim.keymap.set("n", choice.key, function()
      answer(choice.value)
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  vim.keymap.set("n", "<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local item = canvas:item_at(cursor[1])
    if item then
      answer(item.value)
    end
  end, { buffer = bufnr, nowait = true, silent = true })

  for _, lhs in ipairs({ "<Esc>", "q" }) do
    vim.keymap.set("n", lhs, function()
      answer(nil)
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  if require("picked.config").options.mouse.enabled then
    vim.keymap.set("n", "<LeftRelease>", function()
      local position = vim.fn.getmousepos()
      if position.winid ~= winid then
        return
      end
      local item = canvas:item_at(position.line)
      if item then
        answer(item.value)
      end
    end, { buffer = bufnr, nowait = true, silent = true })
  end

  vim.api.nvim_create_autocmd({ "WinLeave", "BufLeave" }, {
    buffer = bufnr,
    once = true,
    callback = function()
      answer(nil)
    end,
  })

  -- Start on the first choice so <CR> is immediately meaningful.
  local first = canvas:find(function()
    return true
  end)
  if first then
    pcall(vim.api.nvim_win_set_cursor, winid, { first, 0 })
  end
end

return M
