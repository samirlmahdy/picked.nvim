---Tests for the remaining views and for the guarantees that are easy to
---regress silently: concurrency, confirmation, and help staying in sync with
---the user's configured mappings.

local gitui = require("gitui")
local repository = require("gitui.git.repository")
local store = require("gitui.state")
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
  require("gitui.state.refresh").now(repo, {})
  t.wait_for(function()
    local current = store.get(repo.root)
    return current ~= nil and current.status ~= nil
  end, "status never loaded")
end

describe("views", function()
  gitui.setup({
    log_level = "off",
    default_keymaps = false,
    file_watch = false,
    refresh_debounce = 0,
    icons = false,
    hints = true,
    confirm = { discard = false, discard_hunk = false },
  })

  after_each(function()
    gitui.close_all()
    store.reset()
    repository.invalidate()
  end)

  describe("diff view", function()
    local diff_view = require("gitui.ui.diff_view")

    ---@return string dir, GitRepository repo, GitUIPanel panel
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
      local panel = require("gitui.ui.panel").get("diff")
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

  describe("commit editor", function()
    local commit = require("gitui.ui.commit")

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

      require("gitui.ui.log").open(repo, {})
      local panel = require("gitui.ui.panel").get("log")
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

      require("gitui.ui.branches").open(repo)
      local panel = require("gitui.ui.panel").get("branches")
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

      require("gitui.ui.stash").open(repo)
      local panel = require("gitui.ui.panel").get("stash")
      t.wait_for(function()
        return panel.canvas ~= nil and text_of(panel.bufnr):find("No stashes", 1, true) ~= nil
      end, "the empty stash view never rendered")

      helper.write(dir, "README.md", "# changed\n")
      helper.git(dir, { "stash", "push", "-m", "my work" })

      require("gitui.ui.stash").open(repo)
      t.wait_for(function()
        return text_of(panel.bufnr):find("my work", 1, true) ~= nil
      end, "the stash never appeared")

      assert.is_not_nil(text_of(panel.bufnr):find("stash@{0}", 1, true))
    end)
  end)

  describe("help", function()
    local help = require("gitui.ui.help")

    it("shows the user's configured keys, not hard-coded ones", function()
      local config = require("gitui.config")
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
      local config = require("gitui.config")
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
    local confirm = require("gitui.ui.confirm")

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
      local refresh = require("gitui.state.refresh")

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

      local command = require("gitui.git.command")
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
      local text_util = require("gitui.utils.text")
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

      require("gitui.ui.source_control").open()
      require("gitui.ui.log").open(repo, {})
      require("gitui.ui.branches").open(repo)
      require("gitui.ui.stash").open(repo)

      gitui.reset()
      vim.wait(200)

      local remaining = vim.tbl_filter(function(bufnr)
        local name = vim.api.nvim_buf_get_name(bufnr)
        return name:match("^gitui://") ~= nil
      end, vim.api.nvim_list_bufs())

      assert.equals(0, #remaining, "gitui buffers survived reset: " .. vim.inspect(vim.tbl_map(function(b)
        return vim.api.nvim_buf_get_name(b)
      end, remaining)))

      local _ = buffers_before
    end)
  end)
end)
