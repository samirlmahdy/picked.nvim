---@brief Merge conflict detection, parsing and resolution primitives.
---
---gitui never resolves a conflict on the user's behalf. It locates the
---conflicting regions, shows every version git recorded (base, ours, theirs),
---and applies exactly the choice the user made.

local command = require("gitui.git.command")
local diff_api = require("gitui.git.diff")

local M = {}

---@class GitConflictRegion
---@field index integer  1-based position in the file
---@field ours_start integer  line of the `<<<<<<<` marker
---@field ours_end integer  last line of our content
---@field base_start integer|nil  line after `|||||||`, when diff3 style is used
---@field base_end integer|nil
---@field separator integer  line of the `=======` marker
---@field theirs_start integer  first line of their content
---@field theirs_end integer  line of the `>>>>>>>` marker
---@field ours_label string
---@field theirs_label string
---@field ours string[]
---@field theirs string[]
---@field base string[]|nil

---@class GitConflictStages
---@field base string|nil  stage 1, absent for an add/add conflict
---@field ours string|nil  stage 2
---@field theirs string|nil  stage 3

--- Marker parsing ------------------------------------------------------------

local OURS_MARKER = "^<<<<<<<+%s?(.*)$"
local BASE_MARKER = "^|||||||+%s?(.*)$"
local SEPARATOR = "^=======+%s*$"
local THEIRS_MARKER = "^>>>>>>>+%s?(.*)$"

---Locate the conflict regions in a sequence of lines.
---
---Handles both `merge` style (ours / theirs) and `diff3` style, which adds the
---merge base between `|||||||` and `=======`.
---@param lines string[]
---@return GitConflictRegion[]
function M.parse_lines(lines)
  local regions = {}
  local current = nil

  for lnum, line in ipairs(lines) do
    local ours_label = line:match(OURS_MARKER)
    local base_label = line:match(BASE_MARKER)
    local theirs_label = line:match(THEIRS_MARKER)

    if ours_label then
      current = {
        index = #regions + 1,
        ours_start = lnum,
        ours_label = ours_label ~= "" and ours_label or "HEAD",
        ours = {},
        theirs = {},
      }
    elseif current and base_label then
      current.ours_end = lnum - 1
      current.base_start = lnum + 1
      current.base = {}
    elseif current and line:match(SEPARATOR) then
      if current.base_start then
        current.base_end = lnum - 1
      else
        current.ours_end = lnum - 1
      end
      current.separator = lnum
      current.theirs_start = lnum + 1
    elseif current and theirs_label and current.separator then
      current.theirs_end = lnum
      current.theirs_label = theirs_label ~= "" and theirs_label or "incoming"

      for index = current.ours_start + 1, current.ours_end do
        current.ours[#current.ours + 1] = lines[index]
      end
      for index = current.theirs_start, current.theirs_end - 1 do
        current.theirs[#current.theirs + 1] = lines[index]
      end
      if current.base_start and current.base_end then
        for index = current.base_start, current.base_end do
          current.base[#current.base + 1] = lines[index]
        end
      end

      regions[#regions + 1] = current
      current = nil
    end
  end

  return regions
end

---@param text string
---@return GitConflictRegion[]
function M.parse(text)
  return M.parse_lines(vim.split(text, "\n", { plain = true }))
end

---Conflict regions in a loaded buffer.
---@param bufnr integer
---@return GitConflictRegion[]
function M.in_buffer(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return {}
  end
  return M.parse_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
end

---The region containing a line, if any.
---@param regions GitConflictRegion[]
---@param lnum integer
---@return GitConflictRegion|nil
function M.at_line(regions, lnum)
  for _, region in ipairs(regions) do
    if lnum >= region.ours_start and lnum <= region.theirs_end then
      return region
    end
  end
  return nil
end

--- Resolution ----------------------------------------------------------------

---@alias GitConflictChoice "ours"|"theirs"|"both"|"base"|"none"

---The replacement lines for a resolution choice.
---@param region GitConflictRegion
---@param choice GitConflictChoice
---@return string[]
function M.resolution_lines(region, choice)
  if choice == "ours" then
    return vim.deepcopy(region.ours)
  elseif choice == "theirs" then
    return vim.deepcopy(region.theirs)
  elseif choice == "base" then
    return vim.deepcopy(region.base or {})
  elseif choice == "both" then
    local lines = vim.deepcopy(region.ours)
    vim.list_extend(lines, region.theirs)
    return lines
  end
  return {}
end

---Replace a conflict region in a buffer with the chosen content.
---
---Edits the buffer rather than the file so the change participates in undo and
---the user can reverse a mistaken choice with `u`.
---@param bufnr integer
---@param region GitConflictRegion
---@param choice GitConflictChoice
---@return boolean ok
function M.resolve_in_buffer(bufnr, region, choice)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  if not vim.bo[bufnr].modifiable then
    return false
  end
  local replacement = M.resolution_lines(region, choice)
  vim.api.nvim_buf_set_lines(bufnr, region.ours_start - 1, region.theirs_end, false, replacement)
  return true
end

--- Index stages ---------------------------------------------------------------

---Read the three versions git recorded for a conflicted path.
---
---Stage 1 is the merge base and is absent for an add/add conflict; stage 2 is
---ours and stage 3 is theirs, each absent when that side deleted the file.
---@param repo GitRepository
---@param path string
---@param callback fun(stages: GitConflictStages)
function M.stages(repo, path, callback)
  local stages = {}
  local pending = 3

  local function finish()
    pending = pending - 1
    if pending == 0 then
      callback(stages)
    end
  end

  local names = { [1] = "base", [2] = "ours", [3] = "theirs" }
  for stage, name in pairs(names) do
    diff_api.blob(repo, ":" .. stage, path, function(content, err)
      -- A missing stage is meaningful information, not a failure.
      stages[name] = (not err and content ~= "") and content or nil
      finish()
    end)
  end
end

---Paths git currently considers unmerged.
---@param repo GitRepository
---@param callback fun(paths: string[]|nil, err: GitError|nil)
function M.unmerged_paths(repo, callback)
  command.run(
    { "diff", "--name-only", "--diff-filter=U", "-z" },
    { cwd = repo.root },
    function(result)
      if not result.ok then
        return callback(nil, command.classify(result))
      end
      local text_util = require("gitui.utils.text")
      callback(text_util.nul_split(result.stdout), nil)
    end
  )
end

---Does this file still contain conflict markers on disk?
---
---Used to warn before staging: git is happy to record a file full of
---`<<<<<<<` as resolved, and that mistake is expensive to notice later.
---@param repo GitRepository
---@param path string
---@return boolean
function M.has_markers_on_disk(repo, path)
  local path_util = require("gitui.utils.path")
  local handle = io.open(path_util.to_os(repo.root .. "/" .. path), "r")
  if not handle then
    return false
  end
  local found = false
  for line in handle:lines() do
    if line:match(OURS_MARKER) or line:match(THEIRS_MARKER) then
      found = true
      break
    end
  end
  handle:close()
  return found
end

---Write the conflict style git should use for future merges.
---@param repo GitRepository
---@param style "merge"|"diff3"|"zdiff3"
---@param callback fun(ok: boolean)
function M.set_conflict_style(repo, style, callback)
  command.run({ "config", "merge.conflictStyle", style }, { cwd = repo.root }, function(result)
    callback(result.ok)
  end)
end

---Re-run the merge for one path with a given conflict style, so the user can
---see the base even if the original merge used the plain two-way style.
---@param repo GitRepository
---@param path string
---@param style "merge"|"diff3"|"zdiff3"
---@param callback fun(content: string|nil, err: GitError|nil)
function M.rematerialize(repo, path, style, callback)
  M.stages(repo, path, function(stages)
    if not stages.ours or not stages.theirs then
      return callback(nil, {
        kind = "incomplete_stages",
        title = "Cannot rebuild this conflict",
        reason = "One side of the conflict deleted the file, so there is no text to merge.",
        hint = "Choose whether to keep or remove the file.",
        raw = "",
      })
    end

    -- `git merge-file` produces exactly the markers git itself would write.
    local args = { "merge-file", "--stdout" }
    if style == "diff3" then
      table.insert(args, "--diff3")
    elseif style == "zdiff3" and command.version_at_least(2, 35) then
      table.insert(args, "--zdiff3")
    end

    local temp = {}
    local function write_temp(name, content)
      local file = vim.fn.tempname() .. "-" .. name
      local handle = io.open(file, "wb")
      if not handle then
        return nil
      end
      handle:write(content or "")
      handle:close()
      temp[#temp + 1] = file
      return file
    end

    local ours_file = write_temp("ours", stages.ours)
    local base_file = write_temp("base", stages.base or "")
    local theirs_file = write_temp("theirs", stages.theirs)
    if not (ours_file and base_file and theirs_file) then
      return callback(nil, {
        kind = "temp_failed",
        title = "Cannot rebuild this conflict",
        reason = "A temporary file could not be created.",
        raw = "",
      })
    end

    vim.list_extend(args, { "-L", "ours", "-L", "base", "-L", "theirs", ours_file, base_file, theirs_file })

    command.run(args, { cwd = repo.root }, function(result)
      for _, file in ipairs(temp) do
        os.remove(file)
      end
      -- merge-file exits with the number of remaining conflicts, which is the
      -- expected outcome here rather than a failure.
      if result.code < 0 then
        return callback(nil, command.classify(result))
      end
      callback(result.stdout, nil)
    end)
  end)
end

return M
