---@brief The contextual help window.
---
---Help is generated from the *configured* mappings, never from a hard-coded
---list, so a user who rebinds `s` sees their own key. That makes the help
---window trustworthy, which is the only thing that makes it worth opening.

local config = require("gitui.config")
local render = require("gitui.ui.render")
local text_util = require("gitui.utils.text")
local window = require("gitui.ui.window")

local M = {}

---Human-readable descriptions for every action name the plugin defines.
---@type table<string, string>
local DESCRIPTIONS = {
  -- Common
  close = "Close this panel",
  help = "Show this help",
  refresh = "Reload from git",
  palette = "Command palette",
  search = "Filter / search",
  next_section = "Next section",
  prev_section = "Previous section",

  -- Source control
  open = "Open file / expand row",
  open_split = "Open in a horizontal split",
  open_vsplit = "Open in a vertical split",
  open_tab = "Open in a new tab",
  stage = "Stage the entry under the cursor",
  stage_all = "Stage everything",
  unstage = "Unstage the entry under the cursor",
  unstage_all = "Unstage everything",
  discard = "Discard changes (destructive)",
  diff = "Diff the entry under the cursor",
  diff_full = "Diff everything against HEAD",
  toggle = "Expand / collapse",
  toggle_all = "Expand / collapse everything",
  commit = "Write a commit",
  commit_amend = "Amend the previous commit",
  commit_push = "Commit and push",
  push = "Push",
  pull = "Pull",
  fetch = "Fetch",
  branches = "Branches",
  log = "Commit history",
  stash = "Stashes",
  blame = "Blame this file",
  file_history = "History of this file",
  open_remote = "Open on the remote's website",
  copy_path = "Copy the absolute path",
  copy_relative_path = "Copy the repository-relative path",
  context_menu = "Contextual menu",
  next_file = "Next file",
  prev_file = "Previous file",
  resolve = "Resolve conflict",

  -- Diff
  stage_hunk = "Stage this hunk",
  unstage_hunk = "Unstage this hunk",
  discard_hunk = "Discard this hunk (destructive)",
  stage_lines = "Stage the selected lines (visual mode)",
  discard_lines = "Discard the selected lines (visual mode)",
  next_hunk = "Next hunk",
  prev_hunk = "Previous hunk",
  open_file = "Open the real file at this line",
  toggle_side = "Switch between staged and unstaged",
  toggle_view = "Switch between the unified patch and side-by-side",

  -- Log
  cherry_pick = "Cherry-pick this commit",
  revert = "Revert this commit",
  branch = "Create a branch here",
  reset = "Reset to this commit",
  copy_hash = "Copy the commit hash",
  checkout = "Check out this commit (detached)",
  tag = "Create a tag here",
  load_more = "Load more commits",

  -- Branches
  switch = "Switch to this branch",
  create = "Create a branch",
  delete = "Delete this branch (destructive)",
  rename = "Rename this branch",
  merge = "Merge into the current branch",
  rebase = "Rebase onto this branch",
  set_upstream = "Set the upstream branch",

  -- Stash
  inspect = "Inspect this stash",
  apply = "Apply, keeping the stash",
  pop = "Apply and remove the stash",
  drop = "Delete this stash (destructive)",

  -- Commit
  submit = "Create the commit",
  submit_push = "Commit and push",
  amend = "Toggle amend",
  cancel = "Cancel",

  -- Conflicts
  ours = "Keep our version",
  theirs = "Keep their version",
  both = "Keep both, ours first",
  base = "Keep the merge base",
  none = "Keep neither",
  next_conflict = "Next conflict",
  prev_conflict = "Previous conflict",

  -- Blame
  reblame = "Blame the parent commit",
}

---Group actions into readable sections for a given keymap group.
---@type table<string, { title: string, actions: string[] }[]>
local SECTIONS = {
  source_control = {
    {
      title = "Navigation",
      actions = { "open", "next_file", "prev_file", "next_section", "prev_section", "search", "toggle", "toggle_all" },
    },
    { title = "Staging", actions = { "stage", "unstage", "stage_all", "unstage_all", "discard" } },
    {
      title = "Inspect",
      actions = { "diff", "diff_full", "blame", "file_history", "open_split", "open_vsplit", "open_tab" },
    },
    {
      title = "Git",
      actions = {
        "commit",
        "commit_amend",
        "commit_push",
        "push",
        "pull",
        "fetch",
        "branches",
        "log",
        "stash",
        "resolve",
      },
    },
    {
      title = "Other",
      actions = { "open_remote", "copy_path", "copy_relative_path", "context_menu", "refresh", "help", "close" },
    },
  },
  diff = {
    { title = "Navigation", actions = { "next_hunk", "prev_hunk", "next_file", "prev_file", "open_file" } },
    {
      title = "Staging",
      actions = { "stage_hunk", "unstage_hunk", "discard_hunk", "stage_lines", "discard_lines" },
    },
    { title = "Other", actions = { "toggle_side", "toggle_view", "refresh", "help", "close" } },
  },
  log = {
    { title = "Inspect", actions = { "open", "diff", "copy_hash", "open_remote", "load_more" } },
    { title = "Act", actions = { "cherry_pick", "revert", "branch", "tag", "checkout", "reset" } },
    { title = "Other", actions = { "search", "refresh", "help", "close" } },
  },
  branches = {
    { title = "Navigation", actions = { "switch", "log", "diff", "search" } },
    { title = "Manage", actions = { "create", "rename", "delete", "set_upstream" } },
    { title = "Integrate", actions = { "merge", "rebase", "push", "fetch" } },
    { title = "Other", actions = { "refresh", "help", "close" } },
  },
  stash = {
    { title = "Stashes", actions = { "inspect", "apply", "pop", "drop", "branch", "create" } },
    { title = "Other", actions = { "refresh", "help", "close" } },
  },
  blame = {
    { title = "Blame", actions = { "inspect", "diff", "reblame", "copy_hash", "open_remote" } },
  },
  conflict = {
    { title = "Resolve", actions = { "ours", "theirs", "both", "base", "none" } },
    { title = "Navigation", actions = { "next_conflict", "prev_conflict" } },
    { title = "Finish", actions = { "stage" } },
  },
  commit = {
    { title = "Commit", actions = { "submit", "submit_push", "amend", "cancel" } },
  },
}

local winid = nil
local bufnr = nil
local unregister = nil

function M.close()
  if unregister then
    unregister()
    unregister = nil
  end
  window.close(winid)
  window.delete_buffer(bufnr)
  winid = nil
  bufnr = nil
end

---Resolve an action's configured keys for a group.
---@param group string
---@param action string
---@return string|nil
local function keys_for(group, action)
  local keymaps = config.options.keymaps
  local lhs = (keymaps[group] and keymaps[group][action])
  if lhs == nil then
    lhs = keymaps.common[action]
  end
  if lhs == false or lhs == nil then
    return nil
  end
  if type(lhs) == "table" then
    return table.concat(lhs, " / ")
  end
  return lhs
end

---Show help for a panel, or for a named keymap group.
---@param source GitUIPanel|string|nil
function M.show(source)
  M.close()

  local group = "source_control"
  if type(source) == "string" then
    group = source
  elseif type(source) == "table" and source.spec then
    group = source.spec.keymap_group or source.spec.name
  end

  local sections = SECTIONS[group] or SECTIONS.source_control
  local title = group:gsub("_", " "):upper()

  bufnr = window.create_buffer({ name = "help", filetype = "gitui-help" })
  unregister = require("gitui.ui.floats").register(M.close)
  local canvas = render.new({ width = 64 })

  canvas:blank()
  canvas:row(nil):add("  "):add(title, "GitUIHelpHeader")
  canvas:row(nil):add("  "):add("Keys shown are your configured mappings.", "GitUIDim")

  -- Width of the key column, computed from the widest key actually bound.
  local key_width = 8
  for _, section in ipairs(sections) do
    for _, action in ipairs(section.actions) do
      local keys = keys_for(group, action)
      if keys then
        key_width = math.max(key_width, text_util.width(keys))
      end
    end
  end

  for _, section in ipairs(sections) do
    local rows = {}
    for _, action in ipairs(section.actions) do
      local keys = keys_for(group, action)
      if keys then
        rows[#rows + 1] = { keys = keys, label = DESCRIPTIONS[action] or action:gsub("_", " ") }
      end
    end

    if #rows > 0 then
      canvas:blank()
      canvas:row(nil):add("  "):add(section.title, "GitUISectionHeader")
      for _, entry in ipairs(rows) do
        canvas
          :row(nil)
          :add("    ")
          :add(text_util.fit(entry.keys, key_width), "GitUIKey")
          :add("  ")
          :add(entry.label, nil)
      end
    end
  end

  -- Global mappings are relevant everywhere and are easy to forget.
  local globals = config.options.global_keymaps
  if config.options.default_keymaps and globals then
    canvas:blank()
    canvas:row(nil):add("  "):add("Global", "GitUISectionHeader")
    local names = {
      source_control = "Source Control panel",
      diff = "Diff the current file",
      branches = "Branches",
      log = "Commit history",
      commit = "Commit",
      palette = "Command palette",
      next_hunk = "Next hunk (in a file)",
      prev_hunk = "Previous hunk (in a file)",
      stage_hunk = "Stage hunk (in a file)",
      unstage_hunk = "Unstage hunk (in a file)",
      discard_hunk = "Discard hunk (in a file)",
      preview_hunk = "Preview hunk (in a file)",
      blame_line = "Blame the current line",
    }
    for _, action in ipairs({
      "source_control",
      "diff",
      "branches",
      "log",
      "commit",
      "palette",
      "next_hunk",
      "prev_hunk",
      "stage_hunk",
      "unstage_hunk",
      "discard_hunk",
      "preview_hunk",
      "blame_line",
    }) do
      local lhs = globals[action]
      if lhs then
        canvas
          :row(nil)
          :add("    ")
          :add(text_util.fit(lhs, key_width), "GitUIKey")
          :add("  ")
          :add(names[action] or action)
      end
    end
  end

  canvas:blank()
  canvas:row(nil):add("  "):add("q", "GitUIKey"):add("  close this window", "GitUIHint")
  canvas:blank()

  canvas:apply(bufnr, vim.api.nvim_create_namespace("gitui_help"))

  local lines = canvas:lines()
  winid = window.open_float(bufnr, {
    title = "HELP — " .. title,
    width = 0.55,
    height = math.min(#lines, math.floor(vim.o.lines * 0.8)),
    min_width = 50,
  })
  vim.wo[winid].cursorline = false

  for _, lhs in ipairs({ "q", "<Esc>", "?" }) do
    vim.keymap.set("n", lhs, M.close, { buffer = bufnr, nowait = true, silent = true })
  end
end

---Every action name gitui knows about, with its description. Used by the
---documentation generator and `:checkhealth`.
---@return table<string, string>
function M.descriptions()
  return vim.deepcopy(DESCRIPTIONS)
end

return M
