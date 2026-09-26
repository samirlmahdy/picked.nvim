---@brief `git status` acquisition and parsing.
---
---Uses `--porcelain=v2 -z`, the only status format git documents as stable for
---machine consumption. `-z` removes every quoting ambiguity: paths containing
---spaces, tabs, quotes, backslashes, newlines or arbitrary UTF-8 arrive as
---literal bytes between NUL terminators.
---
---The parser is deliberately separated from process execution so the test
---suite can feed it exact byte sequences.

local command = require("gitui.git.command")
local text = require("gitui.utils.text")

local M = {}

---@alias GitStatusCode
---| '" "' unmodified
---| '"M"' modified
---| '"A"' added
---| '"D"' deleted
---| '"R"' renamed
---| '"C"' copied
---| '"T"' type changed
---| '"U"' unmerged
---| '"?"' untracked
---| '"!"' ignored

---@class GitFileEntry
---@field path string  path relative to the repository root, forward slashes
---@field orig_path string|nil  source path of a rename or copy
---@field index_status GitStatusCode  staged side (git's X)
---@field worktree_status GitStatusCode  working-tree side (git's Y)
---@field status string  two-character display code, e.g. "MM", "??", "UU"
---@field staged boolean  has changes in the index relative to HEAD
---@field unstaged boolean  has changes in the working tree relative to the index
---@field untracked boolean
---@field ignored boolean
---@field conflicted boolean
---@field conflict_label string|nil  e.g. "both modified"
---@field submodule boolean
---@field submodule_state { commit: boolean, modified: boolean, untracked: boolean }|nil
---@field score integer|nil  rename/copy similarity percentage
---@field kind "ordinary"|"rename"|"unmerged"|"untracked"|"ignored"
---@field mode_head integer|nil
---@field mode_index integer|nil
---@field mode_worktree integer|nil
---@field oid_head string|nil
---@field oid_index string|nil

---@class GitBranchInfo
---@field oid string|nil  full object id of HEAD, nil on an unborn branch
---@field head string|nil  branch name, nil when detached
---@field detached boolean
---@field unborn boolean
---@field upstream string|nil
---@field ahead integer
---@field behind integer

---@class GitStatusResult
---@field files GitFileEntry[]  every entry, sorted by path
---@field staged GitFileEntry[]
---@field unstaged GitFileEntry[]
---@field untracked GitFileEntry[]
---@field conflicts GitFileEntry[]
---@field ignored GitFileEntry[]
---@field by_path table<string, GitFileEntry>
---@field branch GitBranchInfo
---@field clean boolean

--- Conflict labelling -------------------------------------------------------

-- Derived from the XY pair of an unmerged entry, matching git's own wording.
local CONFLICT_LABELS = {
  DD = "both deleted",
  AU = "added by us",
  UD = "deleted by them",
  UA = "added by them",
  DU = "deleted by us",
  AA = "both added",
  UU = "both modified",
}

--- Parsing ------------------------------------------------------------------

---Convert porcelain v2's "unmodified" marker into the space used by
---`git status --short`, which is what users recognise.
---@param code string
---@return string
local function normalize_code(code)
  return code == "." and " " or code
end

---@param field string  the `sub` column, e.g. "N..." or "SC.U"
---@return boolean is_submodule, table|nil state
local function parse_submodule_field(field)
  if field:sub(1, 1) ~= "S" then
    return false, nil
  end
  return true, {
    commit = field:sub(2, 2) == "C",
    modified = field:sub(3, 3) == "M",
    untracked = field:sub(4, 4) == "U",
  }
end

---@param value string
---@return integer|nil
local function parse_mode(value)
  return tonumber(value, 8)
end

---Build an entry from the shared prefix of ordinary and rename records.
---@param x string
---@param y string
---@param kind string
---@param path string
---@return GitFileEntry
local function new_entry(x, y, kind, path)
  x = normalize_code(x)
  y = normalize_code(y)
  return {
    path = path,
    orig_path = nil,
    index_status = x,
    worktree_status = y,
    status = x .. y,
    staged = x ~= " " and x ~= "?" and x ~= "!",
    unstaged = y ~= " ",
    untracked = kind == "untracked",
    ignored = kind == "ignored",
    conflicted = kind == "unmerged",
    submodule = false,
    kind = kind,
  }
end

---Parse the output of `git status --porcelain=v2 -z --branch`.
---@param raw string  raw bytes from git, NUL separated
---@return GitStatusResult
function M.parse(raw)
  ---@type GitStatusResult
  local result = {
    files = {},
    staged = {},
    unstaged = {},
    untracked = {},
    conflicts = {},
    ignored = {},
    by_path = {},
    branch = {
      oid = nil,
      head = nil,
      detached = false,
      unborn = false,
      upstream = nil,
      ahead = 0,
      behind = 0,
    },
    clean = true,
  }

  local fields = text.nul_split(raw)
  local index = 1

  while index <= #fields do
    local field = fields[index]
    index = index + 1

    if field == "" then
      goto continue
    end

    local marker = field:sub(1, 1)

    if marker == "#" then
      --- Header: "# branch.oid <oid>" etc.
      local key, value = field:match("^# (%S+)%s*(.*)$")
      if key == "branch.oid" then
        if value == "(initial)" then
          result.branch.unborn = true
        else
          result.branch.oid = value
        end
      elseif key == "branch.head" then
        if value == "(detached)" then
          result.branch.detached = true
        else
          result.branch.head = value
        end
      elseif key == "branch.upstream" then
        result.branch.upstream = value ~= "" and value or nil
      elseif key == "branch.ab" then
        local ahead, behind = value:match("^%+(%-?%d+)%s+%-(%-?%d+)$")
        result.branch.ahead = tonumber(ahead) or 0
        result.branch.behind = tonumber(behind) or 0
      end
    elseif marker == "1" then
      --- Ordinary: "1 XY sub mH mI mW hH hI path"
      local xy, sub, mode_head, mode_index, mode_worktree, oid_head, oid_index, path =
        field:match("^1 (..) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
      if xy then
        local entry = new_entry(xy:sub(1, 1), xy:sub(2, 2), "ordinary", path)
        entry.mode_head = parse_mode(mode_head)
        entry.mode_index = parse_mode(mode_index)
        entry.mode_worktree = parse_mode(mode_worktree)
        entry.oid_head = oid_head
        entry.oid_index = oid_index
        entry.submodule, entry.submodule_state = parse_submodule_field(sub)
        result.files[#result.files + 1] = entry
      end
    elseif marker == "2" then
      --- Rename or copy: "2 XY sub mH mI mW hH hI Xscore path" then, as a
      --- *separate* NUL-terminated field, the original path.
      local xy, sub, mode_head, mode_index, mode_worktree, oid_head, oid_index, rename_field, path =
        field:match("^2 (..) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
      if xy then
        local entry = new_entry(xy:sub(1, 1), xy:sub(2, 2), "rename", path)
        entry.mode_head = parse_mode(mode_head)
        entry.mode_index = parse_mode(mode_index)
        entry.mode_worktree = parse_mode(mode_worktree)
        entry.oid_head = oid_head
        entry.oid_index = oid_index
        entry.submodule, entry.submodule_state = parse_submodule_field(sub)
        entry.score = tonumber(rename_field:sub(2))
        entry.orig_path = fields[index]
        index = index + 1
        result.files[#result.files + 1] = entry
      end
    elseif marker == "u" then
      --- Unmerged: "u XY sub m1 m2 m3 mW h1 h2 h3 path"
      local xy, sub, _, _, _, _, _, _, _, path =
        field:match("^u (..) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (%S+) (.*)$")
      if xy then
        local entry = new_entry(xy:sub(1, 1), xy:sub(2, 2), "unmerged", path)
        -- A conflicted file is neither staged nor unstaged: it must be
        -- resolved before either concept applies.
        entry.staged = false
        entry.unstaged = false
        entry.status = xy
        entry.conflict_label = CONFLICT_LABELS[xy] or "conflicted"
        entry.submodule, entry.submodule_state = parse_submodule_field(sub)
        result.files[#result.files + 1] = entry
      end
    elseif marker == "?" then
      local path = field:sub(3)
      local entry = new_entry("?", "?", "untracked", path)
      entry.staged = false
      entry.unstaged = true
      result.files[#result.files + 1] = entry
    elseif marker == "!" then
      local path = field:sub(3)
      local entry = new_entry("!", "!", "ignored", path)
      entry.staged = false
      entry.unstaged = false
      result.files[#result.files + 1] = entry
    end

    ::continue::
  end

  table.sort(result.files, function(a, b)
    return a.path < b.path
  end)

  for _, entry in ipairs(result.files) do
    result.by_path[entry.path] = entry
    if entry.conflicted then
      result.conflicts[#result.conflicts + 1] = entry
    elseif entry.ignored then
      result.ignored[#result.ignored + 1] = entry
    elseif entry.untracked then
      result.untracked[#result.untracked + 1] = entry
      result.unstaged[#result.unstaged + 1] = entry
    else
      if entry.staged then
        result.staged[#result.staged + 1] = entry
      end
      if entry.unstaged then
        result.unstaged[#result.unstaged + 1] = entry
      end
    end
  end

  result.clean = #result.staged == 0 and #result.unstaged == 0 and #result.conflicts == 0

  return result
end

--- Acquisition ---------------------------------------------------------------

---@class GitStatusOpts
---@field untracked "all"|"normal"|"no"|nil  defaults to "all"
---@field ignored boolean|nil  include ignored files (expensive; default false)
---@field paths string[]|nil  limit to these pathspecs

---Build the argument vector for a status query.
---@param opts GitStatusOpts|nil
---@return string[]
function M.build_args(opts)
  opts = opts or {}
  local args = {
    "status",
    "--porcelain=v2",
    "-z",
    "--branch",
    "--untracked-files=" .. (opts.untracked or "all"),
    -- Report a submodule as modified only when its recorded commit changed;
    -- recursing into every submodule's working tree is far too slow on large
    -- superprojects and gitui never mutates submodules anyway.
    "--ignore-submodules=dirty",
  }
  if opts.ignored then
    table.insert(args, "--ignored=matching")
  end
  if opts.paths and #opts.paths > 0 then
    table.insert(args, "--")
    vim.list_extend(args, opts.paths)
  end
  return args
end

---Query the repository status.
---@param repo GitRepository
---@param opts GitStatusOpts|nil
---@param callback fun(status: GitStatusResult|nil, err: GitError|nil)
---@return GitHandle
function M.query(repo, opts, callback)
  return command.run(M.build_args(opts), { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end
    local ok, parsed = pcall(M.parse, result.stdout)
    if not ok then
      return callback(nil, {
        kind = "parse_error",
        title = "Could not read repository status",
        reason = tostring(parsed),
        hint = "Please report this with the output of `git status --porcelain=v2 -z --branch`.",
        raw = result.stdout,
      })
    end
    callback(parsed, nil)
  end)
end

--- Display helpers -----------------------------------------------------------

---Human-readable name of a status code.
---@param code string
---@return string
function M.describe_code(code)
  local names = {
    M = "modified",
    A = "added",
    D = "deleted",
    R = "renamed",
    C = "copied",
    T = "type changed",
    U = "conflicted",
    ["?"] = "untracked",
    ["!"] = "ignored",
    [" "] = "unmodified",
  }
  return names[code] or "unknown"
end

---Full description of an entry for a given side, used in headers and menus.
---@param entry GitFileEntry
---@param side "index"|"worktree"|nil
---@return string
function M.describe(entry, side)
  if entry.conflicted then
    return entry.conflict_label or "conflicted"
  end
  if entry.untracked then
    return "untracked"
  end
  if side == "index" then
    return M.describe_code(entry.index_status)
  end
  if side == "worktree" then
    return M.describe_code(entry.worktree_status)
  end
  local parts = {}
  if entry.staged then
    parts[#parts + 1] = "staged: " .. M.describe_code(entry.index_status)
  end
  if entry.unstaged then
    parts[#parts + 1] = M.describe_code(entry.worktree_status)
  end
  return table.concat(parts, ", ")
end

---The single status character to display for an entry in a given section.
---@param entry GitFileEntry
---@param side "index"|"worktree"|nil
---@return string
function M.code_for(entry, side)
  if entry.conflicted then
    return "U"
  end
  if entry.untracked then
    return "?"
  end
  if entry.ignored then
    return "!"
  end
  if side == "index" then
    return entry.index_status
  end
  if side == "worktree" then
    return entry.worktree_status ~= " " and entry.worktree_status or entry.index_status
  end
  return entry.worktree_status ~= " " and entry.worktree_status or entry.index_status
end

return M
