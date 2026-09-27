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

    it("hands the editor window to the file when one is opened", function()
      -- <CR> means "take me to the file". If the diff keeps its window the
      -- file is forced into a third one, which then never goes away.
      local dir, repo = three_hunk_repo("view-handover")
      open_unified(repo)
      local before = #vim.api.nvim_tabpage_list_wins(0)

      require("picked.ui.window").open_file(dir .. "/f.lua", {})
      vim.wait(300)

      assert.is_false(require("picked.ui.panel").get("diff"):is_open(), "the diff should step aside")
      assert.equals(before, #vim.api.nvim_tabpage_list_wins(0), "no extra window should appear")
    end)

    it("retargets a split preview instead of stacking one", function()
      local _, repo = three_hunk_repo("view-split-preview")

      t.with_options({ diff = { view = "split", preview = "auto" } }, function()
        diff_view.preview(repo, { path = "f.lua" }, "worktree")
        t.wait_for(function()
          return diff_view.split_is_open()
        end, "the split preview never opened")
        local count = #vim.api.nvim_tabpage_list_wins(0)

        diff_view.preview(repo, { path = "f.lua" }, "index")
        vim.wait(600)
        assert.equals(count, #vim.api.nvim_tabpage_list_wins(0), "previewing again must not add windows")
      end)
    end)

    it("gives each side half the width left after the sidebar", function()
      -- Wide enough that 'winwidth' (20 by default) is not the binding
      -- constraint; below 2 * winwidth Neovim cannot split evenly at all.
      local columns = vim.o.columns
      vim.o.columns = 160

      local _, repo = three_hunk_repo("view-halves")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")

      -- Two file windows already competing for the editor area: without the
      -- collapse each diff pane ends up a third of the width.
      require("picked.ui.window").open_file(vim.fn.getcwd() .. "/README.md", {})
      vim.cmd("vsplit")
      vim.wait(150)

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")
      vim.wait(250)

      local panes = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          panes[#panes + 1] = vim.api.nvim_win_get_width(winid)
        end
      end
      assert.equals(2, #panes, "expected exactly two diff panes")
      assert.is_true(math.abs(panes[1] - panes[2]) <= 1, ("panes differ: %d vs %d"):format(panes[1], panes[2]))

      -- Together they should hold everything the sidebar left behind.
      local sidebar = require("picked.ui.panel").get("source_control")
      local remaining = vim.o.columns - vim.api.nvim_win_get_width(sidebar.winid) - 2
      assert.is_true(
        panes[1] + panes[2] >= remaining - 1,
        ("panes total %d, expected about %d"):format(panes[1] + panes[2], remaining)
      )

      require("picked.ui.source_control").close()
      vim.o.columns = columns
    end)

    it("keeps the two sides balanced when the layout changes", function()
      local _, repo = three_hunk_repo("view-rebalance")
      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")
      vim.wait(200)

      vim.cmd("vsplit")
      vim.wait(300)
      vim.cmd("close")
      vim.wait(300)

      local panes = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          panes[#panes + 1] = vim.api.nvim_win_get_width(winid)
        end
      end
      assert.equals(2, #panes)
      assert.is_true(math.abs(panes[1] - panes[2]) <= 1, ("panes drifted: %d vs %d"):format(panes[1], panes[2]))
    end)

    it("forgets a split whose panes the user closed by hand", function()
      -- Closing the windows never runs picked's teardown, so openness was
      -- judged from the scratch buffers — which outlive their windows. The
      -- split then looked open when it was not, and asking for it again
      -- toggled to the unified view instead of bringing it back.
      local _, repo = three_hunk_repo("view-manual-close")
      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")

      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          vim.api.nvim_set_current_win(winid)
          pcall(vim.cmd, "close")
        end
      end
      vim.wait(300)
      assert.is_false(diff_view.split_is_open(), "a split with no windows is not open")

      diff_view.toggle_view()
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "asking for the split again should reopen it, not switch to unified")

      local panes = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          panes[#panes + 1] = vim.api.nvim_win_get_width(winid)
        end
      end
      assert.equals(2, #panes, "the reopened split needs both panes")
      assert.is_true(math.abs(panes[1] - panes[2]) <= 1, ("panes differ: %d vs %d"):format(panes[1], panes[2]))
      diff_view.close_side_by_side()
    end)

    it("holds 'winwidth' down while the sidebar and the split need the room", function()
      -- 'winwidth' widens whichever window is current by taking columns from
      -- its neighbours: at 80 it stretched the sidebar to 80 columns, and the
      -- split then had so little left that focusing one pane crushed the other
      -- to a single column.
      --
      -- The stretch itself only happens with a UI attached — headless Neovim
      -- does not re-apply 'winwidth' on window entry — so what is checked here
      -- is the mechanism that prevents it: while picked owns fixed-size
      -- windows the option is clamped to them, and handed back untouched
      -- afterwards.
      local columns, winwidth = vim.o.columns, vim.o.winwidth
      vim.o.columns = 160
      vim.o.winwidth = 80

      local _, repo = three_hunk_repo("view-winwidth")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")
      local sidebar = require("picked.ui.panel").get("source_control")

      assert.is_true(
        vim.o.winwidth <= require("picked.ui.window").sidebar_width(),
        ("'winwidth' is %d, wide enough to stretch the sidebar"):format(vim.o.winwidth)
      )
      assert.equals(80, require("picked.ui.winsize").user_value("winwidth"), "the user's value must be remembered")

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")
      vim.wait(250)

      local panes = {}
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          panes[#panes + 1] = vim.api.nvim_win_get_width(winid)
        end
      end
      assert.equals(2, #panes, "expected exactly two diff panes")
      assert.is_true(math.abs(panes[1] - panes[2]) <= 1, ("panes differ: %d vs %d"):format(panes[1], panes[2]))
      assert.is_true(
        vim.o.winwidth <= panes[1],
        ("'winwidth' is %d, wider than a pane at %d"):format(vim.o.winwidth, panes[1])
      )

      diff_view.close_side_by_side()
      require("picked.ui.source_control").close()
      vim.wait(200)
      assert.equals(80, vim.o.winwidth, "the user's 'winwidth' must be handed back")

      vim.o.winwidth = winwidth
      vim.o.columns = columns
    end)

    it("previews without taking the cursor out of the list", function()
      -- Moving down a file list must not move the cursor with the preview, or
      -- the next `j` lands in the diff instead of on the next file.
      local _, repo = three_hunk_repo("view-preview-focus")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")
      local sidebar = require("picked.ui.panel").get("source_control")
      sidebar:focus()

      t.with_options({ diff = { view = "split", preview = "auto" } }, function()
        diff_view.preview(repo, { path = "f.lua" }, "worktree")
        t.wait_for(function()
          return diff_view.split_is_open()
        end, "the split preview never opened")
        vim.wait(200)

        assert.equals(sidebar.winid, vim.api.nvim_get_current_win(), "the cursor should still be in the list")

        -- <CR> is the explicit "take me there".
        assert.is_true(diff_view.focus_split("f.lua"), "focus_split should find the open split")
        assert.is_true(vim.wo[vim.api.nvim_get_current_win()].diff, "the cursor should now be in a diff pane")
      end)

      diff_view.close_side_by_side()
      require("picked.ui.source_control").close()
    end)

    it("keeps the old diff on screen until the new one is ready", function()
      -- The split used to be torn down before git was asked for the new
      -- sides, so switching files flashed whatever buffer fell into the
      -- windows -- usually a file opened earlier -- until the answer came.
      local dir = helper.init("view-no-flash")
      for _, name in ipairs({ "a.lua", "b.lua" }) do
        helper.write(dir, name, "one\ntwo\nthree\n")
      end
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      for _, name in ipairs({ "a.lua", "b.lua" }) do
        helper.write(dir, name, "one\nTWO " .. name .. "\nthree\n")
      end
      local repo = activate(dir)
      sync(repo)

      t.with_options({ diff = { view = "split", preview = "auto" } }, function()
        diff_view.open(repo, { path = "a.lua", spec = { kind = "worktree" }, view = "split" })
        t.wait_for(function()
          return diff_view.split_is_open()
        end, "the first split never opened")

        diff_view.preview(repo, { path = "b.lua" }, "worktree")

        -- Poll until the new file is up, watching for any moment with no
        -- split on screen. There must not be one.
        local gap = false
        local deadline = vim.uv.now() + 4000
        while vim.uv.now() < deadline do
          if not diff_view.split_is_open() then
            gap = true
          end
          local panes = 0
          for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
            if vim.wo[winid].diff then
              panes = panes + 1
            end
          end
          if panes == 2 and vim.api.nvim_buf_get_name(0):find("b.lua", 1, true) then
            break
          end
          vim.wait(10)
        end
        assert.is_false(gap, "the split disappeared while the next one was loading")
      end)

      diff_view.close_side_by_side()
    end)

    it("discards previews the cursor has already moved past", function()
      -- Three requests in flight at once used to each build their own pair of
      -- panes as they came back, piling up windows and scratch buffers.
      local dir = helper.init("view-supersede")
      for _, name in ipairs({ "a.lua", "b.lua", "c.lua" }) do
        helper.write(dir, name, "one\ntwo\nthree\n")
      end
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      for _, name in ipairs({ "a.lua", "b.lua", "c.lua" }) do
        helper.write(dir, name, "one\nTWO " .. name .. "\nthree\n")
      end
      local repo = activate(dir)
      sync(repo)

      t.with_options({ diff = { view = "split", preview = "auto" } }, function()
        diff_view.preview(repo, { path = "a.lua" }, "worktree")
        diff_view.preview(repo, { path = "c.lua" }, "worktree")
        diff_view.preview(repo, { path = "b.lua" }, "worktree")
        t.wait_for(function()
          return diff_view.split_is_open()
        end, "the split never opened")
        vim.wait(600)

        local panes = 0
        for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if vim.wo[winid].diff then
            panes = panes + 1
          end
        end
        assert.equals(2, panes, "only the last request should have built panes")

        -- A side is named "picked://<label>:<path>"; a panel's own buffer is
        -- "picked://<name>" with no colon, which tells them apart. A worktree
        -- diff loads one side as a blob and takes the other from disk, so
        -- exactly one side buffer should remain.
        local sides = vim.tbl_filter(function(bufnr)
          local name = vim.api.nvim_buf_get_name(bufnr)
          return vim.api.nvim_buf_is_valid(bufnr) and name:match("^picked://[^:]+:") ~= nil
        end, vim.api.nvim_list_bufs())
        assert.equals(
          1,
          #sides,
          "superseded sides must be discarded, not left behind: "
            .. vim.inspect(vim.tbl_map(function(bufnr)
              return vim.api.nvim_buf_get_name(bufnr)
            end, sides))
        )
      end)

      diff_view.close_side_by_side()
    end)

    it("closes the split when the panel that opened it goes", function()
      local _, repo = three_hunk_repo("view-panel-close")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")

      require("picked.ui.panel").get("source_control"):close()
      vim.wait(300)
      assert.is_false(diff_view.split_is_open(), "the split should go with the list that opened it")

      local panes = 0
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.wo[winid].diff then
          panes = panes + 1
        end
      end
      assert.equals(0, panes, "no pane should be left in diff mode")
    end)

    it("closes the split when the panel window is closed directly", function()
      -- `:q` in the sidebar does not go through Panel:close, so the teardown
      -- has to hang off WinClosed as well.
      local _, repo = three_hunk_repo("view-panel-wq")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")

      local sidebar = require("picked.ui.panel").get("source_control")
      sidebar:focus()
      vim.cmd("close")
      vim.wait(300)
      assert.is_false(diff_view.split_is_open(), "closing the window must tear the split down too")
    end)

    it("requests the preview on the cursor move itself", function()
      -- preview_delay = 0 means no timer: the request must already be in
      -- flight when the autocommand returns, not one tick later.
      local _, repo = three_hunk_repo("view-no-debounce")
      require("picked.ui.source_control").open()
      t.wait_for(function()
        return require("picked.ui.panel").get("source_control"):is_open()
      end, "the sidebar never opened")
      local sidebar = require("picked.ui.panel").get("source_control")

      -- The handler is installed when the panel's buffer is built, reading
      -- `preview_delay` then; the default it was built with is the 0 under
      -- test. `diff.preview` and `diff.view` are read at fire time, so those
      -- can still be set here.
      assert.equals(0, require("picked.config").options.diff.preview_delay, "the default must stay undebounced")

      local row
      t.wait_for(function()
        for index, line in ipairs(vim.api.nvim_buf_get_lines(sidebar.bufnr, 0, -1, false)) do
          if line:find("f.lua", 1, true) then
            row = index
            return true
          end
        end
        return false
      end, "f.lua never appeared in the panel")

      t.with_options({ diff = { view = "split", preview = "auto" } }, function()
        sidebar:focus()
        sidebar:set_cursor(row)
        vim.api.nvim_exec_autocmds("CursorMoved", { buffer = sidebar.bufnr })
        -- No wait: with no timer the request is already in flight when the
        -- autocommand returns.
        assert.is_true(diff_view.split_active(), "the preview should be under way already")
      end)

      diff_view.close_side_by_side()
      require("picked.ui.source_control").close()
    end)

    it("takes its mappings back off the user's own buffer", function()
      -- The right-hand side of a worktree diff is the real file. `q` there is
      -- macro recording, so the mapping must not outlive the split.
      local _, repo = three_hunk_repo("view-borrowed-maps")
      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")

      -- Found through the pane rather than by path: on macOS the temporary
      -- directory is reached through a symlink, so the buffer's name and the
      -- path used to create it need not match.
      local file
      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        local bufnr = vim.api.nvim_win_get_buf(winid)
        if vim.wo[winid].diff and not vim.api.nvim_buf_get_name(bufnr):find("^picked://") then
          file = bufnr
        end
      end
      assert.is_not_nil(file, "the file buffer should be loaded as the right-hand side")

      local function maps_q()
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(file, "n")) do
          if map.lhs == "q" then
            return true
          end
        end
        return false
      end
      assert.is_true(maps_q(), "q should close the split while it is open")

      diff_view.close_side_by_side()
      vim.wait(200)
      assert.is_false(maps_q(), "q must be the user's own key again once the split is gone")
    end)

    it("leaves a buffer's unsaved changes intact when it makes room", function()
      local dir, repo = three_hunk_repo("view-unsaved")
      require("picked.ui.window").open_file(dir .. "/f.lua", {})
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { "an unsaved edit" })
      assert.is_true(vim.bo[bufnr].modified)

      diff_view.open(repo, { path = "f.lua", spec = { kind = "worktree" }, view = "split" })
      t.wait_for(function()
        return diff_view.split_is_open()
      end, "the split never opened")

      -- The window may go; the buffer and its edits must not.
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr), "the buffer should still exist")
      assert.is_true(vim.bo[bufnr].modified, "unsaved changes must survive")
      vim.bo[bufnr].modified = false
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

    it("inserts a Copilot suggestion for review", function()
      local dir = helper.simple()
      helper.write(dir, "new.txt", "hello\n")
      helper.git(dir, { "add", "-A" })
      local repo = activate(dir)
      sync(repo)

      local provider = require("picked.integrations.copilot")
      local original = provider.suggest
      provider.suggest = function(_, _, callback)
        vim.schedule(function()
          callback("feat: add greeting\n\nExplain the greeting.", nil)
        end)
      end

      commit.open(repo, {})
      commit.suggest()
      t.wait_for(function()
        return text_of(vim.api.nvim_get_current_buf()):find("feat: add greeting", 1, true) ~= nil
      end, "the suggested message was not inserted")

      provider.suggest = original
      local text = text_of(vim.api.nvim_get_current_buf())
      assert.is_not_nil(text:find("Explain the greeting", 1, true))
      assert.is_true(vim.bo[vim.api.nvim_get_current_buf()].modified)
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

  describe("window minimums", function()
    local winsize = require("picked.ui.winsize")

    after_each(function()
      winsize.reset()
    end)

    it("lowers the option to the smallest claim and restores it", function()
      local original = vim.o.winwidth
      vim.o.winwidth = 90

      winsize.claim("sidebar", "winwidth", 40)
      assert.equals(40, vim.o.winwidth)

      winsize.claim("split", "winwidth", 25)
      assert.equals(25, vim.o.winwidth, "the tightest claim wins")

      winsize.release("split")
      assert.equals(40, vim.o.winwidth, "releasing one claim falls back to the other")

      winsize.release("sidebar")
      assert.equals(90, vim.o.winwidth, "the user's value comes back untouched")

      vim.o.winwidth = original
    end)

    it("never raises the option above what the user chose", function()
      local original = vim.o.winwidth
      vim.o.winwidth = 10

      winsize.claim("sidebar", "winwidth", 40)
      assert.equals(10, vim.o.winwidth, "a claim is a ceiling, not a request")

      winsize.release("sidebar")
      assert.equals(10, vim.o.winwidth)
      vim.o.winwidth = original
    end)

    it("adopts a value the user changes while a claim is held", function()
      local original = vim.o.winwidth
      vim.o.winwidth = 90
      winsize.claim("sidebar", "winwidth", 40)

      -- The user changes their mind with the sidebar still open. Restoring 90
      -- afterwards would undo a setting they had already replaced.
      vim.o.winwidth = 60
      winsize.claim("sidebar", "winwidth", 40)
      assert.equals(40, vim.o.winwidth)
      assert.equals(60, winsize.user_value("winwidth"))

      winsize.release("sidebar")
      assert.equals(60, vim.o.winwidth)
      vim.o.winwidth = original
    end)

    it("ignores a release for a claim that was never made", function()
      local original = vim.o.winwidth
      winsize.release("nobody")
      assert.equals(original, vim.o.winwidth)
    end)
  end)
end)
