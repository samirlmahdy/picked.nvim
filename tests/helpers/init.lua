---@brief Shared test utilities.

local M = {}

M.repo = require("tests.helpers.repo")

---Drive an asynchronous API to completion from a synchronous test body.
---
---plenary's busted implementation is synchronous, so the event loop has to be
---pumped explicitly. Returns everything the callback was invoked with.
---@param fn fun(done: fun(...))
---@param timeout integer|nil milliseconds, default 20s
---@return ...
function M.await(fn, timeout)
  -- LuaJIT is Lua 5.1: no `table.pack`/`table.unpack`.
  local unpack_fn = table.unpack or unpack
  local captured = nil
  fn(function(...)
    captured = { n = select("#", ...), ... }
  end)
  local ok = vim.wait(timeout or 20000, function()
    return captured ~= nil
  end, 5)
  assert(ok and captured, "async call timed out")
  return unpack_fn(captured, 1, captured.n)
end

---Await and assert the operation succeeded, returning its first value.
---@generic T
---@param fn fun(done: fun(value: T, err: GitError|nil))
---@return T
function M.ok(fn)
  local value, err = M.await(fn)
  if err then
    error(("expected success, got %s: %s"):format(err.title or "error", err.reason or err.raw or ""), 2)
  end
  assert(value ~= nil, "expected a value")
  return value
end

---Await and assert the operation failed, returning the error.
---@param fn fun(done: fun(value: any, err: GitError|nil))
---@return GitError
function M.err(fn)
  local value, error_value = M.await(fn)
  assert(error_value ~= nil, "expected an error, got " .. vim.inspect(value))
  return error_value
end

---Block until `predicate` holds, pumping the event loop.
---@param predicate fun(): boolean
---@param message string|nil
---@param timeout integer|nil
function M.wait_for(predicate, message, timeout)
  local ok = vim.wait(timeout or 10000, predicate, 10)
  assert(ok, message or "condition never became true")
end

---Answer `vim.ui.input` automatically.
---
---The default implementation blocks on `vim.fn.input`, which would hang a
---headless run. Returns a function that restores the previous implementation.
---@param answer string|nil|fun(opts: table): string|nil
---@return fun() restore
function M.stub_input(answer)
  local original = vim.ui.input
  vim.ui.input = function(opts, callback)
    local value = type(answer) == "function" and answer(opts) or answer
    vim.schedule(function()
      callback(value)
    end)
  end
  return function()
    vim.ui.input = original
  end
end

---Answer `vim.ui.select` automatically with the item at `index`.
---@param index integer|nil  nil cancels
---@return fun() restore
function M.stub_select(index)
  local original = vim.ui.select
  vim.ui.select = function(items, _, callback)
    vim.schedule(function()
      if index then
        callback(items[index], index)
      else
        callback(nil, nil)
      end
    end)
  end
  return function()
    vim.ui.select = original
  end
end

---Sort a list of strings in place and return it, for stable comparisons.
---@param list string[]
---@return string[]
function M.sorted(list)
  table.sort(list)
  return list
end

---Collect `field` from every element of `list`.
---@param list table[]
---@param field string
---@return any[]
function M.pluck(list, field)
  local out = {}
  for _, item in ipairs(list) do
    out[#out + 1] = item[field]
  end
  return out
end

return M
