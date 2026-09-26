---@brief Temporary git repository builder for the test suite.
---
---Every helper runs git synchronously through a plain `vim.system` call rather
---than through the plugin, so a bug in the plugin's command layer cannot make
---a fixture silently wrong.

local M = {}

---@type string[]
local created = {}

---@param cwd string
---@param args string[]
---@return string stdout
function M.git(cwd, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local result = vim
    .system(cmd, {
      cwd = cwd,
      text = true,
      env = {
        GIT_AUTHOR_NAME = "gitui test",
        GIT_AUTHOR_EMAIL = "test@gitui.invalid",
        GIT_COMMITTER_NAME = "gitui test",
        GIT_COMMITTER_EMAIL = "test@gitui.invalid",
        GIT_AUTHOR_DATE = "2026-01-01T00:00:00+00:00",
        GIT_COMMITTER_DATE = "2026-01-01T00:00:00+00:00",
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
        GIT_TERMINAL_PROMPT = "0",
      },
    })
    :wait()
  assert(result.code == 0, ("git %s failed in %s:\n%s"):format(table.concat(args, " "), cwd, result.stderr or ""))
  return result.stdout or ""
end

---git invocation that is allowed to fail (merge conflicts, etc).
---@param cwd string
---@param args string[]
---@return integer code, string stdout, string stderr
function M.git_try(cwd, args)
  local cmd = { "git" }
  vim.list_extend(cmd, args)
  local result = vim
    .system(cmd, {
      cwd = cwd,
      text = true,
      env = {
        GIT_AUTHOR_NAME = "gitui test",
        GIT_AUTHOR_EMAIL = "test@gitui.invalid",
        GIT_COMMITTER_NAME = "gitui test",
        GIT_COMMITTER_EMAIL = "test@gitui.invalid",
        GIT_CONFIG_GLOBAL = "/dev/null",
        GIT_CONFIG_SYSTEM = "/dev/null",
        GIT_TERMINAL_PROMPT = "0",
      },
    })
    :wait()
  return result.code, result.stdout or "", result.stderr or ""
end

---Create an empty temporary directory that is removed by `M.cleanup()`.
---@param label string|nil
---@return string
function M.tmpdir(label)
  local base = vim.fn.tempname() .. "-" .. (label or "repo")
  vim.fn.mkdir(base, "p")
  created[#created + 1] = base
  -- Resolve symlinks up front: on macOS `/var` is a link to `/private/var`,
  -- and git reports the resolved form.
  return vim.uv.fs_realpath(base) or base
end

---@param dir string
---@param relative string
---@param content string
function M.write(dir, relative, content)
  local full = dir .. "/" .. relative
  local parent = vim.fn.fnamemodify(full, ":h")
  vim.fn.mkdir(parent, "p")
  local handle = assert(io.open(full, "wb"), "cannot write " .. full)
  handle:write(content)
  handle:close()
end

---@param dir string
---@param relative string
---@return string|nil
function M.read(dir, relative)
  local handle = io.open(dir .. "/" .. relative, "rb")
  if not handle then
    return nil
  end
  local content = handle:read("*a")
  handle:close()
  return content
end

---@param dir string
---@param relative string
function M.remove(dir, relative)
  os.remove(dir .. "/" .. relative)
end

---Initialise a repository with a deterministic configuration.
---@param label string|nil
---@return string root
function M.init(label)
  local dir = M.tmpdir(label)
  M.git(dir, { "init", "--quiet", "--initial-branch=main" })
  M.git(dir, { "config", "user.name", "gitui test" })
  M.git(dir, { "config", "user.email", "test@gitui.invalid" })
  M.git(dir, { "config", "commit.gpgsign", "false" })
  M.git(dir, { "config", "core.autocrlf", "false" })
  return dir
end

---@param dir string
---@param message string
function M.commit(dir, message)
  M.git(dir, { "commit", "--quiet", "--no-verify", "--allow-empty", "-m", message })
end

---A repository containing one commit and nothing else.
---@return string root
function M.simple()
  local dir = M.init("simple")
  M.write(dir, "README.md", "# project\n")
  M.git(dir, { "add", "README.md" })
  M.commit(dir, "initial commit")
  return dir
end

---The exhaustive fixture from the specification: every status code, awkward
---filenames, nested directories, renames and a binary file.
---@return string root
function M.kitchen_sink()
  local dir = M.init("kitchen")

  M.write(dir, "README.md", "# project\n")
  M.write(dir, "unchanged.txt", "untouched\n")
  M.write(dir, "modified.txt", "line one\nline two\nline three\n")
  M.write(dir, "deleted.txt", "goodbye\n")
  M.write(dir, "renamed-from.txt", string.rep("stable content line\n", 12))
  M.write(dir, "staged.txt", "before\n")
  M.write(dir, "mixed.txt", "base\n")
  M.write(dir, "src/api/users.lua", "return {}\n")
  M.write(dir, "src/deep/nested/dir/file.lua", "return 1\n")
  M.write(dir, "file with spaces.txt", "spaces\n")
  M.write(dir, 'quote"name.txt', "quoted\n")
  M.write(dir, "café/naïve-ünïcode.txt", "unicode\n")
  M.write(dir, "binary.bin", "\0\1\2\3\255\254binary\0data\n")
  M.git(dir, { "add", "-A" })
  M.commit(dir, "initial commit")

  -- " M" modified in the working tree only
  M.write(dir, "modified.txt", "line one\nline two CHANGED\nline three\n")
  -- " D" deleted in the working tree
  M.remove(dir, "deleted.txt")
  -- "M " staged modification
  M.write(dir, "staged.txt", "after\n")
  M.git(dir, { "add", "staged.txt" })
  -- "MM" staged then modified again
  M.write(dir, "mixed.txt", "staged change\n")
  M.git(dir, { "add", "mixed.txt" })
  M.write(dir, "mixed.txt", "staged change\nplus worktree change\n")
  -- "A " newly added
  M.write(dir, "src/models/user.lua", "return { name = 'user' }\n")
  M.git(dir, { "add", "src/models/user.lua" })
  -- "R " rename
  M.git(dir, { "mv", "renamed-from.txt", "renamed-to.txt" })
  -- "??" untracked, including one with a space and one with unicode
  M.write(dir, "untracked.md", "new\n")
  M.write(dir, "untracked dir/new file.md", "new\n")
  M.write(dir, "ünträcked.md", "new\n")

  return dir
end

---A repository sitting in a conflicted merge.
---@return string root
function M.conflicted()
  local dir = M.init("conflict")
  M.write(dir, "conflict.lua", "local function run()\n  return base()\nend\n")
  M.write(dir, "both-added.txt", "")
  M.remove(dir, "both-added.txt")
  M.write(dir, "shared.txt", "shared\n")
  M.git(dir, { "add", "-A" })
  M.commit(dir, "base")

  M.git(dir, { "checkout", "--quiet", "-b", "feature" })
  M.write(dir, "conflict.lua", "local function run()\n  return theirs()\nend\n")
  M.write(dir, "both-added.txt", "theirs\n")
  M.git(dir, { "add", "-A" })
  M.commit(dir, "feature change")

  M.git(dir, { "checkout", "--quiet", "main" })
  M.write(dir, "conflict.lua", "local function run()\n  return ours()\nend\n")
  M.write(dir, "both-added.txt", "ours\n")
  M.git(dir, { "add", "-A" })
  M.commit(dir, "main change")

  local code = M.git_try(dir, { "merge", "--no-edit", "feature" })
  assert(code ~= 0, "expected the merge to conflict")
  return dir
end

---A repository plus a bare "remote" it is already tracking.
---@return string root, string remote
function M.with_remote()
  local remote = M.tmpdir("remote")
  M.git(remote, { "init", "--quiet", "--bare", "--initial-branch=main" })

  local dir = M.simple()
  M.git(dir, { "remote", "add", "origin", remote })
  M.git(dir, { "push", "--quiet", "-u", "origin", "main" })
  return dir, remote
end

---Remove every directory created during the test run.
function M.cleanup()
  for _, dir in ipairs(created) do
    vim.fn.delete(dir, "rf")
  end
  created = {}
end

return M
