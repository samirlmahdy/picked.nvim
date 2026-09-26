---@brief Centralised application state.
---
---One `RepositoryState` exists per git repository Neovim has touched. The
---store owns data only: it knows nothing about windows, highlights or git
---command construction. Views read from it and subscribe to change events.
---
---Concurrency model (see `doc/ARCHITECTURE.md`):
---  Every repository carries a monotonically increasing `generation`. A refresh
---  captures the generation before it starts and discards its own result if the
---  generation moved on in the meantime. Any mutating operation bumps it. The
---  newest observation therefore always wins, and a slow `git status` started
---  before a stage can never overwrite the state produced after it.

local events = require("gitui.utils.events")
local logger = require("gitui.utils.logger")

local M = {}

---@class RepositoryState
---@field repo GitRepository
---@field status GitStatusResult|nil
---@field head GitHead|nil
---@field git_state GitRepoState|nil
---@field branches GitBranch[]|nil
---@field remotes GitRemote[]|nil
---@field stashes GitStash[]|nil
---@field submodules table<string, boolean>|nil
---@field error GitError|nil  last error that prevented a refresh
---@field generation integer
---@field loading table<string, integer>  operation name -> outstanding count
---@field updated_at integer  vim.uv.now() of the last successful status
---@field cache table<string, { value: any, at: integer }>

---@class UIState
---@field expanded table<string, boolean>  tree node id -> expanded
---@field collapsed_sections table<string, boolean>
---@field cursor table<string, integer[]>  view name -> cursor position
---@field last_view string|nil

---@type table<string, RepositoryState>
local repositories = {}

---@type string|nil
local active_root = nil

---@type UIState
local ui = {
  expanded = {},
  collapsed_sections = {},
  cursor = {},
  last_view = nil,
}

--- Repository states --------------------------------------------------------

---@param repo GitRepository
---@return RepositoryState
function M.ensure(repo)
  local existing = repositories[repo.root]
  if existing then
    -- Keep the descriptor fresh: a worktree can be converted, or the git dir
    -- can move, without the root changing.
    existing.repo = repo
    return existing
  end

  ---@type RepositoryState
  local state = {
    repo = repo,
    status = nil,
    head = nil,
    git_state = nil,
    branches = nil,
    remotes = nil,
    stashes = nil,
    submodules = nil,
    error = nil,
    generation = 0,
    loading = {},
    updated_at = 0,
    cache = {},
  }
  repositories[repo.root] = state
  logger.debug("tracking repository", repo.root)
  events.emit(events.names.REPOSITORY_CHANGED, { root = repo.root, added = true })
  return state
end

---@param root string
---@return RepositoryState|nil
function M.get(root)
  return repositories[root]
end

---@return table<string, RepositoryState>
function M.all()
  return repositories
end

---@return RepositoryState[] sorted by root for a stable repository picker
function M.list()
  local list = {}
  for _, state in pairs(repositories) do
    list[#list + 1] = state
  end
  table.sort(list, function(a, b)
    return a.repo.root < b.repo.root
  end)
  return list
end

---@return integer
function M.count()
  return vim.tbl_count(repositories)
end

---@param repo GitRepository|nil
function M.set_active(repo)
  local root = repo and repo.root or nil
  if root == active_root then
    return
  end
  if repo then
    M.ensure(repo)
  end
  active_root = root
  logger.debug("active repository ->", root)
  events.emit(events.names.REPOSITORY_CHANGED, { root = root, activated = true })
end

---@return RepositoryState|nil
function M.active()
  if not active_root then
    return nil
  end
  return repositories[active_root]
end

---@return string|nil
function M.active_root()
  return active_root
end

---Remove a repository from the store, e.g. after its directory disappeared.
---@param root string
function M.forget(root)
  repositories[root] = nil
  if active_root == root then
    active_root = nil
  end
  events.emit(events.names.REPOSITORY_CHANGED, { root = root, removed = true })
end

--- Generations --------------------------------------------------------------

---Claim a generation token for an operation that is about to read git state.
---@param root string
---@return integer token
function M.current_generation(root)
  local state = repositories[root]
  return state and state.generation or 0
end

---Invalidate in-flight reads. Call this immediately *before* any mutating git
---operation, and again once it completes.
---@param root string
---@return integer new generation
function M.invalidate(root)
  local state = repositories[root]
  if not state then
    return 0
  end
  state.generation = state.generation + 1
  state.cache = {}
  logger.trace("generation bump", root, state.generation)
  return state.generation
end

---Is a result captured at `token` still the newest view of the world?
---@param root string
---@param token integer
---@return boolean
function M.is_current(root, token)
  local state = repositories[root]
  return state ~= nil and state.generation == token
end

--- Updates ------------------------------------------------------------------

---Apply a patch to a repository state and notify subscribers.
---
---Returns false when the update was stale and therefore dropped.
---@param root string
---@param patch table
---@param token integer|nil  generation the data was read at
---@return boolean applied
function M.update(root, patch, token)
  local state = repositories[root]
  if not state then
    return false
  end
  if token ~= nil and state.generation ~= token then
    logger.debug("dropping stale update for", root, "token", token, "current", state.generation)
    return false
  end

  for key, value in pairs(patch) do
    state[key] = value
  end
  state.updated_at = vim.uv.now()

  events.emit(events.names.STATUS_CHANGED, { root = root })
  return true
end

--- Loading indicators -------------------------------------------------------

---Mark an operation as in flight. Returns a function that clears it.
---@param root string
---@param key string
---@return fun()
function M.begin_loading(root, key)
  local state = repositories[root]
  if not state then
    return function() end
  end
  state.loading[key] = (state.loading[key] or 0) + 1
  events.emit(events.names.OPERATION_STARTED, { root = root, operation = key })

  local finished = false
  return function()
    if finished then
      return
    end
    finished = true
    local current = repositories[root]
    if not current then
      return
    end
    local count = (current.loading[key] or 1) - 1
    current.loading[key] = count > 0 and count or nil
    events.emit(events.names.OPERATION_FINISHED, { root = root, operation = key })
  end
end

---@param root string
---@param key string|nil  any operation when omitted
---@return boolean
function M.is_loading(root, key)
  local state = repositories[root]
  if not state then
    return false
  end
  if key then
    return (state.loading[key] or 0) > 0
  end
  return next(state.loading) ~= nil
end

---@param root string
---@return string[]
function M.loading_operations(root)
  local state = repositories[root]
  if not state then
    return {}
  end
  local keys = vim.tbl_keys(state.loading)
  table.sort(keys)
  return keys
end

--- Derived caches -----------------------------------------------------------

---Memoise a derived value until the next generation bump.
---@generic T
---@param root string
---@param key string
---@param ttl integer|nil  milliseconds; omit for "until invalidated"
---@param compute fun(): T
---@return T
function M.cached(root, key, ttl, compute)
  local state = repositories[root]
  if not state then
    return compute()
  end
  local entry = state.cache[key]
  if entry and (not ttl or (vim.uv.now() - entry.at) < ttl) then
    return entry.value
  end
  local value = compute()
  state.cache[key] = { value = value, at = vim.uv.now() }
  return value
end

---@param root string
---@param key string|nil
function M.clear_cache(root, key)
  local state = repositories[root]
  if not state then
    return
  end
  if key then
    state.cache[key] = nil
  else
    state.cache = {}
  end
end

--- UI state -----------------------------------------------------------------

---@return UIState
function M.ui()
  return ui
end

---Tree nodes are expanded by default, so the store only records the
---exceptions. That keeps newly appearing directories visible instead of
---hiding changes the user has not seen yet.
---@param id string
---@return boolean
function M.is_collapsed(id)
  return ui.expanded[id] == false
end

---@param id string
---@return boolean
function M.is_expanded(id)
  return not M.is_collapsed(id)
end

---@param id string
---@param collapsed boolean|nil  toggles when omitted
---@return boolean collapsed
function M.set_collapsed(id, collapsed)
  if collapsed == nil then
    collapsed = not M.is_collapsed(id)
  end
  -- `nil` means "expanded", so the table only ever holds collapsed ids.
  ui.expanded[id] = collapsed and false or nil
  return collapsed
end

---Collapse or expand many nodes at once.
---@param ids string[]
---@param collapsed boolean
function M.set_all_collapsed(ids, collapsed)
  for _, id in ipairs(ids) do
    M.set_collapsed(id, collapsed)
  end
end

---@param name string
---@return boolean
function M.is_section_collapsed(name)
  return ui.collapsed_sections[name] == true
end

---@param name string
---@param value boolean|nil
---@return boolean
function M.set_section_collapsed(name, value)
  if value == nil then
    value = not ui.collapsed_sections[name]
  end
  ui.collapsed_sections[name] = value or nil
  return value
end

--- Lifecycle ----------------------------------------------------------------

---Reset everything. Used by tests and `:GitUIReset`.
function M.reset()
  repositories = {}
  active_root = nil
  ui = { expanded = {}, collapsed_sections = {}, cursor = {}, last_view = nil }
end

return M
