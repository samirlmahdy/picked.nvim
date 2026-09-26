---@brief Repository discovery and low-level repository state.
---
---Discovery never assumes `cwd` is the repository root, that `.git` is a
---directory (it is a file in linked worktrees and submodules), or that a single
---repository is in play. Results are cached per directory, including negative
---results, because Neovim asks "which repo owns this buffer?" constantly.

local command = require("picked.git.command")
local logger = require("picked.utils.logger")
local path_util = require("picked.utils.path")

local M = {}

---@class GitRepository
---@field root string  absolute worktree root
---@field git_dir string  absolute git directory for this worktree
---@field common_dir string  shared git directory (differs in linked worktrees)
---@field is_linked_worktree boolean
---@field is_bare boolean
---@field name string  display name

---@class GitRepoState
---@field kind "normal"|"merge"|"rebase"|"rebase-interactive"|"am"|"cherry-pick"|"revert"|"bisect"
---@field label string  human-readable, e.g. "REBASE IN PROGRESS"
---@field step integer|nil  current step of a sequencer operation
---@field total integer|nil  total steps
---@field head_name string|nil  branch a rebase will return to

---@class GitHead
---@field detached boolean
---@field branch string|nil  branch name when attached
---@field oid string|nil  full object id
---@field short string|nil  abbreviated object id
---@field unborn boolean  true on a fresh repository with no commits

--- Discovery ---------------------------------------------------------------

---@type table<string, GitRepository|false>
local cache = {}

---Cheap filesystem probe: walk up looking for a `.git` entry of any kind.
---Avoids spawning git for the very common "this buffer is not in a repo" case.
---@param dir string
---@return boolean
local function has_git_ancestor(dir)
  local current = dir
  for _ = 1, 64 do
    if vim.uv.fs_stat(path_util.to_os(current .. "/.git")) then
      return true
    end
    local parent = path_util.dirname(current)
    if parent == "" or parent == current then
      return false
    end
    current = parent
  end
  return false
end

---@param value string
---@param base string
---@return string
local function resolve_git_path(value, base)
  if value == "" then
    return ""
  end
  local normalized = path_util.normalize(value)
  -- `--git-common-dir` can be relative to the working directory.
  if normalized:sub(1, 1) == "/" or normalized:match("^%a:/") then
    return path_util.absolute(normalized)
  end
  return path_util.absolute(path_util.join(base, normalized))
end

---Detect the repository containing `dir`.
---@param dir string
---@return GitRepository|nil repo, string|nil error
function M.detect(dir)
  if not dir or dir == "" then
    return nil, "no directory"
  end

  dir = path_util.absolute(dir)

  local cached = cache[dir]
  if cached ~= nil then
    if cached == false then
      return nil, "not a git repository"
    end
    return cached
  end

  local stat = vim.uv.fs_stat(path_util.to_os(dir))
  if not stat then
    cache[dir] = false
    return nil, "directory does not exist"
  end
  if stat.type ~= "directory" then
    dir = path_util.dirname(dir)
  end

  if not has_git_ancestor(dir) then
    cache[dir] = false
    return nil, "not a git repository"
  end

  -- `--path-format=absolute` (git 2.31+) removes the need to resolve
  -- `--git-common-dir` by hand; older git falls back to relative output which
  -- `resolve_git_path` handles.
  local rev_parse_args = { "rev-parse" }
  if command.version_at_least(2, 31) then
    table.insert(rev_parse_args, "--path-format=absolute")
  end
  vim.list_extend(rev_parse_args, {
    "--show-toplevel",
    "--absolute-git-dir",
    "--git-common-dir",
    "--is-bare-repository",
  })

  local result = command.run_sync(rev_parse_args, { cwd = dir, timeout = 5000 })

  if not result.ok then
    cache[dir] = false
    logger.debug("repository detection failed for", dir, result.stderr)
    return nil, command.classify(result).reason
  end

  local lines = vim.split(vim.trim(result.stdout), "\n", { plain = true })
  local toplevel = lines[1] and vim.trim(lines[1]) or ""
  local git_dir = lines[2] and vim.trim(lines[2]) or ""
  local common_dir = lines[3] and vim.trim(lines[3]) or git_dir
  local bare = (lines[4] and vim.trim(lines[4])) == "true"

  if toplevel == "" and not bare then
    cache[dir] = false
    return nil, "not inside a working tree"
  end

  local root = bare and resolve_git_path(git_dir, dir) or path_util.absolute(toplevel)
  git_dir = resolve_git_path(git_dir, dir)
  common_dir = resolve_git_path(common_dir, dir)

  ---@type GitRepository
  local repo = {
    root = root,
    git_dir = git_dir,
    common_dir = common_dir ~= "" and common_dir or git_dir,
    is_linked_worktree = common_dir ~= "" and common_dir ~= git_dir,
    is_bare = bare,
    name = path_util.basename(root),
  }

  cache[dir] = repo
  -- The root resolves to itself, so remember that mapping too.
  cache[repo.root] = repo
  logger.debug("detected repository", repo.root, repo.is_linked_worktree and "(linked worktree)" or "")

  return repo
end

---Repository owning a buffer, falling back to the buffer's directory.
---@param bufnr integer|nil
---@return GitRepository|nil
function M.for_buffer(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local file = path_util.buffer_path(bufnr)
  if file then
    return (M.detect(path_util.dirname(file)))
  end
  return nil
end

---Repository for the current context: the current buffer's file if it has one,
---otherwise the window-local or global working directory.
---@return GitRepository|nil repo, string|nil error
function M.current()
  local repo = M.for_buffer(0)
  if repo then
    return repo
  end
  return M.detect(vim.uv.cwd() or ".")
end

---Forget cached detection results.
---@param dir string|nil  clears everything when omitted
function M.invalidate(dir)
  if not dir then
    cache = {}
    return
  end
  dir = path_util.absolute(dir)
  for key in pairs(cache) do
    if key == dir or path_util.is_within(key, dir) then
      cache[key] = nil
    end
  end
end

--- Repository state --------------------------------------------------------

---@param git_dir string
---@param name string
---@return boolean
local function git_file_exists(git_dir, name)
  return vim.uv.fs_stat(path_util.to_os(git_dir .. "/" .. name)) ~= nil
end

---@param git_dir string
---@param name string
---@return string|nil
local function read_git_file(git_dir, name)
  local file = io.open(path_util.to_os(git_dir .. "/" .. name), "r")
  if not file then
    return nil
  end
  local content = file:read("*a")
  file:close()
  return content and vim.trim(content) or nil
end

---Count the remaining picks of an in-progress rebase.
---@param git_dir string
---@param dir string
---@return integer|nil step, integer|nil total
local function rebase_progress(git_dir, dir)
  local msgnum = read_git_file(git_dir, dir .. "/msgnum")
  local last = read_git_file(git_dir, dir .. "/end")
  if msgnum and last then
    return tonumber(msgnum), tonumber(last)
  end

  -- Interactive rebases track progress through the todo lists instead.
  local done = read_git_file(git_dir, dir .. "/done")
  local todo = read_git_file(git_dir, dir .. "/git-rebase-todo")
  if done or todo then
    local function count(text)
      local n = 0
      for line in (text or ""):gmatch("[^\n]+") do
        if not line:match("^%s*#") and vim.trim(line) ~= "" then
          n = n + 1
        end
      end
      return n
    end
    local done_count = count(done)
    local todo_count = count(todo)
    return done_count, done_count + todo_count
  end

  return nil, nil
end

---Determine what operation, if any, the repository is in the middle of.
---
---Reads the sequencer files directly: this is exactly what git itself does and
---it costs no subprocess, which matters because the panel header refreshes
---often.
---@param repo GitRepository
---@return GitRepoState
function M.state(repo)
  local git_dir = repo.git_dir

  if git_file_exists(git_dir, "rebase-merge") then
    local interactive = git_file_exists(git_dir, "rebase-merge/interactive")
    local step, total = rebase_progress(git_dir, "rebase-merge")
    return {
      kind = interactive and "rebase-interactive" or "rebase",
      label = interactive and "INTERACTIVE REBASE IN PROGRESS" or "REBASE IN PROGRESS",
      step = step,
      total = total,
      head_name = (read_git_file(git_dir, "rebase-merge/head-name") or ""):gsub("^refs/heads/", ""),
    }
  end

  if git_file_exists(git_dir, "rebase-apply") then
    local is_am = git_file_exists(git_dir, "rebase-apply/applying")
    local step, total = rebase_progress(git_dir, "rebase-apply")
    return {
      kind = is_am and "am" or "rebase",
      label = is_am and "APPLYING PATCHES (am)" or "REBASE IN PROGRESS",
      step = step,
      total = total,
      head_name = (read_git_file(git_dir, "rebase-apply/head-name") or ""):gsub("^refs/heads/", ""),
    }
  end

  if git_file_exists(git_dir, "MERGE_HEAD") then
    return { kind = "merge", label = "MERGE IN PROGRESS" }
  end

  if git_file_exists(git_dir, "CHERRY_PICK_HEAD") then
    return { kind = "cherry-pick", label = "CHERRY-PICK IN PROGRESS" }
  end

  if git_file_exists(git_dir, "REVERT_HEAD") then
    return { kind = "revert", label = "REVERT IN PROGRESS" }
  end

  if git_file_exists(git_dir, "BISECT_LOG") then
    return { kind = "bisect", label = "BISECT IN PROGRESS" }
  end

  return { kind = "normal", label = "" }
end

---Current HEAD, read from the filesystem so the panel header never waits on a
---subprocess.
---@param repo GitRepository
---@return GitHead
function M.head(repo)
  local content = read_git_file(repo.git_dir, "HEAD")
  if not content then
    return { detached = false, unborn = true }
  end

  local ref = content:match("^ref:%s*(.+)$")
  if ref then
    local branch = ref:gsub("^refs/heads/", "")
    -- Resolve the branch to an oid; a missing ref means an unborn branch
    -- (a freshly initialised repository).
    local oid = read_git_file(repo.common_dir, ref)
    if not oid then
      local packed = read_git_file(repo.common_dir, "packed-refs")
      if packed then
        oid = packed:match("(%x40)%s+" .. vim.pesc(ref))
      end
    end
    return {
      detached = false,
      branch = branch,
      oid = oid,
      short = oid and oid:sub(1, 7) or nil,
      unborn = oid == nil,
    }
  end

  local oid = content:match("^(%x+)$")
  return {
    detached = true,
    branch = nil,
    oid = oid,
    short = oid and oid:sub(1, 7) or nil,
    unborn = false,
  }
end

--- Worktrees & submodules --------------------------------------------------

---@class GitWorktree
---@field path string
---@field head string|nil
---@field branch string|nil
---@field bare boolean
---@field detached boolean
---@field locked boolean
---@field prunable boolean
---@field is_current boolean

---List the worktrees of a repository.
---@param repo GitRepository
---@param callback fun(worktrees: GitWorktree[]|nil, err: GitError|nil)
function M.worktrees(repo, callback)
  -- `-z` on `worktree list` landed in git 2.36; without it the records are
  -- newline separated, which is safe here because the only variable field is a
  -- path and git quotes it when needed.
  local supports_nul = command.version_at_least(2, 36)
  local args = { "worktree", "list", "--porcelain" }
  if supports_nul then
    table.insert(args, "-z")
  end

  command.run(args, { cwd = repo.root }, function(result)
    if not result.ok then
      return callback(nil, command.classify(result))
    end

    local worktrees = {}
    local current = nil

    local text = require("picked.utils.text")
    local fields = supports_nul and text.nul_split(result.stdout)
      or vim.split(result.stdout:gsub("\n$", ""), "\n", { plain = true })

    for _, field in ipairs(fields) do
      if field == "" then
        if current then
          worktrees[#worktrees + 1] = current
          current = nil
        end
      else
        local key, value = field:match("^(%S+)%s*(.*)$")
        if key == "worktree" then
          if current then
            worktrees[#worktrees + 1] = current
          end
          current = {
            path = path_util.absolute(value),
            bare = false,
            detached = false,
            locked = false,
            prunable = false,
          }
        elseif current then
          if key == "HEAD" then
            current.head = value
          elseif key == "branch" then
            current.branch = value:gsub("^refs/heads/", "")
          elseif key == "bare" then
            current.bare = true
          elseif key == "detached" then
            current.detached = true
          elseif key == "locked" then
            current.locked = true
          elseif key == "prunable" then
            current.prunable = true
          end
        end
      end
    end
    if current then
      worktrees[#worktrees + 1] = current
    end

    for _, worktree in ipairs(worktrees) do
      worktree.is_current = worktree.path == repo.root
    end

    callback(worktrees, nil)
  end)
end

---@class GitSubmodule
---@field path string  relative to the repository root
---@field name string
---@field url string|nil
---@field initialized boolean

---List submodules. Detection only: picked never mutates a submodule implicitly.
---@param repo GitRepository
---@param callback fun(submodules: GitSubmodule[], err: GitError|nil)
function M.submodules(repo, callback)
  -- `config -f .gitmodules` avoids recursing into the submodules themselves,
  -- which on a large superproject is prohibitively slow.
  command.run(
    -- POSIX extended regex, not a Lua pattern.
    { "config", "-z", "--file", ".gitmodules", "--get-regexp", "^submodule\\..*\\.path$" },
    { cwd = repo.root },
    function(result)
      if not result.ok then
        -- No .gitmodules is the overwhelmingly common case, not an error.
        return callback({}, nil)
      end

      local text = require("picked.utils.text")
      local submodules = {}
      for _, record in ipairs(text.nul_split(result.stdout)) do
        -- Records are "key\nvalue" with NUL between entries.
        local key, value = record:match("^([^\n]+)\n(.*)$")
        if key and value then
          local name = key:match("^submodule%.(.+)%.path$")
          if name then
            submodules[#submodules + 1] = {
              name = name,
              path = path_util.normalize(value),
              initialized = vim.uv.fs_stat(path_util.to_os(repo.root .. "/" .. value .. "/.git")) ~= nil,
            }
          end
        end
      end

      table.sort(submodules, function(a, b)
        return a.path < b.path
      end)
      callback(submodules, nil)
    end
  )
end

---Set of submodule paths, for O(1) lookup while rendering status entries.
---@param repo GitRepository
---@param callback fun(paths: table<string, boolean>)
function M.submodule_paths(repo, callback)
  M.submodules(repo, function(submodules)
    local set = {}
    for _, submodule in ipairs(submodules) do
      set[submodule.path] = true
    end
    callback(set)
  end)
end

return M
