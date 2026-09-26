---@brief Refresh orchestration.
---
---Turns "something might have changed" into at most one `git status` per
---repository per debounce window, and guarantees the store only ever moves
---forward in time.

local config = require("gitui.config")
local debounce = require("gitui.utils.debounce")
local events = require("gitui.utils.events")
local logger = require("gitui.utils.logger")
local repository = require("gitui.git.repository")
local status_api = require("gitui.git.status")
local store = require("gitui.state")

local M = {}

---@class GitUIInFlightRefresh
---@field handle GitHandle
---@field token integer  generation the query was started at
---@field callbacks fun(ok: boolean, err: GitError|nil)[]

---@type table<string, GitUIInFlightRefresh>
local in_flight = {}

---@type table<string, fun(reason: string|nil)>
local debounced = {}

---Read the cheap, filesystem-only parts of the repository state.
---@param state RepositoryState
local function refresh_local(state)
  state.head = repository.head(state.repo)
  state.git_state = repository.state(state.repo)
end

---Run a status query and commit the result if it is still current.
---@param repo GitRepository
---@param opts { reason: string|nil, ignored: boolean|nil }
---@param callback fun(ok: boolean, err: GitError|nil)|nil
local function run(repo, opts, callback)
  local root = repo.root
  local state = store.ensure(repo)
  local token = store.current_generation(root)

  -- HEAD and sequencer state come from files, not a subprocess, so they are
  -- refreshed synchronously and are always in sync with what the user sees.
  refresh_local(state)

  local previous = in_flight[root]
  if previous then
    if previous.token == token then
      -- A query started at this same generation is already running and its
      -- answer will be exactly as fresh as a new one. Wait for it instead of
      -- spawning a second `git status` and cancelling the first, which would
      -- report "cancelled" to a caller that did nothing wrong.
      if callback then
        previous.callbacks[#previous.callbacks + 1] = callback
      end
      logger.trace("refresh coalesced", root, opts.reason or "")
      return
    end
    -- The generation moved: the running query predates a mutation and its
    -- answer is already known to be stale.
    previous.handle:cancel()
    in_flight[root] = nil
  end

  local done_loading = store.begin_loading(root, "status")
  logger.trace("refresh start", root, opts.reason or "")

  ---@type GitUIInFlightRefresh
  local entry = { token = token, callbacks = callback and { callback } or {} }

  entry.handle = status_api.query(repo, { ignored = opts.ignored }, function(result, err)
    if in_flight[root] == entry then
      in_flight[root] = nil
    end
    done_loading()

    local ok, failure = false, nil

    if err then
      if err.kind ~= "cancelled" then
        logger.warn("status refresh failed:", err.title, err.reason)
        store.update(root, { error = err }, token)
      end
      failure = err
    else
      ok = store.update(root, { status = result, error = nil }, token)
      if not ok then
        logger.debug("refresh result superseded for", root)
      end
    end

    for _, pending in ipairs(entry.callbacks) do
      pending(ok, failure)
    end
  end)

  in_flight[root] = entry
end

---Refresh a repository immediately, bypassing the debounce.
---@param repo GitRepository
---@param opts { reason: string|nil, ignored: boolean|nil }|nil
---@param callback fun(ok: boolean, err: GitError|nil)|nil
function M.now(repo, opts, callback)
  run(repo, opts or {}, callback)
end

---Request a refresh. Coalesces bursts into a single query.
---@param repo GitRepository
---@param reason string|nil  recorded in the log to make refresh storms visible
function M.request(repo, reason)
  local root = repo.root
  if not debounced[root] then
    local delay = math.max(0, config.options.refresh_debounce)
    debounced[root] = debounce.trailing(function(why)
      run(repo, { reason = why }, nil)
    end, delay)
  end
  debounced[root](reason)
end

---Refresh every tracked repository. Used after operations that can affect more
---than one (checking out a branch in a worktree, for example).
---@param reason string|nil
function M.all(reason)
  for _, state in pairs(store.all()) do
    M.request(state.repo, reason)
  end
end

---Invalidate and refresh after a mutating operation completed successfully.
---
---This is the only correct post-mutation path: it bumps the generation first
---so any query started before the mutation is discarded, then re-reads git.
---@param repo GitRepository
---@param reason string
---@param callback fun()|nil
function M.after_mutation(repo, reason, callback)
  store.invalidate(repo.root)
  store.clear_cache(repo.root)
  M.now(repo, { reason = reason }, function()
    if callback then
      callback()
    end
  end)
end

---Cancel any pending or in-flight refresh for a repository.
---@param root string
function M.cancel(root)
  local entry = in_flight[root]
  if entry then
    entry.handle:cancel()
    in_flight[root] = nil
  end
end

--- Automatic refresh triggers ----------------------------------------------

local augroup = nil
---@type table<string, table> root -> fs_event handles
local watchers = {}

---@param root string
local function stop_watcher(root)
  local watcher = watchers[root]
  if not watcher then
    return
  end
  for _, handle in ipairs(watcher.handles) do
    pcall(function()
      handle:stop()
    end)
    if not handle:is_closing() then
      handle:close()
    end
  end
  watchers[root] = nil
end

---Watch the parts of `.git` whose mtime changes on every interesting event.
---
---Watching the whole working tree is not viable on a large repository, and
---watching `.git` recursively produces a storm during a fetch. Watching the
---index plus the refs directory captures staging, committing, branch switches
---and merges with a handful of events.
---@param repo GitRepository
local function start_watcher(repo)
  if not config.options.file_watch or watchers[repo.root] then
    return
  end

  local handles = {}
  local function watch(path, flags)
    local handle = vim.uv.new_fs_event()
    if not handle then
      return
    end
    local ok = pcall(function()
      handle:start(path, flags or {}, function(err)
        if err then
          return
        end
        vim.schedule(function()
          M.request(repo, "fs-event")
        end)
      end)
    end)
    if ok then
      handles[#handles + 1] = handle
    elseif not handle:is_closing() then
      handle:close()
    end
  end

  local path_util = require("gitui.utils.path")
  -- The git directory itself covers index, HEAD, MERGE_HEAD and the sequencer
  -- state files; refs covers branch creation and updates.
  watch(path_util.to_os(repo.git_dir))
  watch(path_util.to_os(repo.common_dir .. "/refs"), { recursive = true })

  if #handles > 0 then
    watchers[repo.root] = { handles = handles }
    logger.debug("watching", repo.git_dir)
  end
end

---@param repo GitRepository
function M.watch(repo)
  start_watcher(repo)
end

---@param root string
function M.unwatch(root)
  stop_watcher(root)
end

---Install the editor-side refresh triggers.
function M.setup_autocmds()
  if augroup then
    return
  end
  augroup = vim.api.nvim_create_augroup("GitUIRefresh", { clear = true })

  local function repo_for_buffer(bufnr)
    if not config.options.auto_refresh then
      return nil
    end
    local ok, repo = pcall(repository.for_buffer, bufnr)
    return ok and repo or nil
  end

  -- Writing a file is the single most reliable "something changed" signal.
  vim.api.nvim_create_autocmd({ "BufWritePost", "FileChangedShellPost" }, {
    group = augroup,
    callback = function(args)
      local repo = repo_for_buffer(args.buf)
      if repo then
        M.request(repo, "write")
      end
    end,
  })

  -- Returning to Neovim after using git in a terminal.
  vim.api.nvim_create_autocmd({ "FocusGained", "TermLeave", "VimResume" }, {
    group = augroup,
    callback = function()
      if not config.options.auto_refresh then
        return
      end
      for _, state in pairs(store.all()) do
        M.request(state.repo, "focus")
      end
    end,
  })

  -- Entering a buffer from a different repository makes that repository
  -- active, which is what makes multi-root workspaces work.
  vim.api.nvim_create_autocmd({ "BufEnter" }, {
    group = augroup,
    callback = function(args)
      local repo = repo_for_buffer(args.buf)
      if not repo then
        return
      end
      local previous = store.active_root()
      store.ensure(repo)
      if previous ~= repo.root then
        store.set_active(repo)
        M.request(repo, "buffer-enter")
      end
    end,
  })

  vim.api.nvim_create_autocmd("DirChanged", {
    group = augroup,
    callback = function()
      repository.invalidate()
      local repo = repository.detect(vim.uv.cwd() or ".")
      if repo then
        store.set_active(repo)
        M.request(repo, "dir-changed")
      end
    end,
  })

  vim.api.nvim_create_autocmd("VimLeavePre", {
    group = augroup,
    callback = function()
      for root in pairs(watchers) do
        stop_watcher(root)
      end
    end,
  })

  -- Refresh after any operation the plugin itself performed.
  events.on(events.names.OPERATION_FINISHED, function(data)
    if data and data.refresh and data.root then
      local state = store.get(data.root)
      if state then
        M.request(state.repo, "operation:" .. tostring(data.operation))
      end
    end
  end)
end

function M.teardown()
  if augroup then
    pcall(vim.api.nvim_del_augroup_by_id, augroup)
    augroup = nil
  end
  for root in pairs(watchers) do
    stop_watcher(root)
  end
  for root, entry in pairs(in_flight) do
    entry.handle:cancel()
    in_flight[root] = nil
  end
  debounced = {}
end

return M
