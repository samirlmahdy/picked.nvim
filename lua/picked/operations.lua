---@brief User-facing git operations.
---
---This is the layer between "the user pressed a key" and "git ran". It owns
---the three things every mutating operation needs and that must never be left
---to an individual view:
---
---  1. confirmation for anything destructive,
---  2. progress and error reporting,
---  3. invalidating the store *before* the mutation and refreshing after it,
---     so a slow read started earlier can never resurrect stale state.
---
---Views call these functions and render; they never call `git.*` directly for
---anything that writes.

local confirm = require("picked.ui.confirm")
local config = require("picked.config")
local events = require("picked.utils.events")
local git = require("picked.git")
local input = require("picked.ui.input")
local notify = require("picked.ui.notify")
local refresh = require("picked.state.refresh")
local store = require("picked.state")

local M = {}

---Wrap a mutating git call with the invalidate/refresh contract.
---@param repo GitRepository
---@param label string  used for the log and the refresh reason
---@param run fun(done: fun(ok: boolean, err: GitError|nil))
---@param opts { success: string|fun(): string|nil, on_success: fun()|nil, silent: boolean|nil }|nil
local function mutate(repo, label, run, opts)
  opts = opts or {}

  -- Any read in flight predates this write and must be discarded.
  store.invalidate(repo.root)

  run(function(ok, err)
    if not ok then
      if err then
        notify.error(err, { context = label })
      end
      -- The repository may still have changed (a partial merge, for example),
      -- so re-read regardless of the outcome.
      refresh.after_mutation(repo, label .. ":failed")
      return
    end

    refresh.after_mutation(repo, label, function()
      if not opts.silent then
        local message = type(opts.success) == "function" and opts.success() or opts.success
        if message then
          notify.success(message)
        end
      end
      if opts.on_success then
        opts.on_success()
      end
    end)
  end)
end

M.mutate = mutate

---@param count integer
---@param singular string
---@return string
local function plural(count, singular)
  return ("%d %s%s"):format(count, singular, count == 1 and "" or "s")
end

--- Staging --------------------------------------------------------------------

---@param repo GitRepository
---@param paths string[]
function M.stage(repo, paths)
  if #paths == 0 then
    return
  end
  mutate(repo, "stage", function(done)
    git.staging.stage(repo, paths, done)
  end, { success = ("Staged %s"):format(plural(#paths, "file")) })
end

---@param repo GitRepository
---@param paths string[]
function M.unstage(repo, paths)
  if #paths == 0 then
    return
  end
  mutate(repo, "unstage", function(done)
    git.staging.unstage(repo, paths, done)
  end, { success = ("Unstaged %s"):format(plural(#paths, "file")) })
end

---Stage everything, including untracked files.
---@param repo GitRepository
function M.stage_all(repo)
  mutate(repo, "stage-all", function(done)
    git.staging.stage_all(repo, done)
  end, { success = "Staged all changes" })
end

---@param repo GitRepository
function M.unstage_all(repo)
  mutate(repo, "unstage-all", function(done)
    git.staging.unstage_all(repo, done)
  end, { success = "Unstaged all changes" })
end

---Discard working-tree changes.
---
---Untracked files are deleted from disk and tracked files are restored from
---the index, so the confirmation spells out which is which: those are very
---different amounts of lost work.
---@param repo GitRepository
---@param entries GitFileEntry[]
function M.discard(repo, entries)
  if #entries == 0 then
    return
  end

  local tracked, untracked = {}, {}
  for _, entry in ipairs(entries) do
    if entry.untracked then
      untracked[#untracked + 1] = entry.path
    else
      tracked[#tracked + 1] = entry.path
    end
  end

  local details = {}
  for _, entry in ipairs(entries) do
    details[#details + 1] = entry.path .. (entry.untracked and "  (delete file)" or "")
  end

  local message
  if #untracked > 0 and #tracked > 0 then
    message = ("Restore %s from the index and delete %s from disk."):format(
      plural(#tracked, "file"),
      plural(#untracked, "untracked file")
    )
  elseif #untracked > 0 then
    message = ("Delete %s from disk."):format(plural(#untracked, "untracked file"))
  else
    message = ("Restore %s from the index, losing the changes in the working tree."):format(plural(#tracked, "file"))
  end

  confirm.guard("discard", {
    title = "Discard changes?",
    message = message,
    details = details,
    warning = "This cannot be undone.",
    confirm_label = "Discard",
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    mutate(repo, "discard", function(done)
      local pending = 0
      local failure = nil
      local function step(ok, err)
        if not ok and err then
          failure = failure or err
        end
        pending = pending - 1
        if pending == 0 then
          done(failure == nil, failure)
        end
      end

      if #tracked > 0 then
        pending = pending + 1
      end
      if #untracked > 0 then
        pending = pending + 1
      end
      if pending == 0 then
        return done(true, nil)
      end

      if #tracked > 0 then
        git.staging.discard_worktree(repo, tracked, step)
      end
      if #untracked > 0 then
        git.staging.delete_untracked(repo, untracked, step)
      end
    end, {
      success = ("Discarded changes in %s"):format(plural(#entries, "file")),
      on_success = function()
        -- Any buffer showing a discarded file is now stale on disk.
        vim.cmd("checktime")
      end,
    })
  end)
end

--- Hunks ----------------------------------------------------------------------

---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param label string|nil
function M.stage_hunks(repo, path, hunks, opts, label)
  if #hunks == 0 then
    return notify.warn("No hunk under the cursor")
  end
  mutate(repo, "stage-hunk", function(done)
    git.staging.stage_hunks(repo, path, hunks, opts, done)
  end, { success = label or ("Staged %s in %s"):format(plural(#hunks, "hunk"), path) })
end

---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
---@param label string|nil
function M.unstage_hunks(repo, path, hunks, opts, label)
  if #hunks == 0 then
    return notify.warn("No hunk under the cursor")
  end
  mutate(repo, "unstage-hunk", function(done)
    git.staging.unstage_hunks(repo, path, hunks, opts, done)
  end, { success = label or ("Unstaged %s in %s"):format(plural(#hunks, "hunk"), path) })
end

---@param repo GitRepository
---@param path string
---@param hunks GitHunk[]
---@param opts GitPartialOpts|nil
function M.discard_hunks(repo, path, hunks, opts)
  if #hunks == 0 then
    return notify.warn("No hunk under the cursor")
  end

  confirm.guard("discard_hunk", {
    title = ("Discard %s?"):format(plural(#hunks, "hunk")),
    message = ("The selected changes in %s will be reverted to the staged version."):format(path),
    warning = "This cannot be undone.",
    confirm_label = "Discard",
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end
    mutate(repo, "discard-hunk", function(done)
      git.staging.discard_hunks(repo, path, hunks, opts, done)
    end, {
      success = ("Discarded %s"):format(plural(#hunks, "hunk")),
      on_success = function()
        vim.cmd("checktime")
      end,
    })
  end)
end

--- Commit ---------------------------------------------------------------------

---@param repo GitRepository
---@param opts GitCommitOpts
---@param callback fun(ok: boolean)|nil
function M.commit(repo, opts, callback)
  store.invalidate(repo.root)
  local progress = notify.progress(opts.amend and "Amending commit" or "Committing", { root = repo.root })

  git.commits.commit(repo, opts, function(ok, err, output)
    if output and output ~= "" then
      require("picked.ui.output").store(opts.amend and "git commit --amend" or "git commit", output, ok)
    end

    if not ok then
      progress:finish(false, nil, err)
      refresh.after_mutation(repo, "commit:failed")
      if callback then
        callback(false)
      end
      return
    end

    refresh.after_mutation(repo, "commit", function()
      local state = store.get(repo.root)
      local count = state and state.status and #state.status.staged or 0
      progress:finish(true, opts.amend and "Amended commit" or ("Committed (%d staged remaining)"):format(count))
      events.emit(events.names.COMMIT_CREATED, { root = repo.root, amend = opts.amend })
      if callback then
        callback(true)
      end
    end)
  end)
end

--- Network --------------------------------------------------------------------

---@param repo GitRepository
---@param opts GitNetworkOpts|nil
function M.fetch(repo, opts)
  opts = opts or {}
  local target = opts.all and "all remotes" or (opts.remote or "remote")
  local progress = notify.progress("Fetching " .. target, { root = repo.root, key = "fetch" })

  store.invalidate(repo.root)
  git.remotes.fetch(
    repo,
    vim.tbl_extend("force", opts, {
      on_progress = function(line)
        progress:update(line)
      end,
    }),
    function(result)
      require("picked.ui.output").store("git fetch " .. target, result.output, result.ok)
      refresh.after_mutation(repo, "fetch", function()
        if result.ok then
          progress:finish(true, "Fetched " .. target)
        else
          progress.output = result.output
          progress:finish(false, nil, result.err)
        end
        events.emit(events.names.FETCH_FINISHED, { root = repo.root, ok = result.ok })
      end)
    end
  )
end

---Pull, asking for the strategy when the configuration says to.
---@param repo GitRepository
---@param opts GitNetworkOpts|nil
function M.pull(repo, opts)
  opts = opts or {}

  local function run(strategy)
    local merged = vim.tbl_extend("force", opts, {
      rebase = strategy == "rebase",
      ff_only = strategy == "ff-only",
    })
    local progress = notify.progress("Pulling", { root = repo.root, key = "pull" })

    store.invalidate(repo.root)
    merged.on_progress = function(line)
      progress:update(line)
    end

    git.remotes.pull(repo, merged, function(result)
      require("picked.ui.output").store("git pull", result.output, result.ok)
      refresh.after_mutation(repo, "pull", function()
        if result.ok then
          progress:finish(true, "Pulled")
          -- Files on disk changed underneath open buffers.
          vim.cmd("checktime")
        else
          progress.output = result.output
          progress:finish(false, nil, result.err)
        end
        events.emit(events.names.PULL_FINISHED, { root = repo.root, ok = result.ok })
      end)
    end)
  end

  local configured = config.options.remote.pull_strategy
  if configured ~= "ask" then
    return run(configured)
  end

  confirm.choose({
    title = "Pull",
    message = "How should the remote changes be integrated?",
    choices = {
      { key = "m", label = "Merge", description = "create a merge commit if needed", value = "merge" },
      { key = "r", label = "Rebase", description = "replay your commits on top", value = "rebase" },
      { key = "f", label = "Fast-forward only", description = "refuse if a merge is needed", value = "ff-only" },
    },
  }, function(strategy)
    if strategy then
      run(strategy)
    end
  end)
end

---Push, handling the missing-upstream case explicitly rather than failing.
---@param repo GitRepository
---@param opts GitNetworkOpts|nil
function M.push(repo, opts)
  opts = opts or {}
  local state = store.get(repo.root)
  local head = state and state.head

  if head and head.detached then
    return notify.error({
      kind = "detached",
      title = "Cannot push a detached HEAD",
      reason = "HEAD is not on a branch, so there is nothing to push.",
      hint = "Create a branch first, then push.",
      raw = "",
    })
  end

  local branch = opts.branch or (head and head.branch)
  local upstream = state and state.status and state.status.branch.upstream

  local function run(final)
    local label = final.force_with_lease and "Force-pushing" or "Pushing"
    local progress = notify.progress(label, { root = repo.root, key = "push" })

    store.invalidate(repo.root)
    final.on_progress = function(line)
      progress:update(line)
    end

    git.remotes.push(repo, final, function(result)
      require("picked.ui.output").store("git push", result.output, result.ok)
      refresh.after_mutation(repo, "push", function()
        if result.ok then
          progress:finish(true, ("Pushed %s"):format(branch or "HEAD"))
        else
          progress.output = result.output
          progress:finish(false, nil, result.err)
        end
        events.emit(events.names.PUSH_FINISHED, { root = repo.root, ok = result.ok })
      end)
    end)
  end

  local function with_confirmation(final, description)
    if config.options.confirm.push == false and not final.force_with_lease and not final.force then
      return run(final)
    end
    confirm.guard(final.force_with_lease and "force_push" or "push", {
      title = final.force_with_lease and "Force push?" or "Push?",
      message = description,
      warning = final.force_with_lease and table.concat({
        "Force pushing rewrites the remote branch.",
        "--force-with-lease refuses if the remote moved since your last fetch.",
      }, "\n") or nil,
      confirm_label = final.force_with_lease and "Force push" or "Push",
      destructive = final.force_with_lease == true,
      default = not final.force_with_lease,
    }, function(confirmed)
      if confirmed then
        run(final)
      end
    end)
  end

  if upstream or opts.remote then
    local remote = opts.remote
    local description = upstream and ("%s → %s"):format(branch or "HEAD", upstream)
      or ("%s → %s"):format(branch or "HEAD", remote or "remote")
    return with_confirmation(vim.tbl_extend("force", opts, { remote = remote }), description)
  end

  -- No upstream configured: offer to create one instead of failing.
  git.remotes.for_branch(repo, branch, function(remote)
    if not remote then
      return notify.error({
        kind = "no_remote",
        title = "No remote configured",
        reason = "This repository has no remote to push to.",
        hint = "Add one with `git remote add origin <url>`.",
        raw = "",
      })
    end

    if not config.options.remote.auto_set_upstream then
      return with_confirmation(
        vim.tbl_extend("force", opts, { remote = remote, branch = branch }),
        ("%s → %s/%s"):format(branch or "HEAD", remote, branch or "HEAD")
      )
    end

    confirm.ask({
      title = "Set upstream and push?",
      message = ("'%s' has no upstream branch.\n\nPush to %s/%s and track it?"):format(
        branch or "HEAD",
        remote,
        branch or "HEAD"
      ),
      confirm_label = "Push",
      default = true,
    }, function(confirmed)
      if not confirmed then
        return
      end
      run(vim.tbl_extend("force", opts, { remote = remote, branch = branch, set_upstream = true }))
    end)
  end)
end

---Force push, always preferring --force-with-lease.
---@param repo GitRepository
function M.force_push(repo)
  local mode = config.options.remote.force_push_mode
  M.push(repo, {
    force_with_lease = mode ~= "force",
    force = mode == "force",
  })
end

--- Branches --------------------------------------------------------------------

---@param repo GitRepository
---@param name string
function M.switch_branch(repo, name)
  mutate(repo, "switch", function(done)
    git.branches.switch(repo, name, nil, done)
  end, {
    success = ("Switched to %s"):format(name),
    on_success = function()
      vim.cmd("checktime")
      events.emit(events.names.BRANCH_CHANGED, { root = repo.root, branch = name })
    end,
  })
end

---@param repo GitRepository
---@param opts { start_point: string|nil, switch: boolean|nil }|nil
function M.create_branch(repo, opts)
  opts = opts or {}
  input.branch_name({
    prompt = opts.start_point and ("New branch from %s"):format(opts.start_point) or "New branch name",
  }, function(name)
    if not name then
      return
    end
    mutate(repo, "branch-create", function(done)
      git.branches.create(repo, name, {
        start_point = opts.start_point,
        switch = opts.switch ~= false,
      }, done)
    end, {
      success = opts.switch == false and ("Created %s"):format(name) or ("Created and switched to %s"):format(name),
      on_success = function()
        vim.cmd("checktime")
        events.emit(events.names.BRANCH_CHANGED, { root = repo.root, branch = name })
      end,
    })
  end)
end

---@param repo GitRepository
---@param branch GitBranch
function M.delete_branch(repo, branch)
  if branch.is_head then
    return notify.error({
      kind = "current_branch",
      title = "Cannot delete the current branch",
      reason = ("'%s' is checked out."):format(branch.name),
      hint = "Switch to another branch first.",
      raw = "",
    })
  end

  local is_remote = branch.kind == "remote"
  local remote_name = is_remote and branch.remote or nil
  local short_name = is_remote and branch.name:sub(#(remote_name or "") + 2) or branch.name

  confirm.guard("branch_delete", {
    title = is_remote and "Delete remote branch?" or "Delete branch?",
    message = is_remote and ("This deletes '%s' on %s, for everyone."):format(short_name, remote_name)
      or ("Delete local branch '%s'."):format(branch.name),
    warning = is_remote and "This affects the remote repository." or "Unmerged commits would be lost.",
    confirm_label = "Delete",
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    local function attempt(force)
      git.branches.delete(repo, is_remote and short_name or branch.name, {
        force = force,
        remote = remote_name,
      }, function(ok, err)
        if ok then
          refresh.after_mutation(repo, "branch-delete", function()
            notify.success(("Deleted %s"):format(branch.name))
          end)
          return
        end

        -- git refuses to delete an unmerged branch with -d; offering -D here
        -- keeps the safety net while still making the action reachable.
        if not force and err and err.raw:find("not fully merged") then
          return confirm.ask({
            title = "Branch is not fully merged",
            message = ("'%s' has commits that are not on any other branch."):format(branch.name),
            warning = "Deleting it discards those commits.",
            confirm_label = "Delete anyway",
            destructive = true,
          }, function(force_confirmed)
            if force_confirmed then
              attempt(true)
            end
          end)
        end

        notify.error(err or "Could not delete the branch")
        refresh.after_mutation(repo, "branch-delete:failed")
      end)
    end

    store.invalidate(repo.root)
    attempt(false)
  end)
end

---@param repo GitRepository
---@param branch GitBranch
function M.rename_branch(repo, branch)
  input.branch_name({ prompt = ("Rename '%s' to"):format(branch.name), default = branch.name }, function(name)
    if not name or name == branch.name then
      return
    end
    mutate(repo, "branch-rename", function(done)
      git.branches.rename(repo, branch.name, name, nil, done)
    end, { success = ("Renamed to %s"):format(name) })
  end)
end

---@param repo GitRepository
---@param ref string
function M.merge(repo, ref)
  confirm.ask({
    title = ("Merge %s?"):format(ref),
    message = ("Merge '%s' into the current branch."):format(ref),
    confirm_label = "Merge",
    default = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    store.invalidate(repo.root)
    git.branches.merge(repo, ref, nil, function(ok, err)
      refresh.after_mutation(repo, "merge", function()
        vim.cmd("checktime")
        if ok then
          return notify.success(("Merged %s"):format(ref))
        end
        if err and err.kind == "conflict" then
          notify.warn(("Merge stopped with conflicts. Resolve them, then continue."):format())
          require("picked.ui.source_control").open()
          return
        end
        notify.error(err or "Merge failed")
      end)
    end)
  end)
end

---@param repo GitRepository
---@param ref string
function M.rebase(repo, ref)
  confirm.ask({
    title = ("Rebase onto %s?"):format(ref),
    message = ("Replay the current branch's commits on top of '%s'."):format(ref),
    warning = "Rebasing rewrites commit history. Do not rebase commits you have already shared.",
    confirm_label = "Rebase",
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    store.invalidate(repo.root)
    git.branches.rebase(repo, ref, { autostash = true }, function(ok, err)
      refresh.after_mutation(repo, "rebase", function()
        vim.cmd("checktime")
        if ok then
          return notify.success(("Rebased onto %s"):format(ref))
        end
        if err and err.kind == "conflict" then
          notify.warn("Rebase stopped with conflicts. Resolve them, then continue.")
          require("picked.ui.source_control").open()
          return
        end
        notify.error(err or "Rebase failed")
      end)
    end)
  end)
end

---Continue, skip or abort an in-progress sequencer operation.
---@param repo GitRepository
---@param action GitSequencerAction
function M.sequencer(repo, action)
  local state = store.get(repo.root)
  local kind = state and state.git_state and state.git_state.kind or "normal"

  local operation = ({
    merge = "merge",
    rebase = "rebase",
    ["rebase-interactive"] = "rebase",
    am = "am",
    ["cherry-pick"] = "cherry-pick",
    revert = "revert",
  })[kind]

  if not operation then
    return notify.warn("No operation is in progress")
  end

  local function run()
    mutate(repo, operation .. "-" .. action, function(done)
      git.branches.sequencer(repo, operation, action, done)
    end, {
      success = ("%s %s"):format(operation, action == "continue" and "continued" or action .. "ed"),
      on_success = function()
        vim.cmd("checktime")
      end,
    })
  end

  if action == "abort" then
    return confirm.ask({
      title = ("Abort the %s?"):format(operation),
      message = "The repository returns to the state it was in before the operation started.",
      warning = "Work done during the operation is lost.",
      confirm_label = "Abort",
      destructive = true,
    }, function(confirmed)
      if confirmed then
        run()
      end
    end)
  end

  run()
end

--- Reset ------------------------------------------------------------------------

---@param repo GitRepository
---@param revision string
---@param mode "soft"|"mixed"|"hard"
function M.reset(repo, revision, mode)
  local descriptions = {
    soft = "Moves the branch. The index and working tree are untouched.",
    mixed = "Moves the branch and resets the index. Working-tree changes are kept.",
    hard = "Moves the branch and resets both the index and the working tree.",
  }

  local key = mode == "hard" and "reset_hard" or (mode == "mixed" and "reset_mixed" or "reset_soft")

  confirm.guard(key, {
    title = ("Reset --%s to %s?"):format(mode, revision:sub(1, 12)),
    message = descriptions[mode],
    warning = mode == "hard" and "Uncommitted changes in the working tree will be destroyed. This cannot be undone."
      or nil,
    confirm_label = "Reset",
    destructive = mode == "hard",
  }, function(confirmed)
    if not confirmed then
      return
    end
    mutate(repo, "reset", function(done)
      git.branches.reset(repo, revision, mode, done)
    end, {
      success = ("Reset --%s to %s"):format(mode, revision:sub(1, 7)),
      on_success = function()
        vim.cmd("checktime")
      end,
    })
  end)
end

--- Cherry-pick and revert ---------------------------------------------------------

---@param repo GitRepository
---@param commit GitCommit
function M.cherry_pick(repo, commit)
  confirm.ask({
    title = ("Cherry-pick %s?"):format(commit.short),
    message = ("Apply '%s' onto the current branch as a new commit."):format(commit.subject),
    confirm_label = "Cherry-pick",
    default = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    store.invalidate(repo.root)
    git.commits.cherry_pick(repo, { commit.oid }, nil, function(ok, err)
      refresh.after_mutation(repo, "cherry-pick", function()
        vim.cmd("checktime")
        if ok then
          return notify.success(("Cherry-picked %s"):format(commit.short))
        end
        if err and err.kind == "conflict" then
          notify.warn("Cherry-pick stopped with conflicts. Resolve them, then continue.")
          require("picked.ui.source_control").open()
          return
        end
        notify.error(err or "Cherry-pick failed")
      end)
    end)
  end)
end

---@param repo GitRepository
---@param commit GitCommit
function M.revert(repo, commit)
  confirm.guard("revert", {
    title = ("Revert %s?"):format(commit.short),
    message = ("Create a new commit that undoes '%s'.\n\n%s"):format(
      commit.subject,
      "History is not rewritten: the original commit stays in the log."
    ),
    confirm_label = "Revert",
    default = true,
  }, function(confirmed)
    if not confirmed then
      return
    end

    store.invalidate(repo.root)
    git.commits.revert(repo, { commit.oid }, { mainline = commit.is_merge and 1 or nil }, function(ok, err)
      refresh.after_mutation(repo, "revert", function()
        vim.cmd("checktime")
        if ok then
          return notify.success(("Reverted %s"):format(commit.short))
        end
        if err and err.kind == "conflict" then
          notify.warn("Revert stopped with conflicts. Resolve them, then continue.")
          require("picked.ui.source_control").open()
          return
        end
        notify.error(err or "Revert failed")
      end)
    end)
  end)
end

--- Stash -----------------------------------------------------------------------

---@param repo GitRepository
---@param opts GitStashPushOpts|nil
function M.stash_push(repo, opts)
  opts = opts or {}
  input.ask({ prompt = "Stash message (optional)", allow_empty = true }, function(message)
    mutate(repo, "stash", function(done)
      git.stash.push(
        repo,
        vim.tbl_extend("force", opts, {
          message = message,
          include_untracked = opts.include_untracked ~= false,
        }),
        done
      )
    end, {
      success = "Stashed changes",
      on_success = function()
        vim.cmd("checktime")
        events.emit(events.names.STASH_CHANGED, { root = repo.root })
      end,
    })
  end)
end

---@param repo GitRepository
---@param stash GitStash
---@param action "apply"|"pop"
function M.stash_restore(repo, stash, action)
  mutate(repo, "stash-" .. action, function(done)
    git.stash[action](repo, stash.selector, { index = true }, function(ok, err)
      if ok or not err then
        return done(ok, err)
      end
      -- `--index` fails when the stashed index state no longer applies; the
      -- plain restore is still useful and is what the user expects.
      git.stash[action](repo, stash.selector, nil, done)
    end)
  end, {
    success = ("%s %s"):format(action == "pop" and "Popped" or "Applied", stash.selector),
    on_success = function()
      vim.cmd("checktime")
      events.emit(events.names.STASH_CHANGED, { root = repo.root })
    end,
  })
end

---@param repo GitRepository
---@param stash GitStash
function M.stash_drop(repo, stash)
  confirm.guard("stash_drop", {
    title = ("Drop %s?"):format(stash.selector),
    message = stash.message,
    warning = "The stashed changes are deleted. This cannot be undone.",
    confirm_label = "Drop",
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end
    mutate(repo, "stash-drop", function(done)
      git.stash.drop(repo, stash.selector, done)
    end, {
      success = ("Dropped %s"):format(stash.selector),
      on_success = function()
        events.emit(events.names.STASH_CHANGED, { root = repo.root })
      end,
    })
  end)
end

--- Conflicts ---------------------------------------------------------------------

---Stage a file as resolved, refusing when conflict markers are still present.
---@param repo GitRepository
---@param paths string[]
function M.mark_resolved(repo, paths)
  local unresolved = {}
  for _, path in ipairs(paths) do
    if git.conflicts.has_markers_on_disk(repo, path) then
      unresolved[#unresolved + 1] = path
    end
  end

  local function stage()
    mutate(repo, "resolve", function(done)
      git.staging.stage(repo, paths, done)
    end, {
      success = ("Marked %s resolved"):format(plural(#paths, "file")),
      on_success = function()
        events.emit(events.names.CONFLICT_STATE_CHANGED, { root = repo.root })
      end,
    })
  end

  if #unresolved == 0 then
    return stage()
  end

  confirm.ask({
    title = "Conflict markers are still present",
    message = "These files still contain <<<<<<< markers. Staging them records the markers as resolved content.",
    details = unresolved,
    warning = "This is almost always a mistake.",
    confirm_label = "Stage anyway",
    destructive = true,
  }, function(confirmed)
    if confirmed then
      stage()
    end
  end)
end

---Take one whole side of a conflicted file.
---@param repo GitRepository
---@param paths string[]
---@param side "ours"|"theirs"
function M.take_side(repo, paths, side)
  confirm.ask({
    title = ("Take '%s' for %s?"):format(side, plural(#paths, "file")),
    message = side == "ours" and "Keep the version from the current branch, discarding the incoming changes."
      or "Keep the incoming version, discarding the current branch's changes.",
    details = paths,
    warning = "The other side's changes to these files are discarded.",
    confirm_label = "Take " .. side,
    destructive = true,
  }, function(confirmed)
    if not confirmed then
      return
    end
    mutate(repo, "take-" .. side, function(done)
      git.staging.checkout_side(repo, paths, side, function(ok, err)
        if not ok then
          return done(false, err)
        end
        git.staging.stage(repo, paths, done)
      end)
    end, {
      success = ("Took '%s' for %s"):format(side, plural(#paths, "file")),
      on_success = function()
        vim.cmd("checktime")
      end,
    })
  end)
end

--- Clean ------------------------------------------------------------------------

---Remove untracked files, always showing exactly what will be deleted first.
---@param repo GitRepository
---@param opts { ignored: boolean|nil }|nil
function M.clean(repo, opts)
  opts = opts or {}

  git.staging.clean_preview(repo, { ignored = opts.ignored }, function(paths, err)
    if err then
      return notify.error(err)
    end
    if not paths or #paths == 0 then
      return notify.info("Nothing to clean")
    end

    confirm.guard("clean", {
      title = opts.ignored and "Delete untracked and ignored files?" or "Delete untracked files?",
      message = ("%s will be permanently deleted from disk."):format(plural(#paths, "path")),
      details = paths,
      warning = "These files are not in git. This cannot be undone.",
      confirm_label = "Delete",
      destructive = true,
    }, function(confirmed)
      if not confirmed then
        return
      end
      mutate(repo, "clean", function(done)
        git.staging.clean(repo, { ignored = opts.ignored }, done)
      end, { success = ("Deleted %s"):format(plural(#paths, "path")) })
    end)
  end)
end

--- Browsing ----------------------------------------------------------------------

---Open something on the remote's web interface.
---@param repo GitRepository
---@param target GitBrowseTarget
function M.browse(repo, target)
  git.remotes.list(repo, function(remotes, err)
    if err then
      return notify.error(err)
    end
    if not remotes or #remotes == 0 then
      return notify.error({
        kind = "no_remote",
        title = "No remote to open",
        reason = "This repository has no remotes configured.",
        hint = "Add one with `git remote add origin <url>`.",
        raw = "",
      })
    end

    local url, url_err = git.browse.url(remotes[1].fetch_url, target)
    if not url then
      return notify.error({
        kind = "unbrowsable",
        title = "Cannot open this remote",
        reason = url_err or "The remote URL is not a web address.",
        hint = "Set `browse.hosts` if this is a self-hosted forge.",
        raw = remotes[1].fetch_url,
      })
    end

    git.browse.open(url, function(ok, open_err)
      if ok then
        notify.info("Opened " .. url)
      else
        -- Still useful: put it on the clipboard so the user can paste it.
        vim.fn.setreg("+", url)
        notify.warn((open_err or "Could not open a browser") .. "\n\nURL copied to the clipboard:\n" .. url)
      end
    end)
  end)
end

return M
