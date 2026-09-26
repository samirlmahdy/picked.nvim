---@brief String, width, time and fuzzy-matching helpers.

local M = {}

---Display width of a string, accounting for multi-cell and combining chars.
---@param s string
---@return integer
function M.width(s)
  return vim.fn.strdisplaywidth(s)
end

---Truncate to `width` display cells, appending an ellipsis when it does not fit.
---@param s string
---@param width integer
---@param ellipsis string|nil defaults to "…"
---@return string
function M.truncate(s, width, ellipsis)
  if width <= 0 then
    return ""
  end
  if M.width(s) <= width then
    return s
  end
  ellipsis = ellipsis or "…"
  local budget = width - M.width(ellipsis)
  if budget <= 0 then
    return ellipsis:sub(1, width)
  end
  -- strcharpart operates on characters; walk down until the display width fits.
  local chars = vim.fn.strchars(s)
  while chars > 0 do
    local candidate = vim.fn.strcharpart(s, 0, chars)
    if M.width(candidate) <= budget then
      return candidate .. ellipsis
    end
    chars = chars - 1
  end
  return ellipsis
end

---Truncate from the left, keeping the tail (useful for paths).
---@param s string
---@param width integer
---@return string
function M.truncate_left(s, width)
  if width <= 0 then
    return ""
  end
  if M.width(s) <= width then
    return s
  end
  local total = vim.fn.strchars(s)
  for start = 1, total do
    local candidate = "…" .. vim.fn.strcharpart(s, start, total - start)
    if M.width(candidate) <= width then
      return candidate
    end
  end
  return "…"
end

---Right-pad to `width` display cells.
---@param s string
---@param width integer
---@return string
function M.pad(s, width)
  local delta = width - M.width(s)
  if delta <= 0 then
    return s
  end
  return s .. string.rep(" ", delta)
end

---Left-pad to `width` display cells.
---@param s string
---@param width integer
---@return string
function M.lpad(s, width)
  local delta = width - M.width(s)
  if delta <= 0 then
    return s
  end
  return string.rep(" ", delta) .. s
end

---Fit exactly `width` cells: pad when short, truncate when long.
---@param s string
---@param width integer
---@return string
function M.fit(s, width)
  return M.pad(M.truncate(s, width), width)
end

---Split a blob into lines without dropping a trailing empty line distinction.
---@param s string
---@return string[]
function M.lines(s)
  if s == "" then
    return {}
  end
  local out = vim.split(s, "\n", { plain = true })
  -- git output almost always ends with a newline; that trailing "" is an
  -- artefact of the separator, not a real line.
  if out[#out] == "" then
    table.remove(out)
  end
  return out
end

---Split a NUL-separated record stream.
---
---git's `-z` modes terminate every field with NUL, so a trailing empty field is
---an artefact rather than data. A final field without its terminator (which a
---few porcelain modes emit) is still returned.
---@param s string
---@return string[]
function M.nul_split(s)
  local out = {}
  local start = 1
  while true do
    local index = s:find("\0", start, true)
    if not index then
      if start <= #s then
        out[#out + 1] = s:sub(start)
      end
      break
    end
    out[#out + 1] = s:sub(start, index - 1)
    start = index + 1
  end
  return out
end

---Trim surrounding whitespace.
---@param s string
---@return string
function M.trim(s)
  return (s:gsub("^%s+", ""):gsub("%s+$", ""))
end

---Decode a path git wrote with `quote_c_style`.
---
---Needed wherever git has no `-z` mode (`git clean --dry-run`, for example):
---a name containing a quote, a backslash or a control character arrives
---wrapped in double quotes with C escapes.
---@param s string
---@return string
function M.unquote_c_style(s)
  if s:sub(1, 1) ~= '"' or s:sub(-1) ~= '"' then
    return s
  end
  local body = s:sub(2, -2)
  local named = { a = "\a", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", v = "\v" }
  local out = {}
  local index = 1
  while index <= #body do
    local char = body:sub(index, index)
    if char == "\\" then
      local next_char = body:sub(index + 1, index + 1)
      local octal = body:match("^%d%d?%d?", index + 1)
      if named[next_char] then
        out[#out + 1] = named[next_char]
        index = index + 2
      elseif octal then
        out[#out + 1] = string.char(tonumber(octal, 8) % 256)
        index = index + 1 + #octal
      else
        out[#out + 1] = next_char
        index = index + 2
      end
    else
      out[#out + 1] = char
      index = index + 1
    end
  end
  return table.concat(out)
end

local MINUTE = 60
local HOUR = 60 * MINUTE
local DAY = 24 * HOUR
local WEEK = 7 * DAY
local MONTH = 30 * DAY
local YEAR = 365 * DAY

---Format a unix timestamp the way git does: "3 days ago".
---@param timestamp integer
---@param now integer|nil
---@return string
function M.relative_time(timestamp, now)
  now = now or os.time()
  local delta = now - timestamp

  if delta < 0 then
    return "in the future"
  end
  if delta < MINUTE then
    return delta <= 1 and "just now" or ("%d seconds ago"):format(delta)
  end

  local function plural(count, unit)
    count = math.floor(count)
    return ("%d %s%s ago"):format(count, unit, count == 1 and "" or "s")
  end

  if delta < HOUR then
    return plural(delta / MINUTE, "minute")
  elseif delta < DAY then
    return plural(delta / HOUR, "hour")
  elseif delta < WEEK then
    return plural(delta / DAY, "day")
  elseif delta < MONTH then
    return plural(delta / WEEK, "week")
  elseif delta < YEAR then
    return plural(delta / MONTH, "month")
  end
  return plural(delta / YEAR, "year")
end

---Compact relative time for narrow columns: "3d", "2w", "5mo".
---@param timestamp integer
---@param now integer|nil
---@return string
function M.relative_time_short(timestamp, now)
  now = now or os.time()
  local delta = math.max(0, now - timestamp)
  if delta < MINUTE then
    return "now"
  elseif delta < HOUR then
    return ("%dm"):format(delta / MINUTE)
  elseif delta < DAY then
    return ("%dh"):format(delta / HOUR)
  elseif delta < WEEK then
    return ("%dd"):format(delta / DAY)
  elseif delta < MONTH then
    return ("%dw"):format(delta / WEEK)
  elseif delta < YEAR then
    return ("%dmo"):format(delta / MONTH)
  end
  return ("%dy"):format(delta / YEAR)
end

--- Fuzzy matching ---------------------------------------------------------
--
-- A compact subsequence matcher with the bonuses that make results feel right:
-- consecutive runs, word/path boundaries, camelCase transitions and prefix
-- matches all score higher. Good enough to drive the built-in pickers without
-- pulling in a dependency.

local SCORE_MATCH = 16
local BONUS_CONSECUTIVE = 12
local BONUS_BOUNDARY = 10
local BONUS_CAMEL = 8
local BONUS_START = 14
local PENALTY_SKIP = -1

local function is_boundary(prev)
  return prev == nil or prev == "/" or prev == "_" or prev == "-" or prev == "." or prev == " "
end

---Score `needle` against `haystack`.
---@param needle string
---@param haystack string
---@return integer|nil score, integer[]|nil byte positions (1-indexed)
function M.fuzzy_match(needle, haystack)
  if needle == "" then
    return 0, {}
  end
  if #needle > #haystack then
    return nil, nil
  end

  local lower_needle = needle:lower()
  local lower_hay = haystack:lower()

  local score = 0
  local positions = {}
  local hay_index = 1
  local last_match = nil

  for i = 1, #lower_needle do
    local char = lower_needle:sub(i, i)
    local found = lower_hay:find(char, hay_index, true)
    if not found then
      return nil, nil
    end

    -- Prefer a later occurrence when it sits on a word boundary: "ui" should
    -- match "src/ui" on the directory rather than inside "build".
    local probe = found
    while probe do
      local prev = probe > 1 and haystack:sub(probe - 1, probe - 1) or nil
      if is_boundary(prev) then
        found = probe
        break
      end
      probe = lower_hay:find(char, probe + 1, true)
      if probe and last_match and probe > last_match + 8 then
        break
      end
    end

    local prev_char = found > 1 and haystack:sub(found - 1, found - 1) or nil
    score = score + SCORE_MATCH

    if last_match and found == last_match + 1 then
      score = score + BONUS_CONSECUTIVE
    else
      score = score + PENALTY_SKIP * math.min(found - hay_index, 20)
    end

    if found == 1 then
      score = score + BONUS_START
    elseif is_boundary(prev_char) then
      score = score + BONUS_BOUNDARY
    elseif prev_char and prev_char:match("%l") and haystack:sub(found, found):match("%u") then
      score = score + BONUS_CAMEL
    end

    positions[#positions + 1] = found
    last_match = found
    hay_index = found + 1
  end

  -- Shorter haystacks win ties.
  score = score - math.floor(#haystack / 8)
  return score, positions
end

---Filter and rank `items` by `query`.
---@generic T
---@param items T[]
---@param query string
---@param accessor fun(item: T): string
---@return { item: T, score: integer, positions: integer[] }[]
function M.fuzzy_filter(items, query, accessor)
  local results = {}
  if query == "" then
    for _, item in ipairs(items) do
      results[#results + 1] = { item = item, score = 0, positions = {} }
    end
    return results
  end

  for _, item in ipairs(items) do
    local score, positions = M.fuzzy_match(query, accessor(item))
    if score then
      results[#results + 1] = { item = item, score = score, positions = positions }
    end
  end

  table.sort(results, function(a, b)
    if a.score ~= b.score then
      return a.score > b.score
    end
    return accessor(a.item) < accessor(b.item)
  end)

  return results
end

return M
