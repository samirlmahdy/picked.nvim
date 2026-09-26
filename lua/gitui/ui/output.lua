---@brief The git output buffer.
---
---git's stderr is never swallowed. Anything a command printed — a push's
---transfer log, a hook's rejection message, a merge's conflict summary — is
---kept here and reachable with `:GitUIOutput`, so a one-line notification is
---never the whole story.

local render = require("gitui.ui.render")
local window = require("gitui.ui.window")

local M = {}

---@class GitUIOutputEntry
---@field title string
---@field text string
---@field time integer
---@field ok boolean

local HISTORY_LIMIT = 30

---@type GitUIOutputEntry[]
local history = {}

local winid = nil
local bufnr = nil
local namespace = vim.api.nvim_create_namespace("gitui_output")

---Record command output.
---@param title string
---@param text string
---@param ok boolean|nil
function M.store(title, text, ok)
  if not text or text == "" then
    return
  end
  table.insert(history, 1, {
    title = title,
    text = text,
    time = os.time(),
    ok = ok == true,
  })
  while #history > HISTORY_LIMIT do
    table.remove(history)
  end

  -- Keep an open window current.
  if winid and vim.api.nvim_win_is_valid(winid) then
    M.render()
  end
end

---@return GitUIOutputEntry|nil
function M.latest()
  return history[1]
end

---@return GitUIOutputEntry[]
function M.history()
  return history
end

function M.clear()
  history = {}
  if winid and vim.api.nvim_win_is_valid(winid) then
    M.render()
  end
end

function M.render()
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local canvas = render.new({ width = vim.o.columns })

  if #history == 0 then
    canvas:text("No git output has been recorded yet.", "GitUIDim")
    canvas:blank()
    canvas:text("Output from push, pull, fetch, commit and merge appears here.", "GitUIDim")
    canvas:apply(bufnr, namespace)
    return
  end

  for index, entry in ipairs(history) do
    if index > 1 then
      canvas:blank()
      canvas:rule()
      canvas:blank()
    end

    local icons = require("gitui.utils.icons")
    local header = canvas:row(nil)
    header:add(entry.ok and icons.get("success") or icons.get("failure"), entry.ok and "GitUISuccess" or "GitUIError")
    header:add(" ")
    header:add(entry.title, "GitUITitle")
    header:add("  ")
    header:add(os.date("%H:%M:%S", entry.time), "GitUIDate")
    canvas:blank()

    for _, line in ipairs(vim.split(entry.text, "\n", { plain = true })) do
      -- git's progress meter overwrites a line with carriage returns; show
      -- only the final state of each.
      local cleaned = line:gsub("^.*\r", "")
      canvas:text(cleaned)
    end
  end

  canvas:apply(bufnr, namespace)
end

---Open the output window.
---@param opts { focus: boolean|nil }|nil
function M.open(opts)
  opts = opts or {}

  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    bufnr = window.create_buffer({ name = "output", filetype = "gitui-output" })
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", lhs, M.close, { buffer = bufnr, nowait = true, silent = true })
    end
    vim.keymap.set("n", "C", M.clear, { buffer = bufnr, nowait = true, silent = true, desc = "gitui: clear output" })
  end

  if not winid or not vim.api.nvim_win_is_valid(winid) then
    winid = window.open_float(bufnr, {
      title = "GIT OUTPUT",
      footer = "q close   C clear",
      width = 0.8,
      height = 0.7,
      enter = opts.focus ~= false,
    })
    vim.wo[winid].wrap = true
    vim.wo[winid].cursorline = false
  end

  M.render()
end

function M.close()
  window.close(winid)
  winid = nil
end

function M.toggle()
  if winid and vim.api.nvim_win_is_valid(winid) then
    M.close()
  else
    M.open()
  end
end

return M
