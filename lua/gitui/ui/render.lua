---@brief Buffer rendering primitives.
---
---A `Canvas` is an intermediate representation of a panel: a list of rows,
---each made of highlighted segments, with arbitrary metadata attached. Views
---build a canvas and apply it; they never touch extmarks or buffer lines
---directly.
---
---Attaching metadata per row is what makes the whole UI work uniformly:
---keymaps ask "what is under the cursor?", the mouse handler asks "what is
---under this cell?", and both get a plain Lua table back.

local text_util = require("gitui.utils.text")

local M = {}

---@class GitUISegment
---@field text string
---@field hl string|nil
---@field action string|nil  named click target for the mouse handler

---@class GitUIRow
---@field segments GitUISegment[]
---@field item any|nil  metadata the view attaches to this row
---@field line_hl string|nil  highlight applied to the whole line
---@field right GitUISegment[]|nil  right-aligned virtual text
---@field sign { text: string, hl: string }|nil
---@field indent integer

---@class GitUICanvas
---@field rows GitUIRow[]
---@field width integer
local Canvas = {}
Canvas.__index = Canvas

---@class GitUIRowBuilder
---@field row GitUIRow
local RowBuilder = {}
RowBuilder.__index = RowBuilder

---Append a segment.
---@param content string
---@param hl string|nil
---@param action string|nil
---@return GitUIRowBuilder
function RowBuilder:add(content, hl, action)
  if content == nil or content == "" then
    return self
  end
  self.row.segments[#self.row.segments + 1] = { text = content, hl = hl, action = action }
  return self
end

---Append `count` spaces.
---@param count integer
---@return GitUIRowBuilder
function RowBuilder:space(count)
  return self:add(string.rep(" ", math.max(0, count or 1)))
end

---Pad with spaces until the row is `column` cells wide.
---@param column integer
---@return GitUIRowBuilder
function RowBuilder:pad_to(column)
  local current = self:width()
  if current < column then
    self:add(string.rep(" ", column - current))
  end
  return self
end

---Current display width of the row.
---@return integer
function RowBuilder:width()
  local total = 0
  for _, segment in ipairs(self.row.segments) do
    total = total + text_util.width(segment.text)
  end
  return total
end

---Add right-aligned virtual text. Virtual text cannot be selected or copied,
---so it is only ever used for decoration that is also available elsewhere.
---@param content string
---@param hl string|nil
---@return GitUIRowBuilder
function RowBuilder:right(content, hl)
  self.row.right = self.row.right or {}
  self.row.right[#self.row.right + 1] = { text = content, hl = hl }
  return self
end

---Place a sign in the sign column for this row.
---@param content string
---@param hl string|nil
---@return GitUIRowBuilder
function RowBuilder:sign(content, hl)
  self.row.sign = { text = content, hl = hl }
  return self
end

---Highlight the entire line.
---@param hl string
---@return GitUIRowBuilder
function RowBuilder:highlight_line(hl)
  self.row.line_hl = hl
  return self
end

---Attach metadata to this row.
---@param item any
---@return GitUIRowBuilder
function RowBuilder:attach(item)
  self.row.item = item
  return self
end

---Rendered text of the row.
---@return string
function RowBuilder:text()
  local parts = {}
  for _, segment in ipairs(self.row.segments) do
    parts[#parts + 1] = segment.text
  end
  return table.concat(parts)
end

--- Canvas --------------------------------------------------------------------

---@param opts { width: integer|nil }|nil
---@return GitUICanvas
function M.new(opts)
  opts = opts or {}
  return setmetatable({ rows = {}, width = opts.width or 80 }, Canvas)
end

---Start a new row.
---@param item any|nil
---@return GitUIRowBuilder
function Canvas:row(item)
  ---@type GitUIRow
  local row = { segments = {}, item = item, indent = 0 }
  self.rows[#self.rows + 1] = row
  return setmetatable({ row = row }, RowBuilder)
end

---Add an empty row.
---@return GitUIRowBuilder
function Canvas:blank()
  return self:row(nil)
end

---Add a row of plain text.
---@param content string
---@param hl string|nil
---@param item any|nil
---@return GitUIRowBuilder
function Canvas:text(content, hl, item)
  return self:row(item):add(content, hl)
end

---A horizontal rule spanning the canvas width.
---@param char string|nil
---@return GitUIRowBuilder
function Canvas:rule(char)
  return self:row(nil):add(string.rep(char or "─", math.max(1, self.width)), "GitUISeparator")
end

---@return integer
function Canvas:count()
  return #self.rows
end

---Metadata attached to a line (1-based).
---@param lnum integer
---@return any|nil
function Canvas:item_at(lnum)
  local row = self.rows[lnum]
  return row and row.item or nil
end

---The click action at a screen position, if any.
---@param lnum integer
---@param col integer  0-based byte column
---@return string|nil action, any|nil item
function Canvas:action_at(lnum, col)
  local row = self.rows[lnum]
  if not row then
    return nil, nil
  end
  local offset = 0
  for _, segment in ipairs(row.segments) do
    local next_offset = offset + #segment.text
    if col >= offset and col < next_offset then
      return segment.action, row.item
    end
    offset = next_offset
  end
  return nil, row.item
end

---First line whose item satisfies `predicate`.
---@param predicate fun(item: any, lnum: integer): boolean
---@return integer|nil
function Canvas:find(predicate)
  for lnum, row in ipairs(self.rows) do
    if row.item and predicate(row.item, lnum) then
      return lnum
    end
  end
  return nil
end

---Every line whose item satisfies `predicate`.
---@param predicate fun(item: any, lnum: integer): boolean
---@return integer[]
function Canvas:find_all(predicate)
  local out = {}
  for lnum, row in ipairs(self.rows) do
    if row.item and predicate(row.item, lnum) then
      out[#out + 1] = lnum
    end
  end
  return out
end

---Rendered text of every row.
---@return string[]
function Canvas:lines()
  local lines = {}
  for index, row in ipairs(self.rows) do
    local parts = {}
    for _, segment in ipairs(row.segments) do
      parts[#parts + 1] = segment.text
    end
    lines[index] = table.concat(parts)
  end
  return lines
end

---Write the canvas into a buffer.
---
---The buffer is made modifiable only for the duration of the write, so a stray
---keystroke can never edit a panel.
---@param bufnr integer
---@param namespace integer
function Canvas:apply(bufnr, namespace)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end

  local lines = self:lines()
  local was_modifiable = vim.bo[bufnr].modifiable

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = was_modifiable
  vim.bo[bufnr].modified = false

  for index, row in ipairs(self.rows) do
    local lnum = index - 1
    local col = 0

    for _, segment in ipairs(row.segments) do
      local length = #segment.text
      if segment.hl and length > 0 then
        pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, lnum, col, {
          end_col = col + length,
          hl_group = segment.hl,
          -- Panels are rebuilt wholesale; marks must not drift or survive.
          right_gravity = false,
          invalidate = true,
        })
      end
      col = col + length
    end

    local mark = nil
    if row.line_hl then
      mark = mark or {}
      mark.line_hl_group = row.line_hl
    end
    if row.right then
      local chunks = {}
      for _, segment in ipairs(row.right) do
        chunks[#chunks + 1] = { segment.text, segment.hl }
      end
      mark = mark or {}
      mark.virt_text = chunks
      mark.virt_text_pos = "right_align"
    end
    if row.sign then
      mark = mark or {}
      mark.sign_text = row.sign.text
      mark.sign_hl_group = row.sign.hl
    end

    if mark then
      pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, lnum, 0, mark)
    end
  end
end

--- Shared row helpers ---------------------------------------------------------

---A section header: "CHANGES (4)" with a collapse chevron.
---@param canvas GitUICanvas
---@param opts { title: string, count: integer|nil, collapsed: boolean, item: any, actions: GitUISegment[]|nil }
---@return GitUIRowBuilder
function M.section_header(canvas, opts)
  local icons = require("gitui.utils.icons")
  local row = canvas:row(opts.item)
  row:add(opts.collapsed and icons.get("chevron_closed") or icons.get("chevron_open"), "GitUIChevron", "toggle")
  row:add(" ")
  row:add(opts.title, "GitUISectionHeader", "toggle")
  if opts.count then
    row:add((" (%d)"):format(opts.count), "GitUISectionCount", "toggle")
  end
  if opts.actions then
    for _, action in ipairs(opts.actions) do
      row:add(" ")
      row:add(action.text, action.hl, action.action)
    end
  end
  return row
end

---A one-line footer of "key description" pairs.
---@param canvas GitUICanvas
---@param pairs_list { key: string, label: string }[]
---@param width integer
function M.hint_footer(canvas, pairs_list, width)
  local row = canvas:row({ kind = "hint" })
  local used = 0
  for index, entry in ipairs(pairs_list) do
    local piece = #entry.key + 1 + #entry.label + (index > 1 and 2 or 0)
    if used + piece > width then
      break
    end
    if index > 1 then
      row:add("  ")
    end
    row:add(entry.key, "GitUIKey")
    row:add(" ")
    row:add(entry.label, "GitUIHint")
    used = used + piece
  end
end

return M
