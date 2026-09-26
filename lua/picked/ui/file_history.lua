---@brief File and line history.
---
---A file's history is the same commit list the log view shows, scoped to one
---path and following renames. Selecting a commit opens that file *as it was*
---at that revision, which is the question the view exists to answer.

local git = require("picked.git")
local notify = require("picked.ui.notify")
local path_util = require("picked.utils.path")
local window = require("picked.ui.window")

local M = {}

---Open the history of a file.
---@param repo GitRepository
---@param path string  repository-relative
function M.open(repo, path)
  require("picked.ui.log").open(repo, {
    paths = { path },
    title = "HISTORY: " .. path,
  })
end

---Open the history of the current buffer's file.
function M.current_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = path_util.buffer_path(bufnr)
  if not file then
    return notify.warn("This buffer is not a file on disk")
  end

  local repository = require("picked.git.repository")
  local repo = repository.detect(path_util.dirname(file))
  if not repo then
    return notify.warn("Not inside a git repository")
  end

  local relative = path_util.relative(file, repo.root)
  if not relative then
    return notify.warn("This file is outside the repository")
  end

  M.open(repo, relative)
end

---Open the history of a range of lines.
---
---`git log -L` is exact about which commits touched those lines, which is far
---more useful than a whole-file history when chasing one change.
---@param repo GitRepository
---@param path string
---@param first integer
---@param last integer
function M.lines(repo, path, first, last)
  local progress = notify.progress("Reading line history", { root = repo.root, key = "line-history" })

  git.commits.line_history(repo, path, first, last, nil, function(commits, err)
    if err then
      return progress:finish(false, nil, err)
    end
    progress:finish(true, ("%d commits touched lines %d–%d"):format(#(commits or {}), first, last))

    if not commits or #commits == 0 then
      return notify.info("No commits found for those lines")
    end

    -- Reuse the log view, restricted to exactly these commits.
    require("picked.ui.log").open(repo, {
      revisions = vim.tbl_map(function(commit)
        return commit.oid
      end, commits),
      paths = nil,
      title = ("HISTORY: %s:%d-%d"):format(path, first, last),
    })
  end)
end

---Line history for the current buffer's cursor line or visual selection.
---@param first integer|nil
---@param last integer|nil
function M.current_lines(first, last)
  local bufnr = vim.api.nvim_get_current_buf()
  local file = path_util.buffer_path(bufnr)
  if not file then
    return notify.warn("This buffer is not a file on disk")
  end

  local repository = require("picked.git.repository")
  local repo = repository.detect(path_util.dirname(file))
  if not repo then
    return notify.warn("Not inside a git repository")
  end

  local relative = path_util.relative(file, repo.root)
  if not relative then
    return
  end

  if not first then
    first = vim.api.nvim_win_get_cursor(0)[1]
    last = first
  end
  M.lines(repo, relative, first, last or first)
end

---Open a file as it existed at a revision, read-only.
---@param repo GitRepository
---@param revision string
---@param path string
function M.open_at_revision(repo, revision, path)
  git.diff.blob(repo, revision, path, function(content, err)
    if err then
      return notify.error(err)
    end

    local short = revision:sub(1, 7)
    local bufnr = window.create_buffer({
      name = ("%s@%s"):format(path_util.basename(path), short),
      filetype = "",
    })

    vim.bo[bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, vim.split(content or "", "\n", { plain = true }))
    vim.bo[bufnr].modifiable = false
    vim.bo[bufnr].filetype = vim.filetype.match({ filename = path, buf = bufnr }) or ""

    local winid = window.pick_editor_window()
    if winid then
      vim.api.nvim_set_current_win(winid)
      vim.api.nvim_win_set_buf(winid, bufnr)
    else
      vim.cmd("vsplit")
      vim.api.nvim_win_set_buf(vim.api.nvim_get_current_win(), bufnr)
    end

    vim.keymap.set("n", "q", function()
      window.delete_buffer(bufnr)
    end, { buffer = bufnr, nowait = true, silent = true })

    notify.info(("%s at %s (read-only)"):format(path, short))
  end)
end

return M
