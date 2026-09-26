---@brief The commit message editor.
---
---This is a genuine, modifiable Neovim buffer with `filetype=gitcommit`. Every
---editing facility the user already has — insert mode, macros, abbreviations,
---snippets, completion, spell checking, their own `gitcommit` ftplugin —
---works, because nothing here reimplements text editing.
---
---git's own `#` comment block is deliberately *not* injected into the message.
---That keeps `--cleanup` at git's safe default, so a line that legitimately
---starts with `#` survives. The information those comments would carry (which
---files are staged, which branch) is shown in the window title and the
---adjacent status column instead.

local config = require("gitui.config")
local git = require("gitui.git")
local icons = require("gitui.utils.icons")
local notify = require("gitui.ui.notify")
local operations = require("gitui.operations")
local render = require("gitui.ui.render")
local store = require("gitui.state")
local text_util = require("gitui.utils.text")
local window = require("gitui.ui.window")

local M = {}

---@class GitUICommitSession
---@field repo GitRepository
---@field bufnr integer
---@field winid integer
---@field info_bufnr integer|nil
---@field info_winid integer|nil
---@field amend boolean
---@field push boolean
---@field paths string[]|nil
---@field closing boolean

---@type GitUICommitSession|nil
local session = nil

local namespace = vim.api.nvim_create_namespace("gitui_commit")

--- Validation -----------------------------------------------------------------

---@param lines string[]
---@return string[] problems
local function validate(lines)
  local problems = {}

  local subject = lines[1] or ""
  if vim.trim(table.concat(lines, "\n")) == "" then
    problems[#problems + 1] = "The message is empty."
    return problems
  end
  if vim.trim(subject) == "" then
    problems[#problems + 1] = "The first line is the subject and must not be empty."
  end

  local limit = config.options.commit.subject_length
  if limit > 0 and text_util.width(subject) > limit then
    problems[#problems + 1] = ("Subject is %d columns (over %d)."):format(text_util.width(subject), limit)
  end

  if lines[2] and vim.trim(lines[2]) ~= "" then
    problems[#problems + 1] = "Leave a blank line between the subject and the body."
  end

  local body_limit = config.options.commit.body_length
  if body_limit > 0 then
    for index = 3, #lines do
      if text_util.width(lines[index]) > body_limit then
        problems[#problems + 1] = ("Line %d is over %d columns."):format(index, body_limit)
        break
      end
    end
  end

  return problems
end

---Mark the part of the subject that exceeds the configured limit.
---
---A warning highlight beats refusing to commit: the limit is a convention, not
---a rule, and the user may have a good reason to exceed it.
---@param bufnr integer
local function decorate(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_buf_clear_namespace(bufnr, namespace, 0, -1)

  local limit = config.options.commit.subject_length
  if limit <= 0 then
    return
  end

  local subject = (vim.api.nvim_buf_get_lines(bufnr, 0, 1, false))[1] or ""
  if #subject > limit then
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, 0, limit, {
      end_col = #subject,
      hl_group = "GitUIWarning",
    })
    pcall(vim.api.nvim_buf_set_extmark, bufnr, namespace, 0, 0, {
      virt_text = { { ("  %d/%d"):format(text_util.width(subject), limit), "GitUIWarning" } },
      virt_text_pos = "eol",
    })
  end
end

--- The status column -----------------------------------------------------------

---Render the read-only pane showing what is about to be committed.
---@param current GitUICommitSession
local function render_info(current)
  if not current.info_bufnr or not vim.api.nvim_buf_is_valid(current.info_bufnr) then
    return
  end

  local state = store.get(current.repo.root)
  local canvas = render.new({
    width = vim.api.nvim_win_is_valid(current.info_winid or -1) and vim.api.nvim_win_get_width(current.info_winid)
      or 40,
  })

  local head = state and state.head
  canvas
    :row(nil)
    :add(icons.get("branch") .. " ", "GitUIBranch")
    :add(head and (head.branch or (head.detached and "detached HEAD" or "?")) or "?", "GitUIBranchCurrent")

  if current.amend then
    canvas:blank()
    canvas:text("AMENDING the previous commit", "GitUIWarning")
    canvas:text("History will be rewritten.", "GitUIDim")
  end

  local staged = state and state.status and state.status.staged or {}
  canvas:blank()
  canvas:text(("Staged (%d)"):format(#staged), "GitUISectionHeader")

  if #staged == 0 and not current.amend then
    canvas:text("  nothing staged", "GitUIWarning")
  end

  local highlights = require("gitui.ui.highlights")
  for _, entry in ipairs(staged) do
    local code = git.status.code_for(entry, "index")
    canvas
      :row(nil)
      :add("  ")
      :add(code, highlights.for_status(code))
      :add(" ")
      :add(text_util.truncate_left(entry.path, canvas.width - 6))
  end

  local unstaged = state and state.status and state.status.unstaged or {}
  if #unstaged > 0 then
    canvas:blank()
    canvas:text(("Not staged (%d)"):format(#unstaged), "GitUIDim")
    canvas:text("  these will not be committed", "GitUIDim")
  end

  canvas:blank()
  canvas:rule()
  canvas:blank()
  local keys = config.options.keymaps.commit
  local function first(value)
    return type(value) == "table" and value[1] or value
  end
  canvas:row(nil):add(first(keys.submit) or "<C-s>", "GitUIKey"):add("  commit", "GitUIHint")
  canvas:row(nil):add(first(keys.submit_push) or "<C-p>", "GitUIKey"):add("  commit and push", "GitUIHint")
  canvas:row(nil):add(first(keys.amend) or "<C-a>", "GitUIKey"):add("  toggle amend", "GitUIHint")
  canvas:row(nil):add(first(keys.cancel) or "<C-c>", "GitUIKey"):add("  cancel", "GitUIHint")

  canvas:apply(current.info_bufnr, vim.api.nvim_create_namespace("gitui_commit_info"))
end

--- Session -----------------------------------------------------------------------

local function close_session(keep_draft)
  local current = session
  if not current or current.closing then
    return
  end
  current.closing = true
  session = nil

  -- Preserve an unfinished message so reopening does not lose typing.
  if keep_draft and vim.api.nvim_buf_is_valid(current.bufnr) then
    local lines = vim.api.nvim_buf_get_lines(current.bufnr, 0, -1, false)
    local text = vim.trim(table.concat(lines, "\n"))
    M.draft = text ~= "" and text or nil
  else
    M.draft = nil
  end

  window.close(current.info_winid)
  window.delete_buffer(current.info_bufnr)
  window.close(current.winid)
  window.delete_buffer(current.bufnr)
end

---Unsaved message text from a cancelled session, restored on reopen.
---@type string|nil
M.draft = nil

---@param current GitUICommitSession
---@param opts { push: boolean|nil }
local function submit(current, opts)
  local lines = vim.api.nvim_buf_get_lines(current.bufnr, 0, -1, false)
  local message = table.concat(lines, "\n")

  local problems = validate(lines)
  -- Only an empty message is fatal; the rest are conventions.
  if vim.trim(message) == "" then
    return notify.error({
      kind = "empty_message",
      title = "Nothing to commit",
      reason = "The commit message is empty.",
      hint = "Write a subject line first.",
      raw = "",
    })
  end

  local state = store.get(current.repo.root)
  local staged_count = state and state.status and #state.status.staged or 0
  if staged_count == 0 and not current.amend and not (current.paths and #current.paths > 0) then
    return notify.error({
      kind = "nothing_staged",
      title = "Nothing staged",
      reason = "There are no staged changes to commit.",
      hint = "Stage some changes first, or amend the previous commit.",
      raw = "",
    })
  end

  if #problems > 0 then
    -- Surface conventions without blocking; the user decides.
    notify.warn(table.concat(problems, "\n"))
  end

  local repo = current.repo
  local amend = current.amend
  local paths = current.paths
  local should_push = opts.push

  close_session(false)

  operations.commit(repo, {
    message = message,
    amend = amend,
    paths = paths,
    sign = config.options.commit.sign,
  }, function(ok)
    if not ok then
      -- Give the message back so nothing is lost when a hook rejects it.
      M.draft = message
      return
    end
    if should_push then
      operations.push(repo)
    end
  end)
end

---@param current GitUICommitSession
local function install_keymaps(current)
  local keys = config.options.keymaps.commit

  local function map(action, handler)
    local lhs = keys[action]
    if not lhs then
      return
    end
    for _, key in ipairs(type(lhs) == "table" and lhs or { lhs }) do
      vim.keymap.set({ "n", "i" }, key, handler, {
        buffer = current.bufnr,
        silent = true,
        desc = "gitui: " .. action,
      })
    end
  end

  map("submit", function()
    vim.cmd("stopinsert")
    submit(current, {})
  end)

  map("submit_push", function()
    vim.cmd("stopinsert")
    submit(current, { push = true })
  end)

  map("amend", function()
    vim.cmd("stopinsert")
    M.toggle_amend()
  end)

  map("cancel", function()
    vim.cmd("stopinsert")
    close_session(true)
  end)

  vim.keymap.set("n", "<Esc>", function()
    close_session(true)
  end, { buffer = current.bufnr, silent = true, desc = "gitui: cancel commit" })

  -- `:w` is the muscle memory for "I am done with this buffer".
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = current.bufnr,
    callback = function()
      submit(current, {})
    end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = current.bufnr,
    callback = function()
      decorate(current.bufnr)
    end,
  })

  -- Closing the message window tears down the whole session, including the
  -- status pane, so no orphan window is left behind.
  vim.api.nvim_create_autocmd("WinClosed", {
    callback = function(args)
      if session and tonumber(args.match) == session.winid then
        close_session(true)
      end
    end,
  })
end

--- Public API --------------------------------------------------------------------

---@class GitUICommitOpenOpts
---@field amend boolean|nil
---@field push boolean|nil
---@field paths string[]|nil  commit only these paths
---@field message string|nil  prefill

---Open the commit editor.
---@param repo GitRepository
---@param opts GitUICommitOpenOpts|nil
function M.open(repo, opts)
  opts = opts or {}

  if session then
    -- Already open: focus it rather than stacking two editors.
    if vim.api.nvim_win_is_valid(session.winid) then
      vim.api.nvim_set_current_win(session.winid)
      return
    end
    close_session(true)
  end

  local bufnr = window.create_buffer({
    name = "commit",
    filetype = "gitcommit",
    modifiable = true,
  })
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].undolevels = vim.o.undolevels

  local geometry = window.centered_geometry({ width = 0.7, height = 0.5 })
  local info_width = math.min(38, math.floor(geometry.width * 0.4))
  local message_width = geometry.width - info_width - 2

  -- `:w` is advertised alongside the key because many terminals swallow
  -- <C-s> for XON/XOFF flow control, and <C-CR> is not deliverable at all in
  -- some of them. Writing the buffer always works.
  local submit_key = type(config.options.keymaps.commit.submit) == "table" and config.options.keymaps.commit.submit[1]
    or config.options.keymaps.commit.submit

  local winid = window.open_float(bufnr, {
    title = opts.amend and "AMEND COMMIT" or "COMMIT",
    footer = ("%s or :w commit   %s cancel"):format(submit_key, config.options.keymaps.commit.cancel),
    width = message_width,
    height = geometry.height,
    row = geometry.row,
    col = geometry.col,
  })
  vim.wo[winid].wrap = true
  vim.wo[winid].linebreak = true
  vim.wo[winid].cursorline = false
  vim.wo[winid].spell = true
  -- A ruler at the subject limit is a gentler reminder than a warning.
  if config.options.commit.subject_length > 0 then
    vim.wo[winid].colorcolumn = tostring(config.options.commit.subject_length)
  end

  local info_bufnr = window.create_buffer({ name = "commit-info", filetype = "gitui-commit-info" })
  local info_winid = window.open_float(info_bufnr, {
    title = "STAGED",
    width = info_width,
    height = geometry.height,
    row = geometry.row,
    col = geometry.col + message_width + 2,
    enter = false,
    focusable = false,
  })
  vim.wo[info_winid].cursorline = false

  session = {
    repo = repo,
    bufnr = bufnr,
    winid = winid,
    info_bufnr = info_bufnr,
    info_winid = info_winid,
    amend = opts.amend or false,
    push = opts.push or false,
    paths = opts.paths,
    closing = false,
  }

  install_keymaps(session)

  local function fill(message)
    if not session or not vim.api.nvim_buf_is_valid(session.bufnr) then
      return
    end
    local lines = vim.split(message or "", "\n", { plain = true })
    if #lines == 0 then
      lines = { "" }
    end
    vim.api.nvim_buf_set_lines(session.bufnr, 0, -1, false, lines)
    vim.bo[session.bufnr].modified = false
    decorate(session.bufnr)
    render_info(session)

    if vim.api.nvim_win_is_valid(session.winid) then
      vim.api.nvim_set_current_win(session.winid)
      -- Put the cursor at the end of the subject so typing continues it.
      pcall(vim.api.nvim_win_set_cursor, session.winid, { 1, #(lines[1] or "") })
      if vim.trim(table.concat(lines, "")) == "" then
        vim.cmd("startinsert!")
      end
    end
  end

  -- Prefill, in order of specificity: an explicit message, the draft from a
  -- cancelled session, the commit being amended, or git's prepared message
  -- (which is what carries a merge's generated text).
  if opts.message then
    fill(opts.message)
  elseif M.draft then
    local draft = M.draft
    M.draft = nil
    fill(draft)
  elseif opts.amend then
    git.commits.message(repo, "HEAD", function(message, err)
      fill(err and "" or message)
    end)
  else
    git.commits.prepared_message(repo, fill)
  end

  -- Keep the staged list live while the user is typing.
  local events = require("gitui.utils.events")
  local unsubscribe = events.on(events.names.STATUS_CHANGED, function()
    if session then
      vim.schedule(function()
        if session then
          render_info(session)
        end
      end)
    end
  end)
  vim.api.nvim_create_autocmd("BufWipeout", {
    buffer = bufnr,
    once = true,
    callback = unsubscribe,
  })
end

---Switch the open session between committing and amending, reloading the
---message to match.
function M.toggle_amend()
  if not session then
    return
  end
  session.amend = not session.amend

  local current = session
  if current.amend then
    local lines = vim.api.nvim_buf_get_lines(current.bufnr, 0, -1, false)
    if vim.trim(table.concat(lines, "\n")) == "" then
      git.commits.message(current.repo, "HEAD", function(message, err)
        if not err and session == current and vim.api.nvim_buf_is_valid(current.bufnr) then
          vim.api.nvim_buf_set_lines(current.bufnr, 0, -1, false, vim.split(message or "", "\n", { plain = true }))
        end
      end)
    end
  end

  if vim.api.nvim_win_is_valid(current.winid) then
    pcall(vim.api.nvim_win_set_config, current.winid, {
      title = current.amend and " AMEND COMMIT " or " COMMIT ",
    })
  end
  render_info(current)
  notify.info(current.amend and "Amending the previous commit" or "Creating a new commit")
end

---@return boolean
function M.is_open()
  return session ~= nil
end

function M.close()
  close_session(true)
end

---Commit immediately with a message supplied programmatically, skipping the
---editor. Used by `:GitUICommit -m ...` and the command palette.
---@param repo GitRepository
---@param message string
---@param opts GitUICommitOpenOpts|nil
function M.quick(repo, message, opts)
  opts = opts or {}
  operations.commit(repo, {
    message = message,
    amend = opts.amend,
    paths = opts.paths,
    sign = config.options.commit.sign,
  }, function(ok)
    if ok and opts.push then
      operations.push(repo)
    end
  end)
end

return M
