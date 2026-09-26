local branches = require("picked.git.branches")
local commits = require("picked.git.commits")
local remotes = require("picked.git.remotes")
local stash = require("picked.git.stash")
local conflicts = require("picked.git.conflicts")
local blame = require("picked.git.blame")
local browse = require("picked.git.browse")
local graph = require("picked.git.graph")
local repository = require("picked.git.repository")
local t = require("tests.helpers")
local helper = t.repo

describe("branches", function()
  it("parses local, remote and tag refs", function()
    local raw = table.concat({
      table.concat({
        "refs/heads/main",
        "aaa111",
        "*",
        "origin/main",
        "ahead 2, behind 1",
        "latest work",
        "Sam",
        "1767225600",
      }, "\0"),
      table.concat({ "refs/heads/feature/cart", "bbb222", " ", "", "", "wip", "Sam", "1767139200" }, "\0"),
      table.concat({ "refs/remotes/origin/main", "aaa111", " ", "", "", "latest work", "Sam", "1767225600" }, "\0"),
      table.concat({ "refs/tags/v1.0.0", "ccc333", " ", "", "", "release", "Sam", "1767052800" }, "\0"),
    }, "\n")

    local parsed = branches.parse(raw)
    assert.equals(4, #parsed)

    local main = parsed[1]
    assert.equals("main", main.name)
    assert.equals("local", main.kind)
    assert.is_true(main.is_head)
    assert.equals("origin/main", main.upstream)
    assert.equals(2, main.ahead)
    assert.equals(1, main.behind)
    assert.is_false(main.gone)

    assert.equals("feature/cart", parsed[2].name)
    assert.is_false(parsed[2].is_head)
    assert.is_nil(parsed[2].upstream)

    assert.equals("remote", parsed[3].kind)
    assert.equals("origin/main", parsed[3].name)
    assert.equals("origin", parsed[3].remote)

    assert.equals("tag", parsed[4].kind)
    assert.equals("v1.0.0", parsed[4].name)
  end)

  it("recognises a gone upstream", function()
    local raw = table.concat({ "refs/heads/old", "aaa", " ", "origin/old", "gone", "s", "a", "1" }, "\0")
    local parsed = branches.parse(raw)
    assert.is_true(parsed[1].gone)
    assert.equals(0, parsed[1].ahead)
  end)

  it("keeps slashes in remote branch names", function()
    local raw = table.concat({ "refs/remotes/origin/feature/deep/name", "a", " ", "", "", "s", "a", "1" }, "\0")
    local parsed = branches.parse(raw)
    assert.equals("origin/feature/deep/name", parsed[1].name)
    assert.equals("origin", parsed[1].remote)
  end)

  describe("name validation", function()
    it("accepts ordinary names", function()
      for _, name in ipairs({ "main", "feature/cart", "release-1.2", "user/fix_bug" }) do
        assert.is_true(branches.validate_name(name), name .. " should be valid")
      end
    end)

    it("rejects illegal names with an explanation", function()
      local bad = {
        "",
        "-dash",
        ".hidden",
        "has space",
        "a..b",
        "ends/",
        "/starts",
        "x.lock",
        "a@{b",
        "ctrl\tchar",
        "tilde~x",
        "caret^x",
        "colon:x",
        "star*x",
      }
      for _, name in ipairs(bad) do
        local ok, reason = branches.validate_name(name)
        assert.is_false(ok, vim.inspect(name) .. " should be rejected")
        assert.is_string(reason)
      end
    end)
  end)

  it("lists refs from a real repository", function()
    local dir = helper.simple()
    helper.git(dir, { "branch", "feature/one" })
    helper.git(dir, { "tag", "v0.1" })
    local repo = assert(repository.detect(dir))

    local list = t.ok(function(done)
      branches.list(repo, { tags = true }, done)
    end)

    local names = {}
    for _, branch in ipairs(list) do
      names[branch.kind .. ":" .. branch.name] = branch
    end
    assert.is_not_nil(names["local:main"])
    assert.is_not_nil(names["local:feature/one"])
    assert.is_not_nil(names["tag:v0.1"])
    assert.is_true(names["local:main"].is_head)
  end)
end)

describe("commits", function()
  it("parses a log record with a multi-line body", function()
    local unit = "\31"
    local record = table.concat({
      "a8f29d1c0ffee0000000000000000000000000000",
      "a8f29d1",
      "7d3f812 4a8d112",
      "Sam",
      "sam@example.com",
      "1767225600",
      "Committer",
      "c@example.com",
      "1767225700",
      "HEAD -> main, origin/main, tag: v1.0",
      "feat: add checkout API",
      "Body line one.\n\nBody line two.",
    }, unit) .. "\0"

    local parsed = commits.parse(record)
    assert.equals(1, #parsed)
    local commit = parsed[1]
    assert.equals("a8f29d1", commit.short)
    assert.same({ "7d3f812", "4a8d112" }, commit.parents)
    assert.is_true(commit.is_merge)
    assert.equals("Sam", commit.author_name)
    assert.equals(1767225600, commit.author_date)
    assert.equals("feat: add checkout API", commit.subject)
    assert.is_not_nil(commit.body:find("Body line two", 1, true))

    local kinds = {}
    for _, ref in ipairs(commit.refs) do
      kinds[ref.name] = ref.kind
    end
    assert.equals("head", kinds["HEAD"])
    assert.equals("branch", kinds["main"])
    assert.equals("remote", kinds["origin/main"])
    assert.equals("tag", kinds["v1.0"])
  end)

  it("reads real history", function()
    local dir = helper.simple()
    helper.write(dir, "second.txt", "two\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "second commit\n\nwith a body")
    local repo = assert(repository.detect(dir))

    local log = t.ok(function(done)
      commits.log(repo, { max_count = 10 }, done)
    end)
    assert.equals(2, #log)
    assert.equals("second commit", log[1].subject)
    assert.is_not_nil(log[1].body:find("with a body", 1, true))
    assert.equals("initial commit", log[2].subject)
    assert.equals(1, #log[1].parents)
    assert.equals(0, #log[2].parents)
  end)

  it("returns an empty history for an unborn branch", function()
    local dir = helper.init("unborn-log")
    local repo = assert(repository.detect(dir))
    local log = t.ok(function(done)
      commits.log(repo, nil, done)
    end)
    assert.equals(0, #log)
  end)

  it("follows a file across a rename", function()
    local dir = helper.simple()
    helper.write(dir, "before.txt", string.rep("stable\n", 20))
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "add before")
    helper.git(dir, { "mv", "before.txt", "after.txt" })
    helper.commit(dir, "rename it")
    local repo = assert(repository.detect(dir))

    local history = t.ok(function(done)
      commits.file_history(repo, "after.txt", nil, done)
    end)
    local subjects = t.pluck(history, "subject")
    assert.is_true(vim.tbl_contains(subjects, "rename it"))
    assert.is_true(vim.tbl_contains(subjects, "add before"), "history should follow the rename")
  end)

  it("reads line history", function()
    local dir = helper.init("line-history")
    helper.write(dir, "f.txt", "alpha\nbeta\ngamma\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "first")
    helper.write(dir, "f.txt", "alpha\nBETA\ngamma\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "change beta")
    local repo = assert(repository.detect(dir))

    local history = t.ok(function(done)
      commits.line_history(repo, "f.txt", 2, 2, nil, done)
    end)
    local subjects = t.pluck(history, "subject")
    assert.is_true(vim.tbl_contains(subjects, "change beta"))
  end)

  it("creates a commit from a message on stdin", function()
    local dir = helper.simple()
    helper.write(dir, "new.txt", "hi\n")
    helper.git(dir, { "add", "-A" })
    local repo = assert(repository.detect(dir))

    local ok, err = t.await(function(done)
      commits.commit(repo, { message = 'subject line\n\nbody with "quotes" and $shell `chars`\n' }, done)
    end)
    assert.is_true(ok, err and err.reason or "")

    local log = t.ok(function(done)
      commits.log(repo, { max_count = 1 }, done)
    end)
    assert.equals("subject line", log[1].subject)
    assert.is_not_nil(log[1].body:find("$shell", 1, true))
  end)

  it("refuses an empty commit message", function()
    local dir = helper.simple()
    local repo = assert(repository.detect(dir))
    local ok, err = t.await(function(done)
      commits.commit(repo, { message = "   \n\n" }, done)
    end)
    assert.is_false(ok)
    assert.equals("empty_message", err.kind)
  end)
end)

describe("remotes", function()
  it("parses config records", function()
    local raw = table.concat({
      "remote.origin.url\nhttps://github.com/owner/repo.git\0",
      "remote.origin.pushurl\nssh://git@github.com/owner/repo.git\0",
      "remote.upstream.url\ngit@gitlab.com:group/sub/project.git\0",
    })
    local parsed = remotes.parse(raw)
    assert.equals(2, #parsed)
    assert.equals("origin", parsed[1].name)
    assert.equals("https://github.com/owner/repo.git", parsed[1].fetch_url)
    assert.equals("ssh://git@github.com/owner/repo.git", parsed[1].push_url)
    assert.equals("upstream", parsed[2].name)
  end)

  it("reads remotes from a real repository", function()
    local dir, remote_dir = helper.with_remote()
    local repo = assert(repository.detect(dir))
    local list = t.ok(function(done)
      remotes.list(repo, done)
    end)
    assert.equals(1, #list)
    assert.equals("origin", list[1].name)
    assert.equals(remote_dir, list[1].fetch_url)
  end)

  it("reports no remotes without failing", function()
    local dir = helper.simple()
    local repo = assert(repository.detect(dir))
    local list = t.ok(function(done)
      remotes.list(repo, done)
    end)
    assert.equals(0, #list)
  end)
end)

describe("stash", function()
  it("parses a stash list", function()
    local unit = "\31"
    local raw = table.concat({
      table.concat({ "stash@{0}", "aaa111", "1767225600", "WIP on main: 1a2b3c earlier commit" }, unit) .. "\0",
      table.concat({ "stash@{1}", "bbb222", "1767139200", "On feature: my own note" }, unit) .. "\0",
    })
    local parsed = stash.parse(raw)
    assert.equals(2, #parsed)
    assert.equals(0, parsed[1].index)
    assert.equals("main", parsed[1].branch)
    assert.equals("earlier commit", parsed[1].message)
    assert.equals("feature", parsed[2].branch)
    assert.equals("my own note", parsed[2].message)
  end)

  it("round-trips through a real repository", function()
    local dir = helper.simple()
    local repo = assert(repository.detect(dir))
    helper.write(dir, "README.md", "# project changed\n")

    local ok = t.await(function(done)
      stash.push(repo, { message = "my stash" }, done)
    end)
    assert.is_true(ok)
    assert.equals("# project\n", helper.read(dir, "README.md"))

    local list = t.ok(function(done)
      stash.list(repo, done)
    end)
    assert.equals(1, #list)
    assert.equals("my stash", list[1].message)

    assert.is_true(t.await(function(done)
      stash.pop(repo, list[1].selector, nil, done)
    end))
    assert.equals("# project changed\n", helper.read(dir, "README.md"))
  end)

  it("reports nothing to stash", function()
    local dir = helper.simple()
    local repo = assert(repository.detect(dir))
    local ok, err = t.await(function(done)
      stash.push(repo, nil, done)
    end)
    assert.is_false(ok)
    assert.equals("nothing_to_stash", err.kind)
  end)
end)

describe("conflicts", function()
  it("parses merge-style markers", function()
    local text = table.concat({
      "before",
      "<<<<<<< HEAD",
      "ours line one",
      "ours line two",
      "=======",
      "theirs line",
      ">>>>>>> feature/payment",
      "after",
    }, "\n")

    local regions = conflicts.parse(text)
    assert.equals(1, #regions)
    local region = regions[1]
    assert.equals("HEAD", region.ours_label)
    assert.equals("feature/payment", region.theirs_label)
    assert.same({ "ours line one", "ours line two" }, region.ours)
    assert.same({ "theirs line" }, region.theirs)
    assert.is_nil(region.base)
    assert.equals(2, region.ours_start)
    assert.equals(7, region.theirs_end)
  end)

  it("parses diff3-style markers including the base", function()
    local text = table.concat({
      "<<<<<<< ours",
      "mine",
      "||||||| base",
      "original",
      "=======",
      "yours",
      ">>>>>>> theirs",
    }, "\n")

    local region = conflicts.parse(text)[1]
    assert.same({ "mine" }, region.ours)
    assert.same({ "original" }, region.base)
    assert.same({ "yours" }, region.theirs)
  end)

  it("parses several regions", function()
    local text = table.concat({
      "<<<<<<< HEAD",
      "a",
      "=======",
      "b",
      ">>>>>>> x",
      "middle",
      "<<<<<<< HEAD",
      "c",
      "=======",
      "d",
      ">>>>>>> x",
    }, "\n")
    local regions = conflicts.parse(text)
    assert.equals(2, #regions)
    assert.equals(1, regions[1].index)
    assert.equals(2, regions[2].index)
  end)

  it("produces the right replacement for each choice", function()
    local region = conflicts.parse("<<<<<<< HEAD\na\n||||||| base\nz\n=======\nb\n>>>>>>> x")[1]
    assert.same({ "a" }, conflicts.resolution_lines(region, "ours"))
    assert.same({ "b" }, conflicts.resolution_lines(region, "theirs"))
    assert.same({ "z" }, conflicts.resolution_lines(region, "base"))
    assert.same({ "a", "b" }, conflicts.resolution_lines(region, "both"))
    assert.same({}, conflicts.resolution_lines(region, "none"))
  end)

  it("reads the three index stages of a real conflict", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))

    local stages = t.await(function(done)
      conflicts.stages(repo, "conflict.lua", done)
    end)
    assert.is_not_nil(stages.base)
    assert.is_not_nil(stages.ours)
    assert.is_not_nil(stages.theirs)
    assert.is_not_nil(stages.ours:find("ours()", 1, true))
    assert.is_not_nil(stages.theirs:find("theirs()", 1, true))
    assert.is_not_nil(stages.base:find("base()", 1, true))
  end)

  it("lists unmerged paths", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))
    local paths = t.ok(function(done)
      conflicts.unmerged_paths(repo, done)
    end)
    assert.is_true(vim.tbl_contains(paths, "conflict.lua"))
  end)

  it("detects markers left on disk", function()
    local dir = helper.conflicted()
    local repo = assert(repository.detect(dir))
    assert.is_true(conflicts.has_markers_on_disk(repo, "conflict.lua"))
    assert.is_false(conflicts.has_markers_on_disk(repo, "shared.txt"))
  end)
end)

describe("blame", function()
  it("parses porcelain output", function()
    local raw = table.concat({
      "a8f29d1c0ffee000000000000000000000000000 1 1 2",
      "author Sam",
      "author-mail <sam@example.com>",
      "author-time 1767225600",
      "author-tz +0000",
      "committer Sam",
      "committer-time 1767225600",
      "summary feat: first",
      "filename f.lua",
      "\tline one",
      "a8f29d1c0ffee000000000000000000000000000 2 2",
      "\tline two",
      "7d3f812000000000000000000000000000000000 3 3 1",
      "author Ali",
      "author-mail <ali@example.com>",
      "author-time 1767139200",
      "summary fix: second",
      "filename f.lua",
      "\tline three",
    }, "\n")

    local parsed = blame.parse(raw)
    assert.equals(3, parsed.count)
    assert.equals("Sam", parsed.lines[1].commit.author)
    assert.equals("Sam", parsed.lines[2].commit.author)
    assert.equals("Ali", parsed.lines[3].commit.author)
    assert.equals("feat: first", parsed.lines[1].commit.summary)
    assert.equals(1767139200, parsed.lines[3].commit.author_time)
    assert.equals(2, vim.tbl_count(parsed.commits))
  end)

  it("marks uncommitted lines", function()
    local raw = table.concat({
      "0000000000000000000000000000000000000000 1 1 1",
      "author Not Committed Yet",
      "author-time 1767225600",
      "summary Version of f.lua from f.lua",
      "\tnew line",
    }, "\n")
    local parsed = blame.parse(raw)
    assert.is_true(parsed.lines[1].commit.is_uncommitted)
    assert.equals("Not committed yet", blame.format(parsed.lines[1]))
  end)

  it("blames a real file", function()
    local dir = helper.init("blame")
    helper.write(dir, "f.txt", "one\ntwo\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "first commit")
    helper.write(dir, "f.txt", "one\nTWO\n")
    helper.git(dir, { "add", "-A" })
    helper.commit(dir, "second commit")
    local repo = assert(repository.detect(dir))

    local result = t.ok(function(done)
      blame.file(repo, "f.txt", nil, done)
    end)
    assert.equals("first commit", result.lines[1].commit.summary)
    assert.equals("second commit", result.lines[2].commit.summary)
  end)

  it("explains why an untracked file cannot be blamed", function()
    local dir = helper.simple()
    helper.write(dir, "untracked.txt", "hi\n")
    local repo = assert(repository.detect(dir))
    local err = t.err(function(done)
      blame.file(repo, "untracked.txt", nil, done)
    end)
    assert.equals("not_tracked", err.kind)
    assert.is_string(err.hint)
  end)
end)

describe("browse", function()
  local cases = {
    { "https://github.com/owner/repo.git", "github.com", "owner/repo" },
    { "https://github.com/owner/repo", "github.com", "owner/repo" },
    { "git@github.com:owner/repo.git", "github.com", "owner/repo" },
    { "ssh://git@github.com/owner/repo.git", "github.com", "owner/repo" },
    { "ssh://git@github.com:2222/owner/repo.git", "github.com", "owner/repo" },
    { "git@gitlab.com:group/sub/project.git", "gitlab.com", "group/sub/project" },
    { "https://user:token@github.com/owner/repo.git", "github.com", "owner/repo" },
    { "https://bitbucket.org/owner/repo.git", "bitbucket.org", "owner/repo" },
  }

  it("parses every remote URL shape", function()
    for _, case in ipairs(cases) do
      local parsed = browse.parse_url(case[1])
      assert.is_not_nil(parsed, "failed to parse " .. case[1])
      assert.equals(case[2], parsed.host, case[1])
      assert.equals(case[3], parsed.path, case[1])
    end
  end)

  it("ignores unbrowsable remotes", function()
    assert.is_nil(browse.parse_url("/srv/git/repo.git"))
    assert.is_nil(browse.parse_url(""))
  end)

  it("builds GitHub URLs", function()
    local remote = "git@github.com:owner/repo.git"
    assert.equals("https://github.com/owner/repo", browse.url(remote, { kind = "repo" }))
    assert.equals(
      "https://github.com/owner/repo/commit/abc123",
      browse.url(remote, { kind = "commit", ref = "abc123" })
    )
    assert.equals("https://github.com/owner/repo/tree/main", browse.url(remote, { kind = "branch", ref = "main" }))
    assert.equals(
      "https://github.com/owner/repo/blob/main/src/api.lua#L10",
      browse.url(remote, { kind = "file", ref = "main", path = "src/api.lua", first = 10 })
    )
    assert.equals(
      "https://github.com/owner/repo/blob/main/src/api.lua#L10-L20",
      browse.url(remote, { kind = "file", ref = "main", path = "src/api.lua", first = 10, last = 20 })
    )
  end)

  it("builds GitLab URLs", function()
    local remote = "https://gitlab.com/group/project.git"
    assert.equals(
      "https://gitlab.com/group/project/-/blob/main/a.lua#L5-9",
      browse.url(remote, { kind = "file", ref = "main", path = "a.lua", first = 5, last = 9 })
    )
    assert.equals(
      "https://gitlab.com/group/project/-/compare/main...feature",
      browse.url(remote, { kind = "compare", base = "main", head = "feature" })
    )
  end)

  it("builds Bitbucket URLs", function()
    local remote = "https://bitbucket.org/owner/repo.git"
    assert.equals(
      "https://bitbucket.org/owner/repo/src/main/a.lua#lines-5:9",
      browse.url(remote, { kind = "file", ref = "main", path = "a.lua", first = 5, last = 9 })
    )
  end)

  it("percent-encodes awkward paths", function()
    local url = browse.url("git@github.com:o/r.git", {
      kind = "file",
      ref = "main",
      path = "dir/my file.lua",
    })
    assert.equals("https://github.com/o/r/blob/main/dir/my%20file.lua", url)
  end)

  it("honours configured self-hosted forges", function()
    local config = require("picked.config")
    config.options.browse.hosts["git.corp.internal"] = "gitlab"
    local url = browse.url("git@git.corp.internal:team/app.git", { kind = "file", ref = "main", path = "a.lua" })
    assert.equals("https://git.corp.internal/team/app/-/blob/main/a.lua", url)
    config.options.browse.hosts["git.corp.internal"] = nil
  end)
end)

describe("graph", function()
  it("lays out a linear history in one lane", function()
    local list = {
      { oid = "c", parents = { "b" }, is_merge = false },
      { oid = "b", parents = { "a" }, is_merge = false },
      { oid = "a", parents = {}, is_merge = false },
    }
    local cells = graph.layout(list)
    assert.equals(3, #cells)
    for _, cell in ipairs(cells) do
      assert.equals(1, cell.lane)
    end
  end)

  it("opens a second lane for a merge", function()
    local list = {
      { oid = "m", parents = { "a2", "b1" }, is_merge = true },
      { oid = "a2", parents = { "a1" }, is_merge = false },
      { oid = "b1", parents = { "a1" }, is_merge = false },
      { oid = "a1", parents = {}, is_merge = false },
    }
    local cells = graph.layout(list)
    assert.equals(1, cells[1].lane)
    assert.is_true(cells[3].lanes >= 2, "the side branch should occupy its own lane")
    -- every prefix is padded to the same width so subjects align
    local width = cells[1].width
    for _, cell in ipairs(cells) do
      assert.equals(width, cell.width)
    end
  end)

  it("bounds the number of lanes", function()
    local list = {}
    local parents = {}
    for index = 1, 40 do
      parents[index] = "p" .. index
    end
    list[1] = { oid = "wide", parents = parents, is_merge = true }
    local cells = graph.layout(list, { max_lanes = 5 })
    assert.is_true(cells[1].lanes <= 5)
  end)
end)
