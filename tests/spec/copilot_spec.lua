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

  describe("talking to the real executable", function()
    ---Put a stand-in `copilot` on PATH for the duration of `fn`.
    ---@param body string  the script's behaviour for a `-p` invocation
    ---@param fn fun()
    local function with_fake_cli(body, fn)
      local dir = vim.fn.tempname()
      vim.fn.mkdir(dir, "p")
      local script = dir .. "/copilot"
      local lines = {
        "#!/usr/bin/env bash",
        -- The capability probe runs `copilot --help` first.
        'if [ "$1" = "--help" ]; then echo "Usage: copilot [options]"; exit 0; fi',
        body,
      }
      vim.fn.writefile(lines, script)
      vim.fn.setfperm(script, "rwxr-xr-x")

      local saved = vim.env.PATH
      vim.env.PATH = dir .. ":" .. saved
      local ok, err = pcall(fn)
      vim.env.PATH = saved
      vim.fn.delete(dir, "rf")
      if not ok then
        error(err)
      end
    end

    it("returns the message the CLI printed", function()
      -- The streams are consumed as they arrive, so `result.stdout` is empty
      -- and the suggestion has to be rebuilt from what was captured. Getting
      -- that wrong turns every success into "returned no message".
      with_fake_cli('printf "feat: add the thing\\n\\nWith a body.\\n"; exit 0', function()
        local message, err = t.await(function(done)
          copilot._run("prompt", vim.fn.getcwd(), 10000, done)
        end)
        assert.is_nil(err)
        assert.equals("feat: add the thing\n\nWith a body.", message)
      end)
    end)

    it("gives up on an error the CLI will never exit on", function()
      -- The real CLI retries a rejected model for ever. Waiting for it to exit
      -- means the whole timeout spent on "asking Copilot…" and then a message
      -- that says nothing, because the CLI reports this on stdout.
      with_fake_cli(
        'while true; do echo "× Model call failed: {\\"code\\":\\"model_not_supported\\"}"; sleep 1; done',
        function()
          local started = vim.uv.hrtime()
          local message, err = t.await(function(done)
            copilot._run("prompt", vim.fn.getcwd(), 60000, done)
          end)
          local elapsed = (vim.uv.hrtime() - started) / 1e6

          assert.is_nil(message)
          assert.equals("copilot_failed", err.kind)
          assert.is_not_nil(err.reason:find("model", 1, true), "the reason should name the cause: " .. err.reason)
          assert.is_not_nil(err.hint:find("npm i -g", 1, true), "the hint should say how to fix it: " .. err.hint)
          assert.is_true(elapsed < 20000, ("gave up after %dms, which is not sooner than the timeout"):format(elapsed))
        end
      )
    end)
  end)

  describe("the commit editor while it waits", function()
    local commit = require("picked.ui.commit")
    local store = require("picked.state")

    ---The hint row that carries the spinner.
    ---@return string
    local function hint()
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(bufnr) and vim.bo[bufnr].filetype == "picked-commit-info" then
          for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
            if line:find("Copilot") or line:find("suggest message") then
              return vim.trim(line)
            end
          end
        end
      end
      return "<no hint>"
    end

    it("spins, then puts the hint back", function()
      local dir = helper.simple()
      helper.write(dir, "feature.lua", "return 'picked'\n")
      helper.git(dir, { "add", "feature.lua" })
      local repo = assert(repository.detect(dir))
      store.ensure(repo)
      store.set_active(repo)
      require("picked.state.refresh").now(repo, {})
      t.wait_for(function()
        local state = store.get(repo.root)
        return state ~= nil and state.status ~= nil
      end, "status never loaded")

      local original_available, original_run = copilot.available, copilot._run
      copilot.available = function()
        return true
      end
      -- Slow enough to turn a few frames.
      copilot._run = function(_, _, _, callback)
        vim.defer_fn(function()
          callback("feat: add a feature", nil)
        end, 700)
      end

      commit.open(repo, {})
      vim.wait(600)
      assert.is_not_nil(hint():find("suggest message", 1, true), "expected the idle hint, got: " .. hint())

      commit.suggest()
      local frames = {}
      for _ = 1, 8 do
        vim.wait(90)
        local current = hint()
        if frames[#frames] ~= current then
          frames[#frames + 1] = current
        end
      end
      assert.is_true(#frames >= 2, "the spinner should animate, saw: " .. vim.inspect(frames))
      for _, frame in ipairs(frames) do
        -- Never animation alone: the words say what is happening.
        assert.is_not_nil(frame:find("asking Copilot", 1, true), "every frame should still read: " .. frame)
      end

      t.wait_for(function()
        return hint():find("suggest message", 1, true) ~= nil
      end, "the hint never went back to idle")

      commit.close()
      vim.wait(200)
      copilot.available, copilot._run = original_available, original_run
    end)

    it("stops the spinner when the editor closes mid-suggestion", function()
      -- A libuv timer outlives the buffer it was drawing into; left running it
      -- fires at a dead session for the rest of the Neovim run.
      local dir = helper.simple()
      helper.write(dir, "feature.lua", "return 'picked'\n")
      helper.git(dir, { "add", "feature.lua" })
      local repo = assert(repository.detect(dir))
      store.ensure(repo)
      store.set_active(repo)
      require("picked.state.refresh").now(repo, {})
      t.wait_for(function()
        local state = store.get(repo.root)
        return state ~= nil and state.status ~= nil
      end, "status never loaded")

      local original_available, original_run = copilot.available, copilot._run
      copilot.available = function()
        return true
      end
      local answer
      copilot._run = function(_, _, _, callback)
        answer = callback -- never called: the user gives up first
      end

      commit.open(repo, {})
      vim.wait(400)
      commit.suggest()
      vim.wait(150)

      commit.close()
      vim.wait(200)
      assert.is_not_nil(answer, "the suggestion should have been started")
      -- Answering now must not resurrect anything.
      answer("feat: too late", nil)
      vim.wait(200)

      copilot.available, copilot._run = original_available, original_run
    end)
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
