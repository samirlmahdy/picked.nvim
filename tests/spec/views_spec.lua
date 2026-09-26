---Tests for the remaining views and for the guarantees that are easy to
---regress silently: concurrency, confirmation, and help staying in sync with
---the user's configured mappings.

local picked = require("picked")
local repository = require("picked.git.repository")
local store = require("picked.state")
local t = require("tests.helpers")
local helper = t.repo

---@param bufnr integer
---@return string
local function text_of(bufnr)
  assert(vim.api.nvim_buf_is_valid(bufnr), "buffer is not valid")
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

---@param dir string
---@return GitRepository
local function activate(dir)
  repository.invalidate()
  local repo = assert(repository.detect(dir))
  store.ensure(repo)
  store.set_active(repo)
  return repo
end

---@param repo GitRepository
local function sync(repo)
  local state = store.get(repo.root)
  if state then
    state.status = nil
  end
  store.invalidate(repo.root)
  require("picked.state.refresh").now(repo, {})
  t.wait_for(function()
    local current = store.get(repo.root)
    return current ~= nil and current.status ~= nil
  end, "status never loaded")
end

describe("views", function()
  picked.setup({
    log_level = "off",
    default_keymaps = false,
    file_watch = false,
    refresh_debounce = 0,
    icons = false,
    hints = true,
    confirm = { discard = false, discard_hunk = false },
    -- These tests drive the diff view directly; auto-preview would open one
    -- behind their backs.
    diff = { preview = false },
  })

  after_each(function()
    picked.close_all()
    store.reset()
    repository.invalidate()
  end)

  describe("diff view", function()
    local diff_view = require("picked.ui.diff_view")

    ---@return string dir, GitRepository repo, PickedPanel panel
    local function open_diff(spec)
      local dir = helper.init("diffview")
      local base = {}
      for index = 1, 20 do
        base[index] = "line " .. index
      end
      local content = table.concat(base, "\n") .. "\n"
      helper.write(dir, "f.txt", content)
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")

      helper.write(dir, "f.txt", content:gsub("line 3\n", "THREE\n"):gsub("line 18\n", "EIGHTEEN\n"))

      local repo = activate(dir)
      sync(repo)

      diff_view.open(repo, { path = "f.txt", spec = spec or { kind = "worktree" } })
      local panel = require("picked.ui.panel").get("diff")
      -- A comparison with no differences renders a header but no `@@`, so wait
      -- for the loading placeholder to clear rather than for a hunk.
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("Loading diff", 1, true) == nil
      end, "the diff never finished loading")

      return dir, repo, panel
    end

    it("renders both hunks with their headers", function()
      local _, _, panel = open_diff()
      local text = text_of(panel.bufnr)
      assert.is_not_nil(text:find("Index ↔ Working Tree", 1, true))
      assert.is_not_nil(text:find("THREE", 1, true))
      assert.is_not_nil(text:find("EIGHTEEN", 1, true))

      local headers = panel.canvas:find_all(function(item)
        return item.kind == "hunk"
      end)
      assert.equals(2, #headers)
    end)

    it("attaches hunk and body metadata to each row", function()
      local _, _, panel = open_diff()
      local rows = panel.canvas:find_all(function(item)
        return item.kind == "line" and item.line_kind == "add"
      end)
      assert.is_true(#rows > 0)

      local item = panel.canvas:item_at(rows[1])
      assert.is_not_nil(item.hunk)
      assert.is_not_nil(item.body_index)
      assert.is_not_nil(item.new_ln)
    end)

    it("stages the hunk under the cursor with the configured key", function()
      local dir, repo, panel = open_diff()

      local headers = panel.canvas:find_all(function(item)
        return item.kind == "hunk"
      end)
      panel:focus()
      panel:set_cursor(headers[1])
      vim.cmd("normal s")

      t.wait_for(function()
        local staged = helper.git(dir, { "show", ":0:f.txt" })
        return staged:find("THREE", 1, true) ~= nil
      end, "the first hunk was never staged")

      local staged = helper.git(dir, { "show", ":0:f.txt" })
      assert.is_nil(staged:find("EIGHTEEN", 1, true), "only the first hunk should be staged")
      local _ = repo
    end)

    it("refuses to stage from a read-only comparison", function()
      local _, _, panel = open_diff({ kind = "index" })
      -- Nothing is staged, so the index view is empty; the capability check is
      -- what matters here.
      local text = text_of(panel.bufnr)
      assert.is_not_nil(text:find("HEAD ↔ Index", 1, true))
      assert.is_not_nil(text:find("staged changes", 1, true))
    end)

    it("navigates between hunks", function()
      local _, _, panel = open_diff()
      panel:focus()
      panel:set_cursor(1)
      vim.cmd("normal ]c")
      local first = panel:cursor_line()
      vim.cmd("normal ]c")
      local second = panel:cursor_line()
      assert.is_true(second > first, "]c should move forward")
    end)
  end)

  describe("diff view presentations", function()
    local diff_view = require("picked.ui.diff_view")
    local config = require("picked.config")

    ---A file with three well-separated changes, so hunk jumping is meaningful.
    local function three_hunk_repo(label)
      local dir = helper.init(label)
      local base = {}
      for index = 1, 30 do
        base[index] = "line " .. index
      end
      local content = table.concat(base, "\n") .. "\n"
      helper.write(dir, "f.lua", content)
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(
        dir,
        "f.lua",
        content:gsub("line 3\n", "THREE\n"):gsub("line 15\n", "FIFTEEN\n"):gsub("line 27\n", "TWENTYSEVEN\n")
      )
      local repo = activate(dir)
      sync(repo)
      return dir, repo
    end

    local function open_unified(repo)
      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "unified" })
      local panel = require("picked.ui.panel").get("diff")
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("@@", 1, true) ~= nil
      end, "the unified diff never rendered")
      return panel
    end

    after_each(function()
      diff_view.close_side_by_side()
      diff_view.close()
    end)

    it("jumps between hunks in the unified view", function()
      local _, repo = three_hunk_repo("hunks-unified")
      local panel = open_unified(repo)

      local headers = panel.canvas:find_all(function(item)
        return item.kind == "hunk"
      end)
      assert.equals(3, #headers)

      panel:focus()
      panel:set_cursor(1)

      local visited = {}
      for _ = 1, 3 do
        vim.cmd("normal ]c")
        visited[#visited + 1] = panel:cursor_line()
      end
      assert.is_true(visited[1] < visited[2], "]c should move forward")
      assert.is_true(visited[2] < visited[3], "]c should keep moving forward")

      vim.cmd("normal [c")
      assert.equals(visited[2], panel:cursor_line(), "[c should move back one hunk")
    end)

    it("switches to the side-by-side view and back", function()
      local _, repo = three_hunk_repo("view-toggle")
      local panel = open_unified(repo)

      panel:focus()
      diff_view.toggle_view()
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split view never opened")

      -- The two presentations are mutually exclusive.
      assert.is_false(panel:is_open(), "the unified panel should close behind the split")

      local diff_windows = vim.tbl_filter(function(winid)
        return vim.wo[winid].diff
      end, vim.api.nvim_tabpage_list_wins(0))
      assert.equals(2, #diff_windows, "the split view needs exactly two diff windows")

      -- Native diff mode means ]c works without picked doing anything.
      vim.api.nvim_set_current_win(diff_windows[1])
      vim.cmd("normal! gg")
      local first = vim.api.nvim_win_get_cursor(0)[1]
      vim.cmd("normal! ]c")
      assert.is_true(vim.api.nvim_win_get_cursor(0)[1] > first, "]c should jump in diff mode")

      diff_view.toggle_view()
      t.wait_for(function()
        return not diff_view.split_is_open()
      end, "the split view never closed")
      t.wait_for(function()
        return require("picked.ui.panel").get("diff"):is_open()
      end, "the unified view never came back")
    end)

    it("honours the configured split orientation", function()
      local _, repo = three_hunk_repo("view-layout")
      local previous = config.options.diff.layout
      config.options.diff.layout = "horizontal"

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split view never opened")

      local rows = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          rows[#rows + 1] = vim.api.nvim_win_get_position(winid)[1]
        end
      end
      assert.equals(2, #rows)
      assert.is_true(rows[1] ~= rows[2], "horizontal layout must stack the two sides")

      config.options.diff.layout = previous
    end)

    it("falls back to the unified patch when there is nothing to split", function()
      local _, repo = three_hunk_repo("view-fallback")
      -- A whole-tree diff has no single file, so no side-by-side form.
      diff_view.open(repo, { spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return require("picked.ui.panel").get("diff"):is_open()
      end, "the unified fallback never opened")
      assert.is_false(diff_view.split_is_open())
    end)

    it("rejects an invalid view or layout instead of breaking", function()
      t.with_config({
        diff = { view = "nonsense", layout = "diagonal" },
        default_keymaps = false,
        log_level = "off",
      }, function(merged)
        assert.equals("unified", merged.diff.view)
        assert.equals("vertical", merged.diff.layout)
      end)
    end)
  end)

  describe("float dismissal", function()
    -- A float sits above the editor area, so opening a diff or a file from one
    -- used to put the result underneath the list that launched it: the user
    -- asks to see something and nothing appears to happen.
    local panel_lib = require("picked.ui.panel")
    local floats = require("picked.ui.floats")

    ---A repository with two commits and an uncommitted change.
    local function history_repo()
      local dir = helper.init("floats")
      helper.write(dir, "a.lua", "alpha\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "first commit")
      helper.write(dir, "a.lua", "ALPHA\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "second commit")
      helper.write(dir, "a.lua", "ALPHA!\n")
      local repo = activate(dir)
      sync(repo)
      return dir, repo
    end

    ---@return string[] filetypes of every floating window on screen
    local function open_floats()
      local out = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_config(winid).relative ~= "" then
          out[#out + 1] = vim.bo[vim.api.nvim_win_get_buf(winid)].filetype
        end
      end
      table.sort(out)
      return out
    end

    local function open_history(repo)
      require("picked.ui.log").open(repo, {})
      local panel = panel_lib.get("log")
      t.wait_for(function()
        return panel:is_open()
          and panel.canvas ~= nil
          and panel.canvas:find(function(item)
            return item.kind == "commit"
          end) ~= nil
      end, "the history never rendered")
      return panel
    end

    after_each(function()
      floats.close_all()
    end)

    it("replaces the history with the commit details rather than stacking", function()
      local _, repo = history_repo()
      local panel = open_history(repo)

      panel:focus()
      panel:set_cursor(panel.canvas:find(function(item)
        return item.kind == "commit"
      end))
      vim.cmd("normal \13") -- <CR>
      vim.wait(400)

      assert.is_false(panel:is_open(), "the history should stand aside for the details")
      assert.same({ "picked-commit-details" }, open_floats())
    end)

    it("dismisses the history when a diff is opened from it", function()
      local _, repo = history_repo()
      local panel = open_history(repo)

      panel:focus()
      panel:set_cursor(panel.canvas:find(function(item)
        return item.kind == "commit"
      end))
      vim.cmd("normal d")

      t.wait_for(function()
        return panel_lib.get("diff"):is_open()
      end, "the diff never opened")
      vim.wait(200)

      assert.same({}, open_floats(), "nothing should be covering the diff")
      assert.is_false(panel:is_open())
    end)

    it("dismisses a float when a file is opened in the editor area", function()
      local dir, repo = history_repo()
      local panel = open_history(repo)
      assert.is_true(panel:is_open())

      require("picked.ui.window").open_file(dir .. "/a.lua", {})
      vim.wait(300)

      assert.same({}, open_floats(), "the float should not cover the file")
      assert.is_false(panel:is_open())
    end)

    it("keeps only one float panel open at a time", function()
      local _, repo = history_repo()

      require("picked.ui.branches").open(repo)
      t.wait_for(function()
        return panel_lib.get("branches"):is_open()
      end, "branches never opened")

      require("picked.ui.log").open(repo, {})
      t.wait_for(function()
        return panel_lib.get("log"):is_open()
      end, "history never opened")
      vim.wait(200)

      assert.is_false(panel_lib.get("branches"):is_open(), "branches should stand aside")
      assert.same({ "picked-log" }, open_floats())
    end)

    it("dismisses help and the output window too", function()
      local _, repo = history_repo()

      require("picked.ui.help").show("source_control")
      require("picked.ui.output").store("git push", "some output", true)
      require("picked.ui.output").open({ focus = false })
      vim.wait(200)
      assert.is_true(#open_floats() > 0, "the floats should be on screen to begin with")

      require("picked.ui.diff_view").open(repo, { path = "a.lua", spec = { kind = "worktree" } })
      t.wait_for(function()
        return panel_lib.get("diff"):is_open()
      end, "the diff never opened")
      vim.wait(200)

      assert.same({}, open_floats(), "help and output should be dismissed")
    end)

    it("does not recurse when a closer opens something", function()
      -- A registered closer that itself triggers a dismissal must not loop.
      local calls = 0
      floats.register(function()
        calls = calls + 1
        floats.close_all()
      end)
      floats.close_all()
      assert.equals(1, calls)
    end)
  end)

  describe("blame", function()
    local blame = require("picked.ui.blame")

    ---A file whose lines come from three different commits.
    local function layered_repo()
      local dir = helper.init("blame-panes")
      helper.write(dir, "f.lua", "one\ntwo\nthree\nfour\nfive\nsix\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "first")
      helper.write(dir, "f.lua", "one\ntwo\nTHREE\nFOUR\nfive\nsix\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "second")
      helper.write(dir, "f.lua", "one\ntwo\nTHREE\nFOUR\nfive\nSIX\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "third")
      return dir, activate(dir)
    end

    ---@return integer file_win, integer blame_win
    local function panes()
      local file_win, blame_win
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.bo[bufnr].filetype == "picked-blame" then
          blame_win = winid
        elseif vim.api.nvim_buf_get_name(bufnr):match("f%.lua$") then
          file_win = winid
        end
      end
      return assert(file_win, "no pane is showing f.lua"), assert(blame_win, "no blame pane")
    end

    ---Move the cursor the way a user does.
    ---
    ---`nvim_win_set_cursor` deliberately bypasses 'cursorbind' — it is an API
    ---call, not a motion — so a real `G` is required to exercise the binding
    ---at all. CursorMoved additionally does not fire under --headless without
    ---a UI, so the event a keypress would produce is raised explicitly.
    local function move_to(winid, lnum)
      vim.api.nvim_set_current_win(winid)
      vim.cmd("normal! " .. lnum .. "G")
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = vim.api.nvim_win_get_buf(winid) })
      vim.wait(80)
    end

    after_each(function()
      blame.close()
    end)

    it("binds both panes so they move together in either direction", function()
      local _, repo = layered_repo()
      blame.open(repo, "f.lua")
      t.wait_for(function()
        return blame.is_open()
      end, "blame never opened")
      vim.wait(400)

      local file_win, blame_win = panes()

      for _, winid in ipairs({ file_win, blame_win }) do
        assert.is_true(vim.wo[winid].scrollbind, "scrollbind should be on in both panes")
        assert.is_true(vim.wo[winid].cursorbind, "cursorbind should be on in both panes")
      end

      -- Moving in the file moves the blame column…
      move_to(file_win, 5)
      assert.equals(5, vim.api.nvim_win_get_cursor(blame_win)[1])

      -- …and moving in the blame column moves the file. This direction did not
      -- work before: the sync only ever read from the file window.
      move_to(blame_win, 2)
      assert.equals(2, vim.api.nvim_win_get_cursor(file_win)[1])
    end)

    it("highlights the current line and its commit block in both panes", function()
      local _, repo = layered_repo()
      blame.open(repo, "f.lua")
      t.wait_for(function()
        return blame.is_open()
      end, "blame never opened")
      vim.wait(400)

      local file_win, blame_win = panes()
      local ns = vim.api.nvim_create_namespace("picked_blame_sync")

      local function marks(winid)
        local bufnr = vim.api.nvim_win_get_buf(winid)
        local out = {}
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
          out[#out + 1] = ("%d:%s"):format(mark[2] + 1, mark[4].line_hl_group)
        end
        table.sort(out)
        return out
      end

      -- Lines 3 and 4 share the "second" commit, so selecting either should
      -- light up both, in both panes.
      move_to(file_win, 3)

      local in_file, in_blame = marks(file_win), marks(blame_win)
      assert.is_true(#in_file > 0, "the file pane should be highlighted")
      assert.same(in_file, in_blame, "both panes must carry the same highlight")

      local has_current, block_lines = false, {}
      for _, entry in ipairs(in_file) do
        local lnum, group = entry:match("^(%d+):(.+)$")
        if group == "PickedBlameCurrentLine" then
          has_current = true
          assert.equals("3", lnum)
        else
          block_lines[#block_lines + 1] = lnum
        end
      end
      assert.is_true(has_current, "the current line must be highlighted")
      assert.same({ "3", "4" }, block_lines, "the whole commit block must be highlighted")
    end)

    it("gives each commit its own colour in the blame column", function()
      local _, repo = layered_repo()
      blame.open(repo, "f.lua")
      t.wait_for(function()
        return blame.is_open()
      end, "blame never opened")
      vim.wait(400)

      local _, blame_win = panes()
      local bufnr = vim.api.nvim_win_get_buf(blame_win)
      local ns = vim.api.nvim_create_namespace("picked_blame")

      local groups = {}
      for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
        local group = mark[4].hl_group
        if group and group:match("^PickedGraph%d$") then
          groups[mark[2] + 1] = group
        end
      end

      -- Three commits, three distinct colours; line 1 and line 5 are the same
      -- commit and must therefore share one.
      local distinct = {}
      for _, group in pairs(groups) do
        distinct[group] = true
      end
      assert.is_true(vim.tbl_count(distinct) >= 3, "each commit should get its own colour")
      assert.is_not_nil(groups[1])
      assert.equals(groups[1], groups[5], "the same commit must keep the same colour")
    end)

    it("leaves nothing behind on the user's file buffer", function()
      local dir, repo = layered_repo()
      blame.open(repo, "f.lua")
      t.wait_for(function()
        return blame.is_open()
      end, "blame never opened")
      vim.wait(400)

      local file_win = panes()
      local file_bufnr = vim.api.nvim_win_get_buf(file_win)
      blame.close()
      vim.wait(150)

      local ns = vim.api.nvim_create_namespace("picked_blame_sync")
      assert.equals(0, #vim.api.nvim_buf_get_extmarks(file_bufnr, ns, 0, -1, {}))
      assert.is_false(vim.wo[file_win].scrollbind, "scrollbind must be released")
      assert.is_false(vim.wo[file_win].cursorbind, "cursorbind must be released")
      local _ = dir
    end)
  end)

  describe("commit editor", function()
    local commit = require("picked.ui.commit")

    it("opens a modifiable gitcommit buffer with the staged list beside it", function()
      local dir = helper.simple()
      helper.write(dir, "new.txt", "hello\n")
      helper.git(dir, { "add", "-A" })
      local repo = activate(dir)
      sync(repo)

      commit.open(repo, {})
      assert.is_true(commit.is_open())

      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals("gitcommit", vim.bo[bufnr].filetype)
      assert.is_true(vim.bo[bufnr].modifiable)

      commit.close()
      assert.is_false(commit.is_open())
    end)

    it("commits the message typed into the buffer", function()
      local dir = helper.simple()
      helper.write(dir, "new.txt", "hello\n")
      helper.git(dir, { "add", "-A" })
      local repo = activate(dir)
      sync(repo)

      commit.open(repo, {})
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "feat: from the editor", "", "Body text." })

      -- `<C-s>` is the configured submit key.
      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-s>", true, false, true), "x", false)

      t.wait_for(function()
        local code = helper.git_try(dir, { "diff", "--cached", "--quiet" })
        return code == 0
      end, "the commit never happened")

      local subject = vim.trim(helper.git(dir, { "log", "-1", "--format=%s" }))
      assert.equals("feat: from the editor", subject)
      local body = helper.git(dir, { "log", "-1", "--format=%b" })
      assert.is_not_nil(body:find("Body text", 1, true))
    end)

    it("keeps an unfinished message as a draft", function()
      local dir = helper.simple()
      helper.write(dir, "new.txt", "hello\n")
      helper.git(dir, { "add", "-A" })
      local repo = activate(dir)
      sync(repo)

      commit.open(repo, {})
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "half written" })
      commit.close()

      assert.equals("half written", commit.draft)

      commit.open(repo, {})
      t.wait_for(function()
        return text_of(vim.api.nvim_get_current_buf()):find("half written", 1, true) ~= nil
      end, "the draft was not restored")
      commit.close()
      commit.draft = nil
    end)

    it("prefills the previous message when amending", function()
      local dir = helper.simple()
      local repo = activate(dir)
      sync(repo)

      commit.open(repo, { amend = true })
      t.wait_for(function()
        return text_of(vim.api.nvim_get_current_buf()):find("initial commit", 1, true) ~= nil
      end, "the amend message was not prefilled")
      commit.close()
      commit.draft = nil
    end)
  end)

  describe("log view", function()
    it("renders commits with hashes, subjects and a graph", function()
      local dir = helper.simple()
      for index = 1, 3 do
        helper.write(dir, "f" .. index .. ".txt", "x\n")
        helper.git(dir, { "add", "-A" })
        helper.commit(dir, "commit number " .. index)
      end
      local repo = activate(dir)

      require("picked.ui.log").open(repo, {})
      local panel = require("picked.ui.panel").get("log")
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("commit number 3", 1, true) ~= nil
      end, "the log never rendered")

      local text = text_of(panel.bufnr)
      assert.is_not_nil(text:find("commit number 1", 1, true))
      assert.is_not_nil(text:find("initial commit", 1, true))

      local commits = panel.canvas:find_all(function(item)
        return item.kind == "commit"
      end)
      assert.equals(4, #commits)

      local item = panel.canvas:item_at(commits[1])
      assert.equals("commit number 3", item.commit.subject)
      assert.is_not_nil(item.graph, "the graph column should be present at this width")
    end)
  end)

  describe("branch view", function()
    it("marks the current branch and lists remotes", function()
      local dir, _ = helper.with_remote()
      helper.git(dir, { "branch", "feature/one" })
      local repo = activate(dir)

      require("picked.ui.branches").open(repo)
      local panel = require("picked.ui.panel").get("branches")
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("feature/one", 1, true) ~= nil
      end, "branches never rendered")

      local text = text_of(panel.bufnr)
      assert.is_not_nil(text:find("LOCAL", 1, true))
      assert.is_not_nil(text:find("REMOTE", 1, true))
      assert.is_not_nil(text:find("origin/main", 1, true))

      local head_line = panel.canvas:find(function(item)
        return item.branch and item.branch.is_head
      end)
      assert.is_not_nil(head_line)
      assert.equals("main", panel.canvas:item_at(head_line).branch.name)
    end)
  end)

  describe("stash view", function()
    it("lists stashes and offers to create one when empty", function()
      local dir = helper.simple()
      local repo = activate(dir)

      require("picked.ui.stash").open(repo)
      local panel = require("picked.ui.panel").get("stash")
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("No stashes", 1, true) ~= nil
      end, "the empty stash view never rendered")

      helper.write(dir, "README.md", "# changed\n")
      helper.git(dir, { "stash", "push", "-m", "my work" })

      require("picked.ui.stash").open(repo)
      t.wait_for(function()
        return text_of(panel.bufnr):find("my work", 1, true) ~= nil
      end, "the stash never appeared")

      assert.is_not_nil(text_of(panel.bufnr):find("stash@{0}", 1, true))
    end)
  end)

  describe("help", function()
    local help = require("picked.ui.help")

    it("shows the user's configured keys, not hard-coded ones", function()
      local config = require("picked.config")
      local original = config.options.keymaps.source_control.stage
      config.options.keymaps.source_control.stage = "gs"

      help.show("source_control")
      local bufnr = vim.api.nvim_get_current_buf()
      local text = text_of(bufnr)

      assert.is_not_nil(text:find("gs", 1, true), "the rebound key should appear")
      assert.is_not_nil(text:find("Stage the entry under the cursor", 1, true))

      help.close()
      config.options.keymaps.source_control.stage = original
    end)

    it("omits actions the user disabled", function()
      local config = require("picked.config")
      local original = config.options.keymaps.source_control.discard
      config.options.keymaps.source_control.discard = false

      help.show("source_control")
      local text = text_of(vim.api.nvim_get_current_buf())
      assert.is_nil(text:find("Discard changes (destructive)", 1, true))

      help.close()
      config.options.keymaps.source_control.discard = original
    end)
  end)

  describe("confirmation", function()
    local confirm = require("picked.ui.confirm")

    it("declines by default and confirms on y", function()
      local answer = nil
      confirm.ask({ title = "Do the thing?", destructive = true }, function(value)
        answer = value
      end)

      local bufnr = vim.api.nvim_get_current_buf()
      assert.is_not_nil(text_of(bufnr):find("Do the thing?", 1, true))
      assert.is_not_nil(text_of(bufnr):find("[y]", 1, true))

      vim.api.nvim_feedkeys("y", "x", false)
      t.wait_for(function()
        return answer ~= nil
      end, "the dialog never answered")
      assert.is_true(answer)
    end)

    it("treats Enter as 'no' unless a default is declared", function()
      local answer = nil
      confirm.ask({ title = "Destroy everything?", destructive = true }, function(value)
        answer = value
      end)

      vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<CR>", true, false, true), "x", false)
      t.wait_for(function()
        return answer ~= nil
      end, "the dialog never answered")
      assert.is_false(answer, "Enter must not confirm a destructive action by default")
    end)

    it("is skipped when the matching confirm option is off", function()
      local answered = nil
      confirm.guard("discard", { title = "should not appear" }, function(value)
        answered = value
      end)
      t.wait_for(function()
        return answered ~= nil
      end, "guard never called back")
      assert.is_true(answered)
    end)
  end)

  describe("concurrency", function()
    it("drops a status read that a mutation has superseded", function()
      local dir = helper.simple()
      local repo = activate(dir)
      sync(repo)

      local state = store.get(repo.root)
      local token = store.current_generation(repo.root)

      -- A mutation happens while a read is in flight.
      store.invalidate(repo.root)

      local applied = store.update(repo.root, { status = { marker = "stale" } }, token)
      assert.is_false(applied, "a read from before the mutation must not be applied")
      assert.is_nil(state.status and state.status.marker)

      -- A read taken after the mutation is accepted.
      local fresh = store.current_generation(repo.root)
      assert.is_true(store.update(repo.root, { status = { marker = "fresh" } }, fresh))
      assert.equals("fresh", store.get(repo.root).status.marker)
    end)

    it("coalesces concurrent refreshes into one query", function()
      local dir = helper.kitchen_sink()
      local repo = activate(dir)
      local refresh = require("picked.state.refresh")

      local results = {}
      for _ = 1, 5 do
        refresh.now(repo, {}, function(ok, err)
          results[#results + 1] = { ok = ok, err = err }
        end)
      end

      t.wait_for(function()
        return #results == 5
      end, "not every caller was answered")

      for index, result in ipairs(results) do
        assert.is_true(result.ok, ("caller %d was not given a real answer"):format(index))
        assert.is_nil(result.err)
      end
    end)

    it("serialises mutating commands so they cannot race", function()
      local dir = helper.init("serialise")
      for index = 1, 8 do
        helper.write(dir, ("f%d.txt"):format(index), "x\n")
      end
      local repo = activate(dir)

      local command = require("picked.git.command")
      local completed = 0
      for index = 1, 8 do
        command.run({ "add", "--", ("f%d.txt"):format(index) }, {
          cwd = repo.root,
          serialize = true,
        }, function(result)
          assert(result.ok, result.stderr)
          completed = completed + 1
        end)
      end

      t.wait_for(function()
        return completed == 8
      end, "not every queued command finished")

      local staged = helper.git(dir, { "diff", "--cached", "--name-only" })
      for index = 1, 8 do
        assert.is_not_nil(staged:find(("f%d.txt"):format(index), 1, true))
      end
    end)
  end)

  describe("picker", function()
    it("filters items as the query changes", function()
      local text_util = require("picked.utils.text")
      local items = {
        { text = "src/api/users.lua" },
        { text = "src/api/auth.lua" },
        { text = "tests/test_users.lua" },
        { text = "README.md" },
      }

      local results = text_util.fuzzy_filter(items, "users", function(item)
        return item.text
      end)
      assert.equals(2, #results)
      -- The shorter, more boundary-aligned path should rank first.
      assert.equals("src/api/users.lua", results[1].item.text)

      assert.equals(0, #text_util.fuzzy_filter(items, "zzz", function(item)
        return item.text
      end))
      assert.equals(4, #text_util.fuzzy_filter(items, "", function(item)
        return item.text
      end))
    end)
  end)

  describe("resource lifecycle", function()
    it("leaves no buffers or windows behind after reset", function()
      local dir = helper.kitchen_sink()
      local repo = activate(dir)
      sync(repo)

      local buffers_before = #vim.api.nvim_list_bufs()

      require("picked.ui.source_control").open()
      require("picked.ui.log").open(repo, {})
      require("picked.ui.branches").open(repo)
      require("picked.ui.stash").open(repo)

      picked.reset()
      vim.wait(200)

      local remaining = vim.tbl_filter(function(bufnr)
        local name = vim.api.nvim_buf_get_name(bufnr)
        return name:match("^picked://") ~= nil
      end, vim.api.nvim_list_bufs())

      assert.equals(0, #remaining, "picked buffers survived reset: " .. vim.inspect(vim.tbl_map(function(b)
        return vim.api.nvim_buf_get_name(b)
      end, remaining)))

      local _ = buffers_before
    end)
  end)
end)
