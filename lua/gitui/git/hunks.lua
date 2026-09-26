---@brief Unified-diff hunk model, patch construction and partial selection.
---
---One representation serves both sources of diffs:
---  * text produced by `git diff` (parsed with `M.parse`),
---  * text produced by `vim.diff` when comparing a live buffer against the
---    index (`M.compute`), which avoids a subprocess on every keystroke.
---
---Patches built here are fed to `git apply`, so they must be exactly right:
---the counts in an `@@` header, the context lines, and the "no newline"
---markers are all load-bearing. Context lines are deliberately retained
---(rather than using `--unidiff-zero`) because they make `git apply` verify it
---is patching the content we think it is, turning a stale patch into a clean
---refusal instead of a corrupted file.

local M = {}

---@class GitHunk
---@field old_start integer  first line on the "a" side (1-based; 0 for a pure insertion at the top)
---@field old_count integer
---@field new_start integer  first line on the "b" side
---@field new_count integer
---@field lines string[]  patch body: each entry starts with " ", "+", "-" or "\"
---@field heading string  trailing text of the @@ header (a function name, usually)
---@field type "add"|"delete"|"change"
---@field index integer  1-based position within its file's diff

--- Parsing -----------------------------------------------------------------

---@param header string
---@return integer|nil old_start, integer old_count, integer new_start, integer new_count, string heading
local function parse_header(header)
  local old_start, old_count, new_start, new_count, heading =
    header:match("^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@ ?(.*)$")
  if not old_start then
    return nil, 0, 0, 0, ""
  end
  -- An omitted count means exactly one line.
  return tonumber(old_start),
    old_count == "" and 1 or tonumber(old_count),
    tonumber(new_start),
    new_count == "" and 1 or tonumber(new_count),
    heading or ""
end

---@param hunk GitHunk
---@return "add"|"delete"|"change"
local function classify(hunk)
  if hunk.old_count == 0 then
    return "add"
  end
  if hunk.new_count == 0 then
    return "delete"
  end
  local added, removed = 0, 0
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == "+" then
      added = added + 1
    elseif prefix == "-" then
      removed = removed + 1
    end
  end
  if removed == 0 then
    return "add"
  end
  if added == 0 then
    return "delete"
  end
  return "change"
end

---Parse the hunks out of a unified diff.
---
---Accepts a complete `git diff` (headers included) or a bare body such as
---`vim.diff` produces. Lines belonging to the file header are skipped.
---@param text string
---@return GitHunk[]
function M.parse(text)
  local hunks = {}
  if not text or text == "" then
    return hunks
  end

  local lines = vim.split(text, "\n", { plain = true })
  -- A trailing newline yields a final empty element that is an artefact of the
  -- separator, not a diff line. Leaving it in would add a phantom context line
  -- to the last hunk and corrupt every count derived from the body.
  if lines[#lines] == "" then
    table.remove(lines)
  end

  local current = nil
  for _, line in ipairs(lines) do
    if line:sub(1, 2) == "@@" then
      local old_start, old_count, new_start, new_count, heading = parse_header(line)
      if old_start then
        current = {
          old_start = old_start,
          old_count = old_count,
          new_start = new_start,
          new_count = new_count,
          lines = {},
          heading = heading,
          index = #hunks + 1,
        }
        hunks[#hunks + 1] = current
      else
        current = nil
      end
    elseif current then
      local prefix = line:sub(1, 1)
      if prefix == " " or prefix == "+" or prefix == "-" or prefix == "\\" then
        current.lines[#current.lines + 1] = line
      elseif line == "" then
        -- git emits a bare empty line for an unchanged empty line; the leading
        -- space is stripped by some transports, so normalise it back.
        current.lines[#current.lines + 1] = " "
      else
        -- Anything else (a new `diff --git` header) ends this hunk.
        current = nil
      end
    end
  end

  for _, hunk in ipairs(hunks) do
    hunk.type = classify(hunk)
  end

  return hunks
end

--- Computation from two texts ----------------------------------------------

---Diff two blobs with Neovim's built-in xdiff.
---@param old_text string
---@param new_text string
---@param opts { context: integer|nil, algorithm: string|nil, ignore_whitespace: boolean|nil }|nil
---@return GitHunk[]
function M.compute(old_text, new_text, opts)
  opts = opts or {}
  local diff_opts = {
    result_type = "unified",
    ctxlen = opts.context or 3,
    algorithm = opts.algorithm or "histogram",
  }
  if opts.ignore_whitespace then
    diff_opts.ignore_whitespace = true
  end

  local ok, unified = pcall(vim.diff, old_text, new_text, diff_opts)
  if not ok or type(unified) ~= "string" then
    return {}
  end
  return M.parse(unified)
end

--- Line accounting ----------------------------------------------------------

---Recount a hunk's header values from its body. Used after any edit to the
---body so the header can never disagree with the content.
---@param hunk GitHunk
---@return integer old_count, integer new_count
function M.recount(hunk)
  local old_count, new_count = 0, 0
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == " " then
      old_count = old_count + 1
      new_count = new_count + 1
    elseif prefix == "-" then
      old_count = old_count + 1
    elseif prefix == "+" then
      new_count = new_count + 1
    end
  end
  return old_count, new_count
end

---@param hunk GitHunk
---@return integer added, integer removed
function M.counts(hunk)
  local added, removed = 0, 0
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == "+" then
      added = added + 1
    elseif prefix == "-" then
      removed = removed + 1
    end
  end
  return added, removed
end

---Render a hunk's `@@` header.
---@param hunk GitHunk
---@return string
function M.header(hunk)
  local old = hunk.old_count == 1 and tostring(hunk.old_start)
    or ("%d,%d"):format(hunk.old_start, hunk.old_count)
  local new = hunk.new_count == 1 and tostring(hunk.new_start)
    or ("%d,%d"):format(hunk.new_start, hunk.new_count)
  local header = ("@@ -%s +%s @@"):format(old, new)
  if hunk.heading and hunk.heading ~= "" then
    header = header .. " " .. hunk.heading
  end
  return header
end

---Range of buffer lines a hunk covers on the new side.
---
---A pure deletion occupies no lines, so it is reported as a zero-width range
---anchored to the line that now sits where the removed text used to be.
---@param hunk GitHunk
---@return integer first, integer last
function M.new_range(hunk)
  if hunk.new_count == 0 then
    return hunk.new_start, hunk.new_start
  end
  return hunk.new_start, hunk.new_start + hunk.new_count - 1
end

---@param hunks GitHunk[]
---@param lnum integer  buffer line on the new side
---@return GitHunk|nil, integer|nil index
function M.at_line(hunks, lnum)
  for index, hunk in ipairs(hunks) do
    local first, last = M.new_range(hunk)
    if hunk.new_count == 0 then
      -- A deletion is anchored between lines; treat the line above it and the
      -- line at its position as both belonging to it.
      if lnum == first or lnum == first + 1 then
        return hunk, index
      end
    elseif lnum >= first and lnum <= last then
      return hunk, index
    end
  end
  return nil, nil
end

---Hunks overlapping a buffer line range.
---@param hunks GitHunk[]
---@param first integer
---@param last integer
---@return GitHunk[]
function M.in_range(hunks, first, last)
  local out = {}
  for _, hunk in ipairs(hunks) do
    local hfirst, hlast = M.new_range(hunk)
    if hunk.new_count == 0 then
      if hfirst >= first - 1 and hfirst <= last then
        out[#out + 1] = hunk
      end
    elseif hfirst <= last and hlast >= first then
      out[#out + 1] = hunk
    end
  end
  return out
end

--- Partial selection ---------------------------------------------------------

---Build a hunk containing only the selected changes.
---
---Unselected additions are dropped (they must not reach the target), and
---unselected deletions become context (they must survive in the target). The
---result is a valid standalone hunk whose header is recomputed from its body.
---
---@param hunk GitHunk
---@param selected table<integer, boolean>  body line index -> selected
---@return GitHunk|nil  nil when nothing was selected
function M.select_body(hunk, selected)
  local lines = {}
  local any = false

  local index = 1
  while index <= #hunk.lines do
    local line = hunk.lines[index]
    local prefix = line:sub(1, 1)

    -- A "\ No newline at end of file" marker belongs to the line before it and
    -- must travel with it.
    local marker = nil
    if hunk.lines[index + 1] and hunk.lines[index + 1]:sub(1, 1) == "\\" then
      marker = hunk.lines[index + 1]
    end

    if prefix == " " then
      lines[#lines + 1] = line
      if marker then
        lines[#lines + 1] = marker
      end
    elseif prefix == "+" then
      if selected[index] then
        any = true
        lines[#lines + 1] = line
        if marker then
          lines[#lines + 1] = marker
        end
      end
      -- Unselected addition: omit it entirely.
    elseif prefix == "-" then
      if selected[index] then
        any = true
        lines[#lines + 1] = line
        if marker then
          lines[#lines + 1] = marker
        end
      else
        -- Unselected deletion must remain present, so it becomes context.
        lines[#lines + 1] = " " .. line:sub(2)
        if marker then
          lines[#lines + 1] = marker
        end
      end
    elseif prefix == "\\" then
      -- Handled alongside its owning line.
      if index == 1 then
        lines[#lines + 1] = line
      end
    end

    index = index + 1
    if marker then
      index = index + 1
    end
  end

  if not any then
    return nil
  end

  ---@type GitHunk
  local partial = {
    old_start = hunk.old_start,
    old_count = 0,
    new_start = hunk.new_start,
    new_count = 0,
    lines = lines,
    heading = hunk.heading,
    index = hunk.index,
    type = "change",
  }
  partial.old_count, partial.new_count = M.recount(partial)
  partial.type = classify(partial)
  return partial
end

---Body line indices covered by a range of *new side* line numbers.
---
---Selection rule (documented in `:help gitui-line-staging`): an addition is
---selected when its own line number is inside the range; a deletion is
---selected when the line that now occupies its position is inside the range.
---That makes a visual selection in a file buffer behave the way the signs in
---the gutter suggest it should.
---@param hunk GitHunk
---@param first integer
---@param last integer
---@return table<integer, boolean>
function M.body_indices_for_range(hunk, first, last)
  local selected = {}
  local new_ln = hunk.new_start

  for index, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == " " then
      new_ln = new_ln + 1
    elseif prefix == "+" then
      if new_ln >= first and new_ln <= last then
        selected[index] = true
      end
      new_ln = new_ln + 1
    elseif prefix == "-" then
      if new_ln >= first and new_ln <= last then
        selected[index] = true
      end
    end
  end

  return selected
end

---Hunk restricted to a range of buffer lines.
---@param hunk GitHunk
---@param first integer
---@param last integer
---@return GitHunk|nil
function M.select_range(hunk, first, last)
  return M.select_body(hunk, M.body_indices_for_range(hunk, first, last))
end

--- Inversion -----------------------------------------------------------------

---Swap the two sides of a hunk, producing the patch that undoes it.
---
---`git apply -R` is preferred where possible; this exists for callers that
---need the reversed text itself (the diff preview of a discard, for example).
---@param hunk GitHunk
---@return GitHunk
function M.invert(hunk)
  local lines = {}
  for _, line in ipairs(hunk.lines) do
    local prefix = line:sub(1, 1)
    if prefix == "+" then
      lines[#lines + 1] = "-" .. line:sub(2)
    elseif prefix == "-" then
      lines[#lines + 1] = "+" .. line:sub(2)
    else
      lines[#lines + 1] = line
    end
  end
  return {
    old_start = hunk.new_start,
    old_count = hunk.new_count,
    new_start = hunk.old_start,
    new_count = hunk.old_count,
    lines = lines,
    heading = hunk.heading,
    index = hunk.index,
    type = hunk.type == "add" and "delete" or (hunk.type == "delete" and "add" or "change"),
  }
end

--- Patch assembly --------------------------------------------------------------

---Quote a path the way git's `quote_c_style` does.
---
---git only quotes when a name contains a double quote, a backslash or a
---control character — notably *not* for spaces — and `git apply` parses the
---result. Matching that behaviour exactly keeps generated patches
---interchangeable with git's own.
---@param path string
---@return string
function M.quote_path(path)
  if not path:find('[%c"\\]') then
    return path
  end
  local escaped = path:gsub("[\\\"]", "\\%0")
  escaped = escaped:gsub("%c", function(char)
    local byte = char:byte()
    local named = { [7] = "\\a", [8] = "\\b", [12] = "\\f", [10] = "\\n", [13] = "\\r", [9] = "\\t", [11] = "\\v" }
    return named[byte] or ("\\%03o"):format(byte)
  end)
  return '"' .. escaped .. '"'
end

---@class GitPatchOpts
---@field old_path string|nil  defaults to `path` (differs for a rename)
---@field new_file boolean|nil  the "a" side does not exist
---@field deleted_file boolean|nil  the "b" side does not exist
---@field mode string|nil  file mode for a new file, default "100644"

---Assemble a complete, applicable patch for one file.
---
---`new_start` values are recomputed so the hunks stay internally consistent
---even when only a subset of a file's hunks is included.
---@param path string  repository-relative path
---@param hunks GitHunk[]
---@param opts GitPatchOpts|nil
---@return string|nil patch, string|nil error
function M.to_patch(path, hunks, opts)
  opts = opts or {}
  if #hunks == 0 then
    return nil, "no hunks selected"
  end

  local old_path = opts.old_path or path
  local quoted_old = M.quote_path("a/" .. old_path)
  local quoted_new = M.quote_path("b/" .. path)

  local out = {}
  out[#out + 1] = ("diff --git %s %s"):format(quoted_old, quoted_new)
  if opts.new_file then
    out[#out + 1] = "new file mode " .. (opts.mode or "100644")
  elseif opts.deleted_file then
    out[#out + 1] = "deleted file mode " .. (opts.mode or "100644")
  end
  out[#out + 1] = "--- " .. (opts.new_file and "/dev/null" or quoted_old)
  out[#out + 1] = "+++ " .. (opts.deleted_file and "/dev/null" or quoted_new)

  local delta = 0
  for _, hunk in ipairs(hunks) do
    local old_count, new_count = M.recount(hunk)
    ---@type GitHunk
    local adjusted = {
      old_start = hunk.old_start,
      old_count = old_count,
      -- The b-side offset depends on every hunk included before this one.
      new_start = hunk.old_start + delta,
      new_count = new_count,
      lines = hunk.lines,
      heading = hunk.heading,
      index = hunk.index,
      type = hunk.type,
    }
    -- A hunk that only inserts sits *after* `old_start`, and git writes the
    -- b-side start as the first inserted line.
    if old_count == 0 then
      adjusted.new_start = hunk.old_start + delta + 1
    end
    delta = delta + (new_count - old_count)

    out[#out + 1] = M.header(adjusted)
    for _, line in ipairs(hunk.lines) do
      out[#out + 1] = line
    end
  end

  return table.concat(out, "\n") .. "\n", nil
end

--- Rendering helpers ----------------------------------------------------------

---Flatten hunks into displayable lines with per-line metadata.
---@param hunks GitHunk[]
---@class GitUIDiffDisplayRow
---@field text string
---@field kind "header"|"context"|"add"|"delete"|"marker"
---@field hunk GitHunk
---@field body_index integer|nil  index into `hunk.lines`; nil for the header
---@field old_ln integer|nil
---@field new_ln integer|nil

---@return GitUIDiffDisplayRow[]
function M.to_display(hunks)
  local rows = {}
  for _, hunk in ipairs(hunks) do
    rows[#rows + 1] = { text = M.header(hunk), kind = "header", hunk = hunk }
    local old_ln, new_ln = hunk.old_start, hunk.new_start
    for body_index, line in ipairs(hunk.lines) do
      local prefix = line:sub(1, 1)
      local kind = prefix == "+" and "add"
        or prefix == "-" and "delete"
        or prefix == "\\" and "marker"
        or "context"

      local row = {
        text = line,
        kind = kind,
        hunk = hunk,
        body_index = body_index,
      }
      if kind == "context" then
        row.old_ln, row.new_ln = old_ln, new_ln
        old_ln, new_ln = old_ln + 1, new_ln + 1
      elseif kind == "add" then
        row.new_ln = new_ln
        new_ln = new_ln + 1
      elseif kind == "delete" then
        row.old_ln = old_ln
        old_ln = old_ln + 1
      end
      rows[#rows + 1] = row
    end
  end
  return rows
end

return M
