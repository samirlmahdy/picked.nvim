---@brief Commit history.
---
---The graph column is computed from the parent links rather than parsed out of
---`git log --graph`, and it is dropped entirely on narrow windows: a readable
---list of commits beats an unreadable picture of one.
---
---History is paged. Loading 100k commits to show 40 of them is the kind of
---thing that makes a plugin feel slow on a real repository.

local config = require("gitui.config")
local git = require("gitui.git")
local icons = require("gitui.utils.icons")
local notify = require("gitui.ui.notify")
local operations = require("gitui.operations")
local panel_lib = require("gitui.ui.panel")
local text_util = require("gitui.utils.text")

local M = {}

---@class GitUILogItem
---@field id string
---@field kind "commit"|"info"|"more"
---@field commit GitCommit|nil
---@field graph GitGraphCell|nil

---@class GitUILogViewState
---@field repo GitRepository
---@field opts GitLogOpts
---@field title string|nil
---@field commits GitCommit[]
---@field graph GitGraphCell[]
---@field loading boolean
---@field exhausted boolean
---@field error GitError|nil

---@type GitUIPanel|nil
local panel = nil

---@type GitUILogViewState|nil
local current = nil

--- Rendering -------------------------------------------------------------------

---@param canvas GitUICanvas
---@param commit GitCommit
---@param graph GitGraphCell|nil
---@param width integer
local function render_commit(canvas, commit, graph, width)
  ---@type GitUILogItem
  local item = { id = "commit:" .. commit.oid, kind = "commit", commit = commit, graph = graph }
  local row = canvas:row(item)
  local highlights = require("gitui.ui.highlights")

  if graph then
    row:add(graph.prefix, highlights.graph(graph.color), "open")
  else
    row:add(commit.is_merge and (icons.get("merge") .. " ") or (icons.get("commit") .. " "), "GitUIDim", "open")
  end

  row:add(commit.short, "GitUIHash", "open")
  row:add("  ")

  -- Refs first: they are how a human locates a commit in a long list.
  for _, ref in ipairs(commit.refs) do
    local hl = ref.kind == "head" and "GitUIRefHead"
      or ref.kind == "tag" and "GitUITag"
      or ref.kind == "remote" and "GitUIRemoteBranch"
      or "GitUIBranch"
    local prefix = ref.kind == "tag" and icons.get("tag") or ""
    row:add(("%s%s "):format(prefix ~= "" and (prefix .. " ") or "", ref.name), hl, "open")
  end

  local narrow = width < 80
  local meta_width = narrow and 0 or 28
  local available = width - row:width() - meta_width - 2
  row:add(text_util.truncate(commit.subject, math.max(12, available)), nil, "open")

  if not narrow then
    row:right(
      ("%s  %s "):format(
        text_util.truncate(commit.author_name, 14),
        text_util.relative_time_short(commit.committer_date)
      ),
      "GitUIDim"
    )
  end
end

---@param self GitUIPanel
---@param canvas GitUICanvas
local function render_panel(self, canvas)
  local width = self:width()

  if not current then
    canvas:text("  No history loaded", "GitUIDim")
    return
  end

  if current.error then
    canvas:text("  " .. current.error.title, "GitUIError")
    canvas:text("  " .. (current.error.reason or ""), "GitUIDim")
    return
  end

  if #current.commits == 0 then
    canvas:text(current.loading and "  Loading history…" or "  No commits", "GitUIDim")
    return
  end

  local use_graph = config.options.log.graph and width >= 60
  for index, commit in ipairs(current.commits) do
    render_commit(canvas, commit, use_graph and current.graph[index] or nil, width)
  end

  canvas:blank()
  if current.loading then
    canvas:text("  Loading…", "GitUIDim")
  elseif not current.exhausted then
    local keys = self:keys_for("load_more")
    canvas:row({ id = "more", kind = "more" })
      :add("  ")
      :add(keys[1] or "L", "GitUIKey", "load_more")
      :add(("  load more (%d shown)"):format(#current.commits), "GitUIHint", "load_more")
  else
    canvas:text(("  %d commits"):format(#current.commits), "GitUIDim")
  end

  self:render_hints(canvas)
end

--- Loading ----------------------------------------------------------------------

---@param append boolean
local function load(append)
  if not current or not panel then
    return
  end
  if current.loading then
    return
  end

  current.loading = true
  panel:redraw()

  local repo = current.repo
  local page = config.options.log.page_size
  local opts = vim.tbl_extend("force", current.opts, {
    max_count = page,
    skip = append and #current.commits or 0,
  })

  git.commits.log(repo, opts, function(commits, err)
    if not current or current.repo ~= repo then
      return
    end
    current.loading = false
    current.error = err

    if commits then
      if append then
        vim.list_extend(current.commits, commits)
      else
        current.commits = commits
      end
      current.exhausted = #commits < page
      current.graph = git.graph.layout(current.commits)
    end

    if panel and panel:is_open() then
      panel:redraw()
    end
  end)
end

--- Commit details ------------------------------------------------------------------

---Open the detail view for a commit: metadata, message and changed files.
---@param repo GitRepository
---@param commit GitCommit
function M.show_commit(repo, commit)
  local window = require("gitui.ui.window")
  local render = require("gitui.ui.render")

  local bufnr = window.create_buffer({ name = "commit-details", filetype = "gitui-commit-details" })
  local winid = window.open_float(bufnr, {
    title = "COMMIT " .. commit.short,
    footer = "<CR> diff   c cherry-pick   v revert   b branch   y copy hash   q close",
    width = 0.75,
    height = 0.75,
  })

  local namespace = vim.api.nvim_create_namespace("gitui_commit_details")
  local canvas = render.new({ width = vim.api.nvim_win_get_width(winid) })

  canvas:blank()
  canvas:row(nil):add("  "):add(commit.subject, "GitUITitle")
  if commit.body ~= "" then
    canvas:blank()
    for _, line in ipairs(vim.split(commit.body, "\n", { plain = true })) do
      canvas:row(nil):add("  "):add(line)
    end
  end

  canvas:blank()
  canvas:rule()
  canvas:blank()

  local function field(label, value, hl)
    canvas:row(nil):add("  "):add(text_util.pad(label, 10), "GitUIDim"):add(value, hl)
  end

  field("Commit", commit.oid, "GitUIHash")
  field("Author", ("%s <%s>"):format(commit.author_name, commit.author_email), "GitUIAuthor")
  field(
    "Date",
    ("%s  (%s)"):format(
      os.date("%Y-%m-%d %H:%M:%S", commit.author_date),
      text_util.relative_time(commit.author_date)
    ),
    "GitUIDate"
  )
  if commit.committer_name ~= commit.author_name then
    field("Committer", ("%s <%s>"):format(commit.committer_name, commit.committer_email), "GitUIAuthor")
  end
  if #commit.parents > 0 then
    field("Parents", table.concat(vim.tbl_map(function(parent)
      return parent:sub(1, 7)
    end, commit.parents), "  "), "GitUIHash")
  else
    field("Parents", "none (root commit)", "GitUIDim")
  end
  if #commit.refs > 0 then
    field("Refs", table.concat(vim.tbl_map(function(ref)
      return ref.name
    end, commit.refs), ", "), "GitUIBranch")
  end

  canvas:blank()
  canvas:text("  Loading changed files…", "GitUIDim")
  canvas:apply(bufnr, namespace)

  git.diff.numstat(repo, { kind = "commit", from = commit.oid }, function(stats, err)
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end

    -- Rebuild from the point where the placeholder was.
    canvas.rows[#canvas.rows] = nil
    canvas:text(("  Files (%d)"):format(stats and #stats or 0), "GitUISectionHeader")
    canvas:blank()

    if err then
      canvas:text("  " .. err.reason, "GitUIError")
    else
      local highlights = require("gitui.ui.highlights")
      for _, stat in ipairs(stats or {}) do
        local row = canvas:row({ kind = "file", path = stat.path })
        row:add("    ")
        if stat.binary then
          row:add("bin ", "GitUIDim")
        else
          row:add(("+%-4d"):format(stat.added), highlights.for_diff("add"))
          row:add(("−%-4d "):format(stat.removed), highlights.for_diff("delete"))
        end
        row:add(stat.path, nil, "open")
        if stat.old_path then
          row:add("  ← " .. stat.old_path, "GitUIDim")
        end
      end
    end

    canvas:apply(bufnr, namespace)
  end)

  local function close()
    window.close(winid)
    window.delete_buffer(bufnr)
  end

  local function map(lhs, handler)
    vim.keymap.set("n", lhs, handler, { buffer = bufnr, nowait = true, silent = true })
  end

  map("q", close)
  map("<Esc>", close)
  map("<CR>", function()
    local cursor = vim.api.nvim_win_get_cursor(winid)
    local item = canvas:item_at(cursor[1])
    close()
    require("gitui.ui.diff_view").open(repo, {
      path = item and item.path or nil,
      spec = { kind = "commit", from = commit.oid },
    })
  end)
  map("d", function()
    close()
    require("gitui.ui.diff_view").open(repo, { spec = { kind = "commit", from = commit.oid } })
  end)
  map("c", function()
    close()
    operations.cherry_pick(repo, commit)
  end)
  map("v", function()
    close()
    operations.revert(repo, commit)
  end)
  map("b", function()
    close()
    operations.create_branch(repo, { start_point = commit.oid })
  end)
  map("y", function()
    vim.fn.setreg("+", commit.oid)
    notify.info("Copied " .. commit.oid)
  end)
  map("o", function()
    operations.browse(repo, { kind = "commit", ref = commit.oid })
  end)
end

--- Actions ------------------------------------------------------------------------

---@type table<string, fun(panel: GitUIPanel, item: GitUILogItem|nil)>
local actions = {}

---@param item GitUILogItem|nil
---@return GitCommit|nil
local function commit_of(item)
  return item and item.commit or nil
end

actions.open = function(_, item)
  if item and item.kind == "more" then
    return load(true)
  end
  local commit = commit_of(item)
  if commit and current then
    M.show_commit(current.repo, commit)
  end
end

actions.load_more = function()
  load(true)
end

actions.diff = function(_, item)
  local commit = commit_of(item)
  if commit and current then
    require("gitui.ui.diff_view").open(current.repo, { spec = { kind = "commit", from = commit.oid } })
  end
end

actions.cherry_pick = function(_, item)
  local commit = commit_of(item)
  if commit and current then
    operations.cherry_pick(current.repo, commit)
  end
end

actions.revert = function(_, item)
  local commit = commit_of(item)
  if commit and current then
    operations.revert(current.repo, commit)
  end
end

actions.branch = function(_, item)
  local commit = commit_of(item)
  if commit and current then
    operations.create_branch(current.repo, { start_point = commit.oid })
  end
end

actions.checkout = function(_, item)
  local commit = commit_of(item)
  if not commit or not current then
    return
  end
  require("gitui.ui.confirm").ask({
    title = ("Check out %s?"):format(commit.short),
    message = "This leaves HEAD detached at that commit.\n\n" .. commit.subject,
    confirm_label = "Checkout",
  }, function(confirmed)
    if confirmed then
      operations.mutate(current.repo, "checkout-commit", function(done)
        git.branches.switch(current.repo, commit.oid, { detach = true }, done)
      end, { success = ("Checked out %s (detached HEAD)"):format(commit.short) })
    end
  end)
end

actions.reset = function(_, item)
  local commit = commit_of(item)
  if not commit or not current then
    return
  end
  require("gitui.ui.confirm").choose({
    title = ("Reset to %s"):format(commit.short),
    message = commit.subject,
    choices = {
      { key = "s", label = "Soft", description = "keep the index and working tree", value = "soft" },
      { key = "m", label = "Mixed", description = "reset the index, keep the working tree", value = "mixed" },
      { key = "h", label = "Hard", description = "discard everything", value = "hard" },
    },
  }, function(mode)
    if mode then
      operations.reset(current.repo, commit.oid, mode)
    end
  end)
end

actions.tag = function(_, item)
  local commit = commit_of(item)
  if not commit or not current then
    return
  end
  require("gitui.ui.input").ask({ prompt = "Tag name" }, function(name)
    if not name then
      return
    end
    operations.mutate(current.repo, "tag", function(done)
      git.commits.tag(current.repo, name, { revision = commit.oid }, done)
    end, { success = ("Tagged %s as %s"):format(commit.short, name) })
  end)
end

actions.copy_hash = function(_, item)
  local commit = commit_of(item)
  if commit then
    vim.fn.setreg(vim.v.register or "+", commit.oid)
    notify.info("Copied " .. commit.oid)
  end
end

actions.open_remote = function(_, item)
  local commit = commit_of(item)
  if commit and current then
    operations.browse(current.repo, { kind = "commit", ref = commit.oid })
  end
end

actions.refresh = function()
  load(false)
end

actions.search = function()
  if not current then
    return
  end
  require("gitui.ui.input").ask({ prompt = "Search commit messages", allow_empty = true }, function(query)
    if not current then
      return
    end
    current.opts = vim.tbl_extend("force", current.opts, { grep = query ~= "" and query or nil })
    current.commits = {}
    current.exhausted = false
    load(false)
  end)
end

--- Panel -----------------------------------------------------------------------------

---@return GitUIPanel
local function get_panel()
  if panel then
    return panel
  end

  panel = panel_lib.new({
    name = "log",
    layout = "float",
    float = { width = 0.85, height = 0.8 },
    keymap_group = "log",
    title = function()
      if not current then
        return "COMMIT HISTORY"
      end
      return current.title or ("COMMIT HISTORY — " .. current.repo.name)
    end,
    render = render_panel,
    actions = actions,
    hints = {
      { key = "open", label = "details" },
      { key = "diff", label = "diff" },
      { key = "cherry_pick", label = "cherry-pick" },
      { key = "revert", label = "revert" },
      { key = "branch", label = "branch" },
      { key = "help", label = "help" },
    },
    context_menu = function(self, item)
      if not commit_of(item) then
        return {}
      end
      local entries = {}
      local function add(label, action, destructive)
        entries[#entries + 1] = {
          label = label,
          key = self:keys_for(action)[1],
          destructive = destructive,
          action = function()
            actions[action](self, item)
          end,
        }
      end
      add("View commit", "open")
      add("Diff against parent", "diff")
      entries[#entries + 1] = { separator = true }
      add("Cherry-pick", "cherry_pick")
      add("Revert", "revert")
      add("Create branch here", "branch")
      add("Create tag", "tag")
      add("Check out (detached)", "checkout")
      add("Reset to here", "reset", true)
      entries[#entries + 1] = { separator = true }
      add("Copy hash", "copy_hash")
      add("Open on remote", "open_remote")
      return entries
    end,
  })

  return panel
end

---@class GitUILogOpenOpts
---@field revisions string[]|nil
---@field paths string[]|nil
---@field title string|nil
---@field all boolean|nil

---Open the history view.
---@param repo GitRepository
---@param opts GitUILogOpenOpts|nil
function M.open(repo, opts)
  opts = opts or {}
  local instance = get_panel()

  current = {
    repo = repo,
    opts = {
      revisions = opts.revisions,
      paths = opts.paths,
      all = opts.all,
    },
    title = opts.title,
    commits = {},
    graph = {},
    loading = false,
    exhausted = false,
    error = nil,
  }

  instance:open()
  load(false)
end

function M.close()
  if panel then
    panel:close()
  end
end

function M.destroy()
  if panel then
    panel:destroy()
    panel = nil
  end
  current = nil
end

return M
