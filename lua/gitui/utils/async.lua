---@brief Minimal coroutine-based async helpers.
---
---Callback-style APIs compose badly once an operation needs three or four git
---invocations in sequence. `async.run` lets those flows read linearly while
---still never blocking the UI thread.
---
---    async.run(function()
---      local result = async.await(git.status_async(repo))
---      ...
---    end)
---
---A "thunk" is a function accepting a single resume callback. `async.wrap`
---turns a conventional `fn(a, b, callback)` into `fn(a, b) -> thunk`.

local logger = require("gitui.utils.logger")

local M = {}

---@alias GitUIThunk fun(resume: fun(...))

---Run `fn` as a coroutine in which `M.await` may be used.
---@param fn fun()
---@param on_done fun(...)|nil called with the coroutine's return values
function M.run(fn, on_done)
  local co = coroutine.create(fn)

  local step
  step = function(...)
    local results = { coroutine.resume(co, ...) }
    local ok = results[1]

    if not ok then
      local err = results[2]
      logger.error("async task failed:", err)
      logger.debug(debug.traceback(co))
      -- Surface programming errors; git failures are values, not exceptions.
      vim.schedule(function()
        vim.notify("gitui: internal error: " .. tostring(err), vim.log.levels.ERROR)
      end)
      return
    end

    if coroutine.status(co) == "dead" then
      if on_done then
        on_done(unpack(results, 2))
      end
      return
    end

    local thunk = results[2]
    if type(thunk) ~= "function" then
      logger.error("async.await expects a thunk, got", type(thunk))
      return
    end

    local resumed = false
    thunk(function(...)
      -- Guard against callbacks that fire more than once; resuming a dead
      -- coroutine would otherwise raise far from the actual bug.
      if resumed then
        logger.warn("async thunk resumed twice; ignoring")
        return
      end
      resumed = true
      step(...)
    end)
  end

  step()
end

---Suspend until `thunk` calls its resume callback.
---@param thunk GitUIThunk
---@return ... the values passed to the resume callback
function M.await(thunk)
  return coroutine.yield(thunk)
end

---Convert `fn(..., callback)` into `fn(...) -> thunk`.
---@generic F: function
---@param fn F
---@param argc integer number of leading (non-callback) arguments
---@return F
function M.wrap(fn, argc)
  return function(...)
    local args = { ... }
    local n = select("#", ...)
    return function(resume)
      args[argc + 1] = resume
      fn(unpack(args, 1, math.max(n, argc) + 1))
    end
  end
end

---Await several thunks concurrently; resolves once all have completed.
---@param thunks GitUIThunk[]
---@return GitUIThunk
function M.join(thunks)
  return function(resume)
    local total = #thunks
    if total == 0 then
      return resume({})
    end
    local results = {}
    local remaining = total
    for index, thunk in ipairs(thunks) do
      thunk(function(...)
        results[index] = { ... }
        remaining = remaining - 1
        if remaining == 0 then
          resume(results)
        end
      end)
    end
  end
end

---A thunk that resolves on the main loop, making `vim.api` calls safe.
---@return GitUIThunk
function M.schedule()
  return function(resume)
    vim.schedule(resume)
  end
end

---A thunk that resolves after `ms` milliseconds.
---@param ms integer
---@return GitUIThunk
function M.sleep(ms)
  return function(resume)
    vim.defer_fn(resume, ms)
  end
end

return M
