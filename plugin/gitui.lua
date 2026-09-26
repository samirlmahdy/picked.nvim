-- gitui.nvim command definitions.
--
-- Commands are registered eagerly but do no work until invoked, so the plugin
-- costs nothing at startup beyond this file. Each one calls into the public
-- API, which self-initialises if `setup()` has not run.

if vim.g.loaded_gitui then
  return
end
vim.g.loaded_gitui = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("gitui.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

---@param name string
---@param callback fun(args: vim.api.keyset.create_user_command.command_args)
---@param opts vim.api.keyset.user_command|nil
local function command(name, callback, opts)
  vim.api.nvim_create_user_command(name, callback, opts or {})
end

---@return table
local function gitui()
  return require("gitui")
end

--- Panel --------------------------------------------------------------------

command("GitUI", function()
  gitui().toggle()
end, { desc = "Toggle the gitui Source Control panel" })

command("GitUIOpen", function()
  gitui().open()
end, { desc = "Open the gitui Source Control panel" })

command("GitUIClose", function()
  gitui().close_all()
end, { desc = "Close every gitui window" })

command("GitUIToggle", function()
  gitui().toggle()
end, { desc = "Toggle the gitui Source Control panel" })

command("GitUIFocus", function()
  gitui().focus()
end, { desc = "Focus the gitui Source Control panel" })

command("GitUIRefresh", function(args)
  gitui().refresh({ all = args.bang })
end, { bang = true, desc = "Re-read repository state (! refreshes every repository)" })

--- Views --------------------------------------------------------------------

command("GitUIDiff", function(args)
  gitui().diff({
    all = args.args == "all",
    staged = args.args == "staged",
    split = args.bang,
  })
end, {
  nargs = "?",
  bang = true,
  complete = function()
    return { "all", "staged" }
  end,
  desc = "Diff the current file (! opens the side-by-side view)",
})

command("GitUIDiffView", function()
  gitui().toggle_diff_view()
end, { desc = "Toggle the diff between the unified patch and side-by-side" })

command("GitUILog", function(args)
  gitui().log({ all = args.bang })
end, { bang = true, desc = "Commit history (! includes every ref)" })

command("GitUIBranch", function()
  gitui().branches()
end, { desc = "Branches" })

command("GitUIStash", function()
  gitui().stash()
end, { desc = "Stashes" })

command("GitUIBlame", function()
  gitui().blame()
end, { desc = "Blame the current file" })

command("GitUIBlameLine", function()
  gitui().toggle_line_blame()
end, { desc = "Toggle the current-line blame virtual text" })

command("GitUIHistory", function(args)
  if args.range > 0 then
    gitui().line_history(args.line1, args.line2)
  else
    gitui().file_history()
  end
end, { range = true, desc = "History of the current file, or of the selected lines" })

command("GitUIPalette", function()
  gitui().palette()
end, { desc = "gitui command palette" })

command("GitUIRepositories", function()
  gitui().repositories()
end, { desc = "Switch the active repository" })

command("GitUIOutput", function()
  gitui().output()
end, { desc = "Show the raw output of recent git commands" })

command("GitUIDebugLog", function()
  gitui().show_log()
end, { desc = "Show gitui's own log" })

--- Operations ----------------------------------------------------------------

command("GitUICommit", function(args)
  local message = vim.trim(args.args)
  if message ~= "" then
    local repo = gitui()._resolve_repo()
    if repo then
      require("gitui.ui.commit").quick(repo, message, { amend = args.bang })
    end
    return
  end
  gitui().commit({ amend = args.bang })
end, { nargs = "*", bang = true, desc = "Commit (! amends; an argument is used as the message)" })

command("GitUIPush", function(args)
  if args.bang then
    gitui().force_push()
  else
    gitui().push()
  end
end, { bang = true, desc = "Push (! force-pushes with lease)" })

command("GitUIPull", function()
  gitui().pull()
end, { desc = "Pull" })

command("GitUIFetch", function(args)
  gitui().fetch({ all = args.bang })
end, { bang = true, desc = "Fetch (! fetches every remote)" })

command("GitUIStage", function(args)
  gitui().stage(#args.fargs > 0 and args.fargs or nil)
end, { nargs = "*", complete = "file", desc = "Stage paths, or the current file" })

command("GitUIUnstage", function(args)
  gitui().unstage(#args.fargs > 0 and args.fargs or nil)
end, { nargs = "*", complete = "file", desc = "Unstage paths, or the current file" })

--- Hunks ----------------------------------------------------------------------

command("GitUIStageHunk", function(args)
  if args.range > 0 then
    gitui().hunk.stage(args.line1, args.line2)
  else
    gitui().hunk.stage()
  end
end, { range = true, desc = "Stage the hunk under the cursor, or the selected lines" })

command("GitUIUnstageHunk", function()
  gitui().hunk.unstage()
end, { desc = "Unstage the hunk under the cursor" })

command("GitUIDiscardHunk", function(args)
  if args.range > 0 then
    gitui().hunk.discard(args.line1, args.line2)
  else
    gitui().hunk.discard()
  end
end, { range = true, desc = "Discard the hunk under the cursor, or the selected lines" })

command("GitUIPreviewHunk", function()
  gitui().hunk.preview()
end, { desc = "Preview the hunk under the cursor" })

command("GitUINextHunk", function()
  gitui().hunk.next()
end, { desc = "Jump to the next hunk" })

command("GitUIPrevHunk", function()
  gitui().hunk.prev()
end, { desc = "Jump to the previous hunk" })

command("GitUIToggleSigns", function()
  require("gitui.ui.signs").toggle()
end, { desc = "Toggle the git sign column" })

--- Conflicts -------------------------------------------------------------------

command("GitUIConflict", function(args)
  local repo = gitui()._resolve_repo()
  if not repo then
    return
  end
  if args.bang then
    local path_util = require("gitui.utils.path")
    local file = path_util.buffer_path(0)
    local relative = file and path_util.relative(file, repo.root)
    if relative then
      return require("gitui.ui.conflict").three_way(repo, relative)
    end
  end
  require("gitui.ui.conflict").next_file(repo)
end, { bang = true, desc = "Go to the next conflict (! opens the three-way view here)" })

--- Maintenance ------------------------------------------------------------------

command("GitUIReset", function()
  gitui().reset()
  vim.notify("gitui reset", vim.log.levels.INFO)
end, { desc = "Release every gitui resource (for development)" })

command("GitUIHealth", function()
  vim.cmd("checkhealth gitui")
end, { desc = "Run gitui's health checks" })
