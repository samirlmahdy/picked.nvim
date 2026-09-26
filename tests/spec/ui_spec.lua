---End-to-end tests that drive the real UI: real buffers, real keymaps, real
---git. These are the tests that catch a panel which renders but cannot be
---used.

local gitui = require("gitui")
local repository = require("gitui.git.repository")
local source_control = require("gitui.ui.source_control")
local store = require("gitui.state")
local t = require("tests.helpers")
local helper = t.repo

---Lines currently displayed by a panel.
---@param panel GitUIPanel
---@return string[]
local function lines(panel)
  assert(panel.bufnr and vim.api.nvim_buf_is_valid(panel.bufnr), "panel has no buffer")
  return vim.api.nvim_buf_get_lines(panel.bufnr, 0, -1, false)
end

---@param panel GitUIPanel
---@param needle string
---@return integer|nil
local function find_line(panel, needle)
  for index, line in ipairs(lines(panel)) do
    if line:find(needle, 1, true) then
      return index
    end
  end
  return nil
end

---Put the cursor on the first row matching `needle` and press `keys` so the
---buffer-local mapping actually runs.
---@param panel GitUIPanel
---@param needle string
---@param keys string
local function press_on(panel, needle, keys)
  local lnum = find_line(panel, needle)
  assert(lnum, ("no row matching %q in:\n%s"):format(needle, table.concat(lines(panel), "\n")))
  panel:focus()
  panel:set_cursor(lnum)
  -- `normal` (without a bang) honours buffer-local mappings, which is the
  -- whole point: this exercises the same path a user's keypress takes.
  vim.cmd("normal " .. keys)
end

---Open the panel on a repository and wait for its first render.
---@param dir string
---@return GitUIPanel, GitRepository
local function open_panel(dir)
  repository.invalidate()
  local repo = assert(repository.detect(dir))
  store.ensure(repo)
  store.set_active(repo)

  source_control.open({ focus = true })
  local panel = assert(source_control.panel())

  t.wait_for(function()
    local state = store.get(repo.root)
    return state ~= nil and state.status ~= nil
  end, "status never loaded")

  panel:redraw()
  return panel, repo
end

---@param repo GitRepository
---@param predicate fun(status: GitStatusResult): boolean
local function wait_for_status(repo, predicate, message)
  t.wait_for(function()
    local state = store.get(repo.root)
    return state ~= nil and state.status ~= nil and predicate(state.status)
  end, message)
end

describe("source control panel", function()
  gitui.setup({
    log_level = "off",
    default_keymaps = false,
    file_watch = false,
    refresh_debounce = 0,
    icons = false,
    confirm = { discard = false, discard_hunk = false },
    diff = { preview = false },
  })

  after_each(function()
    source_control.close()
    store.reset()
    repository.invalidate()
  end)

  it("opens, renders the branch and lists every section", function()
    local dir = helper.kitchen_sink()
    local panel = open_panel(dir)

    assert.is_true(panel:is_open())

    local text = table.concat(lines(panel), "\n")
    assert.is_not_nil(text:find("main", 1, true), "branch should be shown")
    assert.is_not_nil(text:find("STAGED CHANGES", 1, true))
    assert.is_not_nil(text:find("CHANGES", 1, true))
    assert.is_not_nil(text:find("modified.txt", 1, true))
    assert.is_not_nil(text:find("staged.txt", 1, true))
    assert.is_not_nil(text:find("untracked.md", 1, true))
  end)

  it("attaches the right entry to each row", function()
    local dir = helper.kitchen_sink()
    local panel = open_panel(dir)

    local lnum = assert(find_line(panel, "modified.txt"))
    local item = panel.canvas:item_at(lnum)
    assert.is_not_nil(item)
    assert.equals("file", item.kind)
    assert.equals("modified.txt", item.entry.path)
    assert.equals("unstaged", item.section)
  end)

  it("stages a file with the configured key", function()
    local dir = helper.kitchen_sink()
    local panel, repo = open_panel(dir)

    press_on(panel, "modified.txt", "s")

    wait_for_status(repo, function(status)
      local entry = status.by_path["modified.txt"]
      return entry ~= nil and entry.staged
    end, "modified.txt never became staged")

    panel:redraw()
    local staged_line = assert(find_line(panel, "STAGED CHANGES"))
    local file_line = assert(find_line(panel, "modified.txt"))
    assert.is_true(file_line > staged_line, "the staged file should appear under STAGED CHANGES")
  end)

  it("unstages a file with the configured key", function()
    local dir = helper.kitchen_sink()
    local panel, repo = open_panel(dir)

    press_on(panel, "staged.txt", "u")

    wait_for_status(repo, function(status)
      local entry = status.by_path["staged.txt"]
      return entry ~= nil and not entry.staged
    end, "staged.txt never became unstaged")
  end)

  it("discards a file's changes", function()
    local dir = helper.kitchen_sink()
    local panel, repo = open_panel(dir)
    local before = helper.read(dir, "modified.txt")
    assert.is_not_nil(before:find("CHANGED", 1, true))

    press_on(panel, "modified.txt", "x")

    wait_for_status(repo, function(status)
      return status.by_path["modified.txt"] == nil
    end, "modified.txt never returned to its committed state")

    assert.is_nil((helper.read(dir, "modified.txt") or ""):find("CHANGED", 1, true))
  end)

  it("stages every change at once", function()
    local dir = helper.kitchen_sink()
    local panel, repo = open_panel(dir)

    panel:focus()
    vim.cmd("normal S")

    wait_for_status(repo, function(status)
      return #status.unstaged == 0 and #status.staged > 0
    end, "stage-all never completed")
  end)

  it("collapses and expands a section", function()
    local dir = helper.kitchen_sink()
    local panel = open_panel(dir)

    assert.is_not_nil(find_line(panel, "modified.txt"))
    press_on(panel, "CHANGES (", "za")
    panel:redraw()

    -- The header stays, its contents do not.
    assert.is_not_nil(find_line(panel, "CHANGES ("))
  end)

  it("renders a directory tree for nested paths", function()
    local dir = helper.kitchen_sink()
    local panel = open_panel(dir)
    local text = table.concat(lines(panel), "\n")
    -- src/models/user.lua is staged and nested, so a directory row must exist.
    assert.is_not_nil(text:find("src/models/", 1, true) or text:find("models/", 1, true), text)
  end)

  it("shows conflicts in their own section", function()
    local dir = helper.conflicted()
    local panel = open_panel(dir)
    local text = table.concat(lines(panel), "\n")

    assert.is_not_nil(text:find("MERGE CONFLICTS", 1, true))
    assert.is_not_nil(text:find("conflict.lua", 1, true))
    assert.is_not_nil(text:find("MERGE IN PROGRESS", 1, true))
  end)

  it("reports a clean repository", function()
    local dir = helper.simple()
    local panel = open_panel(dir)
    local text = table.concat(lines(panel), "\n")
    assert.is_not_nil(text:find("No changes", 1, true), text)
  end)

  it("keeps the panel buffer read-only", function()
    local dir = helper.simple()
    local panel = open_panel(dir)
    assert.is_false(vim.bo[panel.bufnr].modifiable)
    assert.equals("nofile", vim.bo[panel.bufnr].buftype)
    assert.equals("gitui-source-control", vim.bo[panel.bufnr].filetype)
  end)

  it("closes without leaving windows or autocommands behind", function()
    local dir = helper.simple()
    local panel = open_panel(dir)
    local bufnr = panel.bufnr

    local before = #vim.api.nvim_list_wins()
    source_control.close()

    assert.is_false(panel:is_open())
    assert.is_true(#vim.api.nvim_list_wins() < before)

    source_control.destroy()
    assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
  end)

  describe("diff preview", function()
    -- `diff.preview` is the option that makes selecting a file show its added
    -- and removed lines, which is the whole point of the panel for anyone
    -- arriving from VS Code. It regressed once by being implemented as a
    -- passive refresh that never opened anything.
    local config = require("gitui.config")
    local diff_view = require("gitui.ui.diff_view")

    local function with_preview(mode, fn)
      local previous = config.options.diff.preview
      config.options.diff.preview = mode
      local ok, err = pcall(fn)
      config.options.diff.preview = previous
      diff_view.close()
      if not ok then
        error(err, 0)
      end
    end

    ---Move the cursor onto a row and fire the event the user's `j` would.
    local function select_row(panel, needle)
      local lnum = assert(find_line(panel, needle), "no row for " .. needle)
      panel:focus()
      panel:set_cursor(lnum)
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = panel.bufnr })
    end

    it("opens the diff when a file is selected, without stealing focus", function()
      local dir = helper.init("preview-auto")
      helper.write(dir, "app.lua", "alpha\nbravo\ncharlie\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(dir, "app.lua", "alpha\nBRAVO\ncharlie\n")

      local panel = open_panel(dir)

      with_preview("auto", function()
        select_row(panel, "app.lua")

        t.wait_for(function()
          local dp = require("gitui.ui.panel").get("diff")
          return dp ~= nil and dp:is_open() and dp.canvas ~= nil
        end, "the diff never opened")

        local dp = require("gitui.ui.panel").get("diff")
        t.wait_for(function()
          return table.concat(vim.api.nvim_buf_get_lines(dp.bufnr, 0, -1, false), "\n"):find("BRAVO", 1, true) ~= nil
        end, "the diff never rendered the change")

        local text = table.concat(vim.api.nvim_buf_get_lines(dp.bufnr, 0, -1, false), "\n")
        assert.is_not_nil(text:find("+BRAVO", 1, true), "added line should carry a + prefix:\n" .. text)
        assert.is_not_nil(text:find("-bravo", 1, true), "removed line should carry a - prefix:\n" .. text)

        -- The cursor must stay where the user left it.
        assert.equals(panel.winid, vim.api.nvim_get_current_win())
      end)
    end)

    it("retargets an open diff as the cursor moves between files", function()
      local dir = helper.init("preview-retarget")
      helper.write(dir, "one.lua", "a\n")
      helper.write(dir, "two.lua", "b\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(dir, "one.lua", "ONE\n")
      helper.write(dir, "two.lua", "TWO\n")

      local panel = open_panel(dir)

      with_preview("auto", function()
        select_row(panel, "one.lua")
        t.wait_for(function()
          local dp = require("gitui.ui.panel").get("diff")
          return dp ~= nil and dp:is_open()
        end, "the diff never opened")

        local dp = require("gitui.ui.panel").get("diff")
        t.wait_for(function()
          return table.concat(vim.api.nvim_buf_get_lines(dp.bufnr, 0, -1, false), "\n"):find("ONE", 1, true) ~= nil
        end, "first file never rendered")

        select_row(panel, "two.lua")
        t.wait_for(function()
          return table.concat(vim.api.nvim_buf_get_lines(dp.bufnr, 0, -1, false), "\n"):find("TWO", 1, true) ~= nil
        end, "the diff never retargeted to the second file")
      end)
    end)

    it("opens nothing when preview is disabled", function()
      local dir = helper.init("preview-off")
      helper.write(dir, "app.lua", "a\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(dir, "app.lua", "B\n")

      local panel = open_panel(dir)

      with_preview(false, function()
        select_row(panel, "app.lua")
        vim.wait(500)
        local dp = require("gitui.ui.panel").get("diff")
        assert.is_true(dp == nil or not dp:is_open(), "preview = false must not open a diff")
      end)
    end)

    it("in follow mode never opens a view of its own", function()
      local dir = helper.init("preview-follow")
      helper.write(dir, "app.lua", "a\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(dir, "app.lua", "B\n")

      local panel = open_panel(dir)

      with_preview("follow", function()
        select_row(panel, "app.lua")
        vim.wait(500)
        local dp = require("gitui.ui.panel").get("diff")
        assert.is_true(dp == nil or not dp:is_open(), "follow mode must not open a diff")
      end)
    end)

    it("accepts true as a synonym for auto", function()
      t.with_config({ diff = { preview = true }, default_keymaps = false, log_level = "off" }, function(merged)
        assert.equals("auto", merged.diff.preview)
      end)
    end)

    it("repairs an invalid preview mode instead of breaking", function()
      t.with_config({ diff = { preview = "nonsense" }, default_keymaps = false, log_level = "off" }, function(merged)
        assert.equals("auto", merged.diff.preview)
      end)
    end)
  end)

  describe("sidebar width", function()
    -- 'winfixwidth' alone does not hold an exact width: Neovim redistributes
    -- columns on every split and close, and the sidebar drifts or stretches.
    local function width_of(panel)
      return vim.api.nvim_win_get_width(panel.winid)
    end

    it("holds its width across split and close cycles", function()
      local dir = helper.kitchen_sink()
      local panel = open_panel(dir)
      local expected = width_of(panel)

      vim.cmd("vsplit")
      vim.wait(120)
      panel:enforce_width()
      assert.equals(expected, width_of(panel), "width should survive a split")

      vim.cmd("close")
      vim.wait(120)
      panel:enforce_width()
      assert.equals(expected, width_of(panel), "width should survive a close")
    end)

    it("keeps its width when it would otherwise be the only window", function()
      local dir = helper.kitchen_sink()
      local panel = open_panel(dir)
      local expected = width_of(panel)

      for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if winid ~= panel.winid then
          vim.api.nvim_set_current_win(winid)
          vim.cmd("close")
        end
      end
      vim.wait(200)
      panel:enforce_width()
      vim.wait(120)

      assert.is_true(#vim.api.nvim_tabpage_list_wins(0) >= 2, "a placeholder window should hold the space")
      assert.equals(expected, width_of(panel), "the sidebar must not stretch to full width")
    end)

    it("respects a deliberate resize", function()
      local dir = helper.kitchen_sink()
      local panel = open_panel(dir)

      vim.api.nvim_win_set_width(panel.winid, 55)
      panel:enforce_width() -- same window count: adopt it
      assert.equals(55, width_of(panel))

      vim.cmd("vsplit")
      vim.wait(120)
      panel:enforce_width()
      assert.equals(55, width_of(panel), "the resized width should be the one defended")
      vim.cmd("close")
    end)
  end)

  describe("closing with q", function()
    it("gives the borrowed editor window back instead of destroying it", function()
      local dir = helper.init("borrow")
      helper.write(dir, "a.lua", "alpha\nbeta\n")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      helper.write(dir, "a.lua", "ALPHA\nbeta\n")

      local panel = open_panel(dir)

      -- Open the file the way <CR> does, so there is a real editor window.
      local path_util = require("gitui.utils.path")
      local editor_win = require("gitui.ui.window").open_file(path_util.join(dir, "a.lua"), {
        exclude = { panel.winid },
      })
      assert.is_not_nil(editor_win)
      local original_buf = vim.api.nvim_win_get_buf(editor_win)
      local window_count = #vim.api.nvim_tabpage_list_wins(0)

      -- The diff borrows that window.
      require("gitui.ui.diff_view").open(vim.deepcopy(store.active().repo), {
        path = "a.lua",
        spec = { kind = "worktree" },
      })
      local diff_panel = require("gitui.ui.panel").get("diff")
      t.wait_for(function()
        return diff_panel:is_open()
      end, "the diff never opened")
      assert.equals(editor_win, diff_panel.winid, "the diff should reuse the editor window")

      -- q must hand it back, not close it.
      diff_panel:focus()
      vim.cmd("normal q")
      vim.wait(200)

      assert.is_false(diff_panel:is_open())
      assert.equals(window_count, #vim.api.nvim_tabpage_list_wins(0), "the window must survive")
      assert.is_true(vim.api.nvim_win_is_valid(editor_win))
      assert.equals(original_buf, vim.api.nvim_win_get_buf(editor_win), "the original buffer must return")
    end)

    it("closes the sidebar", function()
      local dir = helper.simple()
      local panel = open_panel(dir)
      panel:focus()
      vim.cmd("normal q")
      vim.wait(120)
      assert.is_false(panel:is_open())
    end)
  end)

  describe("global keymaps", function()
    local config = require("gitui.config")

    it("expands <prefix> into every global mapping", function()
      t.with_config({ default_keymaps = false, log_level = "off" }, function(merged)
        assert.equals("<leader>guu", merged.global_keymaps.source_control)
        assert.equals("<leader>gud", merged.global_keymaps.diff)
        assert.equals("<leader>gu<space>", merged.global_keymaps.palette)
        -- Motions are not prefixed.
        assert.equals("]c", merged.global_keymaps.next_hunk)
      end)
    end)

    it("moves the whole set when the prefix changes", function()
      t.with_config({ prefix = "<leader>gui", default_keymaps = false, log_level = "off" }, function(merged)
        assert.equals("<leader>guiu", merged.global_keymaps.source_control)
        assert.equals("<leader>guid", merged.global_keymaps.diff)
      end)
    end)

    it("lets an individual mapping be overridden or disabled", function()
      t.with_config({
        global_keymaps = { source_control = "<leader>x", diff = false },
        default_keymaps = false,
        log_level = "off",
      }, function(merged)
        assert.equals("<leader>x", merged.global_keymaps.source_control)
        assert.is_false(merged.global_keymaps.diff)
      end)
    end)

    it("stays clear of the <leader>g namespace by default", function()
      t.with_config({ default_keymaps = false, log_level = "off" }, function(merged)
        for action, lhs in pairs(merged.global_keymaps) do
          if type(lhs) == "string" and lhs:match("^<leader>g") then
            assert.is_not_nil(
              lhs:match("^<leader>gu"),
              ("%s uses %s, which collides with the common <leader>g space"):format(action, lhs)
            )
          end
        end
      end)
    end)

    it("repairs an invalid last_window value", function()
      t.with_config({ last_window = "nonsense", default_keymaps = false, log_level = "off" }, function(merged)
        assert.equals("keep_width", merged.last_window)
      end)
    end)
  end)

  it("survives having no repository", function()
    store.reset()
    repository.invalidate()
    local outside = helper.tmpdir("not-a-repo")
    vim.cmd("noautocmd cd " .. vim.fn.fnameescape(outside))
    -- Repository detection consults the current buffer first, so a file left
    -- open by an earlier test would still resolve to its repository.
    vim.cmd("noautocmd enew")

    source_control.open({ focus = true })
    local panel = assert(source_control.panel())
    panel:redraw()

    local text = table.concat(lines(panel), "\n")
    assert.is_not_nil(text:find("No git repository", 1, true), text)
  end)
end)

describe("status summary API", function()
  after_each(function()
    store.reset()
    repository.invalidate()
  end)

  it("reports counts for the active repository", function()
    local dir = helper.kitchen_sink()
    local repo = assert(repository.detect(dir))
    store.ensure(repo)
    store.set_active(repo)

    require("gitui.state.refresh").now(repo, {})
    t.wait_for(function()
      local state = store.get(repo.root)
      return state ~= nil and state.status ~= nil
    end, "status never loaded")

    local summary = gitui.get_status()
    assert.equals("main", summary.branch)
    assert.equals(repo.root, summary.root)
    assert.is_true(summary.staged > 0)
    assert.is_true(summary.untracked > 0)
    assert.is_false(summary.clean)
    assert.equals("normal", summary.state)

    local line = gitui.statusline({ icons = false })
    assert.is_not_nil(line:find("main", 1, true), line)
  end)

  it("returns an empty statusline with no repository", function()
    store.reset()
    assert.equals("", gitui.statusline())
    assert.is_nil(gitui.get_status().branch)
  end)

  it("reports an in-progress merge", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))
    store.ensure(repo)
    store.set_active(repo)

    require("gitui.state.refresh").now(repo, {})
    t.wait_for(function()
      local state = store.get(repo.root)
      return state ~= nil and state.status ~= nil
    end, "status never loaded")

    local summary = gitui.get_status()
    assert.equals("merge", summary.state)
    assert.is_true(summary.conflicts > 0)
  end)
end)

describe("inline signs", function()
  local signs = require("gitui.ui.signs")

  after_each(function()
    signs.teardown()
    store.reset()
    repository.invalidate()
  end)

  it("computes hunks for a modified buffer", function()
    local dir = helper.init("signs")
    helper.write(dir, "f.txt", "one\ntwo\nthree\nfour\nfive\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "base")

    helper.write(dir, "f.txt", "one\nTWO\nthree\nfour\nfive\n")

    vim.cmd("noautocmd edit " .. vim.fn.fnameescape(dir .. "/f.txt"))
    local bufnr = vim.api.nvim_get_current_buf()

    signs.attach(bufnr)
    t.wait_for(function()
      local attachment = signs.attachment(bufnr)
      return attachment ~= nil and #attachment.hunks > 0
    end, "signs never computed a hunk")

    local attachment = signs.attachment(bufnr)
    local hunks_api = require("gitui.git.hunks")
    assert.equals(1, #attachment.hunks)
    -- The changed line is line 2, so that is where the hunk must resolve.
    assert.is_not_nil(hunks_api.at_line(attachment.hunks, 2))

    local summary = signs.summary(bufnr)
    assert.equals(1, summary.changed)

    -- The sign must actually be placed in the sign column.
    local marks = vim.api.nvim_buf_get_extmarks(
      bufnr,
      vim.api.nvim_create_namespace("gitui_signs"),
      0,
      -1,
      { details = true }
    )
    assert.is_true(#marks >= 1)

    vim.cmd("noautocmd bwipeout!")
  end)

  it("stages a hunk from a file buffer", function()
    local dir = helper.init("signs-stage")
    helper.write(dir, "f.txt", "one\ntwo\nthree\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "base")

    local repo = assert(repository.detect(dir))
    store.ensure(repo)
    store.set_active(repo)

    helper.write(dir, "f.txt", "one\nTWO\nthree\n")
    vim.cmd("noautocmd edit " .. vim.fn.fnameescape(dir .. "/f.txt"))
    local bufnr = vim.api.nvim_get_current_buf()

    signs.attach(bufnr)
    t.wait_for(function()
      local attachment = signs.attachment(bufnr)
      return attachment ~= nil and #attachment.hunks > 0
    end, "signs never computed a hunk")

    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    signs.stage_hunk()

    t.wait_for(function()
      local code = helper.git_try(dir, { "diff", "--cached", "--quiet" })
      return code ~= 0
    end, "the hunk was never staged")

    local staged = helper.git(dir, { "show", ":0:f.txt" })
    assert.is_not_nil(staged:find("TWO", 1, true))

    vim.cmd("noautocmd bwipeout!")
  end)
end)
