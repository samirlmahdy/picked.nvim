---@brief Commit graph layout.
---
---The lane assignment is computed from the parent links picked already has,
---rather than parsing `git log --graph`, whose output is drawn for humans and
---interleaves graph characters with the message in a way that cannot be split
---back apart reliably.
---
---The algorithm is the standard one: every commit occupies a lane; a lane is
---"reserved" by the commit that expects to be drawn there next. Rendering cost
---is linear in commits and bounded by `max_lanes`, so a pathological history
---degrades the picture rather than the frame rate.

local icons = require("picked.utils.icons")

local M = {}

---@class GitGraphCell
---@field lane integer  lane the commit itself occupies
---@field prefix string  the graph column for this row
---@field width integer  display width of `prefix`
---@field lanes integer  number of lanes active on this row
---@field color integer  a stable small integer for highlight selection

local MAX_LANES = 12

---Lay out a list of commits.
---
---`commits` must be in display order (newest first), which is what
---`git log --date-order` produces.
---@param commits GitCommit[]
---@param opts { max_lanes: integer|nil }|nil
---@return GitGraphCell[] cells  parallel to `commits`
function M.layout(commits, opts)
  opts = opts or {}
  local max_lanes = opts.max_lanes or MAX_LANES

  local node = icons.get("graph_commit")
  local merge_node = icons.nerd and "◍" or "@"
  local vertical = icons.get("graph_line")

  ---@type (string|false)[]  lane -> oid the lane is waiting for
  local lanes = {}
  ---@type table<string, integer>  oid -> colour index, kept stable per branch
  local colors = {}
  local next_color = 0

  local cells = {}

  for index, commit in ipairs(commits) do
    -- Find the lane reserved for this commit, or take the first free one.
    local own_lane = nil
    for lane, expected in ipairs(lanes) do
      if expected == commit.oid then
        own_lane = lane
        break
      end
    end

    if not own_lane then
      for lane = 1, max_lanes do
        if not lanes[lane] then
          own_lane = lane
          break
        end
      end
      -- Every lane is busy: share the last one rather than growing without
      -- bound. The picture is approximate at that width anyway.
      own_lane = own_lane or math.min(#lanes + 1, max_lanes)
    end

    if not colors[commit.oid] then
      next_color = next_color + 1
      colors[commit.oid] = next_color
    end
    local color = colors[commit.oid]

    -- Draw the row before mutating the lane table, so the commit's own lane
    -- shows a node and every other active lane shows a vertical line.
    local active = math.max(#lanes, own_lane)
    local parts = {}
    for lane = 1, active do
      if lane == own_lane then
        parts[#parts + 1] = commit.is_merge and merge_node or node
      elseif lanes[lane] then
        parts[#parts + 1] = vertical
      else
        parts[#parts + 1] = " "
      end
      parts[#parts + 1] = " "
    end

    local prefix = table.concat(parts)

    cells[index] = {
      lane = own_lane,
      prefix = prefix,
      width = vim.fn.strdisplaywidth(prefix),
      lanes = active,
      color = color,
    }

    -- The first parent inherits this commit's lane; the others claim new ones
    -- unless they are already expected somewhere.
    lanes[own_lane] = commit.parents[1] or false
    if commit.parents[1] then
      colors[commit.parents[1]] = colors[commit.parents[1]] or color
    end

    for parent_index = 2, #commit.parents do
      local parent = commit.parents[parent_index]
      local already = false
      for _, expected in ipairs(lanes) do
        if expected == parent then
          already = true
          break
        end
      end
      if not already then
        local placed = false
        for lane = 1, max_lanes do
          if not lanes[lane] then
            lanes[lane] = parent
            next_color = next_color + 1
            colors[parent] = colors[parent] or next_color
            placed = true
            break
          end
        end
        if not placed and #lanes < max_lanes then
          lanes[#lanes + 1] = parent
        end
      end
    end

    -- Trim trailing empty lanes so the graph column narrows again once a
    -- branch has been fully consumed.
    while #lanes > 0 and not lanes[#lanes] do
      table.remove(lanes)
    end
  end

  -- Pad every prefix to the widest one so the subjects line up in a column.
  local widest = 0
  for _, cell in ipairs(cells) do
    widest = math.max(widest, cell.width)
  end
  for _, cell in ipairs(cells) do
    if cell.width < widest then
      cell.prefix = cell.prefix .. string.rep(" ", widest - cell.width)
      cell.width = widest
    end
  end

  return cells
end

---Width the graph column will occupy for a set of commits, so the caller can
---decide whether the terminal is wide enough to show it at all.
---@param cells GitGraphCell[]
---@return integer
function M.width(cells)
  local widest = 0
  for _, cell in ipairs(cells) do
    widest = math.max(widest, cell.width)
  end
  return widest
end

return M
