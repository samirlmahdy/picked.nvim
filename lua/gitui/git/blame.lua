---@brief Blame via `git blame --porcelain`.
---
---The porcelain format emits a commit's metadata once and refers back to it by
---oid for subsequent lines, so a large file costs one header per commit rather
---than one per line.

local command = require("gitui.git.command")
local config = require("gitui.config")

local M = {}

---@class GitBlameCommit
---@field oid string
---@field short string
---@field author string
---@field author_mail string
---@field author_time integer
---@field author_tz string
---@field committer string
---@field committer_time integer
---@field summary string
---@field previous string|nil  oid of the previous commit touching this file
---@field filename string|nil  path at this revision
---@field is_uncommitted boolean

---@class GitBlameLine
---@field lnum integer  line number in the final file
---@field orig_lnum integer  line number in the originating commit
---@field commit GitBlameCommit

---@class GitBlameResult
---@field lines table<integer, GitBlameLine>  keyed by final line number
---@field commits table<string, GitBlameCommit>
---@field count integer

-- git uses an all-zero oid for content that is not committed yet.
local UNCOMMITTED = "^0+$"

---Parse `git blame --porcelain` output.
---@param raw string
---@return GitBlameResult
function M.parse(raw)
  ---@type GitBlameResult
  local result = { lines = {}, commits = {}, count = 0 }

  local current_oid = nil
  local pending = nil

  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    -- A header line is "<oid> <orig-lnum> <final-lnum> [<count>]".
    local oid, orig_lnum, final_lnum = line:match("^(%x+) (%d+) (%d+)")
    if oid and #oid >= 32 then
      current_oid = oid
      if not result.commits[oid] then
        result.commits[oid] = {
          oid = oid,
          short = oid:sub(1, 7),
          author = "",
          author_mail = "",
          author_time = 0,
          author_tz = "",
          committer = "",
          committer_time = 0,
          summary = "",
          is_uncommitted = oid:match(UNCOMMITTED) ~= nil,
        }
      end
      pending = {
        lnum = tonumber(final_lnum),
        orig_lnum = tonumber(orig_lnum),
        commit = result.commits[oid],
      }
      result.lines[pending.lnum] = pending
      result.count = math.max(result.count, pending.lnum)
    elseif line:sub(1, 1) == "\t" then
      -- The content line terminates a record.
      pending = nil
    elseif current_oid then
      local commit = result.commits[current_oid]
      local key, value = line:match("^([%w%-]+) ?(.*)$")
      if key == "author" then
        commit.author = value
      elseif key == "author-mail" then
        commit.author_mail = value:gsub("^<", ""):gsub(">$", "")
      elseif key == "author-time" then
        commit.author_time = tonumber(value) or 0
      elseif key == "author-tz" then
        commit.author_tz = value
      elseif key == "committer" then
        commit.committer = value
      elseif key == "committer-time" then
        commit.committer_time = tonumber(value) or 0
      elseif key == "summary" then
        commit.summary = value
      elseif key == "previous" then
        commit.previous = value:match("^(%x+)")
      elseif key == "filename" then
        commit.filename = value
      end
    end
  end

  return result
end

---@class GitBlameOpts
---@field revision string|nil  blame as of this revision instead of the worktree
---@field first integer|nil  restrict to a line range
---@field last integer|nil
---@field ignore_whitespace boolean|nil
---@field follow_copies boolean|nil  -C, expensive on large files

---Blame a file.
---@param repo GitRepository
---@param path string
---@param opts GitBlameOpts|nil
---@param callback fun(blame: GitBlameResult|nil, err: GitError|nil)
---@return GitHandle
function M.file(repo, path, opts, callback)
  opts = opts or {}
  local args = { "blame", "--porcelain" }

  if opts.ignore_whitespace ~= false and config.options.blame.ignore_whitespace then
    table.insert(args, "-w")
  end
  if opts.follow_copies then
    table.insert(args, "-C")
  end
  if opts.first and opts.last then
    table.insert(args, "-L")
    table.insert(args, ("%d,%d"):format(opts.first, opts.last))
  end
  if opts.revision then
    table.insert(args, opts.revision)
  end
  table.insert(args, "--")
  table.insert(args, path)

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      -- Blaming an untracked or newly added file is an expected dead end.
      if result.stderr:find("no such path") or result.stderr:find("is outside repository") then
        return callback(nil, {
          kind = "not_tracked",
          title = "No blame available",
          reason = ("'%s' is not tracked at this revision."):format(path),
          hint = "Commit the file first.",
          raw = result.stderr,
        })
      end
      return callback(nil, command.classify(result))
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---Blame a single line. Cheap enough to run on cursor movement when debounced.
---@param repo GitRepository
---@param path string
---@param lnum integer
---@param callback fun(line: GitBlameLine|nil, err: GitError|nil)
---@return GitHandle
function M.line(repo, path, lnum, callback)
  return M.file(repo, path, { first = lnum, last = lnum }, function(blame, err)
    if err then
      return callback(nil, err)
    end
    callback(blame and blame.lines[lnum] or nil, nil)
  end)
end

---Blame the state of a file as it was *before* a commit, which is what "blame
---the previous version" means when following a line's history backwards.
---@param repo GitRepository
---@param path string
---@param revision string
---@param opts GitBlameOpts|nil
---@param callback fun(blame: GitBlameResult|nil, err: GitError|nil)
function M.before(repo, path, revision, opts, callback)
  local merged = vim.tbl_extend("force", opts or {}, { revision = revision .. "^" })
  return M.file(repo, path, merged, callback)
end

---Format a blame line for display in a gutter or virtual text.
---@param line GitBlameLine
---@param opts { date_format: string|nil, relative: boolean|nil, width: integer|nil }|nil
---@return string
function M.format(line, opts)
  opts = opts or {}
  local commit = line.commit
  if commit.is_uncommitted then
    return "Not committed yet"
  end

  local text_util = require("gitui.utils.text")
  local when = opts.relative and text_util.relative_time(commit.author_time)
    or os.date(opts.date_format or config.options.blame.date_format, commit.author_time)

  local formatted = ("%s  %s, %s  %s"):format(commit.short, commit.author, when, commit.summary)
  if opts.width then
    return text_util.truncate(formatted, opts.width)
  end
  return formatted
end

return M
