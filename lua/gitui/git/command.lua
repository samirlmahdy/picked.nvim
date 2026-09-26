---@brief Safe, asynchronous git process execution.
---
---This is the *only* module in the plugin allowed to spawn a git process.
---Everything above it receives parsed data structures.
---
---Guarantees provided here:
---  * Arguments are always passed as an argv array. No string interpolation,
---    no shell, therefore no injection surface (see `doc/ARCHITECTURE.md`).
---  * The environment is rebuilt from scratch so inherited `GIT_DIR`/
---    `GIT_INDEX_FILE` (set when Neovim is launched *by* git as its editor)
---    can never redirect an operation to the wrong repository.
---  * git can never block waiting for a terminal prompt or an editor.
---  * Mutating commands are serialised per repository so two operations cannot
---    race for `index.lock`.
---  * Every command has a timeout.

local config = require("gitui.config")
local logger = require("gitui.utils.logger")

local M = {}

---@class GitResult
---@field ok boolean  true when git exited 0
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field args string[]  arguments after the `git` executable
---@field cwd string
---@field duration integer milliseconds
---@field cancelled boolean
---@field timed_out boolean

---@class GitCommandOpts
---@field cwd string  repository directory the command runs in
---@field stdin string|nil  written to the child's stdin, which is then closed
---@field timeout integer|nil  overrides the configured default
---@field env table<string,string>|nil  extra environment variables
---@field hooks boolean|nil  command may run user hooks: keep the user's locale
---@field serialize boolean|nil  queue behind other mutating commands
---@field on_stdout fun(chunk: string)|nil  streaming progress
---@field on_stderr fun(chunk: string)|nil  streaming progress (git writes
---       transfer progress to stderr)

--- Environment ------------------------------------------------------------

-- Variables that must never leak in from the parent process: they would point
-- git at a different repository or index than the one we resolved.
local INHERITED_GIT_VARS = {
  "GIT_DIR",
  "GIT_WORK_TREE",
  "GIT_INDEX_FILE",
  "GIT_COMMON_DIR",
  "GIT_OBJECT_DIRECTORY",
  "GIT_ALTERNATE_OBJECT_DIRECTORIES",
  "GIT_PREFIX",
  "GIT_CONFIG",
  "GIT_CONFIG_PARAMETERS",
  "GIT_CONFIG_COUNT",
  "GIT_INTERNAL_GETTEXT_TEST_FALLBACKS",
}

local base_env = nil

---@return table<string,string>
local function environment()
  if base_env then
    return base_env
  end

  local env = {}
  for key, value in pairs(vim.uv.os_environ()) do
    env[key] = value
  end
  for _, key in ipairs(INHERITED_GIT_VARS) do
    env[key] = nil
  end

  -- Never hand control of the terminal to git: a credential prompt or an
  -- editor invocation would hang the job forever with no way out.
  env.GIT_TERMINAL_PROMPT = "0"
  env.GIT_EDITOR = "true"
  env.GIT_SEQUENCE_EDITOR = "true"
  env.GIT_PAGER = "cat"
  env.PAGER = "cat"
  -- `git` skips its progress meter when stdout is not a tty, but some
  -- subcommands still consult this.
  env.GIT_FLUSH = "1"

  base_env = env
  return env
end

---Rebuild the cached environment. Used by tests and after `:let $VAR = ...`.
function M.reset_env()
  base_env = nil
end

--- Executable -------------------------------------------------------------

local git_executable = nil
local git_version = nil

---@return string|nil path, string|nil error
function M.executable()
  if git_executable then
    return git_executable
  end
  local found = vim.fn.exepath("git")
  if found == "" then
    return nil, "git executable not found in $PATH"
  end
  git_executable = found
  return git_executable
end

---@return string|nil semver, integer[]|nil parts
function M.version()
  if git_version then
    return git_version.string, git_version.parts
  end
  local exe = M.executable()
  if not exe then
    return nil, nil
  end
  local result = vim.system({ exe, "--version" }, { text = true, timeout = 5000 }):wait()
  local text = (result.stdout or ""):match("git version ([%d%.]+)")
  if not text then
    return nil, nil
  end
  local parts = {}
  for part in text:gmatch("%d+") do
    parts[#parts + 1] = tonumber(part)
  end
  git_version = { string = text, parts = parts }
  return git_version.string, git_version.parts
end

---@param major integer
---@param minor integer
---@return boolean
function M.version_at_least(major, minor)
  local _, parts = M.version()
  if not parts then
    return false
  end
  if (parts[1] or 0) ~= major then
    return (parts[1] or 0) > major
  end
  return (parts[2] or 0) >= minor
end

--- Global argument prefix --------------------------------------------------

---Arguments applied to every invocation.
---
---`core.quotepath=false` keeps non-ASCII paths as raw UTF-8 bytes instead of
---C-style escapes. `color.ui=false` removes ANSI sequences that would
---otherwise end up in parsed output.
---@param opts GitCommandOpts
---@return string[]
local function global_args(opts)
  local args = {
    "--no-pager",
    "--literal-pathspecs",
    "-c",
    "core.quotepath=false",
    "-c",
    "color.ui=false",
    "-c",
    "core.pager=cat",
  }

  -- Read-only commands must never take the index lock. `git status` normally
  -- refreshes the index's stat cache, which means a background status poll can
  -- make a concurrent `git stash` or `git commit` fail with "could not write
  -- index". `--no-optional-locks` exists precisely for tools that poll status
  -- alongside other git processes; the only cost is that the stat cache is not
  -- refreshed by our polling.
  if not opts.serialize then
    table.insert(args, "--no-optional-locks")
  end
  if not opts.hooks then
    -- Advice text is noise for a machine reader, but hook-running commands may
    -- surface it to the user, so only suppress it for parsed commands.
    table.insert(args, "-c")
    table.insert(args, "advice.statusHints=false")
  end
  return args
end

--- Per-repository serialisation -------------------------------------------

---@type table<string, { running: boolean, queue: fun()[] }>
local locks = {}

---@param cwd string
---@return { running: boolean, queue: fun()[] }
local function lock_for(cwd)
  locks[cwd] = locks[cwd] or { running = false, queue = {} }
  return locks[cwd]
end

---@param cwd string
local function release(cwd)
  local lock = locks[cwd]
  if not lock then
    return
  end
  local next_job = table.remove(lock.queue, 1)
  if next_job then
    next_job()
  else
    lock.running = false
  end
end

--- Execution ---------------------------------------------------------------

---@class GitHandle
---@field kill fun(self: GitHandle, signal: integer|string|nil)
---@field cancel fun(self: GitHandle)
---@field pid integer|nil

local INDEX_LOCK_RETRIES = 3
local INDEX_LOCK_DELAY = 120

---@param args string[]
---@param opts GitCommandOpts
---@param callback fun(result: GitResult)
---@return GitHandle
local function spawn(args, opts, callback)
  local exe, err = M.executable()
  if not exe then
    vim.schedule(function()
      callback({
        ok = false,
        code = 127,
        signal = 0,
        stdout = "",
        stderr = err or "git not found",
        args = args,
        cwd = opts.cwd,
        duration = 0,
        cancelled = false,
        timed_out = false,
      })
    end)
    return { kill = function() end, cancel = function() end }
  end

  local cmd = { exe }
  vim.list_extend(cmd, global_args(opts))
  vim.list_extend(cmd, args)

  local env = environment()
  if opts.env then
    env = vim.tbl_extend("force", env, opts.env)
  end

  local timeout = opts.timeout
    or (opts.hooks and config.options.network_timeout)
    or config.options.timeout

  local started = vim.uv.hrtime()
  local cancelled = false

  -- Streaming handlers receive chunks as they arrive *and* the full output is
  -- still accumulated, so progress display never costs us the final result.
  local stdout_chunks = {}
  local stderr_chunks = {}

  local system_opts = {
    cwd = opts.cwd,
    env = env,
    clear_env = true,
    -- `text = true` rewrites CRLF to LF. git always emits LF line endings for
    -- its own output, so the option can only ever corrupt payload bytes: the
    -- contents of a CRLF file in `git show`, or the carriage returns inside a
    -- diff of one. Everything here is handled as raw bytes instead.
    text = false,
    timeout = timeout,
    stdin = opts.stdin or false,
  }

  if opts.on_stdout then
    system_opts.stdout = function(_, data)
      if data then
        stdout_chunks[#stdout_chunks + 1] = data
        opts.on_stdout(data)
      end
    end
  end
  if opts.on_stderr then
    system_opts.stderr = function(_, data)
      if data then
        stderr_chunks[#stderr_chunks + 1] = data
        opts.on_stderr(data)
      end
    end
  end

  logger.debug("git", table.concat(args, " "), "@", opts.cwd)

  local ok, handle = pcall(vim.system, cmd, system_opts, function(out)
    local duration = math.floor((vim.uv.hrtime() - started) / 1e6)
    local stdout = out.stdout or table.concat(stdout_chunks)
    local stderr = out.stderr or table.concat(stderr_chunks)

    ---@type GitResult
    local result = {
      ok = out.code == 0 and not cancelled,
      code = out.code or -1,
      signal = out.signal or 0,
      stdout = stdout,
      stderr = stderr,
      args = args,
      cwd = opts.cwd,
      duration = duration,
      cancelled = cancelled,
      -- vim.system kills on timeout, which surfaces as a signal rather than a
      -- distinct exit code.
      timed_out = (out.signal or 0) ~= 0 and duration >= (timeout - 100),
    }

    if not result.ok and not cancelled then
      logger.debug("git failed", result.code, table.concat(args, " "), result.stderr)
    end

    vim.schedule(function()
      callback(result)
    end)
  end)

  if not ok then
    vim.schedule(function()
      callback({
        ok = false,
        code = -1,
        signal = 0,
        stdout = "",
        stderr = tostring(handle),
        args = args,
        cwd = opts.cwd,
        duration = 0,
        cancelled = false,
        timed_out = false,
      })
    end)
    return { kill = function() end, cancel = function() end }
  end

  return {
    pid = handle.pid,
    kill = function(_, signal)
      pcall(handle.kill, handle, signal or "sigterm")
    end,
    cancel = function(self)
      cancelled = true
      self:kill("sigterm")
    end,
  }
end

---Did this command fail because another git process held a lock?
---
---git reports this several different ways depending on which stage failed, and
---all of them are worth retrying: the contending process is usually the user's
---own terminal and holds the lock for milliseconds.
---@param result GitResult
---@return boolean
local function is_index_lock_error(result)
  local stderr = result.stderr
  return stderr:find("index%.lock") ~= nil
    or stderr:find("Unable to create.*%.lock") ~= nil
    or stderr:find("could not write index") ~= nil
    or stderr:find("[Uu]nable to write new index file") ~= nil
    or stderr:find("cannot lock ref") ~= nil
end

---Run a git command asynchronously.
---@param args string[] arguments after `git`
---@param opts GitCommandOpts
---@param callback fun(result: GitResult)
---@return GitHandle
function M.run(args, opts, callback)
  assert(type(args) == "table", "gitui: git args must be a list")
  assert(opts and opts.cwd, "gitui: git commands require an explicit cwd")

  -- A cancellable proxy so callers can abort a queued command before it starts.
  local proxy = { cancelled = false, inner = nil }
  proxy.kill = function(_, signal)
    if proxy.inner then
      proxy.inner:kill(signal)
    end
  end
  proxy.cancel = function()
    proxy.cancelled = true
    if proxy.inner then
      proxy.inner:cancel()
    end
  end

  local attempt = 0
  local function launch()
    if proxy.cancelled then
      if opts.serialize then
        release(opts.cwd)
      end
      callback({
        ok = false,
        code = -1,
        signal = 0,
        stdout = "",
        stderr = "cancelled",
        args = args,
        cwd = opts.cwd,
        duration = 0,
        cancelled = true,
        timed_out = false,
      })
      return
    end

    proxy.inner = spawn(args, opts, function(result)
      attempt = attempt + 1
      -- A concurrent git process (often the user's own terminal) held the
      -- index lock. Retrying briefly is far friendlier than failing.
      if not result.ok and attempt <= INDEX_LOCK_RETRIES and is_index_lock_error(result) then
        logger.debug("index.lock busy, retry", attempt)
        vim.defer_fn(launch, INDEX_LOCK_DELAY * attempt)
        return
      end

      if opts.serialize then
        release(opts.cwd)
      end
      callback(result)
    end)
  end

  if opts.serialize then
    local lock = lock_for(opts.cwd)
    if lock.running then
      table.insert(lock.queue, launch)
    else
      lock.running = true
      launch()
    end
  else
    launch()
  end

  return proxy
end

---Thunk-returning variant for use inside `async.run`.
---@param args string[]
---@param opts GitCommandOpts
---@return fun(resume: fun(result: GitResult))
function M.thunk(args, opts)
  return function(resume)
    M.run(args, opts, resume)
  end
end

---Synchronous execution. Reserved for small, bounded commands during startup
---(repository detection) where the cost of an event-loop round trip exceeds
---the cost of the command itself. Never use this for network operations.
---@param args string[]
---@param opts GitCommandOpts
---@return GitResult
function M.run_sync(args, opts)
  local exe, err = M.executable()
  if not exe then
    return {
      ok = false,
      code = 127,
      signal = 0,
      stdout = "",
      stderr = err or "git not found",
      args = args,
      cwd = opts.cwd,
      duration = 0,
      cancelled = false,
      timed_out = false,
    }
  end

  local cmd = { exe }
  vim.list_extend(cmd, global_args(opts))
  vim.list_extend(cmd, args)

  local started = vim.uv.hrtime()
  local out = vim
    .system(cmd, {
      cwd = opts.cwd,
      env = opts.env and vim.tbl_extend("force", environment(), opts.env) or environment(),
      clear_env = true,
      text = false,
      stdin = opts.stdin or false,
      timeout = opts.timeout or 5000,
    })
    :wait()

  return {
    ok = out.code == 0,
    code = out.code or -1,
    signal = out.signal or 0,
    stdout = out.stdout or "",
    stderr = out.stderr or "",
    args = args,
    cwd = opts.cwd,
    duration = math.floor((vim.uv.hrtime() - started) / 1e6),
    cancelled = false,
    timed_out = false,
  }
end

--- Error classification ----------------------------------------------------

---@class GitError
---@field kind string  stable machine-readable identifier
---@field title string  one line: what happened
---@field reason string  why it happened
---@field hint string|nil  what the user can do next
---@field raw string  complete git output, never discarded

---Patterns are ordered most-specific first. `LC_ALL` is deliberately *not*
---forced, so a localised git falls through to the generic case rather than
---being misclassified — the raw output is always shown either way.
local CLASSIFIERS = {
  {
    kind = "not_a_repository",
    match = "not a git repository",
    title = "Not a git repository",
    reason = "The directory is not inside a git working tree.",
    hint = "Run `git init`, or open a file inside a repository.",
  },
  {
    kind = "auth",
    match = "Authentication failed",
    title = "Authentication failed",
    reason = "The remote rejected your credentials.",
    hint = "Check your credential helper, SSH agent or personal access token.",
  },
  {
    kind = "auth",
    match = "Permission denied %(publickey",
    title = "SSH authentication failed",
    reason = "The remote rejected the SSH key offered by your agent.",
    hint = "Run `ssh-add -l` to confirm your key is loaded, then try again.",
  },
  {
    kind = "auth",
    match = "could not read Username",
    title = "Authentication required",
    reason = "The remote asked for credentials, but interactive prompts are disabled inside Neovim.",
    hint = "Configure a credential helper (`git config --global credential.helper`) or use an SSH remote.",
  },
  {
    kind = "network",
    match = "Could not resolve host",
    title = "Network unreachable",
    reason = "The remote host could not be resolved.",
    hint = "Check your network connection and the remote URL.",
  },
  {
    kind = "network",
    match = "Connection timed out",
    title = "Connection timed out",
    reason = "The remote did not respond.",
    hint = "Check your network connection, then retry.",
  },
  {
    kind = "non_fast_forward",
    match = "non%-fast%-forward",
    title = "Push rejected",
    reason = "The remote branch contains commits that are not present locally.",
    hint = "Pull (or rebase) first, then push again.",
  },
  {
    kind = "non_fast_forward",
    match = "Updates were rejected",
    title = "Push rejected",
    reason = "The remote branch has moved on since your last fetch.",
    hint = "Pull (or rebase) first, then push again.",
  },
  {
    kind = "no_upstream",
    match = "has no upstream branch",
    title = "No upstream branch",
    reason = "This branch is not tracking a remote branch.",
    hint = "Push with --set-upstream to create the tracking relationship.",
  },
  {
    kind = "conflict",
    match = "CONFLICT",
    title = "Merge conflict",
    reason = "Changes on both sides touched the same lines.",
    hint = "Resolve the conflicts, stage the files, then continue.",
  },
  {
    kind = "conflict",
    match = "Automatic merge failed",
    title = "Merge conflict",
    reason = "Changes on both sides touched the same lines.",
    hint = "Resolve the conflicts, stage the files, then continue.",
  },
  {
    kind = "local_changes",
    match = "would be overwritten by",
    title = "Local changes would be lost",
    reason = "Uncommitted changes conflict with the files this operation needs to replace.",
    hint = "Commit, stash or discard your changes first.",
  },
  {
    kind = "index_lock",
    match = "index%.lock",
    title = "Repository is busy",
    reason = "Another git process is holding `index.lock`.",
    hint = "Wait for it to finish. If no git process is running, remove `.git/index.lock`.",
  },
  {
    kind = "hook",
    match = "hook declined",
    title = "Hook rejected the operation",
    reason = "A git hook exited non-zero.",
    hint = "Fix the issue reported by the hook, or bypass hooks explicitly.",
  },
  {
    kind = "signing",
    match = "gpg failed to sign",
    title = "Commit signing failed",
    reason = "git could not produce a signature for this commit.",
    hint = "Check `git config user.signingkey` and that your GPG/SSH agent is unlocked.",
  },
  {
    kind = "dirty_worktree",
    match = "you have unstaged changes",
    title = "Unstaged changes present",
    reason = "This operation requires a clean working tree.",
    hint = "Commit or stash your changes first.",
  },
  {
    kind = "rebase_in_progress",
    match = "rebase in progress",
    title = "Rebase in progress",
    reason = "A rebase is already underway.",
    hint = "Continue, skip or abort the rebase before starting another operation.",
  },
  {
    kind = "nothing_to_commit",
    match = "nothing to commit",
    title = "Nothing to commit",
    reason = "There are no staged changes.",
    hint = "Stage some changes first.",
  },
  {
    kind = "empty_commit",
    match = "no changes added to commit",
    title = "Nothing to commit",
    reason = "There are no staged changes.",
    hint = "Stage some changes first.",
  },
}

---Turn a failed result into an actionable, user-facing error.
---Every error answers: what happened, why, and what to do next.
---@param result GitResult
---@return GitError
function M.classify(result)
  local raw = result.stderr
  if raw == "" then
    raw = result.stdout
  end

  if result.cancelled then
    return {
      kind = "cancelled",
      title = "Operation cancelled",
      reason = "The command was superseded or aborted.",
      hint = nil,
      raw = raw,
    }
  end

  if result.timed_out then
    return {
      kind = "timeout",
      title = "git timed out",
      reason = ("`git %s` did not finish in time."):format(result.args[1] or "?"),
      hint = "Increase `timeout` in your gitui configuration, or check for a stuck credential prompt.",
      raw = raw,
    }
  end

  if result.code == 127 then
    return {
      kind = "no_git",
      title = "git is not available",
      reason = "No `git` executable was found in $PATH.",
      hint = "Install git, or make it visible to Neovim's environment.",
      raw = raw,
    }
  end

  local haystack = raw
  for _, classifier in ipairs(CLASSIFIERS) do
    if haystack:lower():find(classifier.match:lower()) then
      return {
        kind = classifier.kind,
        title = classifier.title,
        reason = classifier.reason,
        hint = classifier.hint,
        raw = raw,
      }
    end
  end

  -- Unrecognised: show git's own first line rather than inventing a message.
  local first_line = raw:match("^%s*([^\n]+)") or ("git exited with status " .. tostring(result.code))
  first_line = first_line:gsub("^fatal:%s*", ""):gsub("^error:%s*", "")
  return {
    kind = "unknown",
    title = ("git %s failed"):format(result.args[1] or ""),
    reason = first_line,
    hint = nil,
    raw = raw,
  }
end

---Cancel every queued (not yet started) command for a repository.
---@param cwd string
function M.drain(cwd)
  local lock = locks[cwd]
  if lock then
    lock.queue = {}
  end
end

return M
