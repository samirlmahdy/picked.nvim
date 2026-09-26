---@brief Dismissing transient floating windows.
---
---picked shows several things in the editor area — a diff, a file, a blame
---column — and several things in floats: history, branches, stashes, commit
---details, help, menus.
---
---A float sits *above* the editor area, so opening a diff from the history
---list puts the diff underneath the list that launched it: the user asks to
---see something and nothing appears to happen. Rather than making every
---action remember to tidy up after itself, anything about to occupy the
---editor area calls `close_all()` here first.
---
---Panels with a float layout are discovered through the panel registry.
---One-off floats (commit details, help, the output buffer, hunk previews)
---register a closer while they are on screen.

local M = {}

---@type table<integer, fun()>
local closers = {}
local next_id = 0

-- Guards against a closer that itself triggers a dismissal, which would
-- otherwise recurse through the registry.
local closing = false

---Register a transient float so it is dismissed when the editor area is used.
---@param close fun()
---@return fun() unregister
function M.register(close)
  next_id = next_id + 1
  local id = next_id
  closers[id] = close
  return function()
    closers[id] = nil
  end
end

---Close every registered float, and every panel whose layout is a float.
---
---@param opts { except: PickedPanel|nil }|nil
function M.close_all(opts)
  if closing then
    return
  end
  closing = true

  local pending = {}
  for id, close in pairs(closers) do
    pending[#pending + 1] = close
    closers[id] = nil
  end
  for _, close in ipairs(pending) do
    pcall(close)
  end

  local except = opts and opts.except
  local ok, panel_lib = pcall(require, "picked.ui.panel")
  if ok then
    for _, panel in ipairs(panel_lib.all()) do
      if panel ~= except and panel.spec.layout == "float" and panel:is_open() then
        pcall(function()
          panel:close()
        end)
      end
    end
  end

  closing = false
end

---Is any registered float currently on screen?
---@return boolean
function M.any()
  if next(closers) ~= nil then
    return true
  end
  local ok, panel_lib = pcall(require, "picked.ui.panel")
  if not ok then
    return false
  end
  for _, panel in ipairs(panel_lib.all()) do
    if panel.spec.layout == "float" and panel:is_open() then
      return true
    end
  end
  return false
end

return M
