---@brief Branch and ref enumeration plus branch operations.
---
---`for-each-ref` with an explicit `--format` is used instead of `git branch`,
---whose output is designed for humans. Fields are separated by NUL (`%00`),
---which no refname or subject line can contain.

local command = require("gitui.git.command")

local M = {}

---@class GitBranch
---@field name string  short name: "main", or "origin/main" for a remote branch
---@field full string  full refname: "refs/heads/main"
---@field kind "local"|"remote"|"tag"
---@field remote string|nil  remote name, for remote-tracking branches
---@field is_head boolean
---@field oid string
---@field short_oid string
---@field upstream string|nil  short name of the upstream branch
---@field ahead integer
---@field behind integer
---@field gone boolean  the upstream ref no longer exists
---@field subject string  subject line of the tip commit
---@field author string
---@field date integer  committer date as a unix timestamp

-- Field order must match FORMAT below.
local FIELDS = {
  "refname",
  "objectname",
  "head",
  "upstream_short",
  "track",
  "subject",
  "author",
  "date",
}

local FORMAT = table.concat({
  "%(refname)",
  "%(objectname)",
  "%(HEAD)",
  "%(upstream:short)",
  "%(upstream:track,nobracket)",
  "%(contents:subject)",
  "%(authorname)",
  "%(committerdate:unix)",
}, "%00")

---Parse `[ahead 3, behind 2]` / `ahead 3, behind 2` / `gone`.
---@param track string
---@return integer ahead, integer behind, boolean gone
local function parse_track(track)
  if track == "" then
    return 0, 0, false
  end
  if track:find("gone") then
    return 0, 0, true
  end
  local ahead = tonumber(track:match("ahead (%d+)")) or 0
  local behind = tonumber(track:match("behind (%d+)")) or 0
  return ahead, behind, false
end

---@param refname string
---@return "local"|"remote"|"tag"|nil kind, string name, string|nil remote
local function classify_ref(refname)
  local head = refname:match("^refs/heads/(.+)$")
  if head then
    return "local", head, nil
  end
  local remote = refname:match("^refs/remotes/(.+)$")
  if remote then
    -- The remote name is the first segment; the rest is the branch, which may
    -- itself contain slashes.
    local remote_name = remote:match("^([^/]+)/")
    return "remote", remote, remote_name
  end
  local tag = refname:match("^refs/tags/(.+)$")
  if tag then
    return "tag", tag, nil
  end
  return nil, refname, nil
end

---Parse `for-each-ref` output produced with FORMAT.
---@param raw string
---@return GitBranch[]
function M.parse(raw)
  local branches = {}
  -- Records are newline separated: a refname cannot contain a newline, and
  -- `%(contents:subject)` is a single folded line by construction.
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    if line ~= "" then
      local values = vim.split(line, "\0", { plain = true })
      local record = {}
      for index, field in ipairs(FIELDS) do
        record[field] = values[index] or ""
      end

      local kind, name, remote = classify_ref(record.refname)
      if kind then
        local ahead, behind, gone = parse_track(record.track)
        branches[#branches + 1] = {
          name = name,
          full = record.refname,
          kind = kind,
          remote = remote,
          is_head = record.head == "*",
          oid = record.objectname,
          short_oid = record.objectname:sub(1, 7),
          upstream = record.upstream_short ~= "" and record.upstream_short or nil,
          ahead = ahead,
          behind = behind,
          gone = gone,
          subject = record.subject,
          author = record.author,
          date = tonumber(record.date) or 0,
        }
      end
    end
  end
  return branches
end

---@class GitBranchListOpts
---@field locals boolean|nil  include local branches (default true)
---@field remotes boolean|nil  include remote-tracking branches (default true)
---@field tags boolean|nil  include tags (default false)
---@field sort string|nil  a `for-each-ref` sort key

---List refs.
---@param repo GitRepository
---@param opts GitBranchListOpts|nil
---@param callback fun(branches: GitBranch[]|nil, err: GitError|nil)
---@return GitHandle
function M.list(repo, opts, callback)
  opts = opts or {}
  local patterns = {}
  if opts.locals ~= false then
    patterns[#patterns + 1] = "refs/heads"
  end
  if opts.remotes ~= false then
    patterns[#patterns + 1] = "refs/remotes"
  end
  if opts.tags then
    patterns[#patterns + 1] = "refs/tags"
  end

  local args = {
    "for-each-ref",
    "--format=" .. FORMAT,
    -- Most recently used first: that is almost always the order a human wants.
    "--sort=" .. (opts.sort or "-committerdate"),
  }
  vim.list_extend(args, patterns)

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---Local branches only.
---@param repo GitRepository
---@param callback fun(branches: GitBranch[]|nil, err: GitError|nil)
function M.locals(repo, callback)
  return M.list(repo, { remotes = false }, callback)
end

--- Validation ---------------------------------------------------------------

---Is `name` a legal branch name?
---
---Mirrors `git check-ref-format --branch` so the user gets an explanation
---before a command fails, without paying for a subprocess on every keystroke.
---@param name string
---@return boolean ok, string|nil reason
function M.validate_name(name)
  if name == "" then
    return false, "The name cannot be empty."
  end
  if name:match("^%-") then
    return false, "A branch name cannot start with '-'."
  end
  if name:match("^%.") or name:match("/%.") then
    return false, "No path component may start with '.'."
  end
  if name:match("%.%.") then
    return false, "A branch name cannot contain '..'."
  end
  if name:match("[%c~^:%?%*%[\\]") then
    return false, "A branch name cannot contain space, control characters or any of ~ ^ : ? * [ \\."
  end
  if name:find(" ") then
    return false, "A branch name cannot contain spaces."
  end
  if name:match("//") then
    return false, "A branch name cannot contain '//'."
  end
  if name:match("/$") or name:match("^/") then
    return false, "A branch name cannot start or end with '/'."
  end
  if name:match("%.lock$") or name:match("%.lock/") then
    return false, "A branch name cannot end with '.lock'."
  end
  if name:match("@{") then
    return false, "A branch name cannot contain '@{'."
  end
  if name == "@" then
    return false, "'@' is reserved."
  end
  if name:match("%.$") then
    return false, "A branch name cannot end with '.'."
  end
  return true, nil
end

---Ask git itself whether a ref name is valid. Used before the actual command
---so a rejection can be explained rather than dumped.
---@param repo GitRepository
---@param name string
---@param callback fun(ok: boolean, reason: string|nil)
function M.check_name(repo, name, callback)
  local ok, reason = M.validate_name(name)
  if not ok then
    return callback(false, reason)
  end
  command.run({ "check-ref-format", "--branch", name }, { cwd = repo.root }, function(result)
    callback(result.ok, result.ok and nil or "git rejected this branch name.")
  end)
end

---Does a local branch with this name exist?
---@param repo GitRepository
---@param name string
---@param callback fun(exists: boolean)
function M.exists(repo, name, callback)
  command.run({ "show-ref", "--verify", "--quiet", "refs/heads/" .. name }, { cwd = repo.root }, function(result)
    callback(result.ok)
  end)
end

--- Operations ---------------------------------------------------------------

---@alias GitBranchCallback fun(ok: boolean, err: GitError|nil)

---@param callback GitBranchCallback
---@return fun(result: GitResult)
local function finish(callback)
  return function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end
end

---Switch to an existing branch, or to a detached commit.
---@param repo GitRepository
---@param target string  branch name or revision
---@param opts { detach: boolean|nil, create: boolean|nil, force: boolean|nil }|nil
---@param callback GitBranchCallback
function M.switch(repo, target, opts, callback)
  opts = opts or {}
  local args
  if command.version_at_least(2, 23) then
    args = { "switch" }
    if opts.create then
      table.insert(args, "-c")
    end
    if opts.detach then
      table.insert(args, "--detach")
    end
    if opts.force then
      table.insert(args, "--discard-changes")
    end
  else
    args = { "checkout" }
    if opts.create then
      table.insert(args, "-b")
    end
    if opts.detach then
      table.insert(args, "--detach")
    end
    if opts.force then
      table.insert(args, "--force")
    end
  end
  table.insert(args, target)

  -- Checking out runs hooks and can take a while on a large tree.
  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, finish(callback))
end

---Create a branch.
---@param repo GitRepository
---@param name string
---@param opts { start_point: string|nil, switch: boolean|nil, force: boolean|nil }|nil
---@param callback GitBranchCallback
function M.create(repo, name, opts, callback)
  opts = opts or {}
  if opts.switch then
    local args = command.version_at_least(2, 23) and { "switch", "-c", name } or { "checkout", "-b", name }
    if opts.start_point then
      table.insert(args, opts.start_point)
    end
    return command.run(args, { cwd = repo.root, serialize = true, hooks = true }, finish(callback))
  end

  local args = { "branch" }
  if opts.force then
    table.insert(args, "--force")
  end
  table.insert(args, name)
  if opts.start_point then
    table.insert(args, opts.start_point)
  end
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Delete a branch.
---
---`force` maps to `-D`, which discards unmerged commits: the caller must have
---obtained explicit confirmation.
---@param repo GitRepository
---@param name string
---@param opts { force: boolean|nil, remote: string|nil }|nil
---@param callback GitBranchCallback
function M.delete(repo, name, opts, callback)
  opts = opts or {}
  if opts.remote then
    -- Deleting the remote branch is a push of an empty ref.
    return command.run(
      { "push", "--delete", opts.remote, name },
      { cwd = repo.root, serialize = true, hooks = true, timeout = require("gitui.config").options.network_timeout },
      finish(callback)
    )
  end
  local args = { "branch", opts.force and "-D" or "-d", name }
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Rename a branch.
---@param repo GitRepository
---@param from string
---@param to string
---@param opts { force: boolean|nil }|nil
---@param callback GitBranchCallback
function M.rename(repo, from, to, opts, callback)
  opts = opts or {}
  local args = { "branch", opts.force and "-M" or "-m", from, to }
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Set or clear a branch's upstream.
---@param repo GitRepository
---@param branch string
---@param upstream string|nil  nil unsets
---@param callback GitBranchCallback
function M.set_upstream(repo, branch, upstream, callback)
  local args = upstream and { "branch", "--set-upstream-to=" .. upstream, branch }
    or { "branch", "--unset-upstream", branch }
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Merge a ref into the current branch.
---@param repo GitRepository
---@param ref string
---@param opts { no_ff: boolean|nil, squash: boolean|nil, ff_only: boolean|nil, message: string|nil }|nil
---@param callback GitBranchCallback
function M.merge(repo, ref, opts, callback)
  opts = opts or {}
  local args = { "merge", "--no-edit" }
  if opts.no_ff then
    table.insert(args, "--no-ff")
  end
  if opts.ff_only then
    table.insert(args, "--ff-only")
  end
  if opts.squash then
    table.insert(args, "--squash")
  end
  if opts.message then
    table.insert(args, "-m")
    table.insert(args, opts.message)
  end
  table.insert(args, ref)
  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, function(result)
    if result.ok then
      return callback(true, nil)
    end
    -- A conflicting merge is a legitimate outcome, not a failure to report as
    -- an error: the caller switches to conflict resolution.
    local err = command.classify(result)
    callback(false, err)
  end)
end

---Rebase the current branch onto a ref.
---@param repo GitRepository
---@param ref string
---@param opts { interactive: boolean|nil, onto: string|nil, autostash: boolean|nil }|nil
---@param callback GitBranchCallback
function M.rebase(repo, ref, opts, callback)
  opts = opts or {}
  local args = { "rebase" }
  if opts.autostash then
    table.insert(args, "--autostash")
  end
  if opts.onto then
    table.insert(args, "--onto")
    table.insert(args, opts.onto)
  end
  table.insert(args, ref)
  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, finish(callback))
end

---@alias GitSequencerAction "continue"|"abort"|"skip"|"quit"

---Drive an in-progress merge, rebase, cherry-pick or revert.
---@param repo GitRepository
---@param operation "merge"|"rebase"|"cherry-pick"|"revert"|"am"
---@param action GitSequencerAction
---@param callback GitBranchCallback
function M.sequencer(repo, operation, action, callback)
  local args = { operation, "--" .. action }
  -- `git merge --continue` opens an editor unless told otherwise; the command
  -- layer already neutralises $GIT_EDITOR, so the existing message is kept.
  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, finish(callback))
end

---Reset the current branch to a revision.
---
---Destructive in `hard` mode: confirmation is the caller's responsibility.
---@param repo GitRepository
---@param revision string
---@param mode "soft"|"mixed"|"hard"|"keep"|"merge"
---@param callback GitBranchCallback
function M.reset(repo, revision, mode, callback)
  command.run({ "reset", "--" .. mode, revision }, { cwd = repo.root, serialize = true }, finish(callback))
end

return M
