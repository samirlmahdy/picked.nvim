---@brief Highlight group definitions.
---
---No colour is ever hard-coded. Every group is defined with `default = true`
---and linked to a group the user's colourscheme already styles, so gitui
---inherits the editor's palette and any explicit user override wins.
---
---State is never communicated by colour alone: each of these groups
---accompanies a status letter, a symbol or a label elsewhere in the UI.

local M = {}

---@type table<string, vim.api.keyset.highlight>
local groups = {
  -- File status. Neovim defines Added/Changed/Removed as standard groups.
  GitUIAdded = { link = "Added" },
  GitUIModified = { link = "Changed" },
  GitUIDeleted = { link = "Removed" },
  GitUIRenamed = { link = "Changed" },
  GitUICopied = { link = "Changed" },
  GitUITypeChanged = { link = "Changed" },
  GitUIUntracked = { link = "Comment" },
  GitUIIgnored = { link = "Comment" },
  GitUIConflict = { link = "DiagnosticError" },
  GitUIStaged = { link = "Added" },
  GitUISubmodule = { link = "Special" },

  -- Structure.
  GitUITitle = { link = "Title" },
  GitUIHeader = { link = "Title" },
  GitUISectionHeader = { link = "Function" },
  GitUISectionCount = { link = "Comment" },
  GitUIDirectory = { link = "Directory" },
  GitUIChevron = { link = "Comment" },
  GitUISelected = { link = "Visual" },
  GitUICursorLine = { link = "CursorLine" },
  GitUIDim = { link = "Comment" },
  GitUIBorder = { link = "FloatBorder" },
  GitUINormal = { link = "NormalFloat" },
  GitUISeparator = { link = "WinSeparator" },

  -- Git objects.
  GitUIBranch = { link = "Identifier" },
  GitUIBranchCurrent = { link = "Title" },
  GitUIRemoteBranch = { link = "Constant" },
  GitUIRemote = { link = "Constant" },
  GitUITag = { link = "Special" },
  GitUIHash = { link = "Identifier" },
  GitUIAuthor = { link = "Constant" },
  GitUIDate = { link = "Comment" },
  GitUIStash = { link = "Special" },
  GitUIRefHead = { link = "Title" },

  -- Diffs.
  GitUIDiffAdd = { link = "DiffAdd" },
  GitUIDiffDelete = { link = "DiffDelete" },
  GitUIDiffChange = { link = "DiffChange" },
  GitUIDiffText = { link = "DiffText" },
  GitUIDiffHeader = { link = "Function" },
  GitUIDiffHunkHeader = { link = "Identifier" },
  GitUIDiffContext = { link = "Normal" },
  GitUIDiffLineNr = { link = "LineNr" },
  GitUIDiffFileName = { link = "Title" },

  -- Sign column. Linked to the foreground-only variants so signs never paint
  -- a background over the user's line highlighting.
  GitUISignAdd = { link = "Added" },
  GitUISignChange = { link = "Changed" },
  GitUISignDelete = { link = "Removed" },
  GitUISignTopDelete = { link = "Removed" },
  GitUISignChangeDelete = { link = "Changed" },
  GitUISignUntracked = { link = "Comment" },

  -- Blame.
  GitUIBlame = { link = "Comment" },
  GitUIBlameVirtual = { link = "Comment" },
  GitUIBlameHash = { link = "Identifier" },
  GitUIBlameAuthor = { link = "Constant" },
  GitUIBlameDate = { link = "Comment" },
  -- The current line, drawn in *both* panes so the code and its blame stay
  -- visually tied together even though only one of them has focus.
  GitUIBlameCurrentLine = { link = "CursorLine" },
  -- Every line belonging to the same commit as the current one.
  GitUIBlameBlock = { link = "ColorColumn" },

  -- Conflicts.
  GitUIConflictOurs = { link = "DiffAdd" },
  GitUIConflictTheirs = { link = "DiffChange" },
  GitUIConflictBase = { link = "DiffText" },
  GitUIConflictMarker = { link = "DiagnosticError" },
  GitUIConflictLabel = { link = "Title" },

  -- Feedback.
  GitUISuccess = { link = "DiagnosticOk" },
  GitUIWarning = { link = "DiagnosticWarn" },
  GitUIError = { link = "DiagnosticError" },
  GitUIInfo = { link = "DiagnosticInfo" },
  GitUIProgress = { link = "DiagnosticInfo" },

  -- Hints and help.
  GitUIKey = { link = "Special" },
  GitUIHint = { link = "Comment" },
  GitUIHelpHeader = { link = "Title" },

  -- Counters shown next to section headers and in the status line.
  GitUIAhead = { link = "Added" },
  GitUIBehind = { link = "Removed" },
  GitUIBadge = { link = "Comment" },

  -- Fuzzy-match positions in pickers.
  GitUIMatch = { link = "Special" },

  -- Commit graph lanes. Six distinct, colourscheme-provided hues that cycle.
  GitUIGraph1 = { link = "Function" },
  GitUIGraph2 = { link = "String" },
  GitUIGraph3 = { link = "Identifier" },
  GitUIGraph4 = { link = "Constant" },
  GitUIGraph5 = { link = "Special" },
  GitUIGraph6 = { link = "Type" },
}

local GRAPH_LANES = 6

---Highlight group for a graph lane colour index.
---@param color integer
---@return string
function M.graph(color)
  return "GitUIGraph" .. tostring(((color - 1) % GRAPH_LANES) + 1)
end

---Highlight group for a blame commit's colour index.
---
---Adjacent commits get different hues so the block structure of a file's
---history is visible at a glance, rather than every row being one flat colour.
---Reuses the graph palette, which colourschemes already style.
---@param color integer
---@return string
function M.blame_commit(color)
  return M.graph(color)
end

---Highlight group for a single-letter git status code.
---@param code string
---@return string
function M.for_status(code)
  local map = {
    M = "GitUIModified",
    A = "GitUIAdded",
    D = "GitUIDeleted",
    R = "GitUIRenamed",
    C = "GitUICopied",
    T = "GitUITypeChanged",
    U = "GitUIConflict",
    ["?"] = "GitUIUntracked",
    ["!"] = "GitUIIgnored",
    [" "] = "GitUIDim",
  }
  return map[code] or "GitUIDim"
end

---Highlight group for a diff line kind.
---@param kind "add"|"delete"|"context"|"header"|"marker"
---@return string
function M.for_diff(kind)
  if kind == "add" then
    return "GitUIDiffAdd"
  elseif kind == "delete" then
    return "GitUIDiffDelete"
  elseif kind == "header" then
    return "GitUIDiffHunkHeader"
  elseif kind == "marker" then
    return "GitUIDim"
  end
  return "GitUIDiffContext"
end

local augroup = nil

---Define every group. Safe to call repeatedly.
function M.setup()
  for name, spec in pairs(groups) do
    local definition = vim.deepcopy(spec)
    definition.default = true
    pcall(vim.api.nvim_set_hl, 0, name, definition)
  end

  if not augroup then
    augroup = vim.api.nvim_create_augroup("GitUIHighlights", { clear = true })
    -- A colourscheme change clears links established with `default`, so they
    -- have to be re-established rather than defined once at startup.
    vim.api.nvim_create_autocmd("ColorScheme", {
      group = augroup,
      callback = function()
        M.setup()
      end,
    })
  end
end

---Names of every group gitui defines, for documentation and `:checkhealth`.
---@return string[]
function M.names()
  local names = vim.tbl_keys(groups)
  table.sort(names)
  return names
end

return M
