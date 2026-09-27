---Keeps 'winwidth' and 'winheight' from overruling picked's fixed-size windows.
---
---Both options are a promise that the *current* window gets at least that much
---room, and Neovim keeps the promise by taking the space out of its neighbours.
---That is fine for ordinary editing and ruinous for a sidebar or a two-pane
---diff: with the common `winwidth=80`, focusing the source control panel
---stretched it from 40 columns to 80, and focusing one side of a side-by-side
---diff collapsed the other side to a single column. 'winfixwidth' does not
---help — it governs how space is *redistributed*, not this minimum.
---
---So a window that must hold a size registers a claim here. The option is
---lowered to the smallest claim, and restored the moment the last claim is
---dropped. Lowering a minimum never forces a window to any particular size, so
---the user's other windows are unaffected beyond no longer being auto-widened
---while a picked panel is on screen — and the setting itself is handed back
---intact.
local M = {}

---@type table<string, table<string, integer>>  option -> key -> columns/rows
local claims = { winwidth = {}, winheight = {} }

---@type table<string, integer|nil>  the user's value, before any claim
local saved = {}

---@type table<string, integer|nil>  the value this module last wrote
local written = {}

---@param option "winwidth"|"winheight"
local function apply(option)
  -- Anything we did not write ourselves is the user changing the option while
  -- a claim is held. Take it as the new baseline, or closing the panel would
  -- restore a value they had already moved on from.
  if written[option] and vim.o[option] ~= written[option] then
    saved[option] = vim.o[option]
  end

  local limit = nil
  for _, value in pairs(claims[option]) do
    limit = limit and math.min(limit, value) or value
  end

  if not limit then
    if saved[option] then
      vim.o[option] = saved[option]
      saved[option] = nil
    end
    written[option] = nil
    return
  end

  saved[option] = saved[option] or vim.o[option]
  -- Never raise the option: a claim is a ceiling, not a request.
  written[option] = math.max(1, math.min(saved[option], limit))
  vim.o[option] = written[option]
end

---Hold `option` at or below `size` until this key is released.
---@param key string  identifies the claimant, so re-claiming replaces
---@param option "winwidth"|"winheight"
---@param size integer
function M.claim(key, option, size)
  if not claims[option] then
    return
  end
  claims[option][key] = math.max(1, size)
  apply(option)
end

---Drop a claim. Unknown keys are ignored, so this is safe to call on every
---close path without tracking whether a claim was ever made.
---@param key string
---@param option "winwidth"|"winheight"|nil  nil releases the key everywhere
function M.release(key, option)
  for name, held in pairs(claims) do
    if (option == nil or option == name) and held[key] ~= nil then
      held[key] = nil
      apply(name)
    end
  end
end

---Drop every claim and restore both options.
function M.reset()
  for option in pairs(claims) do
    claims[option] = {}
    apply(option)
  end
end

---The value the user configured, whatever picked has clamped it to.
---@param option "winwidth"|"winheight"
---@return integer
function M.user_value(option)
  return saved[option] or vim.o[option]
end

---@return table<string, table<string, integer>>
function M.inspect()
  return vim.deepcopy(claims)
end

return M
