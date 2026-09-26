-- Minimal init used by the test runner. Keeps the plugin under test and
-- plenary on the runtimepath and nothing else, so tests never depend on the
-- developer's personal configuration.

local function find_plenary()
  if vim.env.PLENARY_PATH and vim.fn.isdirectory(vim.env.PLENARY_PATH) == 1 then
    return vim.env.PLENARY_PATH
  end
  local candidates = {
    vim.fn.getcwd() .. "/.tests/plenary.nvim",
    vim.fn.stdpath("data") .. "/lazy/plenary.nvim",
    vim.fn.stdpath("data") .. "/site/pack/packer/start/plenary.nvim",
    vim.fn.stdpath("data") .. "/plugged/plenary.nvim",
  }
  for _, candidate in ipairs(candidates) do
    if vim.fn.isdirectory(candidate) == 1 then
      return candidate
    end
  end
  return nil
end

local root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")

vim.opt.runtimepath:prepend(root)

-- `tests/` lives outside `lua/`, so make `require("tests.helpers")` resolve
-- both `tests/helpers.lua` and `tests/helpers/init.lua`.
package.path = table.concat({
  root .. "/?.lua",
  root .. "/?/init.lua",
  package.path,
}, ";")

local plenary = find_plenary()
if plenary then
  vim.opt.runtimepath:append(plenary)
else
  io.stderr:write("plenary.nvim not found; run scripts/test.sh which installs it\n")
end

vim.opt.swapfile = false
vim.opt.shadafile = "NONE"
vim.opt.more = false
vim.opt.termguicolors = true

-- Tests exercise git heavily; make sure the child processes are deterministic.
vim.env.GIT_AUTHOR_NAME = "picked test"
vim.env.GIT_AUTHOR_EMAIL = "test@picked.invalid"
vim.env.GIT_COMMITTER_NAME = "picked test"
vim.env.GIT_COMMITTER_EMAIL = "test@picked.invalid"
vim.env.GIT_CONFIG_GLOBAL = "/dev/null"
vim.env.GIT_CONFIG_SYSTEM = "/dev/null"

require("picked.config").setup({ log_level = "off", default_keymaps = false })
