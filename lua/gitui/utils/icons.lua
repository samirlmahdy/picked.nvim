---@brief Icon set with automatic ASCII fallback.
---
---Nerd fonts are never required. When `config.icons` is "auto" the plugin
---probes for a glyph-capable environment and silently downgrades to ASCII,
---because a row of tofu boxes is worse than plain text.
---
---Every icon is paired with a text label elsewhere in the UI, so the interface
---remains fully legible with icons disabled.

local M = {}

local NERD = {
  -- Structure
  chevron_closed = "",
  chevron_open = "",
  folder = "",
  folder_open = "",
  file = "",
  -- Status
  added = "",
  modified = "",
  deleted = "",
  renamed = "",
  copied = "",
  untracked = "",
  ignored = "",
  conflict = "",
  staged = "",
  submodule = "",
  -- Git objects
  branch = "",
  remote = "",
  tag = "",
  commit = "",
  stash = "",
  merge = "",
  -- Feedback
  spinner = { "⠋", "⠙", "⠹", "⠸", "⠼", "⠴", "⠦", "⠧", "⠇", "⠏" },
  success = "✓",
  failure = "✗",
  warning = "⚠",
  info = "ℹ",
  arrow_up = "↑",
  arrow_down = "↓",
  separator = "│",
  bullet = "●",
  dot = "·",
  graph_commit = "●",
  graph_line = "│",
}

local ASCII = {
  chevron_closed = ">",
  chevron_open = "v",
  folder = "/",
  folder_open = "/",
  file = " ",
  added = "A",
  modified = "M",
  deleted = "D",
  renamed = "R",
  copied = "C",
  untracked = "?",
  ignored = "!",
  conflict = "!",
  staged = "+",
  submodule = "S",
  branch = "@",
  remote = "^",
  tag = "#",
  commit = "*",
  stash = "$",
  merge = "Y",
  spinner = { "|", "/", "-", "\\" },
  success = "+",
  failure = "x",
  warning = "!",
  info = "i",
  arrow_up = "^",
  arrow_down = "v",
  separator = "|",
  bullet = "*",
  dot = ".",
  graph_commit = "*",
  graph_line = "|",
}

---@type table<string, any>
M.set = ASCII

---Heuristic: can this UI render nerd-font glyphs?
---@return boolean
local function detect()
  -- A GUI or a terminal that advertises 256+ colours is usually paired with a
  -- patched font; `vim.g.have_nerd_font` lets users state it explicitly.
  if vim.g.have_nerd_font ~= nil then
    return vim.g.have_nerd_font and true or false
  end
  -- mini.icons / nvim-web-devicons being installed is strong evidence the user
  -- already relies on glyphs.
  for _, module in ipairs({ "mini.icons", "nvim-web-devicons" }) do
    if pcall(require, module) then
      return true
    end
  end
  if vim.fn.has("gui_running") == 1 or vim.g.neovide or vim.g.nvy then
    return true
  end
  local term = vim.env.TERM_PROGRAM
  if term == "WezTerm" or term == "iTerm.app" or term == "ghostty" or term == "kitty" or term == "Apple_Terminal" then
    return true
  end
  if vim.env.KITTY_WINDOW_ID or vim.env.ALACRITTY_WINDOW_ID or vim.env.WEZTERM_PANE then
    return true
  end
  return false
end

---@param setting boolean|"auto"
function M.setup(setting)
  local use_nerd
  if setting == "auto" then
    use_nerd = detect()
  else
    use_nerd = setting and true or false
  end
  M.set = use_nerd and NERD or ASCII
  M.nerd = use_nerd
end

---@param name string
---@return string
function M.get(name)
  local value = M.set[name]
  if type(value) == "string" then
    return value
  end
  return ""
end

---Icon for a single-letter git status code.
---@param code string
---@return string
function M.for_status(code)
  local map = {
    M = "modified",
    A = "added",
    D = "deleted",
    R = "renamed",
    C = "copied",
    ["?"] = "untracked",
    ["!"] = "ignored",
    U = "conflict",
    T = "modified",
  }
  return M.get(map[code] or "file")
end

---Filetype icon for a path, delegating to whichever icon provider is present.
---Returns an empty string (and no highlight) when neither is installed.
---@param path string
---@return string icon, string|nil highlight
function M.for_file(path)
  if not M.nerd then
    return "", nil
  end

  local ok, mini = pcall(require, "mini.icons")
  if ok and mini.get then
    local icon, hl = mini.get("file", path)
    return icon or "", hl
  end

  local ok_dev, devicons = pcall(require, "nvim-web-devicons")
  if ok_dev then
    local name = vim.fn.fnamemodify(path, ":t")
    local ext = name:match("%.([^.]+)$") or ""
    local icon, hl = devicons.get_icon(name, ext, { default = true })
    return icon or "", hl
  end

  return M.get("file"), nil
end

return M
