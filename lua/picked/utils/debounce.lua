---@brief Debounce / throttle primitives backed by libuv timers.

local M = {}

---Trailing-edge debounce: `fn` runs `ms` after the last call.
---@generic F: function
---@param fn F
---@param ms integer
---@return F wrapped, fun() cancel
function M.trailing(fn, ms)
  local timer = nil
  local pending_args = nil

  local function cancel()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
    pending_args = nil
  end

  local function wrapped(...)
    pending_args = { n = select("#", ...), ... }
    if timer then
      timer:stop()
    else
      timer = vim.uv.new_timer()
    end
    if not timer then
      -- Timer allocation failed (resource exhaustion); run immediately rather
      -- than silently dropping the call.
      return fn(...)
    end
    timer:start(
      ms,
      0,
      vim.schedule_wrap(function()
        local args = pending_args
        cancel()
        if args then
          fn(unpack(args, 1, args.n))
        end
      end)
    )
  end

  return wrapped, cancel
end

---Leading-edge throttle: `fn` runs immediately, then at most once per `ms`.
---A call made during the cooldown is remembered and replayed at its end.
---@generic F: function
---@param fn F
---@param ms integer
---@return F wrapped, fun() cancel
function M.throttle(fn, ms)
  local timer = nil
  local queued = nil

  local function cancel()
    if timer then
      timer:stop()
      if not timer:is_closing() then
        timer:close()
      end
      timer = nil
    end
    queued = nil
  end

  local function wrapped(...)
    if timer then
      queued = { n = select("#", ...), ... }
      return
    end

    fn(...)

    timer = vim.uv.new_timer()
    if not timer then
      return
    end
    timer:start(
      ms,
      0,
      vim.schedule_wrap(function()
        local args = queued
        cancel()
        if args then
          wrapped(unpack(args, 1, args.n))
        end
      end)
    )
  end

  return wrapped, cancel
end

return M
