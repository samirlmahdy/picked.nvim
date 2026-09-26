---@brief Diff acquisition.
---
---Every comparison the UI offers is expressed as a `GitDiffSpec`, so callers
---never assemble git arguments themselves and an "ambiguous diff" (§89) is
---impossible: the spec always names both sides explicitly.

local command = require("gitui.git.command")
local config = require("gitui.config")
local hunks_api = require("gitui.git.hunks")
local text_util = require("gitui.utils.text")

local M = {}

---@alias GitDiffKind
---| '"worktree"'  index -> working tree (the unstaged changes)
---| '"index"'     HEAD -> index (the staged changes)
---| '"head"'      HEAD -> working tree (everything)
---| '"commit"'    a commit against its first parent
---| '"range"'     an arbitrary pair of revisions
---| '"merge_base"' `a...b`

---@class GitDiffSpec
---@field kind GitDiffKind
---@field from string|nil  revision, for "commit", "range" and "merge_base"
---@field to string|nil
---@field paths string[]|nil  limit the diff to these paths

---@class GitFileDiff
---@field path string
---@field old_path string|nil
---@field raw string  the complete patch text for this file
---@field hunks GitHunk[]
---@field binary boolean
---@field mode_change { old: string, new: string }|nil
---@field spec GitDiffSpec

---Human-readable description of what a spec compares, shown in window titles
---so the user always knows which two things they are looking at.
---@param spec GitDiffSpec
---@return string
function M.describe(spec)
  if spec.kind == "worktree" then
    return "Index ↔ Working Tree"
  elseif spec.kind == "index" then
    return "HEAD ↔ Index"
  elseif spec.kind == "head" then
    return "HEAD ↔ Working Tree"
  elseif spec.kind == "commit" then
    return ("%s^ ↔ %s"):format(spec.from or "?", spec.from or "?")
  elseif spec.kind == "merge_base" then
    return ("%s ... %s"):format(spec.from or "?", spec.to or "?")
  end
  return ("%s ↔ %s"):format(spec.from or "HEAD", spec.to or "Working Tree")
end

---Short labels for the two sides of a comparison.
---@param spec GitDiffSpec
---@return string left, string right
function M.side_labels(spec)
  if spec.kind == "worktree" then
    return "index", "working tree"
  elseif spec.kind == "index" then
    return "HEAD", "index"
  elseif spec.kind == "head" then
    return "HEAD", "working tree"
  elseif spec.kind == "commit" then
    local rev = spec.from or "HEAD"
    return rev .. "^", rev
  end
  return spec.from or "HEAD", spec.to or "working tree"
end

---Base git arguments shared by every diff query.
---
---`--no-ext-diff` and `--no-textconv` keep a user's external difftool or
---textconv filter from replacing the content we are about to parse, and the
---explicit prefixes defeat `diff.noprefix` / `diff.mnemonicPrefix`.
---@param opts { context: integer|nil, ignore_whitespace: boolean|nil, renames: boolean|nil }|nil
---@return string[]
local function base_args(opts)
  opts = opts or {}
  local diff_config = config.options.diff
  local args = {
    "diff",
    "--no-color",
    "--no-ext-diff",
    "--no-textconv",
    "--src-prefix=a/",
    "--dst-prefix=b/",
    "--ignore-submodules=dirty",
    "-U" .. tostring(opts.context or diff_config.context),
    "--diff-algorithm=" .. (diff_config.algorithm or "histogram"),
  }
  if opts.renames ~= false then
    table.insert(args, "--find-renames")
  end
  if opts.ignore_whitespace or diff_config.ignore_whitespace then
    table.insert(args, "--ignore-all-space")
  end
  return args
end

---Translate a spec into the revision selector portion of the argument list.
---@param spec GitDiffSpec
---@return string[] args, string|nil error
local function spec_args(spec)
  if spec.kind == "worktree" then
    return {}
  elseif spec.kind == "index" then
    return { "--cached" }
  elseif spec.kind == "head" then
    return { "HEAD" }
  elseif spec.kind == "commit" then
    if not spec.from then
      return {}, "commit diff requires a revision"
    end
    -- `<rev>^!` is "this commit against its parents" and, unlike `<rev>^..<rev>`,
    -- it does not fail on a root commit.
    return { spec.from .. "^!" }
  elseif spec.kind == "merge_base" then
    if not (spec.from and spec.to) then
      return {}, "merge-base diff requires two revisions"
    end
    return { spec.from .. "..." .. spec.to }
  elseif spec.kind == "range" then
    if not spec.from then
      return {}, "range diff requires at least one revision"
    end
    if spec.to then
      return { spec.from, spec.to }
    end
    return { spec.from }
  end
  return {}, "unknown diff kind: " .. tostring(spec.kind)
end

---@param spec GitDiffSpec
---@param extra string[]|nil
---@param opts table|nil
---@return string[]|nil args, string|nil error
local function build(spec, extra, opts)
  local args = base_args(opts)
  local revisions, err = spec_args(spec)
  if err then
    return nil, err
  end
  vim.list_extend(args, revisions)
  if extra then
    vim.list_extend(args, extra)
  end
  if spec.paths and #spec.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, spec.paths)
  end
  return args, nil
end

--- Per-file diffs -----------------------------------------------------------

---Split a multi-file diff into per-file sections.
---
---Rather than parsing the `diff --git a/x b/x` line — which is genuinely
---ambiguous for paths containing " b/" — callers pass the paths they asked
---for, and single-file queries (the common case) never need splitting at all.
---@param raw string
---@return string[] sections
local function split_files(raw)
  local sections = {}
  local current = nil
  for line in (raw .. "\n"):gmatch("([^\n]*)\n") do
    if line:sub(1, 11) == "diff --git " then
      current = { line }
      sections[#sections + 1] = current
    elseif current then
      current[#current + 1] = line
    end
  end
  local out = {}
  for _, lines in ipairs(sections) do
    out[#out + 1] = table.concat(lines, "\n")
  end
  return out
end

---Parse the metadata git puts between `diff --git` and the first `@@`.
---@param raw string
---@return { binary: boolean, mode_change: table|nil, old_path: string|nil, new_file: boolean, deleted_file: boolean }
local function parse_file_header(raw)
  local info = { binary = false, new_file = false, deleted_file = false }
  for line in raw:gmatch("([^\n]*)\n") do
    if line:sub(1, 2) == "@@" then
      break
    end
    if line:match("^Binary files ") or line:match("^GIT binary patch") then
      info.binary = true
    elseif line:match("^new file mode") then
      info.new_file = true
    elseif line:match("^deleted file mode") then
      info.deleted_file = true
    elseif line:match("^rename from ") then
      info.old_path = line:sub(#"rename from " + 1)
    elseif line:match("^copy from ") then
      info.old_path = line:sub(#"copy from " + 1)
    else
      local old_mode = line:match("^old mode (%d+)")
      local new_mode = line:match("^new mode (%d+)")
      if old_mode then
        info.mode_change = info.mode_change or {}
        info.mode_change.old = old_mode
      elseif new_mode then
        info.mode_change = info.mode_change or {}
        info.mode_change.new = new_mode
      end
    end
  end
  return info
end

---Diff a single file.
---@param repo GitRepository
---@param path string  repository-relative
---@param spec GitDiffSpec
---@param opts { context: integer|nil, ignore_whitespace: boolean|nil }|nil
---@param callback fun(diff: GitFileDiff|nil, err: GitError|nil)
---@return GitHandle|nil
function M.file(repo, path, spec, opts, callback)
  local scoped = vim.tbl_extend("force", spec, { paths = { path } })
  local args, err = build(scoped, nil, opts)
  if not args then
    return callback(nil, { kind = "invalid_spec", title = "Cannot build diff", reason = err, raw = "" })
  end

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    local raw = result.stdout
    local info = parse_file_header(raw .. "\n")

    ---@type GitFileDiff
    local diff = {
      path = path,
      old_path = info.old_path,
      raw = raw,
      hunks = info.binary and {} or hunks_api.parse(raw),
      binary = info.binary,
      mode_change = info.mode_change,
      spec = spec,
    }
    callback(diff, nil)
  end)
end

---Diff every file touched by a spec.
---@param repo GitRepository
---@param spec GitDiffSpec
---@param opts table|nil
---@param callback fun(diffs: GitFileDiff[]|nil, err: GitError|nil)
---@return GitHandle|nil
function M.files(repo, spec, opts, callback)
  local args, err = build(spec, nil, opts)
  if not args then
    return callback(nil, { kind = "invalid_spec", title = "Cannot build diff", reason = err, raw = "" })
  end

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    local diffs = {}
    for _, section in ipairs(split_files(result.stdout)) do
      local info = parse_file_header(section .. "\n")
      -- The `+++ b/<path>` line is the authoritative name: it ends at a tab or
      -- at end of line, with no ambiguity from the path's own contents.
      local new_name = section:match("\n%+%+%+ b/([^\n\t]*)") or section:match("\n%+%+%+ ([^\n\t]*)")
      local old_name = section:match("\n%-%-%- a/([^\n\t]*)")
      local path = new_name
      if not path or path == "/dev/null" then
        path = old_name
      end
      if path then
        diffs[#diffs + 1] = {
          path = path,
          old_path = info.old_path or (old_name ~= path and old_name or nil),
          raw = section,
          hunks = info.binary and {} or hunks_api.parse(section),
          binary = info.binary,
          mode_change = info.mode_change,
          spec = spec,
        }
      end
    end
    callback(diffs, nil)
  end)
end

--- Summaries ------------------------------------------------------------------

---@class GitDiffStat
---@field path string
---@field old_path string|nil
---@field added integer
---@field removed integer
---@field binary boolean

---Per-file added/removed line counts.
---@param repo GitRepository
---@param spec GitDiffSpec
---@param callback fun(stats: GitDiffStat[]|nil, err: GitError|nil)
---@return GitHandle|nil
function M.numstat(repo, spec, callback)
  local args, err = build(spec, { "--numstat", "-z" }, { context = 0 })
  if not args then
    return callback(nil, { kind = "invalid_spec", title = "Cannot build diff", reason = err, raw = "" })
  end

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    -- With `-z`, numstat emits "added\tremoved\t" then the path as its own
    -- NUL-terminated field; a rename adds a second path field.
    local stats = {}
    local fields = text_util.nul_split(result.stdout)
    local index = 1
    while index <= #fields do
      local field = fields[index]
      local added, removed, inline_path = field:match("^(%S+)\t(%S+)\t?(.*)$")
      if added then
        local entry = {
          added = tonumber(added) or 0,
          removed = tonumber(removed) or 0,
          binary = added == "-",
        }
        if inline_path ~= "" then
          entry.path = inline_path
          index = index + 1
        else
          -- Rename: old path then new path follow as separate fields.
          entry.old_path = fields[index + 1]
          entry.path = fields[index + 2]
          index = index + 3
        end
        if entry.path then
          stats[#stats + 1] = entry
        end
      else
        index = index + 1
      end
    end
    callback(stats, nil)
  end)
end

---@class GitNameStatus
---@field path string
---@field old_path string|nil
---@field status string  single letter: A M D R C T
---@field score integer|nil

---Changed paths with their change type.
---@param repo GitRepository
---@param spec GitDiffSpec
---@param callback fun(entries: GitNameStatus[]|nil, err: GitError|nil)
---@return GitHandle|nil
function M.name_status(repo, spec, callback)
  local args, err = build(spec, { "--name-status", "-z" }, { context = 0 })
  if not args then
    return callback(nil, { kind = "invalid_spec", title = "Cannot build diff", reason = err, raw = "" })
  end

  return command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    local entries = {}
    local fields = text_util.nul_split(result.stdout)
    local index = 1
    while index <= #fields do
      local code = fields[index]
      index = index + 1
      if code and code ~= "" then
        local letter = code:sub(1, 1)
        local score = tonumber(code:sub(2))
        if letter == "R" or letter == "C" then
          local old_path = fields[index]
          local path = fields[index + 1]
          index = index + 2
          if path then
            entries[#entries + 1] = { status = letter, score = score, old_path = old_path, path = path }
          end
        else
          local path = fields[index]
          index = index + 1
          if path then
            entries[#entries + 1] = { status = letter, score = score, path = path }
          end
        end
      end
    end
    callback(entries, nil)
  end)
end

--- Blob access ----------------------------------------------------------------

---Read the content of a path at a revision.
---
---`rev` may be a commit-ish, `:0` for the index, or `:1`/`:2`/`:3` for the
---base/ours/theirs stages of a conflicted file.
---@param repo GitRepository
---@param rev string
---@param path string
---@param callback fun(content: string|nil, err: GitError|nil)
---@return GitHandle
function M.blob(repo, rev, path, callback)
  -- `:0:path` for an index stage, `<rev>:path` for a commit. Only the first
  -- colon separates, so a path containing one is unambiguous either way.
  local object = rev .. ":" .. path
  return command.run({ "--no-replace-objects", "cat-file", "blob", object }, { cwd = repo.root }, function(result)
    if not result.ok then
      -- A path that does not exist at this revision is an expected outcome
      -- (a newly added file has no HEAD version), not an error to report.
      if result.stderr:find("does not exist") or result.stderr:find("exists on disk, but not in") then
        return callback("", nil)
      end
      return callback(nil, command.classify(result))
    end
    callback(result.stdout, nil)
  end)
end

---Content of a path in the index (stage 0).
---@param repo GitRepository
---@param path string
---@param callback fun(content: string|nil, err: GitError|nil)
function M.index_blob(repo, path, callback)
  return M.blob(repo, ":0", path, callback)
end

---Is this path tracked in the index?
---@param repo GitRepository
---@param path string
---@param callback fun(tracked: boolean)
function M.is_tracked(repo, path, callback)
  command.run({ "ls-files", "--error-unmatch", "-z", "--", path }, { cwd = repo.root }, function(result)
    callback(result.ok)
  end)
end

return M
