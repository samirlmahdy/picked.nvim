---@brief Stash enumeration and operations.

local command = require("gitui.git.command")
local text_util = require("gitui.utils.text")

local M = {}

---@class GitStash
---@field index integer  0-based position
---@field selector string  "stash@{0}"
---@field oid string
---@field date integer  unix timestamp
---@field message string  the human part of the reflog subject
---@field branch string|nil  branch the stash was created on
---@field raw_subject string  the full reflog subject

local UNIT = "\31"
local FORMAT = table.concat({ "%gd", "%H", "%ct", "%gs" }, "%x1f")

---Split "WIP on main: 1a2b3c subject" into its branch and message parts.
---@param subject string
---@return string|nil branch, string message
local function parse_subject(subject)
  local branch, rest = subject:match("^WIP on ([^:]+): (.*)$")
  if branch then
    -- git prefixes the message with the tip commit it was taken from.
    return branch, (rest:gsub("^%x+%s+", ""))
  end
  branch, rest = subject:match("^On ([^:]+): (.*)$")
  if branch then
    return branch, rest
  end
  return nil, subject
end

---Parse `git stash list -z --format=...` output.
---@param raw string
---@return GitStash[]
function M.parse(raw)
  local stashes = {}
  for _, record in ipairs(text_util.nul_split(raw)) do
    record = record:gsub("^\n", "")
    if record ~= "" then
      local values = vim.split(record, UNIT, { plain = true })
      local selector = values[1] or ""
      if selector ~= "" then
        local branch, message = parse_subject(values[4] or "")
        stashes[#stashes + 1] = {
          index = tonumber(selector:match("{(%d+)}")) or #stashes,
          selector = selector,
          oid = values[2] or "",
          date = tonumber(values[3]) or 0,
          message = message,
          branch = branch,
          raw_subject = values[4] or "",
        }
      end
    end
  end
  return stashes
end

---List stashes.
---@param repo GitRepository
---@param callback fun(stashes: GitStash[]|nil, err: GitError|nil)
---@return GitHandle
function M.list(repo, callback)
  return command.run({ "stash", "list", "-z", "--format=" .. FORMAT }, { cwd = repo.root }, function(result)
    if not result.ok then
      -- A repository with no stash ref reports an error on some git
      -- versions; an empty list is the right answer either way.
      if result.stderr:find("unknown revision") or result.stderr:find("ambiguous argument") then
        return callback({}, nil)
      end
      return callback(nil, command.classify(result))
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---@param callback fun(ok: boolean, err: GitError|nil)
---@return fun(result: GitResult)
local function finish(callback)
  return function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end
end

---@class GitStashPushOpts
---@field message string|nil
---@field include_untracked boolean|nil
---@field keep_index boolean|nil
---@field all boolean|nil  also stash ignored files
---@field paths string[]|nil  stash only these paths
---@field staged_only boolean|nil  stash only what is staged (git 2.35+)

---Create a stash.
---@param repo GitRepository
---@param opts GitStashPushOpts|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.push(repo, opts, callback)
  opts = opts or {}
  local args = { "stash", "push" }
  if opts.include_untracked then
    table.insert(args, "--include-untracked")
  end
  if opts.all then
    table.insert(args, "--all")
  end
  if opts.keep_index then
    table.insert(args, "--keep-index")
  end
  if opts.staged_only and command.version_at_least(2, 35) then
    table.insert(args, "--staged")
  end
  if opts.message and opts.message ~= "" then
    table.insert(args, "--message")
    table.insert(args, opts.message)
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end

  command.run(args, { cwd = repo.root, serialize = true }, function(result)
    if result.ok then
      -- "No local changes to save" exits 0 but stashes nothing.
      if result.stdout:find("No local changes to save") then
        return callback(false, {
          kind = "nothing_to_stash",
          title = "Nothing to stash",
          reason = "The working tree has no changes to save.",
          raw = result.stdout,
        })
      end
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end)
end

---Apply a stash, keeping it in the list.
---@param repo GitRepository
---@param selector string
---@param opts { index: boolean|nil }|nil  restore the staged/unstaged split
---@param callback fun(ok: boolean, err: GitError|nil)
function M.apply(repo, selector, opts, callback)
  local args = { "stash", "apply" }
  if opts and opts.index then
    table.insert(args, "--index")
  end
  table.insert(args, selector)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Apply a stash and remove it from the list.
---@param repo GitRepository
---@param selector string
---@param opts { index: boolean|nil }|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.pop(repo, selector, opts, callback)
  local args = { "stash", "pop" }
  if opts and opts.index then
    table.insert(args, "--index")
  end
  table.insert(args, selector)
  command.run(args, { cwd = repo.root, serialize = true }, finish(callback))
end

---Delete a stash. Destructive: confirmation is the caller's responsibility.
---@param repo GitRepository
---@param selector string
---@param callback fun(ok: boolean, err: GitError|nil)
function M.drop(repo, selector, callback)
  command.run({ "stash", "drop", selector }, { cwd = repo.root, serialize = true }, finish(callback))
end

---Create a branch from a stash and drop it.
---@param repo GitRepository
---@param selector string
---@param name string
---@param callback fun(ok: boolean, err: GitError|nil)
function M.branch(repo, selector, name, callback)
  command.run(
    { "stash", "branch", name, selector },
    { cwd = repo.root, serialize = true, hooks = true },
    finish(callback)
  )
end

---Delete every stash. Heavily destructive; used only behind an explicit
---confirmation in the UI.
---@param repo GitRepository
---@param callback fun(ok: boolean, err: GitError|nil)
function M.clear(repo, callback)
  command.run({ "stash", "clear" }, { cwd = repo.root, serialize = true }, finish(callback))
end

---Files changed by a stash, with their line counts.
---@param repo GitRepository
---@param selector string
---@param callback fun(stats: GitDiffStat[]|nil, err: GitError|nil)
function M.stat(repo, selector, callback)
  local diff = require("gitui.git.diff")
  -- A stash commit's first parent is the state it was taken from.
  diff.numstat(repo, { kind = "range", from = selector .. "^", to = selector }, callback)
end

---Full diff of a stash.
---@param repo GitRepository
---@param selector string
---@param callback fun(diffs: GitFileDiff[]|nil, err: GitError|nil)
function M.diff(repo, selector, callback)
  local diff = require("gitui.git.diff")
  diff.files(repo, { kind = "range", from = selector .. "^", to = selector }, nil, callback)
end

return M
