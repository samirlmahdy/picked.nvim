---The acceptance workflow from the specification, executed end to end against
---a real repository and a real remote.
---
---Every step is the same code path a user's keystroke takes. If this file
---passes, the complete "open repo → stage → commit → branch → push → pull →
---inspect → stash → conflict → resolve" loop works without leaving Neovim.

local gitui = require("gitui")
local git = require("gitui.git")
local operations = require("gitui.operations")
local refresh = require("gitui.state.refresh")
local repository = require("gitui.git.repository")
local store = require("gitui.state")
local t = require("tests.helpers")
local helper = t.repo

---Force a fresh status read and wait for it to land.
---
---Waiting for the refresh callback alone is not enough: a concurrent refresh
---can supersede this one, in which case the answer arrives from the other
---query. Clearing the stored status first makes "a new status arrived"
---unambiguous, so a stale value can never be mistaken for a fresh one.
---@param repo GitRepository
local function sync(repo)
  local state = store.get(repo.root)
  if state then
    state.status = nil
  end
  store.invalidate(repo.root)
  refresh.now(repo, {})
  t.wait_for(function()
    local current = store.get(repo.root)
    return current ~= nil and current.status ~= nil
  end, "status never loaded for " .. repo.root)
end

---@param repo GitRepository
---@return GitStatusResult
local function status_of(repo)
  sync(repo)
  local state = assert(store.get(repo.root))
  return assert(state.status)
end

---Run an operation that ends in a store update and wait for it to land.
---@param repo GitRepository
---@param run fun()
---@param predicate fun(status: GitStatusResult): boolean
---@param message string
local function act(repo, run, predicate, message)
  run()
  t.wait_for(function()
    local state = store.get(repo.root)
    return state ~= nil and state.status ~= nil and predicate(state.status)
  end, message)
end

---@param repo GitRepository
local function activate(repo)
  store.ensure(repo)
  store.set_active(repo)
end

describe("the full git workflow", function()
  gitui.setup({
    log_level = "off",
    default_keymaps = false,
    file_watch = false,
    refresh_debounce = 0,
    icons = false,
    -- The workflow test drives destructive operations directly; the
    -- confirmation dialogs themselves are covered by their own tests.
    confirm = {
      discard = false,
      discard_hunk = false,
      reset_hard = false,
      force_push = false,
      branch_delete = false,
      stash_drop = false,
      clean = false,
      revert = false,
      push = false,
      pull = false,
    },
    remote = { pull_strategy = "merge" },
  })

  -- Prompts must never block a headless run; `""` accepts the default in
  -- every prompt this file reaches.
  local restore_input = t.stub_input("")

  after_each(function()
    store.reset()
    repository.invalidate()
  end)

  it("walks the complete loop against a real remote", function()
    local dir, remote_dir = helper.with_remote()
    local repo = assert(repository.detect(dir))
    activate(repo)

    --- See changed files -------------------------------------------------
    helper.write(dir, "app.lua", "local function run()\n  return 1\nend\n")
    helper.write(dir, "notes.md", "# notes\n")
    local status = status_of(repo)
    assert.equals(2, #status.untracked)

    --- Stage a file ------------------------------------------------------
    act(repo, function()
      operations.stage(repo, { "app.lua" })
    end, function(current)
      local entry = current.by_path["app.lua"]
      return entry ~= nil and entry.staged
    end, "app.lua never staged")

    --- View the staged diff ----------------------------------------------
    local staged_diff = t.ok(function(done)
      git.diff.file(repo, "app.lua", { kind = "index" }, nil, done)
    end)
    assert.is_true(#staged_diff.hunks > 0)
    assert.is_not_nil(staged_diff.raw:find("local function run", 1, true))

    --- Unstage it again --------------------------------------------------
    act(repo, function()
      operations.unstage(repo, { "app.lua" })
    end, function(current)
      local entry = current.by_path["app.lua"]
      return entry ~= nil and not entry.staged
    end, "app.lua never unstaged")

    --- Stage it once more and commit --------------------------------------
    act(repo, function()
      operations.stage(repo, { "app.lua" })
    end, function(current)
      return #current.staged == 1
    end, "app.lua never staged the second time")

    local committed = false
    operations.commit(repo, { message = "feat: add app\n\nWith a body." }, function(ok)
      committed = ok
    end)
    t.wait_for(function()
      return committed
    end, "commit never completed")

    --- Inspect the commit -------------------------------------------------
    local log = t.ok(function(done)
      git.commits.log(repo, { max_count = 5 }, done)
    end)
    assert.equals("feat: add app", log[1].subject)
    assert.is_not_nil(log[1].body:find("With a body", 1, true))

    local details = t.ok(function(done)
      git.diff.numstat(repo, { kind = "commit", from = log[1].oid }, done)
    end)
    assert.equals("app.lua", details[1].path)

    --- Create and switch to a branch ---------------------------------------
    assert.is_true(t.await(function(done)
      git.branches.create(repo, "feature/cart", { switch = true }, done)
    end))
    sync(repo)
    assert.equals("feature/cart", store.get(repo.root).head.branch)

    --- Modify, stage a single hunk, commit ----------------------------------
    helper.write(dir, "app.lua", "local function run()\n  return 2\nend\n")
    local worktree_diff = t.ok(function(done)
      git.diff.file(repo, "app.lua", { kind = "worktree" }, nil, done)
    end)
    assert.equals(1, #worktree_diff.hunks)

    act(repo, function()
      operations.stage_hunks(repo, "app.lua", worktree_diff.hunks, nil)
    end, function(current)
      local entry = current.by_path["app.lua"]
      return entry ~= nil and entry.staged
    end, "the hunk was never staged")

    committed = false
    operations.commit(repo, { message = "fix: return 2" }, function(ok)
      committed = ok
    end)
    t.wait_for(function()
      return committed
    end, "second commit never completed")

    --- Push the new branch --------------------------------------------------
    local pushed = nil
    git.remotes.push(repo, { remote = "origin", branch = "feature/cart", set_upstream = true }, function(result)
      pushed = result
    end)
    t.wait_for(function()
      return pushed ~= nil
    end, "push never returned")
    assert.is_true(pushed.ok, pushed.output)

    local remote_refs = helper.git(remote_dir, { "for-each-ref", "--format=%(refname)" })
    assert.is_not_nil(remote_refs:find("refs/heads/feature/cart", 1, true))

    --- Fetch ---------------------------------------------------------------
    local fetched = nil
    git.remotes.fetch(repo, { remote = "origin" }, function(result)
      fetched = result
    end)
    t.wait_for(function()
      return fetched ~= nil
    end, "fetch never returned")
    assert.is_true(fetched.ok, fetched.output)

    --- Pull (with a commit made elsewhere) ----------------------------------
    local other = helper.tmpdir("clone")
    helper.git(vim.fn.fnamemodify(other, ":h"), { "clone", "--quiet", remote_dir, other })
    helper.git(other, { "config", "user.name", "gitui test" })
    helper.git(other, { "config", "user.email", "test@gitui.invalid" })
    helper.git(other, { "checkout", "--quiet", "feature/cart" })
    helper.write(other, "remote-change.txt", "from elsewhere\n")
    helper.git(other, { "add", "-A" })
    helper.git(other, { "commit", "--quiet", "-m", "chore: remote change" })
    helper.git(other, { "push", "--quiet", "origin", "feature/cart" })

    local pulled = nil
    git.remotes.pull(repo, { remote = "origin", branch = "feature/cart" }, function(result)
      pulled = result
    end)
    t.wait_for(function()
      return pulled ~= nil
    end, "pull never returned")
    assert.is_true(pulled.ok, pulled.output)
    assert.equals("from elsewhere\n", helper.read(dir, "remote-change.txt"))

    --- Blame ----------------------------------------------------------------
    local blame = t.ok(function(done)
      git.blame.file(repo, "app.lua", nil, done)
    end)
    assert.is_not_nil(blame.lines[2])
    assert.equals("fix: return 2", blame.lines[2].commit.summary)

    --- File history ---------------------------------------------------------
    local history = t.ok(function(done)
      git.commits.file_history(repo, "app.lua", nil, done)
    end)
    local subjects = t.pluck(history, "subject")
    assert.is_true(vim.tbl_contains(subjects, "feat: add app"))
    assert.is_true(vim.tbl_contains(subjects, "fix: return 2"))

    --- Stash and restore ----------------------------------------------------
    helper.write(dir, "app.lua", "local function run()\n  return 3\nend\n")
    -- Observe the change first, so "app.lua disappeared" below genuinely means
    -- the stash happened rather than that it was never seen.
    assert.is_not_nil(status_of(repo).by_path["app.lua"])

    -- `stash_push` asks for a message through `vim.ui.input`, which the stub
    -- installed at the top of this file answers.
    act(repo, function()
      operations.stash_push(repo)
    end, function(current)
      return current.by_path["app.lua"] == nil
    end, "the stash never completed")

    local stashed = t.ok(function(done)
      git.stash.list(repo, done)
    end)
    assert.equals(1, #stashed)
    assert.is_not_nil(helper.read(dir, "app.lua"):find("return 2", 1, true))

    act(repo, function()
      operations.stash_restore(repo, stashed[1], "pop")
    end, function(current)
      return current.by_path["app.lua"] ~= nil
    end, "the stash was never popped")
    assert.is_not_nil(helper.read(dir, "app.lua"):find("return 3", 1, true))

    --- Remote links -----------------------------------------------------------
    local url = git.browse.url("git@github.com:owner/repo.git", {
      kind = "file",
      ref = "feature/cart",
      path = "app.lua",
      first = 2,
    })
    assert.equals("https://github.com/owner/repo/blob/feature/cart/app.lua#L2", url)

    restore_input()
  end)

  it("resolves a merge conflict end to end", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))
    activate(repo)

    local status = status_of(repo)
    assert.is_true(#status.conflicts >= 1)
    assert.equals("merge", store.get(repo.root).git_state.kind)

    --- Open the conflicted file and resolve it through the buffer ---------
    local conflict = require("gitui.ui.conflict")
    conflict.open(repo, "conflict.lua")

    local bufnr = vim.fn.bufnr(dir .. "/conflict.lua")
    assert.is_true(bufnr ~= -1, "the conflicted file should be open")

    local regions = git.conflicts.in_buffer(bufnr)
    assert.equals(1, #regions)
    assert.is_not_nil(regions[1].ours[1]:find("ours()", 1, true))
    assert.is_not_nil(regions[1].theirs[1]:find("theirs()", 1, true))

    assert.is_true(git.conflicts.resolve_in_buffer(bufnr, regions[1], "theirs"))
    assert.equals(0, #git.conflicts.in_buffer(bufnr))

    local resolved = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
    assert.is_not_nil(resolved:find("theirs()", 1, true))
    assert.is_nil(resolved:find("<<<<<<<", 1, true))

    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent write")
    end)

    --- Resolve the second conflicted file by taking a side ----------------
    assert.is_true(t.await(function(done)
      git.staging.checkout_side(repo, { "both-added.txt" }, "ours", done)
    end))

    --- Stage both as resolved, then commit the merge ----------------------
    act(repo, function()
      operations.mark_resolved(repo, { "conflict.lua", "both-added.txt" })
    end, function(current)
      return #current.conflicts == 0
    end, "conflicts were never marked resolved")

    local committed = false
    operations.commit(repo, { message = "merge: resolve conflicts" }, function(ok)
      committed = ok
    end)
    t.wait_for(function()
      return committed
    end, "the merge commit never completed")

    sync(repo)
    assert.equals("normal", store.get(repo.root).git_state.kind)

    local log = t.ok(function(done)
      git.commits.log(repo, { max_count = 1 }, done)
    end)
    assert.is_true(log[1].is_merge, "the resulting commit should have two parents")

    conflict.close()
    vim.cmd("noautocmd silent! bwipeout! " .. bufnr)
  end)

  it("aborts a merge cleanly", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))
    activate(repo)
    sync(repo)

    assert.is_true(t.await(function(done)
      git.branches.sequencer(repo, "merge", "abort", done)
    end))

    sync(repo)
    local state = store.get(repo.root)
    assert.equals("normal", state.git_state.kind)
    assert.equals(0, #state.status.conflicts)
  end)

  it("detects a detached HEAD", function()
    local dir = helper.simple()
    helper.write(dir, "second.txt", "two\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "second")

    local repo = assert(repository.detect(dir))
    helper.git(dir, { "checkout", "--quiet", "HEAD~1" })
    activate(repo)
    sync(repo)

    local state = store.get(repo.root)
    assert.is_true(state.head.detached)
    assert.is_nil(state.head.branch)

    local summary = gitui.get_status()
    assert.is_true(summary.detached)
    assert.is_not_nil(summary.branch, "a detached HEAD should still report its short oid")
  end)

  it("works inside a linked worktree", function()
    local dir = helper.simple()
    local worktree_dir = helper.tmpdir("linked") .. "/wt"
    helper.git(dir, { "worktree", "add", "-b", "wt-branch", worktree_dir })

    local repo = assert(repository.detect(worktree_dir))
    assert.is_true(repo.is_linked_worktree)
    assert.is_true(repo.git_dir ~= repo.common_dir)
    assert.equals(vim.uv.fs_realpath(worktree_dir), repo.root)

    activate(repo)
    helper.write(worktree_dir, "in-worktree.txt", "hello\n")
    local status = status_of(repo)
    assert.equals("wt-branch", status.branch.head)
    assert.is_not_nil(status.by_path["in-worktree.txt"])

    local worktrees = t.ok(function(done)
      repository.worktrees(repo, done)
    end)
    assert.is_true(#worktrees >= 2)
  end)

  it("reports an unborn branch without failing", function()
    local dir = helper.init("unborn-workflow")
    helper.write(dir, "first.txt", "hi\n")
    local repo = assert(repository.detect(dir))
    activate(repo)

    local status = status_of(repo)
    assert.is_true(status.branch.unborn)
    assert.equals(1, #status.untracked)

    local state = store.get(repo.root)
    assert.is_true(state.head.unborn)

    -- Committing on an unborn branch must work.
    assert.is_true(t.await(function(done)
      git.staging.stage(repo, { "first.txt" }, done)
    end))

    local committed = false
    operations.commit(repo, { message = "initial" }, function(ok)
      committed = ok
    end)
    t.wait_for(function()
      return committed
    end, "the initial commit never completed")

    sync(repo)
    assert.is_false(store.get(repo.root).head.unborn)
  end)
end)
