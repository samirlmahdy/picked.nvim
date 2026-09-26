---@brief `:checkhealth picked`.
---
---Checks the things that actually break picked in the field: a missing or
---ancient git, a broken configuration, a terminal that cannot render the
---configured icons, and mappings the user's own config has already claimed.

local M = {}

local health = vim.health

---@param name string
---@return boolean
local function has_module(name)
  return pcall(require, name)
end

local function check_neovim()
  health.start("Neovim")

  if vim.fn.has("nvim-0.10") == 1 then
    health.ok("Neovim " .. tostring(vim.version()))
  else
    health.error("picked requires Neovim 0.10 or newer", {
      "Upgrade Neovim; picked uses vim.system, vim.uv and extmark signs unconditionally.",
    })
  end

  if vim.o.mouse ~= "" then
    health.ok("'mouse' is set to '" .. vim.o.mouse .. "' — mouse support is available")
  else
    health.info("'mouse' is empty — picked's mouse support is inactive (every action still has a key)")
  end
end

local function check_git()
  health.start("git")

  local command = require("picked.git.command")
  local executable, err = command.executable()

  if not executable then
    return health.error(err or "git not found", {
      "Install git and make sure it is on the PATH Neovim sees.",
      "Check with :lua vim.print(vim.fn.exepath('git'))",
    })
  end
  health.ok("git executable: " .. executable)

  local version = command.version()
  if not version then
    return health.warn("could not determine the git version")
  end

  if command.version_at_least(2, 23) then
    health.ok("git " .. version)
  elseif command.version_at_least(2, 20) then
    health.warn("git " .. version .. " — `git restore`/`switch` are unavailable", {
      "picked falls back to `git reset`/`checkout`, which behave the same here.",
      "Upgrading to git 2.23+ is recommended.",
    })
  else
    health.error("git " .. version .. " is older than picked supports", {
      "Upgrade to git 2.20 or newer; 2.23+ is recommended.",
    })
  end

  if not command.version_at_least(2, 31) then
    health.info("git < 2.31: repository detection uses relative path resolution (supported, slightly slower)")
  end
end

local function check_repository()
  health.start("Repository")

  local repository = require("picked.git.repository")
  local repo, err = repository.current()

  if not repo then
    return health.info("not inside a git repository right now (" .. tostring(err) .. ")")
  end

  health.ok("repository: " .. repo.root)
  if repo.is_linked_worktree then
    health.info("this is a linked worktree; shared git dir: " .. repo.common_dir)
  end
  if repo.is_bare then
    health.warn("this is a bare repository — there is no working tree to stage from")
  end

  local state = repository.state(repo)
  if state.kind ~= "normal" then
    health.info("in progress: " .. state.label)
  end

  local head = repository.head(repo)
  if head.unborn then
    health.info("HEAD is unborn (no commits yet)")
  elseif head.detached then
    health.info("HEAD is detached at " .. tostring(head.short))
  else
    health.ok("on branch " .. tostring(head.branch))
  end
end

local function check_config()
  health.start("Configuration")

  local config = require("picked.config")
  local options = config.options

  health.ok("position: " .. options.position .. ", width: " .. tostring(options.width))

  -- Only report confirmations the user actively turned off. Several entries
  -- default to `false` because the operation is not destructive (push, pull,
  -- a soft reset), and flagging those would train people to ignore this
  -- section.
  local defaults = config.defaults().confirm
  local disabled = {}
  for key, value in pairs(options.confirm) do
    if value == false and defaults[key] == true then
      disabled[#disabled + 1] = key
    end
  end
  table.sort(disabled)

  if #disabled == 0 then
    health.ok("every destructive operation asks for confirmation")
  else
    health.warn("confirmation disabled for: " .. table.concat(disabled, ", "), {
      "These destructive operations will run without asking.",
      "That is an explicit opt-in to an unsafe mode; remove the override to restore the prompt.",
    })
  end

  if options.remote.force_push_mode == "force" then
    health.warn("force_push_mode is 'force'", {
      "'with-lease' refuses to overwrite commits you have not seen. Prefer it unless you have a specific reason.",
    })
  else
    health.ok("force pushes use --force-with-lease")
  end

  if options.signs.enabled then
    health.ok("inline signs enabled (debounce " .. tostring(options.signs.debounce) .. "ms)")
  else
    health.info("inline signs disabled")
  end

  if options.auto_refresh then
    health.ok("auto refresh on, debounced at " .. tostring(options.refresh_debounce) .. "ms")
  else
    health.info("auto refresh disabled — use :PickedRefresh")
  end

  if options.file_watch then
    health.ok("filesystem watching enabled")
  else
    health.info("filesystem watching disabled; refreshes come from autocommands only")
  end
end

local function check_icons()
  health.start("Icons")

  local icons = require("picked.utils.icons")
  if icons.nerd then
    health.ok("using nerd-font glyphs")
    health.info("if you see tofu boxes, set `icons = false` or `vim.g.have_nerd_font = false`")
  else
    health.ok("using the ASCII fallback — no patched font required")
    health.info("set `icons = true` (or `vim.g.have_nerd_font = true`) to enable glyphs")
  end
end

local function check_keymaps()
  health.start("Keymaps")

  local config = require("picked.config")
  if not config.options.default_keymaps then
    return health.info("default keymaps disabled")
  end

  local conflicts = {}
  for action, lhs in pairs(config.options.global_keymaps) do
    if type(lhs) == "string" and lhs ~= "" then
      local existing = vim.fn.maparg(lhs, "n", false, true)
      if existing and existing.desc and not tostring(existing.desc):match("^picked") and existing.buffer == 0 then
        conflicts[#conflicts + 1] = ("%s (%s) is already mapped to: %s"):format(
          lhs,
          action,
          existing.desc or existing.rhs or "?"
        )
      end
    end
  end

  if #conflicts == 0 then
    health.ok("no conflicts with existing global mappings")
  else
    health.warn("some default mappings were skipped because they are already taken", conflicts)
    health.info("picked never overwrites an existing mapping; rebind via `global_keymaps` if you want them")
  end
end

local function check_integrations()
  health.start("Optional integrations")

  local detected = require("picked.integrations").detected()
  local names = vim.tbl_keys(detected)
  table.sort(names)

  for _, name in ipairs(names) do
    if detected[name] then
      health.ok(name .. " detected")
    else
      health.info(name .. " not installed (optional)")
    end
  end

  if not detected["snacks.nvim"] and not detected["telescope.nvim"] and not detected["fzf-lua"] then
    health.info("no picker framework found — picked uses its own built-in picker")
  end
end

local function check_runtime()
  health.start("Runtime state")

  local store = require("picked.state")
  local count = store.count()
  if count == 0 then
    health.info("no repositories tracked yet")
  else
    health.ok(("tracking %d repositor%s"):format(count, count == 1 and "y" or "ies"))
    for _, state in ipairs(store.list()) do
      local marker = state.repo.root == store.active_root() and " (active)" or ""
      health.info("  " .. state.repo.root .. marker)
    end
  end

  local logger = require("picked.utils.logger")
  health.info("log level: " .. logger.get_level() .. "   file: " .. logger.file())
end

function M.check()
  if not has_module("picked") then
    return health.error("picked is not on the runtimepath")
  end

  check_neovim()
  check_git()
  check_repository()
  check_config()
  check_icons()
  check_keymaps()
  check_integrations()
  check_runtime()
end

return M
