---@brief Text input.
---
---Delegates to `vim.ui.input`, so whatever the user has already configured —
---snacks.input, dressing.nvim, noice, or the built-in command line — is what
---they get. gitui adds validation and a consistent cancellation contract on
---top rather than building a competing prompt.

local M = {}

---@class GitUIInputOpts
---@field prompt string
---@field default string|nil
---@field completion string|nil  a `:command-completion` name
---@field validate fun(value: string): boolean, string|nil
---@field allow_empty boolean|nil

---Ask for a line of text.
---
---`callback` receives `nil` when the user cancelled, which is always
---distinguishable from an empty string.
---@param opts GitUIInputOpts
---@param callback fun(value: string|nil)
function M.ask(opts, callback)
  local notify = require("gitui.ui.notify")

  vim.ui.input({
    prompt = opts.prompt:gsub("%s*$", "") .. ": ",
    default = opts.default,
    completion = opts.completion,
  }, function(value)
    if value == nil then
      return callback(nil)
    end

    value = vim.trim(value)
    if value == "" and not opts.allow_empty then
      return callback(nil)
    end

    if opts.validate then
      local ok, reason = opts.validate(value)
      if not ok then
        notify.error(reason or "Invalid input")
        -- Re-ask with what they typed so a typo is a correction, not a retype.
        return M.ask(vim.tbl_extend("force", opts, { default = value }), callback)
      end
    end

    callback(value)
  end)
end

---Ask for a branch name, validating it before the git command runs.
---@param opts { prompt: string|nil, default: string|nil }
---@param callback fun(name: string|nil)
function M.branch_name(opts, callback)
  local branches = require("gitui.git.branches")
  M.ask({
    prompt = opts.prompt or "New branch name",
    default = opts.default,
    validate = function(value)
      return branches.validate_name(value)
    end,
  }, callback)
end

---Open a scratch buffer for multi-line text and hand back the result.
---
---Used for anything longer than a line (a tag annotation, a stash message)
---where a single-line prompt would be the wrong shape.
---@param opts { title: string, filetype: string|nil, initial: string|nil, footer: string|nil }
---@param callback fun(text: string|nil)
function M.multiline(opts, callback)
  local window = require("gitui.ui.window")

  local bufnr = window.create_buffer({
    name = "input",
    filetype = opts.filetype or "gitui-input",
    modifiable = true,
  })
  vim.bo[bufnr].modifiable = true
  vim.bo[bufnr].buftype = "acwrite"

  local initial = vim.split(opts.initial or "", "\n", { plain = true })
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, initial)

  local winid = window.open_float(bufnr, {
    title = opts.title,
    footer = opts.footer or "<C-s> accept   <C-c> cancel",
    width = 0.6,
    height = 0.3,
  })
  vim.wo[winid].wrap = true

  local finished = false
  local function finish(value)
    if finished then
      return
    end
    finished = true
    window.close(winid)
    window.delete_buffer(bufnr)
    vim.schedule(function()
      callback(value)
    end)
  end

  local function accept()
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local text = table.concat(lines, "\n")
    finish(vim.trim(text) ~= "" and text or nil)
  end

  for _, lhs in ipairs({ "<C-s>", "<C-CR>" }) do
    vim.keymap.set({ "n", "i" }, lhs, accept, { buffer = bufnr, silent = true })
  end
  vim.keymap.set({ "n", "i" }, "<C-c>", function()
    finish(nil)
  end, { buffer = bufnr, silent = true })
  vim.keymap.set("n", "<Esc>", function()
    finish(nil)
  end, { buffer = bufnr, silent = true })

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = bufnr,
    callback = accept,
  })

  vim.cmd("startinsert")
end

return M
