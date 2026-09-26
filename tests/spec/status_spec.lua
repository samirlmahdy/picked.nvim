local status = require("picked.git.status")
local repository = require("picked.git.repository")
local t = require("tests.helpers")
local helper = t.repo

describe("status parser", function()
  describe("pure parsing", function()
    it("reads branch headers", function()
      local raw = table.concat({
        "# branch.oid 1c0ffee1c0ffee1c0ffee1c0ffee1c0ffee1c0ff\0",
        "# branch.head feature/cart\0",
        "# branch.upstream origin/feature/cart\0",
        "# branch.ab +3 -2\0",
      })
      local result = status.parse(raw)
      assert.equals("1c0ffee1c0ffee1c0ffee1c0ffee1c0ffee1c0ff", result.branch.oid)
      assert.equals("feature/cart", result.branch.head)
      assert.equals("origin/feature/cart", result.branch.upstream)
      assert.equals(3, result.branch.ahead)
      assert.equals(2, result.branch.behind)
      assert.is_false(result.branch.detached)
      assert.is_true(result.clean)
    end)

    it("detects a detached head", function()
      local result = status.parse("# branch.oid abc\0# branch.head (detached)\0")
      assert.is_true(result.branch.detached)
      assert.is_nil(result.branch.head)
    end)

    it("detects an unborn branch", function()
      local result = status.parse("# branch.oid (initial)\0# branch.head main\0")
      assert.is_true(result.branch.unborn)
      assert.equals("main", result.branch.head)
    end)

    it("parses an ordinary entry", function()
      local raw = "1 .M N... 100644 100644 100644 aaaa bbbb src/foo.lua\0"
      local result = status.parse(raw)
      local entry = result.files[1]
      assert.equals("src/foo.lua", entry.path)
      assert.equals(" ", entry.index_status)
      assert.equals("M", entry.worktree_status)
      assert.equals(" M", entry.status)
      assert.is_false(entry.staged)
      assert.is_true(entry.unstaged)
      assert.equals(tonumber("100644", 8), entry.mode_worktree)
      assert.equals("aaaa", entry.oid_head)
    end)

    it("parses a staged-and-modified entry into both sections", function()
      local result = status.parse("1 MM N... 100644 100644 100644 aaaa bbbb foo.lua\0")
      assert.equals(1, #result.files)
      assert.equals(1, #result.staged)
      assert.equals(1, #result.unstaged)
      assert.equals("MM", result.files[1].status)
    end)

    it("parses a rename with its original path in the following field", function()
      local raw = "2 R. N... 100644 100644 100644 aaaa bbbb R100 new/name.lua\0old/name.lua\0"
      local result = status.parse(raw)
      assert.equals(1, #result.files)
      local entry = result.files[1]
      assert.equals("new/name.lua", entry.path)
      assert.equals("old/name.lua", entry.orig_path)
      assert.equals(100, entry.score)
      assert.equals("rename", entry.kind)
      assert.is_true(entry.staged)
    end)

    it("does not mistake a rename's original path for another entry", function()
      local raw = table.concat({
        "2 R. N... 100644 100644 100644 aaaa bbbb R100 b.lua\0a.lua\0",
        "1 .M N... 100644 100644 100644 cccc dddd c.lua\0",
      })
      local result = status.parse(raw)
      assert.equals(2, #result.files)
      local paths = vim.tbl_map(function(entry)
        return entry.path
      end, result.files)
      table.sort(paths)
      assert.same({ "b.lua", "c.lua" }, paths)
    end)

    it("parses unmerged entries with conflict labels", function()
      local raw = "u UU N... 100644 100644 100644 100644 a1 a2 a3 conflict.lua\0"
      local result = status.parse(raw)
      local entry = result.files[1]
      assert.is_true(entry.conflicted)
      assert.equals("UU", entry.status)
      assert.equals("both modified", entry.conflict_label)
      assert.equals(1, #result.conflicts)
      assert.is_false(entry.staged)
      assert.is_false(entry.unstaged)
      assert.is_false(result.clean)
    end)

    it("labels every unmerged combination", function()
      local cases = {
        DD = "both deleted",
        AU = "added by us",
        UD = "deleted by them",
        UA = "added by them",
        DU = "deleted by us",
        AA = "both added",
        UU = "both modified",
      }
      for code, label in pairs(cases) do
        local raw = ("u %s N... 100644 100644 100644 100644 a1 a2 a3 f.lua\0"):format(code)
        local entry = status.parse(raw).files[1]
        assert.equals(label, entry.conflict_label, "for code " .. code)
      end
    end)

    it("parses untracked and ignored entries", function()
      local result = status.parse("? new.lua\0! build/out.o\0")
      assert.equals(2, #result.files)
      assert.equals(1, #result.untracked)
      assert.equals(1, #result.ignored)
      assert.equals("new.lua", result.untracked[1].path)
      assert.equals("??", result.untracked[1].status)
      assert.equals("build/out.o", result.ignored[1].path)
    end)

    it("keeps awkward filenames byte-exact", function()
      local names = {
        "file with spaces.txt",
        'quote"name.txt',
        "back\\slash.txt",
        "tab\there.txt",
        "café/naïve-ünïcode.txt",
        "new\nline.txt",
        "emoji-🎉.txt",
      }
      local parts = {}
      for _, name in ipairs(names) do
        parts[#parts + 1] = "? " .. name .. "\0"
      end
      local result = status.parse(table.concat(parts))
      assert.equals(#names, #result.files)
      local seen = {}
      for _, entry in ipairs(result.files) do
        seen[entry.path] = true
      end
      for _, name in ipairs(names) do
        assert.is_true(seen[name] == true, "missing " .. vim.inspect(name))
      end
    end)

    it("recognises submodule entries", function()
      local raw = "1 .M SC.U 160000 160000 160000 aaaa bbbb external/library\0"
      local entry = status.parse(raw).files[1]
      assert.is_true(entry.submodule)
      assert.is_true(entry.submodule_state.commit)
      assert.is_false(entry.submodule_state.modified)
      assert.is_true(entry.submodule_state.untracked)
    end)

    it("ignores an empty or truncated stream", function()
      assert.equals(0, #status.parse("").files)
      assert.equals(0, #status.parse("\0\0").files)
      assert.equals(0, #status.parse("garbage without a marker\0").files)
    end)
  end)

  describe("against a real repository", function()
    local dir = helper.kitchen_sink()
    local repo = assert(repository.detect(dir))
    local result = t.ok(function(done)
      status.query(repo, nil, done)
    end)

    it("finds every expected entry", function()
      local function find(path)
        return result.by_path[path]
      end

      assert.equals(" M", find("modified.txt").status)
      assert.equals(" D", find("deleted.txt").status)
      assert.equals("M ", find("staged.txt").status)
      assert.equals("MM", find("mixed.txt").status)
      assert.equals("A ", find("src/models/user.lua").status)
      assert.equals("??", find("untracked.md").status)
      assert.is_nil(find("unchanged.txt"))
    end)

    it("reports the rename with its source", function()
      local entry = result.by_path["renamed-to.txt"]
      assert.is_not_nil(entry)
      assert.equals("renamed-from.txt", entry.orig_path)
      assert.equals("R", entry.index_status)
    end)

    it("handles filenames with spaces, quotes and unicode", function()
      assert.is_not_nil(result.by_path["untracked dir/new file.md"])
      assert.is_not_nil(result.by_path["ünträcked.md"])
    end)

    it("splits staged and unstaged sections correctly", function()
      local staged = {}
      for _, entry in ipairs(result.staged) do
        staged[entry.path] = true
      end
      assert.is_true(staged["staged.txt"])
      assert.is_true(staged["mixed.txt"])
      assert.is_true(staged["src/models/user.lua"])
      assert.is_nil(staged["modified.txt"])

      local unstaged = {}
      for _, entry in ipairs(result.unstaged) do
        unstaged[entry.path] = true
      end
      assert.is_true(unstaged["modified.txt"])
      assert.is_true(unstaged["mixed.txt"])
      assert.is_true(unstaged["deleted.txt"])
      assert.is_nil(unstaged["staged.txt"])
    end)

    it("reports the branch", function()
      assert.equals("main", result.branch.head)
      assert.is_false(result.branch.detached)
      assert.is_nil(result.branch.upstream)
    end)

    it("is not clean", function()
      assert.is_false(result.clean)
    end)
  end)

  describe("conflicted repository", function()
    it("reports unmerged paths", function()
      local dir = helper.conflicted()
      local repo = assert(repository.detect(dir))
      local result = t.ok(function(done)
        status.query(repo, nil, done)
      end)

      assert.is_true(#result.conflicts >= 1)
      local conflict = result.by_path["conflict.lua"]
      assert.is_not_nil(conflict)
      assert.is_true(conflict.conflicted)
      assert.equals("both modified", conflict.conflict_label)

      local both_added = result.by_path["both-added.txt"]
      assert.is_not_nil(both_added)
      assert.equals("both added", both_added.conflict_label)
    end)
  end)
end)
