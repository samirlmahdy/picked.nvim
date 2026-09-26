---@brief Path helpers.
---
---Git always speaks forward slashes; the filesystem on Windows does not. Every
---path crossing the git boundary is normalised to forward slashes, and every
---path handed to Neovim is converted back.

local M = {}

M.sep = package.config:sub(1, 1)
M.is_windows = M.sep == "\\"

---Normalise a filesystem path to the plugin's canonical form: forward slashes,
---no trailing separator, no redundant `.` segments.
---@param path string
---@return string
function M.normalize(path)
  if path == "" then
    return path
  end
  path = path:gsub("\\", "/")
  path = path:gsub("/+", "/")
  path = path:gsub("/%./", "/")
  path = path:gsub("^%./", "")
  if #path > 1 then
    path = path:gsub("/$", "")
  end
  return path
end

---Convert a canonical path into a form suitable for `vim.fn` / `:edit`.
---@param path string
---@return string
function M.to_os(path)
  if M.is_windows then
    return (path:gsub("/", "\\"))
  end
  return path
end

---@param ... string
---@return string
function M.join(...)
  local parts = {}
  for i = 1, select("#", ...) do
    local part = select(i, ...)
    if part and part ~= "" then
      parts[#parts + 1] = (part:gsub("/+$", ""))
    end
  end
  return M.normalize(table.concat(parts, "/"))
end

---@param path string
---@return string
function M.dirname(path)
  path = M.normalize(path)
  local dir = path:match("^(.*)/[^/]*$")
  return dir or ""
end

---@param path string
---@return string
function M.basename(path)
  path = M.normalize(path)
  return path:match("[^/]*$") or path
end

---@param path string
---@return string extension without the dot, or ""
function M.extension(path)
  return M.basename(path):match("%.([^.]+)$") or ""
end

---Split a path into its components.
---@param path string
---@return string[]
function M.segments(path)
  local out = {}
  for segment in M.normalize(path):gmatch("[^/]+") do
    out[#out + 1] = segment
  end
  return out
end

---Is `path` inside `root` (or equal to it)?
---@param path string
---@param root string
---@return boolean
function M.is_within(path, root)
  path = M.normalize(path)
  root = M.normalize(root)
  if path == root then
    return true
  end
  return path:sub(1, #root + 1) == root .. "/"
end

---Path of `path` relative to `root`. Returns nil when `path` is outside.
---@param path string
---@param root string
---@return string|nil
function M.relative(path, root)
  path = M.normalize(path)
  root = M.normalize(root)
  if path == root then
    return ""
  end
  if path:sub(1, #root + 1) == root .. "/" then
    return path:sub(#root + 2)
  end
  return nil
end

---Resolve a path to an absolute, symlink-free canonical path.
---Falls back to `fnamemodify` when the file does not exist yet.
---@param path string
---@return string
function M.absolute(path)
  if path == "" then
    return M.normalize(vim.uv.cwd() or "")
  end
  local resolved = vim.uv.fs_realpath(M.to_os(path))
  if resolved then
    return M.normalize(resolved)
  end
  return M.normalize(vim.fn.fnamemodify(M.to_os(path), ":p"))
end

---Replace the user's home directory with `~`.
---@param path string
---@return string
function M.tilde(path)
  local home = M.normalize(vim.uv.os_homedir() or "")
  if home ~= "" and M.is_within(path, home) then
    local rest = M.relative(path, home)
    return rest == "" and "~" or ("~/" .. rest)
  end
  return path
end

---Shorten a path for display by eliding leading directories.
---@param path string
---@param max_width integer
---@return string
function M.shorten(path, max_width)
  if vim.fn.strdisplaywidth(path) <= max_width then
    return path
  end
  local parts = M.segments(path)
  -- Keep the basename intact; abbreviate parents to their first character.
  for i = 1, #parts - 1 do
    parts[i] = parts[i]:sub(1, 1)
    local candidate = table.concat(parts, "/")
    if vim.fn.strdisplaywidth(candidate) <= max_width then
      return candidate
    end
  end
  local name = parts[#parts] or path
  if vim.fn.strdisplaywidth(name) <= max_width then
    return name
  end
  return "…" .. name:sub(-(max_width - 1))
end

---Is this buffer backed by a real file on disk?
---@param bufnr integer
---@return string|nil absolute path
function M.buffer_path(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return nil
  end
  if vim.bo[bufnr].buftype ~= "" then
    return nil
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == "" then
    return nil
  end
  -- Ignore paths owned by other plugins' virtual schemes (fugitive://, oil://…)
  if name:match("^%a[%w+.-]*://") then
    return nil
  end
  return M.absolute(name)
end

return M
