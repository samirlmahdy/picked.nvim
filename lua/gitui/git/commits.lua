---@brief Commit history, commit inspection and commit creation.
---
---`git log -z` terminates each record with NUL and fields are separated with
---`%x1f` (ASCII unit separator), so a commit body containing blank lines,
---tabs or any punctuation is parsed without ambiguity.

local command = require("gitui.git.command")
local config = require("gitui.config")

local M = {}

---@class GitRef
---@field name string
---@field kind "head"|"branch"|"remote"|"tag"|"stash"|"other"

---@class GitCommit
---@field oid string
---@field short string
---@field parents string[]
---@field author_name string
---@field author_email string
---@field author_date integer
---@field committer_name string
---@field committer_email string
---@field committer_date integer
---@field refs GitRef[]
---@field subject string
---@field body string
---@field is_merge boolean

local UNIT = "\31"

local FIELDS = {
  "oid",
  "short",
  "parents",
  "author_name",
  "author_email",
  "author_date",
  "committer_name",
  "committer_email",
  "committer_date",
  "refs",
  "subject",
  "body",
}

local FORMAT = table.concat({
  "%H",
  "%h",
  "%P",
  "%an",
  "%ae",
  "%at",
  "%cn",
  "%ce",
  "%ct",
  "%D",
  "%s",
  "%b",
}, "%x1f")

---Parse the decoration list from `%D`: "HEAD -> main, origin/main, tag: v1".
---@param decoration string
---@return GitRef[]
local function parse_refs(decoration)
  local refs = {}
  if decoration == "" then
    return refs
  end
  for entry in decoration:gmatch("[^,]+") do
    local name = vim.trim(entry)
    if name ~= "" then
      local kind = "branch"
      local head_target = name:match("^HEAD %->%s*(.+)$")
      if head_target then
        refs[#refs + 1] = { name = "HEAD", kind = "head" }
        name = head_target
      elseif name == "HEAD" then
        kind = "head"
      end

      local tag = name:match("^tag:%s*(.+)$")
      if tag then
        name, kind = tag, "tag"
      elseif kind ~= "head" then
        kind = name:find("/") and "remote" or "branch"
      end
      refs[#refs + 1] = { name = name, kind = kind }
    end
  end
  return refs
end

---Parse `git log -z` output produced with FORMAT.
---@param raw string
---@return GitCommit[]
function M.parse(raw)
  local commits = {}
  local text_util = require("gitui.utils.text")

  for _, record in ipairs(text_util.nul_split(raw)) do
    -- `-z` puts the NUL *between* records, so every record after the first
    -- begins with the newline that terminated the previous one.
    record = record:gsub("^\n", "")
    if record ~= "" then
      local values = vim.split(record, UNIT, { plain = true })
      if #values >= #FIELDS - 1 then
        local fields = {}
        for index, name in ipairs(FIELDS) do
          fields[name] = values[index] or ""
        end

        local parents = {}
        for parent in fields.parents:gmatch("%S+") do
          parents[#parents + 1] = parent
        end

        commits[#commits + 1] = {
          oid = fields.oid,
          short = fields.short,
          parents = parents,
          author_name = fields.author_name,
          author_email = fields.author_email,
          author_date = tonumber(fields.author_date) or 0,
          committer_name = fields.committer_name,
          committer_email = fields.committer_email,
          committer_date = tonumber(fields.committer_date) or 0,
          refs = parse_refs(fields.refs),
          subject = fields.subject,
          body = (fields.body:gsub("%s+$", "")),
          is_merge = #parents > 1,
        }
      end
    end
  end

  return commits
end

---@class GitLogOpts
---@field max_count integer|nil
---@field skip integer|nil
---@field revisions string[]|nil  revision arguments ("main", "a..b", "--all")
---@field paths string[]|nil
---@field author string|nil
---@field grep string|nil
---@field follow boolean|nil  track a single file across renames
---@field first_parent boolean|nil
---@field all boolean|nil
---@field reverse boolean|nil

---@param opts GitLogOpts|nil
---@return string[]
function M.build_args(opts)
  opts = opts or {}
  local args = {
    "log",
    "-z",
    "--format=" .. FORMAT,
    "--no-show-signature",
    "--date-order",
  }

  table.insert(args, "--max-count=" .. tostring(opts.max_count or config.options.log.page_size))
  if opts.skip and opts.skip > 0 then
    table.insert(args, "--skip=" .. tostring(opts.skip))
  end
  if opts.all then
    table.insert(args, "--all")
  end
  if opts.first_parent then
    table.insert(args, "--first-parent")
  end
  if opts.reverse then
    table.insert(args, "--reverse")
  end
  if opts.author then
    table.insert(args, "--author=" .. opts.author)
  end
  if opts.grep then
    table.insert(args, "--grep=" .. opts.grep)
    table.insert(args, "--regexp-ignore-case")
  end
  if opts.follow then
    -- `--follow` only works with exactly one pathspec.
    table.insert(args, "--follow")
  end
  if opts.revisions then
    vim.list_extend(args, opts.revisions)
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end
  return args
end

---Read commit history.
---@param repo GitRepository
---@param opts GitLogOpts|nil
---@param callback fun(commits: GitCommit[]|nil, err: GitError|nil)
---@return GitHandle
function M.log(repo, opts, callback)
  return command.run(M.build_args(opts), { cwd = repo.root }, function(result)
    if not result.ok then
      -- An unborn branch has no commits; that is an empty history, not a
      -- failure the user needs to hear about.
      if result.stderr:find("does not have any commits yet") or result.stderr:find("unknown revision") then
        return callback({}, nil)
      end
      return callback(nil, command.classify(result))
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---History of a single file, following renames.
---@param repo GitRepository
---@param path string
---@param opts GitLogOpts|nil
---@param callback fun(commits: GitCommit[]|nil, err: GitError|nil)
function M.file_history(repo, path, opts, callback)
  local merged = vim.tbl_extend("force", opts or {}, { paths = { path }, follow = true })
  return M.log(repo, merged, callback)
end

---History of a range of lines within a file.
---
---`git log -L` cannot be combined with `-z`, so the records are read with
---`--no-patch` and a newline-delimited format instead. A commit oid contains
---no newline, which makes that unambiguous.
---@param repo GitRepository
---@param path string
---@param first integer
---@param last integer
---@param opts { max_count: integer|nil }|nil
---@param callback fun(commits: GitCommit[]|nil, err: GitError|nil)
function M.line_history(repo, path, first, last, opts, callback)
  opts = opts or {}
  local args = {
    "log",
    "--no-patch",
    "--format=%H",
    "--max-count=" .. tostring(opts.max_count or 64),
    ("-L%d,%d:%s"):format(first, last, path),
  }

  command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    local oids = {}
    for line in result.stdout:gmatch("[^\n]+") do
      if line:match("^%x+$") then
        oids[#oids + 1] = line
      end
    end
    if #oids == 0 then
      return callback({}, nil)
    end

    -- Re-read the selected commits through the normal format so callers get
    -- the same GitCommit shape as everywhere else.
    M.show_many(repo, oids, callback)
  end)
end

---Load full records for a specific list of revisions, preserving their order.
---@param repo GitRepository
---@param oids string[]
---@param callback fun(commits: GitCommit[]|nil, err: GitError|nil)
function M.show_many(repo, oids, callback)
  if #oids == 0 then
    return callback({}, nil)
  end
  local args = {
    "log",
    "-z",
    "--format=" .. FORMAT,
    "--no-show-signature",
    "--no-walk",
  }
  vim.list_extend(args, oids)

  command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end
    callback(M.parse(result.stdout), nil)
  end)
end

---Load a single commit.
---@param repo GitRepository
---@param revision string
---@param callback fun(commit: GitCommit|nil, err: GitError|nil)
function M.show(repo, revision, callback)
  M.show_many(repo, { revision }, function(commits, err)
    if err then
      return callback(nil, err)
    end
    if not commits or #commits == 0 then
      return callback(nil, {
        kind = "not_found",
        title = "Commit not found",
        reason = ("No commit matches '%s'."):format(revision),
        raw = "",
      })
    end
    callback(commits[1], nil)
  end)
end

---Count commits reachable from a revision, for pagination UI.
---@param repo GitRepository
---@param revisions string[]|nil
---@param callback fun(count: integer)
function M.count(repo, revisions, callback)
  local args = { "rev-list", "--count" }
  vim.list_extend(args, revisions or { "HEAD" })
  command.run(args, { cwd = repo.root }, function(result)
    callback(result.ok and (tonumber(vim.trim(result.stdout)) or 0) or 0)
  end)
end

--- Commit creation -----------------------------------------------------------

---@class GitCommitOpts
---@field message string
---@field amend boolean|nil
---@field no_verify boolean|nil  skip hooks; never the default
---@field signoff boolean|nil
---@field allow_empty boolean|nil
---@field paths string[]|nil  commit only these paths
---@field reset_author boolean|nil
---@field sign boolean|nil  nil inherits the repository's commit.gpgsign

---Create a commit.
---
---The message is written to stdin rather than an argument so its bytes reach
---git exactly as typed, whatever their length or content. Hooks run normally:
---bypassing them requires an explicit `no_verify`.
---@param repo GitRepository
---@param opts GitCommitOpts
---@param callback fun(ok: boolean, err: GitError|nil, output: string|nil)
function M.commit(repo, opts, callback)
  local message = opts.message or ""
  if vim.trim(message) == "" and not opts.allow_empty then
    return callback(false, {
      kind = "empty_message",
      title = "Empty commit message",
      reason = "A commit needs a message.",
      hint = "Write a subject line, then commit again.",
      raw = "",
    })
  end

  local args = { "commit", "--file=-" }
  if opts.amend then
    table.insert(args, "--amend")
  end
  if opts.no_verify then
    table.insert(args, "--no-verify")
  end
  if opts.signoff then
    table.insert(args, "--signoff")
  end
  if opts.allow_empty then
    table.insert(args, "--allow-empty")
  end
  if opts.reset_author then
    table.insert(args, "--reset-author")
  end
  -- Signing is left to git's own configuration unless explicitly overridden,
  -- so a repository configured for GPG or SSH signing keeps working.
  if opts.sign == true then
    table.insert(args, "--gpg-sign")
  elseif opts.sign == false then
    table.insert(args, "--no-gpg-sign")
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end

  command.run(args, {
    cwd = repo.root,
    stdin = message,
    serialize = true,
    hooks = true,
  }, function(result)
    if result.ok then
      return callback(true, nil, result.stdout)
    end
    local err = command.classify(result)
    -- A failing hook is the most common commit failure and its output is the
    -- only thing that explains why, so it is surfaced verbatim.
    if result.stdout ~= "" then
      err.raw = result.stdout .. "\n" .. err.raw
    end
    callback(false, err, result.stdout)
  end)
end

---Message of an existing commit, used to prefill an amend.
---@param repo GitRepository
---@param revision string
---@param callback fun(message: string|nil, err: GitError|nil)
function M.message(repo, revision, callback)
  command.run({ "log", "-1", "--format=%B", "--no-show-signature", revision }, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end
    callback((result.stdout:gsub("\n+$", "\n")), nil)
  end)
end

---The message git would suggest right now: an in-progress merge or a squash
---message left by the sequencer, otherwise empty.
---@param repo GitRepository
---@param callback fun(message: string)
function M.prepared_message(repo, callback)
  local path_util = require("gitui.utils.path")
  for _, name in ipairs({ "MERGE_MSG", "SQUASH_MSG" }) do
    local handle = io.open(path_util.to_os(repo.git_dir .. "/" .. name), "r")
    if handle then
      local content = handle:read("*a")
      handle:close()
      if content and vim.trim(content) ~= "" then
        -- Drop git's comment lines: the panel shows that information itself.
        local lines = {}
        for line in content:gmatch("([^\n]*)\n?") do
          if line:sub(1, 1) ~= "#" then
            lines[#lines + 1] = line
          end
        end
        return callback((table.concat(lines, "\n"):gsub("\n+$", "\n")))
      end
    end
  end
  callback("")
end

--- Cherry-pick and revert -----------------------------------------------------

---@param repo GitRepository
---@param revisions string[]
---@param opts { no_commit: boolean|nil, mainline: integer|nil }|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.cherry_pick(repo, revisions, opts, callback)
  opts = opts or {}
  local args = { "cherry-pick" }
  if opts.no_commit then
    table.insert(args, "--no-commit")
  end
  if opts.mainline then
    table.insert(args, "--mainline")
    table.insert(args, tostring(opts.mainline))
  end
  vim.list_extend(args, revisions)

  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end)
end

---Revert a commit by creating a new commit that undoes it.
---@param repo GitRepository
---@param revisions string[]
---@param opts { no_commit: boolean|nil, mainline: integer|nil }|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.revert(repo, revisions, opts, callback)
  opts = opts or {}
  local args = { "revert", "--no-edit" }
  if opts.no_commit then
    table.insert(args, "--no-commit")
  end
  if opts.mainline then
    table.insert(args, "--mainline")
    table.insert(args, tostring(opts.mainline))
  end
  vim.list_extend(args, revisions)

  command.run(args, { cwd = repo.root, serialize = true, hooks = true }, function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end)
end

---Create a tag.
---@param repo GitRepository
---@param name string
---@param opts { revision: string|nil, message: string|nil, force: boolean|nil }|nil
---@param callback fun(ok: boolean, err: GitError|nil)
function M.tag(repo, name, opts, callback)
  opts = opts or {}
  local args = { "tag" }
  if opts.force then
    table.insert(args, "--force")
  end
  if opts.message and opts.message ~= "" then
    table.insert(args, "--annotate")
    table.insert(args, "--file=-")
  end
  table.insert(args, name)
  if opts.revision then
    table.insert(args, opts.revision)
  end

  command.run(args, {
    cwd = repo.root,
    serialize = true,
    stdin = opts.message ~= "" and opts.message or nil,
  }, function(result)
    if result.ok then
      return callback(true, nil)
    end
    callback(false, command.classify(result))
  end)
end

return M
