---@brief The git facade.
---
---Everything above this line works with parsed data structures and never
---constructs a git argument. The submodules are exposed directly for callers
---that need the full surface; the flat helpers below cover the common cases
---named in the plugin's public contract.

local M = {}

M.command = require("gitui.git.command")
M.repository = require("gitui.git.repository")
M.status = require("gitui.git.status")
M.diff = require("gitui.git.diff")
M.hunks = require("gitui.git.hunks")
M.staging = require("gitui.git.staging")
M.branches = require("gitui.git.branches")
M.commits = require("gitui.git.commits")
M.remotes = require("gitui.git.remotes")
M.stash = require("gitui.git.stash")
M.conflicts = require("gitui.git.conflicts")
M.blame = require("gitui.git.blame")
M.browse = require("gitui.git.browse")
M.graph = require("gitui.git.graph")

--- Convenience surface -------------------------------------------------------

---@param repo GitRepository
---@param opts GitStatusOpts|nil
---@param callback fun(status: GitStatusResult|nil, err: GitError|nil)
function M.get_status(repo, opts, callback)
  return M.status.query(repo, opts, callback)
end

---Unstaged changes for a file (index → working tree).
---@param repo GitRepository
---@param path string
---@param callback fun(diff: GitFileDiff|nil, err: GitError|nil)
function M.diff_file(repo, path, callback)
  return M.diff.file(repo, path, { kind = "worktree" }, nil, callback)
end

---Staged changes for a file (HEAD → index).
---@param repo GitRepository
---@param path string
---@param callback fun(diff: GitFileDiff|nil, err: GitError|nil)
function M.diff_cached(repo, path, callback)
  return M.diff.file(repo, path, { kind = "index" }, nil, callback)
end

---@param repo GitRepository
---@param paths string[]
---@param callback fun(ok: boolean, err: GitError|nil)
function M.stage_file(repo, paths, callback)
  return M.staging.stage(repo, paths, callback)
end

---@param repo GitRepository
---@param paths string[]
---@param callback fun(ok: boolean, err: GitError|nil)
function M.unstage_file(repo, paths, callback)
  return M.staging.unstage(repo, paths, callback)
end

---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.stage_hunk(repo, path, hunks, opts, callback)
  return M.staging.stage_hunks(repo, path, hunks, opts, callback)
end

---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.unstage_hunk(repo, path, hunks, opts, callback)
  return M.staging.unstage_hunks(repo, path, hunks, opts, callback)
end

---@param repo GitRepository
---@param paths string[]
---@param callback fun(ok: boolean, err: GitError|nil)
function M.discard_file(repo, paths, callback)
  return M.staging.discard_worktree(repo, paths, callback)
end

---@param repo GitRepository
---@param opts GitCommitOpts
---@param callback fun(ok: boolean, err: GitError|nil, output: string|nil)
function M.commit(repo, opts, callback)
  return M.commits.commit(repo, opts, callback)
end

---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
function M.push(repo, opts, callback)
  return M.remotes.push(repo, opts, callback)
end

---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
function M.pull(repo, opts, callback)
  return M.remotes.pull(repo, opts, callback)
end

---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
function M.fetch(repo, opts, callback)
  return M.remotes.fetch(repo, opts, callback)
end

---@param repo GitRepository
---@param opts GitBranchListOpts|nil
---@param callback fun(branches: GitBranch[]|nil, err: GitError|nil)
function M.branch_list(repo, opts, callback)
  return M.branches.list(repo, opts, callback)
end

---@param repo GitRepository
---@param name string
---@param opts table|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.branch_create(repo, name, opts, callback)
  return M.branches.create(repo, name, opts, callback)
end

---@param repo GitRepository
---@param name string
---@param opts table|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.branch_delete(repo, name, opts, callback)
  return M.branches.delete(repo, name, opts, callback)
end

---@param repo GitRepository
---@param name string
---@param opts table|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.branch_switch(repo, name, opts, callback)
  return M.branches.switch(repo, name, opts, callback)
end

---@param repo GitRepository
---@param opts GitLogOpts|nil
---@param callback fun(commits: GitCommit[]|nil, err: GitError|nil)
function M.log(repo, opts, callback)
  return M.commits.log(repo, opts, callback)
end

---@param repo GitRepository
---@param revision string
---@param callback fun(commit: GitCommit|nil, err: GitError|nil)
function M.show(repo, revision, callback)
  return M.commits.show(repo, revision, callback)
end

---@param repo GitRepository
---@param callback fun(stashes: GitStash[]|nil, err: GitError|nil)
function M.stash_list(repo, callback)
  return M.stash.list(repo, callback)
end

---@param repo GitRepository
---@param opts GitStashPushOpts|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.stash_push(repo, opts, callback)
  return M.stash.push(repo, opts, callback)
end

---@param repo GitRepository
---@param selector string
---@param opts table|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.stash_pop(repo, selector, opts, callback)
  return M.stash.pop(repo, selector, opts, callback)
end

return M
