---@brief Turning git remotes into web URLs.
---
---Handles the three shapes a remote can take — `https://host/owner/repo.git`,
---`ssh://git@host:port/owner/repo`, and the scp-like `git@host:owner/repo` —
---and the URL layouts of the common forges. Self-hosted instances are
---supported by mapping their hostname to a provider in the configuration.

local config = require("picked.config")

local M = {}

---@class GitRemoteUrl
---@field host string
---@field owner string  everything before the final path segment
---@field repo string  final path segment, without ".git"
---@field path string  "owner/repo"
---@field port integer|nil
---@field scheme "https"|"ssh"|"git"|"file"

---@alias GitForge "github"|"gitlab"|"bitbucket"|"gitea"|"sourcehut"

--- Parsing -------------------------------------------------------------------

---@param value string
---@return string
local function strip_git_suffix(value)
  return (value:gsub("%.git$", ""))
end

---Parse a git remote URL into its parts.
---@param url string
---@return GitRemoteUrl|nil
function M.parse_url(url)
  url = vim.trim(url)
  if url == "" then
    return nil
  end

  -- scp-like syntax: [user@]host:path — note the absence of "//" after the
  -- colon, which is what distinguishes it from a real URL.
  local scp_host, scp_path = url:match("^[^/]-@?([%w%.%-_]+):([^/].*)$")
  if scp_host and not url:match("^%a[%w+.-]*://") then
    return {
      host = scp_host,
      path = strip_git_suffix(scp_path),
      owner = strip_git_suffix(scp_path):match("^(.*)/[^/]+$") or "",
      repo = strip_git_suffix(scp_path):match("([^/]+)$") or "",
      scheme = "ssh",
    }
  end

  local scheme, rest = url:match("^(%a[%w+.-]*)://(.*)$")
  if not scheme then
    -- A bare local path is a valid remote, but there is nothing to browse.
    return nil
  end

  -- Strip any userinfo, then split host[:port] from the path.
  rest = rest:gsub("^[^@/]*@", "")
  local authority, path = rest:match("^([^/]+)/?(.*)$")
  if not authority then
    return nil
  end

  local host, port = authority:match("^(.-):(%d+)$")
  host = host or authority

  path = strip_git_suffix(path):gsub("^/", ""):gsub("/$", "")
  if path == "" then
    return nil
  end

  return {
    host = host,
    port = tonumber(port),
    path = path,
    owner = path:match("^(.*)/[^/]+$") or "",
    repo = path:match("([^/]+)$") or "",
    scheme = scheme == "https" and "https" or scheme == "http" and "https" or scheme,
  }
end

---Identify the forge behind a host.
---@param host string
---@return GitForge
function M.detect_forge(host)
  local configured = config.options.browse.hosts[host]
  if configured then
    return configured
  end
  if host:find("github") then
    return "github"
  end
  if host:find("gitlab") then
    return "gitlab"
  end
  if host:find("bitbucket") then
    return "bitbucket"
  end
  if host:find("gitea") or host:find("codeberg") then
    return "gitea"
  end
  if host:find("sr%.ht") then
    return "sourcehut"
  end
  -- Most self-hosted forges are GitLab or Gitea, both of which use GitHub's
  -- blob/commit layout closely enough for the links to work.
  return "github"
end

--- URL construction ------------------------------------------------------------

---Percent-encode a path segment, leaving separators intact.
---@param value string
---@return string
local function encode_path(value)
  return (value:gsub("[^%w%-%._~/]", function(char)
    return ("%%%02X"):format(char:byte())
  end))
end

---@param parsed GitRemoteUrl
---@return string
local function base_url(parsed)
  return ("https://%s/%s"):format(parsed.host, parsed.path)
end

---@class GitBrowseTarget
---@field kind "repo"|"branch"|"commit"|"file"|"compare"
---@field ref string|nil  branch, tag or commit
---@field path string|nil  repository-relative file path
---@field first integer|nil  first line of a selection
---@field last integer|nil  last line of a selection
---@field base string|nil  for a comparison
---@field head string|nil

---Build the web URL for a target.
---@param remote_url string
---@param target GitBrowseTarget
---@return string|nil url, string|nil error
function M.url(remote_url, target)
  local parsed = M.parse_url(remote_url)
  if not parsed then
    return nil, ("'%s' is not a browsable remote URL."):format(remote_url)
  end

  local forge = M.detect_forge(parsed.host)
  local base = base_url(parsed)
  local ref = target.ref or "HEAD"
  local path = target.path and encode_path(target.path) or nil

  if target.kind == "repo" then
    return base, nil
  end

  if target.kind == "commit" then
    if forge == "bitbucket" then
      return ("%s/commits/%s"):format(base, ref), nil
    elseif forge == "sourcehut" then
      return ("%s/commit/%s"):format(base, ref), nil
    end
    return ("%s/commit/%s"):format(base, ref), nil
  end

  if target.kind == "branch" then
    if forge == "bitbucket" then
      return ("%s/src/%s"):format(base, ref), nil
    elseif forge == "sourcehut" then
      return ("%s/tree/%s"):format(base, ref), nil
    end
    return ("%s/tree/%s"):format(base, ref), nil
  end

  if target.kind == "compare" then
    local from, to = target.base or "main", target.head or ref
    if forge == "gitlab" then
      return ("%s/-/compare/%s...%s"):format(base, from, to), nil
    elseif forge == "bitbucket" then
      return ("%s/branches/compare/%s..%s"):format(base, to, from), nil
    end
    return ("%s/compare/%s...%s"):format(base, from, to), nil
  end

  if target.kind == "file" then
    if not path then
      return nil, "no file path given"
    end

    local url, anchor
    if forge == "gitlab" then
      url = ("%s/-/blob/%s/%s"):format(base, ref, path)
      anchor = target.first and ("#L%d"):format(target.first) or nil
      if target.first and target.last and target.last > target.first then
        anchor = ("#L%d-%d"):format(target.first, target.last)
      end
    elseif forge == "bitbucket" then
      url = ("%s/src/%s/%s"):format(base, ref, path)
      anchor = target.first and ("#lines-%d"):format(target.first) or nil
      if target.first and target.last and target.last > target.first then
        anchor = ("#lines-%d:%d"):format(target.first, target.last)
      end
    elseif forge == "sourcehut" then
      url = ("%s/tree/%s/item/%s"):format(base, ref, path)
      anchor = target.first and ("#L%d"):format(target.first) or nil
    else -- github, gitea and lookalikes
      url = ("%s/blob/%s/%s"):format(base, ref, path)
      anchor = target.first and ("#L%d"):format(target.first) or nil
      if target.first and target.last and target.last > target.first then
        anchor = ("#L%d-L%d"):format(target.first, target.last)
      end
    end

    return url .. (anchor or ""), nil
  end

  return nil, "unknown browse target: " .. tostring(target.kind)
end

--- Opening -------------------------------------------------------------------

---The command this platform uses to open a URL.
---@return string[]|nil
function M.opener()
  local configured = config.options.browse.opener
  if configured then
    return configured
  end
  if vim.fn.has("mac") == 1 then
    return { "open" }
  end
  if vim.fn.has("win32") == 1 or vim.fn.has("wsl") == 1 then
    return { "cmd.exe", "/c", "start", "" }
  end
  for _, candidate in ipairs({ "xdg-open", "gio", "wslview" }) do
    if vim.fn.executable(candidate) == 1 then
      return candidate == "gio" and { "gio", "open" } or { candidate }
    end
  end
  return nil
end

---Open a URL in the system browser.
---@param url string
---@param callback fun(ok: boolean, err: string|nil)|nil
function M.open(url, callback)
  callback = callback or function() end

  -- Neovim 0.10 ships a cross-platform opener; prefer it and keep the manual
  -- detection as a fallback for older versions and unusual environments.
  if vim.ui.open then
    local ok, handle = pcall(vim.ui.open, url)
    if ok and handle then
      return callback(true, nil)
    end
  end

  local opener = M.opener()
  if not opener then
    return callback(false, "No URL opener found. Set `browse.opener` in your picked configuration.")
  end

  local cmd = vim.deepcopy(opener)
  table.insert(cmd, url)
  vim.system(cmd, { detach = true }, function(result)
    vim.schedule(function()
      callback(result.code == 0, result.code ~= 0 and (result.stderr or "opener failed") or nil)
    end)
  end)
end

return M
