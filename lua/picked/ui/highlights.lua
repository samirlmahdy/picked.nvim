---@brief Highlight group definitions.
---
---No colour is ever hard-coded. Every group is defined with `default = true`
---and linked to a group the user's colourscheme already styles, so picked
---inherits the editor's palette and any explicit user override wins.
---
---State is never communicated by colour alone: each of these groups
---accompanies a status letter, a symbol or a label elsewhere in the UI.

local M = {}

---@type table<string, vim.api.keyset.highlight>
local groups = {
  -- File status. Neovim defines Added/Changed/Removed as standard groups.
  PickedAdded = { link = "Added" },
  PickedModified = { link = "Changed" },
  PickedDeleted = { link = "Removed" },
  PickedRenamed = { link = "Changed" },
  PickedCopied = { link = "Changed" },
  PickedTypeChanged = { link = "Changed" },
  PickedUntracked = { link = "Comment" },
  PickedIgnored = { link = "Comment" },
  PickedConflict = { link = "DiagnosticError" },
  PickedStaged = { link = "Added" },
  PickedSubmodule = { link = "Special" },

  -- Structure.
  PickedTitle = { link = "Title" },
  PickedHeader = { link = "Title" },
  PickedSectionHeader = { link = "Function" },
  PickedSectionCount = { link = "Comment" },
  PickedDirectory = { link = "Directory" },
  PickedChevron = { link = "Comment" },
  PickedSelected = { link = "Visual" },
  PickedCursorLine = { link = "CursorLine" },
  PickedDim = { link = "Comment" },
  PickedBorder = { link = "FloatBorder" },
  PickedNormal = { link = "NormalFloat" },
  PickedSeparator = { link = "WinSeparator" },

  -- Git objects.
  PickedBranch = { link = "Identifier" },
  PickedBranchCurrent = { link = "Title" },
  PickedRemoteBranch = { link = "Constant" },
  PickedRemote = { link = "Constant" },
  PickedTag = { link = "Special" },
  PickedHash = { link = "Identifier" },
  PickedAuthor = { link = "Constant" },
  PickedDate = { link = "Comment" },
  PickedStash = { link = "Special" },
  PickedRefHead = { link = "Title" },

  -- Diffs.
  PickedDiffAdd = { link = "DiffAdd" },
  PickedDiffDelete = { link = "DiffDelete" },
  PickedDiffChange = { link = "DiffChange" },
  PickedDiffText = { link = "DiffText" },
  PickedDiffHeader = { link = "Function" },
  PickedDiffHunkHeader = { link = "Identifier" },
  PickedDiffContext = { link = "Normal" },
  PickedDiffLineNr = { link = "LineNr" },
  PickedDiffFileName = { link = "Title" },

  -- Sign column. Linked to the foreground-only variants so signs never paint
  -- a background over the user's line highlighting.
  PickedSignAdd = { link = "Added" },
  PickedSignChange = { link = "Changed" },
  PickedSignDelete = { link = "Removed" },
  PickedSignTopDelete = { link = "Removed" },
  PickedSignChangeDelete = { link = "Changed" },
  PickedSignUntracked = { link = "Comment" },

  -- Blame.
  PickedBlame = { link = "Comment" },
  PickedBlameVirtual = { link = "Comment" },
  PickedBlameHash = { link = "Identifier" },
  PickedBlameAuthor = { link = "Constant" },
  PickedBlameDate = { link = "Comment" },
  -- The current line, drawn in *both* panes so the code and its blame stay
  -- visually tied together even though only one of them has focus.
  PickedBlameCurrentLine = { link = "CursorLine" },
  -- Every line belonging to the same commit as the current one.
  PickedBlameBlock = { link = "ColorColumn" },

  -- Conflicts.
  PickedConflictOurs = { link = "DiffAdd" },
  PickedConflictTheirs = { link = "DiffChange" },
  PickedConflictBase = { link = "DiffText" },
  PickedConflictMarker = { link = "DiagnosticError" },
  PickedConflictLabel = { link = "Title" },

  -- Feedback.
  PickedSuccess = { link = "DiagnosticOk" },
  PickedWarning = { link = "DiagnosticWarn" },
  PickedError = { link = "DiagnosticError" },
  PickedInfo = { link = "DiagnosticInfo" },
  PickedProgress = { link = "DiagnosticInfo" },

  -- Hints and help.
  PickedKey = { link = "Special" },
  PickedHint = { link = "Comment" },
  PickedHelpHeader = { link = "Title" },

  -- Counters shown next to section headers and in the status line.
  PickedAhead = { link = "Added" },
  PickedBehind = { link = "Removed" },
  PickedBadge = { link = "Comment" },

  -- Fuzzy-match positions in pickers.
  PickedMatch = { link = "Special" },

  -- Commit graph lanes. Six distinct, colourscheme-provided hues that cycle.
  PickedGraph1 = { link = "Function" },
  PickedGraph2 = { link = "String" },
  PickedGraph3 = { link = "Identifier" },
  PickedGraph4 = { link = "Constant" },
  PickedGraph5 = { link = "Special" },
  PickedGraph6 = { link = "Type" },
}

local GRAPH_LANES = 6

---Highlight group for a graph lane colour index.
---@param color integer
---@return string
function M.graph(color)
  return "PickedGraph" .. tostring(((color - 1) % GRAPH_LANES) + 1)
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
    M = "PickedModified",
    A = "PickedAdded",
    D = "PickedDeleted",
    R = "PickedRenamed",
    C = "PickedCopied",
    T = "PickedTypeChanged",
    U = "PickedConflict",
    ["?"] = "PickedUntracked",
    ["!"] = "PickedIgnored",
    [" "] = "PickedDim",
  }
  return map[code] or "PickedDim"
end

---Highlight group for a diff line kind.
---@param kind "add"|"delete"|"context"|"header"|"marker"
---@return string
function M.for_diff(kind)
  if kind == "add" then
    return "PickedDiffAdd"
  elseif kind == "delete" then
    return "PickedDiffDelete"
  elseif kind == "header" then
    return "PickedDiffHunkHeader"
  elseif kind == "marker" then
    return "PickedDim"
  end
  return "PickedDiffContext"
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
    augroup = vim.api.nvim_create_augroup("PickedHighlights", { clear = true })
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

---Names of every group picked defines, for documentation and `:checkhealth`.
---@return string[]
function M.names()
  local names = vim.tbl_keys(groups)
  table.sort(names)
  return names
end

return M
