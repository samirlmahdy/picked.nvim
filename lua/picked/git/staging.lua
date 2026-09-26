---@brief Staging, unstaging and discarding at file, hunk and line granularity.
---
---Whole-file operations use git's own porcelain (`add`, `restore`, `rm`),
---which is always correct and handles deletions, renames and untracked files
---without special cases.
---
---Partial operations build a patch and hand it to `git apply`. That is the
---same machinery `git add -p` uses; nothing here re-implements what git
---already does, and a patch that no longer matches the target is *rejected*
---rather than force-fitted.
---
---Every function in this module mutates the repository. Callers must bump the
---store generation afterwards — `operations.lua` does this centrally.

local command = require("picked.git.command")
local hunks_api = require("picked.git.hunks")

local M = {}

---@alias GitStagingCallback fun(ok: boolean, err: GitError|nil)

---@param paths string[]
---@return boolean
local function has_paths(paths)
  return type(paths) == "table" and #paths > 0
end

---@param callback GitStagingCallback
---@return fun(result: GitResult)
local function finish(callback)
  return function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end
end

--- Whole-file operations -----------------------------------------------------

---Stage paths.
---
---`add -A` is intentional: it stages deletions and untracked files as well as
---modifications, which is what "stage this entry" means in the panel.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.stage(repo, paths, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end
  local args = { "add", "-A", "--" }
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Stage every change in the repository, including untracked files.
---
---No pathspec is passed at all. Magic pathspecs such as `:/` are unavailable
---because the command layer sets `--literal-pathspecs` — a deliberate
---trade-off that keeps a file literally named `:weird` from being
---misinterpreted — and a bare `git add -A` already means "the whole working
---tree" regardless of the current directory.
---@param repo GitRepository
---@param callback GitStagingCallback
function M.stage_all(repo, callback)
  command.run({ "add", "-A" }, { cwd = repo.root, serialize = true }, finish(callback))
end

---Unstage every staged change.
---@param repo GitRepository
---@param callback GitStagingCallback
function M.unstage_all(repo, callback)
  local repository = require("picked.git.repository")
  if repository.head(repo).unborn then
    return command.run({ "rm", "--cached", "-r", "--quiet", "." }, {
      cwd = repo.root,
      serialize = true,
    }, finish(callback))
  end

  local args = command.version_at_least(2, 23) and { "restore", "--staged", "." } or { "reset", "--quiet", "HEAD" }
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Staging the "ours" or "theirs" side is *not* offered here: a conflicted file
---must be resolved in the working tree first. This stages a resolved file.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.mark_resolved(repo, paths, callback)
  M.stage(repo, paths, callback)
end

---Remove paths from the index, keeping the working tree untouched.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.unstage(repo, paths, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end

  -- On an unborn branch there is no HEAD to restore from, so the only way to
  -- unstage is to drop the entry from the index entirely.
  local repository = require("picked.git.repository")
  local head = repository.head(repo)
  if head.unborn then
    local args = { "rm", "--cached", "-r", "--quiet", "--" }
    vim.list_extend(args, paths)
    return command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
  end

  local args
  if command.version_at_least(2, 23) then
    args = { "restore", "--staged", "--" }
  else
    args = { "reset", "--quiet", "HEAD", "--" }
  end
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Discard working-tree changes, restoring each path from the index.
---
---Destructive: callers are responsible for confirmation.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.discard_worktree(repo, paths, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end
  local args
  if command.version_at_least(2, 23) then
    args = { "restore", "--worktree", "--" }
  else
    args = { "checkout", "--quiet", "--" }
  end
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Discard both staged and unstaged changes, restoring each path from HEAD.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.discard_all(repo, paths, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end
  local args
  if command.version_at_least(2, 23) then
    args = { "restore", "--source=HEAD", "--staged", "--worktree", "--" }
  else
    args = { "checkout", "--quiet", "HEAD", "--" }
  end
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Delete untracked files from disk.
---
---Uses `git clean` rather than `os.remove` so git's own safety rules apply and
---the operation is auditable in the reflog of the user's shell history.
---@param repo GitRepository
---@param paths string[]
---@param callback GitStagingCallback
function M.delete_untracked(repo, paths, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end
  -- `-f` is required for clean to do anything; `-d` covers untracked
  -- directories. Ignored files are *not* removed: that needs `-x`, which is
  -- exposed separately and guarded by its own confirmation.
  local args = { "clean", "-f", "-d", "--quiet", "--" }
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Preview what `git clean` would remove.
---@param repo GitRepository
---@param opts { ignored: boolean|nil, directories: boolean|nil, paths: string[]|nil }
---@param callback fun(paths: string[]|nil, err: GitError|nil)
function M.clean_preview(repo, opts, callback)
  -- `git clean` has no `-z` mode, so paths arrive newline separated and
  -- C-quoted when they contain awkward bytes.
  local args = { "clean", "--dry-run" }
  if opts.directories ~= false then
    table.insert(args, "-d")
  end
  if opts.ignored then
    table.insert(args, "-x")
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end

  command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end
    local text_util = require("picked.utils.text")
    local paths = {}
    for _, line in ipairs(text_util.lines(result.stdout)) do
      local path = line:match("^Would remove (.+)$") or line:match("^Would skip repository (.+)$")
      if path then
        paths[#paths + 1] = text_util.unquote_c_style(path)
      end
    end
    callback(paths, nil)
  end)
end

---Remove untracked files. Guarded by an explicit preview in the UI.
---@param repo GitRepository
---@param opts { ignored: boolean|nil, directories: boolean|nil, paths: string[]|nil }
---@param callback GitStagingCallback
function M.clean(repo, opts, callback)
  local args = { "clean", "-f", "--quiet" }
  if opts.directories ~= false then
    table.insert(args, "-d")
  end
  if opts.ignored then
    table.insert(args, "-x")
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

--- Patch application ---------------------------------------------------------

---@param context integer
---@return string[]
local function apply_args(context)
  local args = { "apply", "--whitespace=nowarn" }
  -- A zero-context patch cannot be located by content, so git requires an
  -- explicit opt-in to trust its line numbers.
  if context == 0 then
    table.insert(args, "--unidiff-zero")
  end
  return args
end

---Apply a patch.
---@param repo GitRepository
---@param patch string
---@param opts { cached: boolean|nil, reverse: boolean|nil, context: integer|nil, index: boolean|nil }
---@param callback GitStagingCallback
function M.apply_patch(repo, patch, opts, callback)
  if not patch or patch == "" then
    return callback(false, {
      kind = "empty_patch",
      title = "Nothing to apply",
      reason = "The selection produced an empty patch.",
      hint = "Select at least one added or removed line.",
      raw = "",
    })
  end

  local args = apply_args(opts.context or 3)
  if opts.cached then
    table.insert(args, "--cached")
  end
  if opts.index then
    table.insert(args, "--index")
  end
  if opts.reverse then
    table.insert(args, "-R")
  end
  table.insert(args, "-")

  command.run(args, { cwd = repo.root, stdin = patch, serialize = true }, function(result)
    if result.ok then
      return callback(true, nil)
    end

    local err = command.classify(result)
    -- `git apply` failing almost always means the patch no longer matches the
    -- target, which happens when the file changed underneath the view.
    if err.kind == "unknown" and result.stderr:find("patch does not apply") then
      err = {
        kind = "patch_stale",
        title = "Could not apply the selection",
        reason = "The file changed since this diff was produced, so the patch no longer matches.",
        hint = "Refresh (r) and try again.",
        raw = result.stderr,
      }
    end
    callback(false, err)
  end)
end

--- Partial staging -----------------------------------------------------------

---@class GitPartialOpts
---@field old_path string|nil
---@field new_file boolean|nil
---@field deleted_file boolean|nil
---@field mode string|nil
---@field context integer|nil

---Stage a subset of a file's hunks.
---
---The hunks must come from an *unstaged* diff (index → working tree), because
---the patch is applied forwards onto the index.
---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param callback GitStagingCallback
function M.stage_hunks(repo, path, hunks, opts, callback)
  opts = opts or {}
  local patch, err = hunks_api.to_patch(path, hunks, opts)
  if not patch then
    return callback(false, {
      kind = "empty_patch",
      title = "Nothing to stage",
      reason = err or "no hunks selected",
      raw = "",
    })
  end
  M.apply_patch(repo, patch, { cached = true, context = opts.context }, callback)
end

---Unstage a subset of a file's hunks.
---
---The hunks must come from a *staged* diff (HEAD → index); the patch is
---reverse-applied to the index.
---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param callback GitStagingCallback
function M.unstage_hunks(repo, path, hunks, opts, callback)
  opts = opts or {}
  local patch, err = hunks_api.to_patch(path, hunks, opts)
  if not patch then
    return callback(false, {
      kind = "empty_patch",
      title = "Nothing to unstage",
      reason = err or "no hunks selected",
      raw = "",
    })
  end
  M.apply_patch(repo, patch, { cached = true, reverse = true, context = opts.context }, callback)
end

---Discard a subset of a file's working-tree hunks.
---
---Destructive: the caller must have obtained confirmation. The hunks must
---come from an unstaged diff; the patch is reverse-applied to the working
---tree, leaving the index untouched.
---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param callback GitStagingCallback
function M.discard_hunks(repo, path, hunks, opts, callback)
  opts = opts or {}
  local patch, err = hunks_api.to_patch(path, hunks, opts)
  if not patch then
    return callback(false, {
      kind = "empty_patch",
      title = "Nothing to discard",
      reason = err or "no hunks selected",
      raw = "",
    })
  end
  M.apply_patch(repo, patch, { reverse = true, context = opts.context }, callback)
end

--- Conflict resolution -------------------------------------------------------

---@alias GitConflictSide "ours"|"theirs"|"base"

---Check out one side of a conflicted file wholesale.
---@param repo GitRepository
---@param paths string[]
---@param side GitConflictSide
---@param callback GitStagingCallback
function M.checkout_side(repo, paths, side, callback)
  if not has_paths(paths) then
    return callback(false, nil)
  end
  local flag = side == "ours" and "--ours" or side == "theirs" and "--theirs" or nil
  if not flag then
    return callback(false, {
      kind = "invalid_side",
      title = "Cannot take that side",
      reason = "Only 'ours' and 'theirs' can be checked out directly.",
      hint = "Use the conflict view to combine the base with either side.",
      raw = "",
    })
  end
  local args = { "checkout", flag, "--" }
  vim.list_extend(args, paths)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

return M
