-- picked.nvim command definitions.
--
-- Commands are registered eagerly but do no work until invoked, so the plugin
-- costs nothing at startup beyond this file. Each one calls into the public
-- API, which self-initialises if `setup()` has not run.

if vim.g.loaded_picked then
  return
end
vim.g.loaded_picked = true

if vim.fn.has("nvim-0.10") == 0 then
  vim.notify("picked.nvim requires Neovim 0.10 or newer", vim.log.levels.ERROR)
  return
end

---@param name string
---@param callback fun(args: vim.api.keyset.create_user_command.command_args)
---@param opts vim.api.keyset.user_command|nil
local function command(name, callback, opts)
  vim.api.nvim_create_user_command(name, callback, opts or {})
end

---@return table
local function picked()
  return require("picked")
end

--- Panel --------------------------------------------------------------------

command("Picked", function()
  picked().toggle()
end, { desc = "Toggle the picked Source Control panel" })

command("PickedOpen", function()
  picked().open()
end, { desc = "Open the picked Source Control panel" })

command("PickedClose", function()
  picked().close_all()
end, { desc = "Close every picked window" })

command("PickedToggle", function()
  picked().toggle()
end, { desc = "Toggle the picked Source Control panel" })

command("PickedFocus", function()
  picked().focus()
end, { desc = "Focus the picked Source Control panel" })

command("PickedRefresh", function(args)
  picked().refresh({ all = args.bang })
end, { bang = true, desc = "Re-read repository state (! refreshes every repository)" })

--- Views --------------------------------------------------------------------

command("PickedDiff", function(args)
  picked().diff({
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

command("PickedDiffView", function()
  picked().toggle_diff_view()
end, { desc = "Toggle the diff between the unified patch and side-by-side" })

command("PickedLog", function(args)
  picked().log({ all = args.bang })
end, { bang = true, desc = "Commit history (! includes every ref)" })

command("PickedBranch", function()
  picked().branches()
end, { desc = "Branches" })

command("PickedStash", function()
  picked().stash()
end, { desc = "Stashes" })

command("PickedBlame", function()
  picked().blame()
end, { desc = "Blame the current file" })

command("PickedBlameLine", function()
  picked().toggle_line_blame()
end, { desc = "Toggle the current-line blame virtual text" })

command("PickedHistory", function(args)
  if args.range > 0 then
    picked().line_history(args.line1, args.line2)
  else
    picked().file_history()
  end
end, { range = true, desc = "History of the current file, or of the selected lines" })

command("PickedPalette", function()
  picked().palette()
end, { desc = "picked command palette" })

command("PickedRepositories", function()
  picked().repositories()
end, { desc = "Switch the active repository" })

command("PickedOutput", function()
  picked().output()
end, { desc = "Show the raw output of recent git commands" })

command("PickedDebugLog", function()
  picked().show_log()
end, { desc = "Show picked's own log" })

--- Operations ----------------------------------------------------------------

command("PickedCommit", function(args)
  local message = vim.trim(args.args)
  if message ~= "" then
    local repo = picked()._resolve_repo()
    if repo then
      require("picked.ui.commit").quick(repo, message, { amend = args.bang })
    end
    return
  end
  picked().commit({ amend = args.bang })
end, { nargs = "*", bang = true, desc = "Commit (! amends; an argument is used as the message)" })

command("PickedPush", function(args)
  if args.bang then
    picked().force_push()
  else
    picked().push()
  end
end, { bang = true, desc = "Push (! force-pushes with lease)" })

command("PickedPull", function()
  picked().pull()
end, { desc = "Pull" })

command("PickedFetch", function(args)
  picked().fetch({ all = args.bang })
end, { bang = true, desc = "Fetch (! fetches every remote)" })

command("PickedStage", function(args)
  picked().stage(#args.fargs > 0 and args.fargs or nil)
end, { nargs = "*", complete = "file", desc = "Stage paths, or the current file" })

command("PickedUnstage", function(args)
  picked().unstage(#args.fargs > 0 and args.fargs or nil)
end, { nargs = "*", complete = "file", desc = "Unstage paths, or the current file" })

--- Hunks ----------------------------------------------------------------------

command("PickedStageHunk", function(args)
  if args.range > 0 then
    picked().hunk.stage(args.line1, args.line2)
  else
    picked().hunk.stage()
  end
end, { range = true, desc = "Stage the hunk under the cursor, or the selected lines" })

command("PickedUnstageHunk", function()
  picked().hunk.unstage()
end, { desc = "Unstage the hunk under the cursor" })

command("PickedDiscardHunk", function(args)
  if args.range > 0 then
    picked().hunk.discard(args.line1, args.line2)
  else
    picked().hunk.discard()
  end
end, { range = true, desc = "Discard the hunk under the cursor, or the selected lines" })

command("PickedPreviewHunk", function()
  picked().hunk.preview()
end, { desc = "Preview the hunk under the cursor" })

command("PickedNextHunk", function()
  picked().hunk.next()
end, { desc = "Jump to the next hunk" })

command("PickedPrevHunk", function()
  picked().hunk.prev()
end, { desc = "Jump to the previous hunk" })

command("PickedToggleSigns", function()
  require("picked.ui.signs").toggle()
end, { desc = "Toggle the git sign column" })

--- Conflicts -------------------------------------------------------------------

command("PickedConflict", function(args)
  local repo = picked()._resolve_repo()
  if not repo then
    return
  end
  if args.bang then
    local path_util = require("picked.utils.path")
    local file = path_util.buffer_path(0)
    local relative = file and path_util.relative(file, repo.root)
    if relative then
      return require("picked.ui.conflict").three_way(repo, relative)
    end
  end
  require("picked.ui.conflict").next_file(repo)
end, { bang = true, desc = "Go to the next conflict (! opens the three-way view here)" })

--- Maintenance ------------------------------------------------------------------

command("PickedReset", function()
  picked().reset()
  vim.notify("picked reset", vim.log.levels.INFO)
end, { desc = "Release every picked resource (for development)" })

command("PickedHealth", function()
  vim.cmd("checkhealth picked")
end, { desc = "Run picked's health checks" })
