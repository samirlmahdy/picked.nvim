local copilot = require("picked.integrations.copilot")
local repository = require("picked.git.repository")
local t = require("tests.helpers")
local helper = t.repo

describe("GitHub Copilot commit-message suggestions", function()
  it("runs without granting repository tools", function()
    local command = copilot._command("describe this diff", { silent = true, no_ask_user = true })
    assert.same("copilot", command[1])
    assert.is_true(vim.tbl_contains(command, "--no-ask-user"))
    assert.is_true(vim.tbl_contains(command, "-s"))
    assert.is_true(vim.tbl_contains(command, "--no-color"))
    assert.is_true(vim.tbl_contains(command, "--deny-tool=shell"))
    assert.is_true(vim.tbl_contains(command, "--deny-tool=write"))
    assert.is_true(vim.tbl_contains(command, "--deny-tool=read"))
    assert.is_true(vim.tbl_contains(command, "--deny-tool=url"))

    local legacy = copilot._command("describe this diff")
    assert.is_false(vim.tbl_contains(legacy, "--no-ask-user"))
    assert.is_false(vim.tbl_contains(legacy, "-s"))
  end)

  it("sends the staged diff and returns an editable message", function()
    local dir = helper.simple()
    helper.write(dir, "feature.lua", "return 'picked'\n")
    helper.git(dir, { "add", "feature.lua" })
    local repo = assert(repository.detect(dir))

    local original_available = copilot.available
    local original_run = copilot._run
    local captured_prompt
    copilot.available = function()
      return true
    end
    copilot._run = function(prompt, cwd, timeout, callback)
      captured_prompt = prompt
      assert.equals(dir, cwd)
      assert.equals(5000, timeout)
      callback("feat: add picked feature", nil)
    end

    local message, err = t.await(function(done)
      copilot.suggest(repo, { timeout = 5000 }, done)
    end)
    copilot.available = original_available
    copilot._run = original_run

    assert.is_nil(err)
    assert.equals("feat: add picked feature", message)
    assert.is_not_nil(captured_prompt:find("feature.lua", 1, true))
    assert.is_not_nil(captured_prompt:find("return 'picked'", 1, true))
    assert.is_not_nil(captured_prompt:find("untrusted data", 1, true))
  end)

  it("refuses to invent a message when nothing is staged", function()
    local dir = helper.simple()
    local repo = assert(repository.detect(dir))
    local original_available = copilot.available
    copilot.available = function()
      return true
    end

    local message, err = t.await(function(done)
      copilot.suggest(repo, nil, done)
    end)
    copilot.available = original_available

    assert.is_nil(message)
    assert.equals("nothing_staged", err.kind)
  end)
end)
