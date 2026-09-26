---@brief Git blame.
---
---Two presentations sharing one data source:
---
---  * a full-file blame view, opened beside the file and scroll-bound to it,
---    so a line's author is always next to the line itself,
---  * current-line virtual text, which is the lightweight always-on variant.
---
---Both are strictly read-only views over `git blame --porcelain`.

local config = require("gitui.config")
local debounce = require("gitui.utils.debounce")
local git = require("gitui.git")
local notify = require("gitui.ui.notify")
local path_util = require("gitui.utils.path")
local render = require("gitui.ui.render")
local text_util = require("gitui.utils.text")
local window = require("gitui.ui.window")

local M = {}

---@class GitUIBlameSession
---@field repo GitRepository
---@field path string
---@field file_bufnr integer
---@field file_winid integer
---@field bufnr integer
---@field winid integer
---@field blame GitBlameResult|nil
---@field revision string|nil
---@field augroup integer

---@type GitUIBlameSession|nil
local session = nil

local namespace = vim.api.nvim_create_namespace("gitui_blame")
local virtual_namespace = vim.api.nvim_create_namespace("gitui_blame_virtual")

--- The blame column --------------------------------------------------------------

---@param current GitUIBlameSession
local function draw(current)
  if not vim.api.nvim_buf_is_valid(current.bufnr) then
    return
  end

  local canvas = render.new({ width = vim.api.nvim_win_get_width(current.winid) })
  local blame = current.blame

  if not blame then
    canvas:text(" loading blame…", "GitUIDim")
    canvas:apply(current.bufnr, namespace)
    return
  end

  local line_count = vim.api.nvim_buf_line_count(current.file_bufnr)
  local previous_oid = nil

  for lnum = 1, line_count do
    local entry = blame.lines[lnum]
    local row = canvas:row(entry and { kind = "blame", line = entry, lnum = lnum } or nil)

    if not entry then
      row:add(" ")
    elseif entry.commit.is_uncommitted then
      row:add(" " .. text_util.pad("", 7), "GitUIDim")
      row:add(" not committed yet", "GitUIDim")
    else
      local commit = entry.commit
      -- Repeating the same commit on every line of a block is noise; showing
      -- it once per run makes the block structure visible instead.
      local repeated = commit.oid == previous_oid
      if repeated then
        row:add(" " .. string.rep(" ", 7), "GitUIDim")
        row:add(" " .. string.rep(" ", 10), "GitUIDim")
        row:add(" " .. text_util.pad("", 14), "GitUIDim")
      else
        row:add(" ")
        row:add(commit.short, "GitUIBlameHash", "inspect")
        row:add(" ")
        row:add(os.date(config.options.blame.date_format, commit.author_time), "GitUIBlameDate", "inspect")
        row:add(" ")
        row:add(text_util.fit(commit.author, 14), "GitUIBlameAuthor", "inspect")
      end
      previous_oid = commit.oid
    end
  end

  canvas:apply(current.bufnr, namespace)
end

---Keep the blame column and the file scrolled together.
---@param current GitUIBlameSession
local function sync_scroll(current)
  if not (vim.api.nvim_win_is_valid(current.winid) and vim.api.nvim_win_is_valid(current.file_winid)) then
    return
  end
  local cursor = vim.api.nvim_win_get_cursor(current.file_winid)
  local count = vim.api.nvim_buf_line_count(current.bufnr)
  pcall(vim.api.nvim_win_set_cursor, current.winid, { math.min(cursor[1], count), 0 })

  -- Align the top line too, so the two panes never drift apart.
  local view = vim.api.nvim_win_call(current.file_winid, vim.fn.winsaveview)
  vim.api.nvim_win_call(current.winid, function()
    vim.fn.winrestview({ topline = view.topline, lnum = math.min(cursor[1], count), leftcol = 0 })
  end)
end

local function close_session()
  local current = session
  if not current then
    return
  end
  session = nil

  pcall(vim.api.nvim_del_augroup_by_id, current.augroup)
  window.close(current.winid)
  window.delete_buffer(current.bufnr)

  if vim.api.nvim_win_is_valid(current.file_winid) then
    vim.wo[current.file_winid].scrollbind = false
  end
end

---@param current GitUIBlameSession
---@return GitBlameLine|nil
local function line_under_cursor(current)
  if not current.blame then
    return nil
  end
  local winid = vim.api.nvim_get_current_win() == current.winid and current.winid or current.file_winid
  if not vim.api.nvim_win_is_valid(winid) then
    return nil
  end
  local lnum = vim.api.nvim_win_get_cursor(winid)[1]
  return current.blame.lines[lnum]
end

---@param current GitUIBlameSession
local function install_keymaps(current)
  local keys = config.options.keymaps.blame

  local function map(action, handler)
    local lhs = keys[action]
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set("n", key, handler, { buffer = current.bufnr, nowait = true, silent = true })
    end
  end

  map("inspect", function()
    local entry = line_under_cursor(current)
    if not entry or entry.commit.is_uncommitted then
      return notify.info("This line is not committed yet")
    end
    git.commits.show(current.repo, entry.commit.oid, function(commit, err)
      if err then
        return notify.error(err)
      end
      require("gitui.ui.log").show_commit(current.repo, commit)
    end)
  end)

  map("diff", function()
    local entry = line_under_cursor(current)
    if not entry or entry.commit.is_uncommitted then
      return
    end
    require("gitui.ui.diff_view").open(current.repo, {
      path = entry.commit.filename or current.path,
      spec = { kind = "commit", from = entry.commit.oid },
    })
  end)

  map("reblame", function()
    local entry = line_under_cursor(current)
    if not entry or entry.commit.is_uncommitted then
      return
    end
    -- Blaming the parent is how a user walks backwards through a line's
    -- history one rewrite at a time.
    M.reblame_before(entry.commit.oid)
  end)

  map("copy_hash", function()
    local entry = line_under_cursor(current)
    if entry and not entry.commit.is_uncommitted then
      vim.fn.setreg("+", entry.commit.oid)
      notify.info("Copied " .. entry.commit.oid)
    end
  end)

  map("open_remote", function()
    local entry = line_under_cursor(current)
    if entry and not entry.commit.is_uncommitted then
      require("gitui.operations").browse(current.repo, { kind = "commit", ref = entry.commit.oid })
    end
  end)

  for _, lhs in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", lhs, close_session, { buffer = current.bufnr, nowait = true, silent = true })
  end
end

---Load blame data into the session.
---@param current GitUIBlameSession
local function load(current)
  git.blame.file(current.repo, current.path, { revision = current.revision }, function(blame, err)
    if session ~= current then
      return
    end
    if err then
      close_session()
      return notify.error(err)
    end
    current.blame = blame
    draw(current)
    sync_scroll(current)
  end)
end

--- Public API ---------------------------------------------------------------------

---Open the blame view for a file.
---@param repo GitRepository
---@param path string  repository-relative
---@param opts { revision: string|nil }|nil
function M.open(repo, path, opts)
  opts = opts or {}

  if session then
    close_session()
  end

  -- The file must be on screen: blame is only meaningful next to its lines.
  local file_winid = window.open_file(path_util.join(repo.root, path), { cmd = "edit" })
  if not file_winid then
    return notify.error("Could not open " .. path)
  end
  local file_bufnr = vim.api.nvim_win_get_buf(file_winid)

  local bufnr = window.create_buffer({ name = "blame", filetype = "gitui-blame" })

  vim.api.nvim_set_current_win(file_winid)
  vim.cmd("noautocmd leftabove 46vsplit")
  local winid = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(winid, bufnr)
  window.configure_window(winid, { winfixwidth = true, number = false, cursorline = true })
  vim.wo[winid].scrollbind = false
  vim.wo[winid].wrap = false

  local augroup = vim.api.nvim_create_augroup("GitUIBlameSession", { clear = true })

  session = {
    repo = repo,
    path = path,
    file_bufnr = file_bufnr,
    file_winid = file_winid,
    bufnr = bufnr,
    winid = winid,
    blame = nil,
    revision = opts.revision,
    augroup = augroup,
  }

  install_keymaps(session)

  vim.api.nvim_create_autocmd({ "CursorMoved", "WinScrolled" }, {
    group = augroup,
    callback = function()
      if session and vim.api.nvim_get_current_win() == session.file_winid then
        sync_scroll(session)
      end
    end,
  })

  -- Closing either window ends the session; a blame column with no file is
  -- meaningless, and a leaked scroll-bound window is worse.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = augroup,
    callback = function(args)
      local closed = tonumber(args.match)
      if session and (closed == session.winid or closed == session.file_winid) then
        vim.schedule(close_session)
      end
    end,
  })

  -- Rewriting history invalidates every line's attribution.
  vim.api.nvim_create_autocmd("BufWritePost", {
    group = augroup,
    buffer = file_bufnr,
    callback = function()
      if session then
        load(session)
      end
    end,
  })

  draw(session)
  load(session)
  vim.api.nvim_set_current_win(file_winid)
end

---Re-blame the current file as it was before a commit.
---@param revision string
function M.reblame_before(revision)
  local current = session
  if not current then
    return
  end
  local repo, path = current.repo, current.path
  close_session()
  M.open(repo, path, { revision = revision .. "^" })
  notify.info("Blaming as of " .. revision:sub(1, 7) .. "^")
end

function M.close()
  close_session()
end

---@return boolean
function M.is_open()
  return session ~= nil
end

--- Current-line virtual text ---------------------------------------------------------

local virtual_augroup = nil
---@type table<integer, integer>  bufnr -> last blamed line
local virtual_state = {}

local function clear_virtual(bufnr)
  if vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, virtual_namespace, 0, -1)
  end
end

---@param bufnr integer
local function show_virtual(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or vim.bo[bufnr].buftype ~= "" then
    return
  end

  local file = path_util.buffer_path(bufnr)
  if not file then
    return
  end

  local repository = require("gitui.git.repository")
  local repo = repository.detect(path_util.dirname(file))
  if not repo then
    return
  end

  local relative = path_util.relative(file, repo.root)
  if not relative then
    return
  end

  local winid = vim.api.nvim_get_current_win()
  if vim.api.nvim_win_get_buf(winid) ~= bufnr then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(winid)[1]

  clear_virtual(bufnr)
  virtual_state[bufnr] = lnum

  git.blame.line(repo, relative, lnum, function(entry, err)
    -- The cursor may have moved on while git was running.
    if err or not entry or virtual_state[bufnr] ~= lnum then
      return
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    if vim.api.nvim_buf_line_count(bufnr) < lnum then
      return
    end

    local label = git.blame.format(entry, { relative = true, width = 80 })
    pcall(vim.api.nvim_buf_set_extmark, bufnr, virtual_namespace, lnum - 1, 0, {
      virt_text = { { "  " .. label, "GitUIBlameVirtual" } },
      virt_text_pos = "eol",
      hl_mode = "combine",
    })
  end)
end

---Enable the current-line blame virtual text.
function M.enable_virtual_text()
  if virtual_augroup then
    return
  end
  virtual_augroup = vim.api.nvim_create_augroup("GitUIBlameVirtual", { clear = true })

  local update = debounce.trailing(function()
    show_virtual(vim.api.nvim_get_current_buf())
  end, config.options.blame.virtual_text_delay)

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    group = virtual_augroup,
    callback = function(args)
      clear_virtual(args.buf)
      update()
    end,
  })

  vim.api.nvim_create_autocmd({ "BufLeave", "InsertEnter" }, {
    group = virtual_augroup,
    callback = function(args)
      clear_virtual(args.buf)
    end,
  })
end

function M.disable_virtual_text()
  if virtual_augroup then
    pcall(vim.api.nvim_del_augroup_by_id, virtual_augroup)
    virtual_augroup = nil
  end
  for bufnr in pairs(virtual_state) do
    clear_virtual(bufnr)
  end
  virtual_state = {}
end

function M.toggle_virtual_text()
  if virtual_augroup then
    M.disable_virtual_text()
    notify.info("Line blame off")
  else
    M.enable_virtual_text()
    notify.info("Line blame on")
  end
end

---Blame just the line under the cursor, shown in a floating window.
---
---Cheaper and less intrusive than the full view when the question is only
---"who wrote this one line?".
function M.line()
  local bufnr = vim.api.nvim_get_current_buf()
  local file = path_util.buffer_path(bufnr)
  if not file then
    return notify.warn("This buffer is not a file")
  end

  local repository = require("gitui.git.repository")
  local repo = repository.detect(path_util.dirname(file))
  if not repo then
    return notify.warn("Not inside a git repository")
  end

  local relative = path_util.relative(file, repo.root)
  if not relative then
    return
  end

  local lnum = vim.api.nvim_win_get_cursor(0)[1]
  git.blame.line(repo, relative, lnum, function(entry, err)
    if err then
      return notify.error(err)
    end
    if not entry then
      return notify.info("No blame information for this line")
    end

    local commit = entry.commit
    if commit.is_uncommitted then
      return notify.info("Not committed yet")
    end

    local lines = {
      commit.summary,
      "",
      ("Commit   %s"):format(commit.oid),
      ("Author   %s <%s>"):format(commit.author, commit.author_mail),
      ("Date     %s  (%s)"):format(
        os.date("%Y-%m-%d %H:%M", commit.author_time),
        text_util.relative_time(commit.author_time)
      ),
    }
    if commit.filename and commit.filename ~= relative then
      lines[#lines + 1] = ("File     %s"):format(commit.filename)
    end
    lines[#lines + 1] = ""
    lines[#lines + 1] = "<CR> open commit   q close"

    local float_bufnr = window.create_buffer({ name = "blame-line", filetype = "gitui-blame-line" })
    vim.bo[float_bufnr].modifiable = true
    vim.api.nvim_buf_set_lines(float_bufnr, 0, -1, false, lines)
    vim.bo[float_bufnr].modifiable = false

    local float_winid = window.open_float(float_bufnr, { title = "Blame", width = 1, height = #lines })
    window.fit_float(float_winid, lines, { min_width = 40 })
    vim.wo[float_winid].cursorline = false

    local function close()
      window.close(float_winid)
      window.delete_buffer(float_bufnr)
    end
    for _, lhs in ipairs({ "q", "<Esc>" }) do
      vim.keymap.set("n", lhs, close, { buffer = float_bufnr, nowait = true, silent = true })
    end
    vim.keymap.set("n", "<CR>", function()
      close()
      git.commits.show(repo, commit.oid, function(full, show_err)
        if show_err then
          return notify.error(show_err)
        end
        require("gitui.ui.log").show_commit(repo, full)
      end)
    end, { buffer = float_bufnr, nowait = true, silent = true })
  end)
end

return M
