---@brief Remotes and the network operations that use them.
---
---Fetch, pull and push stream git's progress output so the UI can show live
---feedback, and every one of them has a generous but finite timeout: an
---operation that hangs is reported rather than leaving Neovim's status line
---spinning forever.

local command = require("picked.git.command")
local config = require("picked.config")
local text_util = require("picked.utils.text")

local M = {}

---@class GitRemote
---@field name string
---@field fetch_url string
---@field push_url string

---Parse `git config -z --get-regexp ^remote\..*\.(url|pushurl)$`.
---
---Records are NUL separated and each is "key\nvalue", so a URL containing
---spaces or any other character is read intact.
---@param raw string
---@return GitRemote[]
function M.parse(raw)
  local by_name = {}
  local order = {}

  for _, record in ipairs(text_util.nul_split(raw)) do
    local key, value = record:match("^([^\n]+)\n(.*)$")
    if key then
      -- A remote name may contain dots, so match the suffix rather than
      -- splitting on the first separator.
      local name, kind = key:match("^remote%.(.+)%.(url)$")
      if not name then
        name, kind = key:match("^remote%.(.+)%.(pushurl)$")
      end
      if name then
        if not by_name[name] then
          by_name[name] = { name = name, fetch_url = "", push_url = "" }
          order[#order + 1] = name
        end
        if kind == "url" then
          by_name[name].fetch_url = value
          if by_name[name].push_url == "" then
            by_name[name].push_url = value
          end
        else
          by_name[name].push_url = value
        end
      end
    end
  end

  local remotes = {}
  for _, name in ipairs(order) do
    remotes[#remotes + 1] = by_name[name]
  end
  table.sort(remotes, function(a, b)
    -- "origin" first: it is what the user means nine times out of ten.
    if a.name == "origin" then
      return true
    end
    if b.name == "origin" then
      return false
    end
    return a.name < b.name
  end)
  return remotes
end

---List the repository's remotes.
---@param repo GitRepository
---@param callback fun(remotes: GitRemote[]|nil, err: GitError|nil)
---@return GitHandle
function M.list(repo, callback)
  return command.run(
    -- POSIX extended regex, not a Lua pattern: this string is given to git.
    { "config", "-z", "--get-regexp", "^remote\\..*\\.(url|pushurl)$" },
    { cwd = repo.root },
    function(result)
      -- Exit status 1 simply means "no matches", i.e. no remotes configured.
      if not result.ok and result.code ~= 1 then
        return callback(nil, command.classify(result))
      end
      callback(M.parse(result.stdout), nil)
    end
  )
end

---The remote a branch tracks, falling back to the default push remote.
---@param repo GitRepository
---@param branch string|nil
---@param callback fun(remote: string|nil)
function M.for_branch(repo, branch, callback)
  local keys = {}
  if branch then
    keys[#keys + 1] = "branch." .. branch .. ".remote"
  end
  keys[#keys + 1] = "remote.pushDefault"

  local function try(index)
    local key = keys[index]
    if not key then
      -- Nothing configured: fall back to the first remote, which is `origin`
      -- in every ordinary repository.
      return M.list(repo, function(remotes)
        callback(remotes and remotes[1] and remotes[1].name or nil)
      end)
    end
    command.run({ "config", "--get", key }, { cwd = repo.root }, function(result)
      local value = vim.trim(result.stdout)
      if result.ok and value ~= "" then
        return callback(value)
      end
      try(index + 1)
    end)
  end

  try(1)
end

--- Network operations ---------------------------------------------------------

---@class GitNetworkOpts
---@field remote string|nil
---@field refspec string|nil
---@field branch string|nil
---@field set_upstream boolean|nil
---@field force boolean|nil  plain --force; never used without explicit intent
---@field force_with_lease boolean|nil  the safe force
---@field tags boolean|nil
---@field prune boolean|nil
---@field all boolean|nil
---@field rebase boolean|nil  pull strategy
---@field ff_only boolean|nil  pull strategy
---@field on_progress fun(line: string)|nil

---@class GitNetworkResult
---@field ok boolean
---@field output string  combined stdout and stderr, for the output buffer
---@field err GitError|nil

---Run a network command, streaming its progress.
---@param repo GitRepository
---@param args string[]
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
---@return GitHandle
local function network(repo, args, opts, callback)
  local chunks = {}

  local function collect(chunk)
    chunks[#chunks + 1] = chunk
    if opts.on_progress then
      -- git reports transfer progress with carriage returns; report only the
      -- last complete status so the UI is not flooded.
      for line in chunk:gmatch("[^\r\n]+") do
        local trimmed = vim.trim(line)
        if trimmed ~= "" then
          opts.on_progress(trimmed)
        end
      end
    end
  end

  return command.run(args, {
    cwd = repo.root,
    serialize = true,
    hooks = true,
    timeout = config.options.network_timeout,
    on_stdout = collect,
    on_stderr = collect,
  }, function(result)
    local output = result.stdout
    if result.stderr ~= "" then
      output = output == "" and result.stderr or (output .. "\n" .. result.stderr)
    end
    if result.ok then
      return callback({ ok = true, output = output, err = nil })
    end
    callback({ ok = false, output = output, err = command.classify(result) })
  end)
end

---Fetch from one or all remotes.
---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
---@return GitHandle
function M.fetch(repo, opts, callback)
  opts = opts or {}
  local args = { "fetch", "--progress" }
  if opts.all then
    table.insert(args, "--all")
  end
  if opts.prune or (opts.prune == nil and config.options.remote.fetch_prune) then
    table.insert(args, "--prune")
  end
  if opts.tags then
    table.insert(args, "--tags")
  end
  if opts.remote and not opts.all then
    table.insert(args, opts.remote)
    if opts.refspec then
      table.insert(args, opts.refspec)
    end
  end
  return network(repo, args, opts, callback)
end

---Pull, using the caller's explicit strategy.
---
---There is no implicit default here: the UI asks, or the configuration
---states one. A surprise rebase is not an acceptable outcome.
---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
---@return GitHandle
function M.pull(repo, opts, callback)
  opts = opts or {}
  local args = { "pull", "--progress" }
  if opts.rebase then
    table.insert(args, "--rebase")
  elseif opts.ff_only then
    table.insert(args, "--ff-only")
  else
    table.insert(args, "--no-rebase")
  end
  table.insert(args, "--no-edit")
  if opts.remote then
    table.insert(args, opts.remote)
    if opts.branch then
      table.insert(args, opts.branch)
    end
  end
  return network(repo, args, opts, callback)
end

---Push.
---
---`force_with_lease` is preferred over `force` everywhere in the UI; plain
---`--force` requires the caller to ask for it by name.
---@param repo GitRepository
---@param opts GitNetworkOpts
---@param callback fun(result: GitNetworkResult)
---@return GitHandle
function M.push(repo, opts, callback)
  opts = opts or {}
  local args = { "push", "--progress" }
  if opts.force_with_lease then
    table.insert(args, "--force-with-lease")
    -- Without --force-if-includes, a lease can still be satisfied by a ref
    -- your working tree has never seen.
    if command.version_at_least(2, 30) then
      table.insert(args, "--force-if-includes")
    end
  elseif opts.force then
    table.insert(args, "--force")
  end
  if opts.set_upstream then
    table.insert(args, "--set-upstream")
  end
  if opts.tags then
    table.insert(args, "--tags")
  end
  if opts.remote then
    table.insert(args, opts.remote)
    if opts.refspec then
      table.insert(args, opts.refspec)
    elseif opts.branch then
      table.insert(args, opts.branch)
    end
  end
  return network(repo, args, opts, callback)
end

---Add a remote.
---@param repo GitRepository
---@param name string
---@param url string
---@param callback fun(ok: boolean, err: GitError|nil)
function M.add(repo, name, url, callback)
  command.run({ "remote", "add", name, url }, { cwd = repo.root, serialize = true }, function(result)
    callback(result.ok, result.ok and nil or command.classify(result))
  end)
end

---Remove a remote.
---@param repo GitRepository
---@param name string
---@param callback fun(ok: boolean, err: GitError|nil)
function M.remove(repo, name, callback)
  command.run({ "remote", "remove", name }, { cwd = repo.root, serialize = true }, function(result)
    callback(result.ok, result.ok and nil or command.classify(result))
  end)
end

---Prune stale remote-tracking refs.
---@param repo GitRepository
---@param name string
---@param callback fun(ok: boolean, err: GitError|nil)
function M.prune(repo, name, callback)
  command.run({ "remote", "prune", name }, {
    cwd = repo.root,
    serialize = true,
    timeout = config.options.network_timeout,
  }, function(result)
    callback(result.ok, result.ok and nil or command.classify(result))
  end)
end

return M
