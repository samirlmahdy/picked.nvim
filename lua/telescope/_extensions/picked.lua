---@brief Telescope extension.
---
---Optional, and deliberately narrow: it exposes picked's data as telescope
---pickers and hands the selection back to picked's own actions. It does not
---try to reimplement the panel, and picked never requires it.
---
---    require("telescope").load_extension("picked")
---    :Telescope picked branches
---    :Telescope picked commits
---    :Telescope picked status
---    :Telescope picked stashes

local ok, telescope = pcall(require, "telescope")
if not ok then
  error("telescope.nvim is required for this extension")
end

local actions = require("telescope.actions")
local action_state = require("telescope.actions.state")
local conf = require("telescope.config").values
local finders = require("telescope.finders")
local pickers = require("telescope.pickers")

local picked = require("picked")
local git = require("picked.git")
local operations = require("picked.operations")

---Resolve the repository, reporting the same error the rest of picked would.
---@return GitRepository|nil
local function repo()
  return picked._resolve_repo()
end

---Drain an async picked call for telescope, which builds its list up front.
---@generic T
---@param fn fun(done: fun(value: T, err: GitError|nil))
---@param timeout integer|nil
---@return any|nil
local function await(fn, timeout)
  local captured = nil
  fn(function(value, err)
    captured = { value = value, err = err }
  end)
  vim.wait(timeout or 10000, function()
    return captured ~= nil
  end, 10)
  if not captured or captured.err then
    require("picked.ui.notify").error(captured and captured.err or "picked: request timed out")
    return nil
  end
  return captured.value
end

--- Pickers --------------------------------------------------------------------

local function branches(opts)
  opts = opts or {}
  local repository = repo()
  if not repository then
    return
  end

  local list = await(function(done)
    git.branches.list(repository, { tags = false }, done)
  end)
  if not list then
    return
  end

  pickers
    .new(opts, {
      prompt_title = "Git branches",
      finder = finders.new_table({
        results = list,
        entry_maker = function(branch)
          local marker = branch.is_head and "● " or "  "
          return {
            value = branch,
            ordinal = branch.name,
            display = ("%s%-40s %s"):format(marker, branch.name, branch.subject),
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            operations.switch_branch(repository, entry.value.name)
          end
        end)

        map({ "i", "n" }, "<C-d>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            operations.delete_branch(repository, entry.value)
          end
        end)

        map({ "i", "n" }, "<C-m>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            operations.merge(repository, entry.value.name)
          end
        end)

        return true
      end,
    })
    :find()
end

local function commits(opts)
  opts = opts or {}
  local repository = repo()
  if not repository then
    return
  end

  local list = await(function(done)
    git.commits.log(repository, { max_count = opts.max_count or 500 }, done)
  end)
  if not list then
    return
  end

  local text_util = require("picked.utils.text")

  pickers
    .new(opts, {
      prompt_title = "Git commits",
      finder = finders.new_table({
        results = list,
        entry_maker = function(commit)
          return {
            value = commit,
            ordinal = commit.short .. " " .. commit.subject .. " " .. commit.author_name,
            display = ("%s %-60s %s"):format(
              commit.short,
              text_util.truncate(commit.subject, 60),
              text_util.relative_time_short(commit.committer_date)
            ),
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require("picked.ui.log").show_commit(repository, entry.value)
          end
        end)

        map({ "i", "n" }, "<C-d>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require("picked.ui.diff_view").open(repository, {
              spec = { kind = "commit", from = entry.value.oid },
            })
          end
        end)

        return true
      end,
    })
    :find()
end

local function status(opts)
  opts = opts or {}
  local repository = repo()
  if not repository then
    return
  end

  local result = await(function(done)
    git.status.query(repository, nil, done)
  end)
  if not result then
    return
  end

  local path_util = require("picked.utils.path")

  pickers
    .new(opts, {
      prompt_title = "Git status",
      finder = finders.new_table({
        results = result.files,
        entry_maker = function(entry)
          return {
            value = entry,
            ordinal = entry.path,
            display = ("%s %s"):format(entry.status, entry.path),
            path = path_util.join(repository.root, entry.path),
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      previewer = conf.file_previewer(opts),
      attach_mappings = function(prompt_bufnr, map)
        map({ "i", "n" }, "<C-s>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            operations.stage(repository, { entry.value.path })
          end
        end)

        map({ "i", "n" }, "<C-d>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require("picked.ui.diff_view").open(repository, {
              path = entry.value.path,
              spec = { kind = "worktree" },
            })
          end
        end)

        return true
      end,
    })
    :find()
end

local function stashes(opts)
  opts = opts or {}
  local repository = repo()
  if not repository then
    return
  end

  local list = await(function(done)
    git.stash.list(repository, done)
  end)
  if not list then
    return
  end

  pickers
    .new(opts, {
      prompt_title = "Git stashes",
      finder = finders.new_table({
        results = list,
        entry_maker = function(stash)
          return {
            value = stash,
            ordinal = stash.selector .. " " .. stash.message,
            display = ("%-11s %s"):format(stash.selector, stash.message),
          }
        end,
      }),
      sorter = conf.generic_sorter(opts),
      attach_mappings = function(prompt_bufnr, map)
        actions.select_default:replace(function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            require("picked.ui.stash").inspect(entry.value)
          end
        end)

        map({ "i", "n" }, "<C-p>", function()
          local entry = action_state.get_selected_entry()
          actions.close(prompt_bufnr)
          if entry then
            operations.stash_restore(repository, entry.value, "pop")
          end
        end)

        return true
      end,
    })
    :find()
end

return telescope.register_extension({
  exports = {
    picked = branches,
    branches = branches,
    commits = commits,
    status = status,
    stashes = stashes,
  },
})
