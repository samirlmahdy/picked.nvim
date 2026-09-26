---@brief Mouse support for panels.
---
---Mouse handling is strictly additive: every action reachable with the mouse
---has a keyboard mapping, and nothing here changes modes or moves windows
---behind the user's back.
---
---The interaction model is deliberately conservative, because a sidebar that
---opens files on every stray click is worse than one with no mouse support:
---
---  * single click on a control (a chevron, a `[+]` button) runs that control,
---  * single click anywhere else only moves the cursor,
---  * double click runs the row's primary action,
---  * right click opens the contextual menu.

local config = require("picked.config")

local M = {}

---Resolve a mouse event to a panel row.
---@param panel PickedPanel
---@return { lnum: integer, col: integer, item: any|nil, action: string|nil }|nil
local function locate(panel)
  if not panel.canvas or not panel:is_open() then
    return nil
  end

  local position = vim.fn.getmousepos()
  if position.winid ~= panel.winid then
    return nil
  end
  if position.line < 1 then
    return nil
  end

  -- `column` is 1-based and counts virtual columns; the canvas indexes bytes
  -- from zero.
  local col = math.max(0, position.column - 1)
  local action, item = panel.canvas:action_at(position.line, col)

  return { lnum = position.line, col = col, item = item, action = action }
end

---@param panel PickedPanel
---@param name string
---@param item any
---@return boolean handled
local function invoke(panel, name, item)
  local handler = panel.spec.actions and panel.spec.actions[name]
  if not handler then
    return false
  end
  handler(panel, item)
  return true
end

---Install the mouse mappings for a panel.
---@param panel PickedPanel
function M.attach(panel)
  local mouse = config.options.mouse
  if not mouse.enabled or not panel.bufnr then
    return
  end

  local function map(lhs, handler)
    vim.keymap.set("n", lhs, handler, {
      buffer = panel.bufnr,
      nowait = true,
      silent = true,
      desc = "picked: mouse",
    })
  end

  if mouse.click then
    -- Bind the release rather than the press so Neovim has already moved the
    -- cursor and any drag-selection has finished.
    map("<LeftRelease>", function()
      local hit = locate(panel)
      if not hit then
        return
      end
      panel:set_cursor(hit.lnum, hit.col)
      if hit.action then
        invoke(panel, hit.action, hit.item)
      end
    end)
  end

  if mouse.double_click then
    map("<2-LeftMouse>", function()
      local hit = locate(panel)
      if not hit then
        return
      end
      panel:set_cursor(hit.lnum, hit.col)
      -- A control under the pointer wins; otherwise run the row's primary
      -- action, which each panel declares as `open`.
      if hit.action and invoke(panel, hit.action, hit.item) then
        return
      end
      invoke(panel, "open", hit.item)
    end)
  end

  if mouse.context_menu then
    local function open_menu()
      local hit = locate(panel)
      if not hit then
        return
      end
      panel:set_cursor(hit.lnum, hit.col)
      if not panel.spec.context_menu then
        return
      end
      local entries = panel.spec.context_menu(panel, hit.item)
      if entries and #entries > 0 then
        require("picked.ui.menu").open({
          entries = entries,
          anchor = { lnum = hit.lnum, col = hit.col, winid = panel.winid },
        })
      end
    end

    map("<RightMouse>", open_menu)
    -- Some terminals only deliver the release event.
    map("<RightRelease>", function() end)
  end

  -- Middle click pastes by default, which would try to modify a read-only
  -- panel and raise an error; make it a no-op instead.
  map("<MiddleMouse>", function() end)
  map("<MiddleRelease>", function() end)
end

---Ensure `mouse` is usable at all, without overriding a user who deliberately
---disabled it.
---@return boolean enabled
function M.available()
  return vim.o.mouse ~= ""
end

return M
