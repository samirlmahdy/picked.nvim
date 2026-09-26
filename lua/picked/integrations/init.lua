---@brief Optional integrations.
---
---Every integration is detected at runtime and is entirely optional: picked's
---core depends on nothing but Neovim and git. Nothing here is required for any
---feature to work; these only make picked fit better into an editor that
---already has these plugins.

local config = require("picked.config")

local M = {}

---@param name string
---@return boolean
local function enabled(name)
  return config.options.integrations[name] ~= false
end

---@param module string
---@return table|nil
local function available(module)
  local ok, loaded = pcall(require, module)
  return ok and loaded or nil
end

M.available = available

--- which-key -----------------------------------------------------------------

---Describe picked's prefixes so which-key shows meaningful group names instead
---of a wall of raw keys.
local function setup_which_key()
  if not enabled("which_key") then
    return
  end
  local which_key = available("which-key")
  if not which_key or not which_key.add then
    return
  end

  local keys = config.options.global_keymaps
  local prefix = (keys.source_control or "<leader>gs"):match("^(.*)%a$") or "<leader>g"
  local hunk_prefix = (keys.stage_hunk or "<leader>hs"):match("^(.*)%a$") or "<leader>h"

  pcall(which_key.add, {
    { prefix, group = "git" },
    { hunk_prefix, group = "git hunk" },
  })
end

--- Telescope -----------------------------------------------------------------

---Register picked's telescope extension, if telescope is installed.
---
---The extension deliberately exposes pickers only; it does not try to
---reimplement the panel.
local function setup_telescope()
  if not enabled("telescope") then
    return
  end
  local telescope = available("telescope")
  if not telescope then
    return
  end
  -- Loading is lazy: registering here would force telescope to initialise.
  -- Users opt in with `require("telescope").load_extension("picked")`.
end

--- lualine -------------------------------------------------------------------

---A lualine component, for users who prefer a table to a function.
---
---    require("lualine").setup({
---      sections = { lualine_b = { require("picked.integrations").lualine() } },
---    })
---@param opts table|nil
---@return table
function M.lualine(opts)
  opts = opts or {}
  return vim.tbl_extend("force", {
    function()
      return require("picked").statusline(opts)
    end,
    cond = function()
      return require("picked").get_status().branch ~= nil
    end,
  }, opts.component or {})
end

--- Setup ---------------------------------------------------------------------

function M.setup()
  -- Deferred so an integration that is itself lazy-loaded has had a chance to
  -- appear before we look for it.
  vim.schedule(function()
    pcall(setup_which_key)
    pcall(setup_telescope)
  end)
end

---Names of the integrations that are actually present, for `:checkhealth`.
---@return table<string, boolean>
function M.detected()
  return {
    ["snacks.nvim"] = available("snacks") ~= nil,
    ["telescope.nvim"] = available("telescope") ~= nil,
    ["fzf-lua"] = available("fzf-lua") ~= nil,
    ["which-key.nvim"] = available("which-key") ~= nil,
    ["mini.icons"] = available("mini.icons") ~= nil,
    ["nvim-web-devicons"] = available("nvim-web-devicons") ~= nil,
  }
end

return M
