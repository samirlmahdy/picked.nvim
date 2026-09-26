---@brief The command palette.
---
---One searchable list of everything gitui can do, so a capability the user has
---not memorised a key for is still one fuzzy search away. Commands that make
---no sense right now (unstage with nothing staged, continue with no rebase in
---progress) are simply absent rather than failing when chosen.

local notify = require("gitui.ui.notify")
local operations = require("gitui.operations")
local repository = require("gitui.git.repository")
local store = require("gitui.state")

local M = {}

---@class GitUIPaletteCommand
---@field name string
---@field group string
---@field run fun(repo: GitRepository)
---@field available fun(state: RepositoryState|nil): boolean|nil

---@return GitUIPaletteCommand[]
local function commands()
  ---@type GitUIPaletteCommand[]
  local list = {
    {
      group = "View",
      name = "Source Control panel",
      run = function()
        require("gitui.ui.source_control").toggle()
      end,
    },
    {
      group = "View",
      name = "Commit history",
      run = function(repo)
        require("gitui.ui.log").open(repo, {})
      end,
    },
    {
      group = "View",
      name = "Branches",
      run = function(repo)
        require("gitui.ui.branches").open(repo)
      end,
    },
    {
      group = "View",
      name = "Stashes",
      run = function(repo)
        require("gitui.ui.stash").open(repo)
      end,
    },
    {
      group = "View",
      name = "Git output",
      run = function()
        require("gitui.ui.output").open()
      end,
    },

    {
      group = "Stage",
      name = "Stage all changes",
      available = function(state)
        return state and state.status and #state.status.unstaged > 0
      end,
      run = function(repo)
        operations.stage_all(repo)
      end,
    },
    {
      group = "Stage",
      name = "Unstage all changes",
      available = function(state)
        return state and state.status and #state.status.staged > 0
      end,
      run = function(repo)
        operations.unstage_all(repo)
      end,
    },
    {
      group = "Stage",
      name = "Stage hunk under the cursor",
      run = function()
        require("gitui.ui.signs").stage_hunk()
      end,
    },
    {
      group = "Stage",
      name = "Unstage hunk under the cursor",
      run = function()
        require("gitui.ui.signs").unstage_hunk()
      end,
    },
    {
      group = "Stage",
      name = "Discard hunk under the cursor",
      run = function()
        require("gitui.ui.signs").discard_hunk()
      end,
    },

    {
      group = "Commit",
      name = "Commit",
      run = function(repo)
        require("gitui.ui.commit").open(repo, {})
      end,
    },
    {
      group = "Commit",
      name = "Commit and push",
      run = function(repo)
        require("gitui.ui.commit").open(repo, { push = true })
      end,
    },
    {
      group = "Commit",
      name = "Amend the previous commit",
      run = function(repo)
        require("gitui.ui.commit").open(repo, { amend = true })
      end,
    },

    {
      group = "Remote",
      name = "Push",
      run = function(repo)
        operations.push(repo)
      end,
    },
    {
      group = "Remote",
      name = "Force push (with lease)",
      run = function(repo)
        operations.force_push(repo)
      end,
    },
    {
      group = "Remote",
      name = "Pull",
      run = function(repo)
        operations.pull(repo)
      end,
    },
    {
      group = "Remote",
      name = "Fetch",
      run = function(repo)
        operations.fetch(repo)
      end,
    },
    {
      group = "Remote",
      name = "Fetch all remotes",
      run = function(repo)
        operations.fetch(repo, { all = true })
      end,
    },
    {
      group = "Remote",
      name = "Fetch and prune",
      run = function(repo)
        operations.fetch(repo, { all = true, prune = true })
      end,
    },
    {
      group = "Remote",
      name = "Open repository on the web",
      run = function(repo)
        operations.browse(repo, { kind = "repo" })
      end,
    },
    {
      group = "Remote",
      name = "Open current file on the web",
      run = function(repo)
        local path_util = require("gitui.utils.path")
        local file = path_util.buffer_path(0)
        if not file then
          return notify.warn("The current buffer is not a file")
        end
        local relative = path_util.relative(file, repo.root)
        local state = store.get(repo.root)
        operations.browse(repo, {
          kind = "file",
          ref = state and state.head and state.head.branch or "HEAD",
          path = relative,
          first = vim.api.nvim_win_get_cursor(0)[1],
        })
      end,
    },

    {
      group = "Branch",
      name = "Create a branch",
      run = function(repo)
        operations.create_branch(repo, {})
      end,
    },
    {
      group = "Branch",
      name = "Switch branch",
      run = function(repo)
        require("gitui.ui.branches").pick(repo, function(branch)
          operations.switch_branch(repo, branch.name)
        end)
      end,
    },
    {
      group = "Branch",
      name = "Merge a branch into this one",
      run = function(repo)
        require("gitui.ui.branches").pick(repo, function(branch)
          operations.merge(repo, branch.name)
        end)
      end,
    },
    {
      group = "Branch",
      name = "Rebase onto a branch",
      run = function(repo)
        require("gitui.ui.branches").pick(repo, function(branch)
          operations.rebase(repo, branch.name)
        end)
      end,
    },

    {
      group = "Stash",
      name = "Stash changes",
      run = function(repo)
        operations.stash_push(repo)
      end,
    },
    {
      group = "Stash",
      name = "Stash changes, keeping the index",
      run = function(repo)
        operations.stash_push(repo, { keep_index = true })
      end,
    },
    {
      group = "Stash",
      name = "Pop the most recent stash",
      run = function(repo)
        require("gitui.ui.stash").pop_latest(repo)
      end,
    },

    {
      group = "Inspect",
      name = "Diff the current file",
      run = function(repo)
        local path_util = require("gitui.utils.path")
        local file = path_util.buffer_path(0)
        if not file then
          return notify.warn("The current buffer is not a file")
        end
        require("gitui.ui.diff_view").open(repo, {
          path = path_util.relative(file, repo.root),
          spec = { kind = "worktree" },
        })
      end,
    },
    {
      group = "Inspect",
      name = "Diff everything against HEAD",
      run = function(repo)
        require("gitui.ui.diff_view").open(repo, { spec = { kind = "head" } })
      end,
    },
    {
      group = "Inspect",
      name = "Blame the current file",
      run = function(repo)
        local path_util = require("gitui.utils.path")
        local file = path_util.buffer_path(0)
        if not file then
          return notify.warn("The current buffer is not a file")
        end
        require("gitui.ui.blame").open(repo, path_util.relative(file, repo.root))
      end,
    },
    {
      group = "Inspect",
      name = "Toggle line blame",
      run = function()
        require("gitui.ui.blame").toggle_virtual_text()
      end,
    },
    {
      group = "Inspect",
      name = "History of the current file",
      run = function()
        require("gitui.ui.file_history").current_file()
      end,
    },
    {
      group = "Inspect",
      name = "History of the current line",
      run = function()
        require("gitui.ui.file_history").current_lines()
      end,
    },

    {
      group = "Conflicts",
      name = "Go to the next conflicted file",
      available = function(state)
        return state and state.status and #state.status.conflicts > 0
      end,
      run = function(repo)
        require("gitui.ui.conflict").next_file(repo)
      end,
    },
    {
      group = "Conflicts",
      name = "Three-way merge view",
      available = function(state)
        return state and state.status and #state.status.conflicts > 0
      end,
      run = function(repo)
        local state = store.get(repo.root)
        local first = state and state.status and state.status.conflicts[1]
        if first then
          require("gitui.ui.conflict").three_way(repo, first.path)
        end
      end,
    },

    {
      group = "Sequencer",
      name = "Continue the operation in progress",
      available = function(state)
        return state and state.git_state and state.git_state.kind ~= "normal"
      end,
      run = function(repo)
        operations.sequencer(repo, "continue")
      end,
    },
    {
      group = "Sequencer",
      name = "Skip this step",
      available = function(state)
        return state and state.git_state and state.git_state.kind ~= "normal"
      end,
      run = function(repo)
        operations.sequencer(repo, "skip")
      end,
    },
    {
      group = "Sequencer",
      name = "Abort the operation in progress",
      available = function(state)
        return state and state.git_state and state.git_state.kind ~= "normal"
      end,
      run = function(repo)
        operations.sequencer(repo, "abort")
      end,
    },

    {
      group = "Danger",
      name = "Reset --soft to a commit",
      run = function(repo)
        require("gitui.ui.log").open(repo, { title = "RESET — pick a commit (R)" })
      end,
    },
    {
      group = "Danger",
      name = "Delete untracked files (clean)",
      run = function(repo)
        operations.clean(repo)
      end,
    },
    {
      group = "Danger",
      name = "Delete untracked and ignored files",
      run = function(repo)
        operations.clean(repo, { ignored = true })
      end,
    },

    {
      group = "Other",
      name = "Refresh",
      run = function(repo)
        store.invalidate(repo.root)
        require("gitui.state.refresh").now(repo, { reason = "palette" })
      end,
    },
    {
      group = "Other",
      name = "Switch repository",
      available = function()
        return store.count() > 1
      end,
      run = function()
        M.repositories()
      end,
    },
    {
      group = "Other",
      name = "Show the log file",
      run = function()
        require("gitui").show_log()
      end,
    },
    {
      group = "Other",
      name = "Help",
      run = function()
        require("gitui.ui.help").show("source_control")
      end,
    },
  }

  return list
end

---Open the command palette.
function M.open()
  local state = store.active()
  local repo = state and state.repo or repository.current()

  if not repo then
    return notify.error({
      kind = "no_repository",
      title = "No git repository",
      reason = "The command palette needs a repository to act on.",
      hint = "Open a file inside a repository first.",
      raw = "",
    })
  end

  local items = {}
  for _, command in ipairs(commands()) do
    local available = command.available == nil or command.available(state) == true
    if available then
      items[#items + 1] = {
        -- Including the group in the match text lets "remote push" find it.
        text = command.group .. " " .. command.name,
        segments = {
          { text = ("%-10s"):format(command.group), hl = "GitUIDim" },
          { text = command.name },
        },
        value = command,
      }
    end
  end

  require("gitui.ui.picker").open({
    title = "Git commands",
    items = items,
    on_select = function(command)
      command.run(repo)
    end,
  })
end

---Pick one of the repositories Neovim has seen and make it active.
function M.repositories()
  local states = store.list()
  if #states == 0 then
    return notify.info("No repositories are being tracked")
  end

  local active_root = store.active_root()
  local path_util = require("gitui.utils.path")
  local icons = require("gitui.utils.icons")

  local items = {}
  for _, state in ipairs(states) do
    local is_active = state.repo.root == active_root
    local branch = state.head and (state.head.branch or "detached") or "?"
    items[#items + 1] = {
      text = state.repo.root,
      segments = {
        { text = is_active and (icons.get("bullet") .. " ") or "  ", hl = "GitUIBranchCurrent" },
        { text = state.repo.name, hl = "GitUITitle" },
        { text = "  " .. branch, hl = "GitUIBranch" },
        { text = "  " .. path_util.tilde(state.repo.root), hl = "GitUIDim" },
      },
      value = state.repo,
    }
  end

  require("gitui.ui.picker").open({
    title = "Repositories",
    items = items,
    on_select = function(repo)
      store.set_active(repo)
      require("gitui.state.refresh").now(repo, { reason = "repository-switch" })
      notify.info("Active repository: " .. repo.name)
    end,
  })
end

return M
