local diff_api = require("picked.git.diff")
local hunks_api = require("picked.git.hunks")
local repository = require("picked.git.repository")
local staging = require("picked.git.staging")
local t = require("tests.helpers")
local helper = t.repo

---Unstaged (index -> working tree) hunks for a path.
---@param repo GitRepository
---@param path string
---@return GitHunk[]
local function worktree_hunks(repo, path)
  local diff = t.ok(function(done)
    diff_api.file(repo, path, { kind = "worktree" }, nil, done)
  end)
  return diff.hunks
end

---Staged (HEAD -> index) hunks for a path.
---@param repo GitRepository
---@param path string
---@return GitHunk[]
local function index_hunks(repo, path)
  local diff = t.ok(function(done)
    diff_api.file(repo, path, { kind = "index" }, nil, done)
  end)
  return diff.hunks
end

---Content of a path in the index.
---@param repo GitRepository
---@param path string
---@return string
local function index_content(repo, path)
  local content = t.ok(function(done)
    diff_api.index_blob(repo, path, done)
  end)
  return content
end

---@param fn fun(done: fun(ok: boolean, err: GitError|nil))
local function apply(fn)
  local ok, err = t.await(fn)
  if not ok then
    error(("staging operation failed: %s — %s"):format(err and err.title or "?", err and err.reason or ""), 2)
  end
end

-- Twenty lines keeps two edits far enough apart that git emits two separate
-- hunks rather than merging their context regions into one.
local NUMBERS = {}
for i = 1, 20 do
  NUMBERS[i] = "line " .. i
end
local BASE = table.concat(NUMBERS, "\n") .. "\n"

---Repository with `file.txt` committed as BASE.
---@return string dir, GitRepository repo
local function base_repo(label)
  local dir = helper.init(label)
  helper.write(dir, "file.txt", BASE)
  helper.git(dir, { "add", "-A" })
  helper.commit(dir, "base")
  return dir, assert(repository.detect(dir))
end

describe("staging", function()
  describe("whole files", function()
    it("stages, unstages and discards a modification", function()
      local dir, repo = base_repo("stage-file")
      helper.write(dir, "file.txt", BASE:gsub("line 3", "LINE THREE"))

      apply(function(done)
        staging.stage(repo, { "file.txt" }, done)
      end)
      assert.is_not_nil(index_content(repo, "file.txt"):find("LINE THREE", 1, true))

      apply(function(done)
        staging.unstage(repo, { "file.txt" }, done)
      end)
      assert.is_nil(index_content(repo, "file.txt"):find("LINE THREE", 1, true))

      apply(function(done)
        staging.discard_worktree(repo, { "file.txt" }, done)
      end)
      assert.equals(BASE, helper.read(dir, "file.txt"))
    end)

    it("stages a deletion", function()
      local dir, repo = base_repo("stage-delete")
      helper.remove(dir, "file.txt")
      apply(function(done)
        staging.stage(repo, { "file.txt" }, done)
      end)
      local code = helper.git_try(dir, { "cat-file", "-e", ":0:file.txt" })
      assert.is_not_equal(0, code)
    end)

    it("stages an untracked file", function()
      local dir, repo = base_repo("stage-untracked")
      helper.write(dir, "brand-new.txt", "hello\n")
      apply(function(done)
        staging.stage(repo, { "brand-new.txt" }, done)
      end)
      assert.equals("hello\n", index_content(repo, "brand-new.txt"))
    end)

    it("handles paths containing spaces and unicode", function()
      local dir, repo = base_repo("stage-awkward")
      helper.write(dir, "a file with spaces.txt", "content\n")
      helper.write(dir, "ünïcode ✓.txt", "content\n")
      apply(function(done)
        staging.stage(repo, { "a file with spaces.txt", "ünïcode ✓.txt" }, done)
      end)
      assert.equals("content\n", index_content(repo, "a file with spaces.txt"))
      assert.equals("content\n", index_content(repo, "ünïcode ✓.txt"))
    end)

    it("removes untracked files with clean, and previews first", function()
      local dir, repo = base_repo("clean")
      helper.write(dir, "junk.txt", "junk\n")

      local preview = t.ok(function(done)
        staging.clean_preview(repo, { paths = { "junk.txt" } }, done)
      end)
      assert.same({ "junk.txt" }, preview)

      apply(function(done)
        staging.delete_untracked(repo, { "junk.txt" }, done)
      end)
      assert.is_nil(helper.read(dir, "junk.txt"))
    end)

    it("unstages on an unborn branch", function()
      local dir = helper.init("unborn")
      helper.write(dir, "first.txt", "hi\n")
      helper.git(dir, { "add", "-A" })
      local repo = assert(repository.detect(dir))

      apply(function(done)
        staging.unstage(repo, { "first.txt" }, done)
      end)
      local code = helper.git_try(dir, { "cat-file", "-e", ":0:first.txt" })
      assert.is_not_equal(0, code)
      -- the file itself must survive
      assert.equals("hi\n", helper.read(dir, "first.txt"))
    end)
  end)

  describe("hunk granularity", function()
    it("stages only the selected hunk", function()
      local dir, repo = base_repo("stage-hunk")
      local modified = BASE:gsub("line 2\n", "LINE TWO\n"):gsub("line 18\n", "LINE EIGHTEEN\n")
      helper.write(dir, "file.txt", modified)

      local hunks = worktree_hunks(repo, "file.txt")
      assert.equals(2, #hunks)

      apply(function(done)
        staging.stage_hunks(repo, "file.txt", { hunks[1] }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_not_nil(staged:find("LINE TWO", 1, true), "first hunk should be staged")
      assert.is_nil(staged:find("LINE EIGHTEEN", 1, true), "second hunk should not be staged")
      -- the working tree keeps both changes
      assert.equals(modified, helper.read(dir, "file.txt"))
    end)

    it("stages the second hunk alone, with correct offsets", function()
      local dir, repo = base_repo("stage-hunk2")
      local modified = BASE:gsub("line 2\n", "LINE TWO\nEXTRA\n"):gsub("line 18\n", "LINE EIGHTEEN\n")
      helper.write(dir, "file.txt", modified)

      local hunks = worktree_hunks(repo, "file.txt")
      assert.equals(2, #hunks)

      apply(function(done)
        staging.stage_hunks(repo, "file.txt", { hunks[2] }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_nil(staged:find("LINE TWO", 1, true))
      assert.is_not_nil(staged:find("LINE EIGHTEEN", 1, true))
    end)

    it("unstages a single hunk", function()
      local dir, repo = base_repo("unstage-hunk")
      helper.write(dir, "file.txt", BASE:gsub("line 2\n", "LINE TWO\n"):gsub("line 18\n", "LINE EIGHTEEN\n"))
      apply(function(done)
        staging.stage(repo, { "file.txt" }, done)
      end)

      local staged_hunks = index_hunks(repo, "file.txt")
      assert.equals(2, #staged_hunks)

      apply(function(done)
        staging.unstage_hunks(repo, "file.txt", { staged_hunks[1] }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_nil(staged:find("LINE TWO", 1, true), "first hunk should be unstaged")
      assert.is_not_nil(staged:find("LINE EIGHTEEN", 1, true), "second hunk should remain staged")
    end)

    it("discards a single working-tree hunk without touching the index", function()
      local dir, repo = base_repo("discard-hunk")
      helper.write(dir, "file.txt", BASE:gsub("line 2\n", "LINE TWO\n"):gsub("line 18\n", "LINE EIGHTEEN\n"))

      local hunks = worktree_hunks(repo, "file.txt")
      apply(function(done)
        staging.discard_hunks(repo, "file.txt", { hunks[1] }, nil, done)
      end)

      local content = helper.read(dir, "file.txt")
      assert.is_nil(content:find("LINE TWO", 1, true), "first hunk should be discarded")
      assert.is_not_nil(content:find("LINE EIGHTEEN", 1, true), "second hunk should survive")
      -- the index was never staged, so it still matches HEAD
      assert.equals(BASE, index_content(repo, "file.txt"))
    end)

    it("refuses a patch that no longer matches", function()
      local dir, repo = base_repo("stale-patch")
      helper.write(dir, "file.txt", BASE:gsub("line 2\n", "LINE TWO\n"))
      local hunks = worktree_hunks(repo, "file.txt")

      -- The *index* moves underneath us before the patch is applied. A patch
      -- built against the old index can no longer be located in the new one,
      -- and git must refuse rather than force-fit it.
      helper.write(dir, "file.txt", "completely different\n")
      helper.git(dir, { "add", "file.txt" })

      local ok, err = t.await(function(done)
        staging.stage_hunks(repo, "file.txt", hunks, nil, done)
      end)
      assert.is_false(ok)
      assert.is_not_nil(err)
      assert.equals("patch_stale", err.kind)
      assert.is_not_nil(err.hint)
    end)
  end)

  describe("line granularity", function()
    it("stages one line out of several changed lines", function()
      local dir, repo = base_repo("stage-lines")
      local modified = BASE:gsub("line 4\nline 5\nline 6\n", "FOUR\nFIVE\nSIX\n")
      helper.write(dir, "file.txt", modified)

      local hunks = worktree_hunks(repo, "file.txt")
      assert.equals(1, #hunks)

      -- Stage only buffer line 5 ("FIVE").
      local partial = assert(hunks_api.select_range(hunks[1], 5, 5))
      apply(function(done)
        staging.stage_hunks(repo, "file.txt", { partial }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_not_nil(staged:find("FIVE", 1, true), "selected line should be staged")
      assert.is_nil(staged:find("FOUR", 1, true), "unselected line should not be staged")
      assert.is_nil(staged:find("SIX", 1, true), "unselected line should not be staged")
      -- the other original lines must survive in the index
      assert.is_not_nil(staged:find("line 4", 1, true))
      assert.is_not_nil(staged:find("line 6", 1, true))
    end)

    it("stages a single added line", function()
      local dir, repo = base_repo("stage-added-line")
      helper.write(dir, "file.txt", BASE:gsub("line 5\n", "line 5\nNEW A\nNEW B\n"))

      local hunks = worktree_hunks(repo, "file.txt")
      local partial = assert(hunks_api.select_range(hunks[1], 6, 6)) -- "NEW A"
      apply(function(done)
        staging.stage_hunks(repo, "file.txt", { partial }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_not_nil(staged:find("NEW A", 1, true))
      assert.is_nil(staged:find("NEW B", 1, true))
    end)

    it("stages a single deleted line", function()
      local dir, repo = base_repo("stage-deleted-line")
      helper.write(dir, "file.txt", BASE:gsub("line 4\nline 5\n", ""))

      local hunks = worktree_hunks(repo, "file.txt")
      -- Both deletions are anchored to new-side line 4 (what is now "line 6").
      local indices = hunks_api.body_indices_for_range(hunks[1], 4, 4)
      -- Keep only the first deletion.
      local first_deletion = nil
      for index in pairs(indices) do
        if not first_deletion or index < first_deletion then
          first_deletion = index
        end
      end
      local partial = assert(hunks_api.select_body(hunks[1], { [first_deletion] = true }))

      apply(function(done)
        staging.stage_hunks(repo, "file.txt", { partial }, nil, done)
      end)

      local staged = index_content(repo, "file.txt")
      assert.is_nil(staged:find("line 4\n", 1, true), "selected deletion should be staged")
      assert.is_not_nil(staged:find("line 5\n", 1, true), "unselected deletion should remain")
    end)
  end)

  describe("awkward content", function()
    it("stages a hunk in a file without a trailing newline", function()
      local dir = helper.init("no-eol")
      helper.write(dir, "file.txt", "alpha\nbeta\ngamma")
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      local repo = assert(repository.detect(dir))

      helper.write(dir, "file.txt", "alpha\nBETA\ngamma")
      local hunks = worktree_hunks(repo, "file.txt")
      assert.is_true(#hunks >= 1)

      apply(function(done)
        staging.stage_hunks(repo, "file.txt", hunks, nil, done)
      end)
      assert.equals("alpha\nBETA\ngamma", index_content(repo, "file.txt"))
    end)

    it("stages a hunk in a file whose name contains a space", function()
      local dir = helper.init("spaced-hunk")
      helper.write(dir, "my file.txt", BASE)
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      local repo = assert(repository.detect(dir))

      helper.write(dir, "my file.txt", BASE:gsub("line 3\n", "THREE\n"))
      local hunks = worktree_hunks(repo, "my file.txt")
      apply(function(done)
        staging.stage_hunks(repo, "my file.txt", hunks, nil, done)
      end)
      assert.is_not_nil(index_content(repo, "my file.txt"):find("THREE", 1, true))
    end)

    it("stages a hunk in a file whose name contains a quote", function()
      local dir = helper.init("quoted-hunk")
      local name = 'say "hi".txt'
      helper.write(dir, name, BASE)
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      local repo = assert(repository.detect(dir))

      helper.write(dir, name, BASE:gsub("line 3\n", "THREE\n"))
      local hunks = worktree_hunks(repo, name)
      assert.is_true(#hunks >= 1)
      apply(function(done)
        staging.stage_hunks(repo, name, hunks, nil, done)
      end)
      assert.is_not_nil(index_content(repo, name):find("THREE", 1, true))
    end)

    it("partially stages a brand new file", function()
      local dir, repo = base_repo("partial-new")
      helper.write(dir, "fresh.txt", "alpha\nbeta\ngamma\n")

      -- An untracked file has no index entry, so the patch must declare it new.
      local computed = hunks_api.compute("", "alpha\nbeta\ngamma\n", { context = 3 })
      assert.equals(1, #computed)
      local partial = assert(hunks_api.select_range(computed[1], 1, 2))

      apply(function(done)
        staging.stage_hunks(repo, "fresh.txt", { partial }, { new_file = true }, done)
      end)

      assert.equals("alpha\nbeta\n", index_content(repo, "fresh.txt"))
      -- the working tree still has all three lines
      assert.equals("alpha\nbeta\ngamma\n", helper.read(dir, "fresh.txt"))
    end)

    it("preserves CRLF line endings through a partial stage", function()
      local dir = helper.init("crlf")
      local crlf_base = "one\r\ntwo\r\nthree\r\nfour\r\n"
      helper.write(dir, "file.txt", crlf_base)
      helper.git(dir, { "add", "-A" })
      helper.commit(dir, "base")
      local repo = assert(repository.detect(dir))

      helper.write(dir, "file.txt", "one\r\nTWO\r\nthree\r\nfour\r\n")
      local hunks = worktree_hunks(repo, "file.txt")
      apply(function(done)
        staging.stage_hunks(repo, "file.txt", hunks, nil, done)
      end)
      assert.equals("one\r\nTWO\r\nthree\r\nfour\r\n", index_content(repo, "file.txt"))
    end)
  end)
end)
