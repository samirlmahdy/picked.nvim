---@brief Hierarchical file tree construction.
---
---Turns a flat list of status entries into a directory tree, collapsing chains
---of single-child directories into one row ("src/api/v2/") so a deeply nested
---change does not cost five lines of indentation in a 40-column sidebar.

local path_util = require("gitui.utils.path")

local M = {}

---@class GitUITreeNode
---@field kind "directory"|"file"
---@field name string  display label; a flattened directory keeps its slashes
---@field path string  repository-relative path
---@field id string  stable identity for expansion state and cursor anchoring
---@field children GitUITreeNode[]
---@field entry GitFileEntry|nil  files only
---@field paths string[]  every file path at or below this node
---@field depth integer

---@param id_prefix string
---@param path string
---@return string
local function node_id(id_prefix, path)
  return id_prefix .. ":" .. path
end

---Build a tree from status entries.
---@param entries GitFileEntry[]
---@param opts { id_prefix: string, flatten: boolean|nil }
---@return GitUITreeNode[] roots
function M.build(entries, opts)
  local flatten = opts.flatten ~= false

  ---@type GitUITreeNode
  local root = {
    kind = "directory",
    name = "",
    path = "",
    id = node_id(opts.id_prefix, ""),
    children = {},
    paths = {},
    depth = 0,
  }

  ---@type table<string, GitUITreeNode>
  local directories = { [""] = root }

  ---@param path string
  ---@return GitUITreeNode
  local function ensure_directory(path)
    local existing = directories[path]
    if existing then
      return existing
    end

    local parent_path = path_util.dirname(path)
    local parent = ensure_directory(parent_path)

    local node = {
      kind = "directory",
      name = path_util.basename(path),
      path = path,
      id = node_id(opts.id_prefix, path),
      children = {},
      paths = {},
      depth = 0,
    }
    directories[path] = node
    parent.children[#parent.children + 1] = node
    return node
  end

  for _, entry in ipairs(entries) do
    local parent = ensure_directory(path_util.dirname(entry.path))
    parent.children[#parent.children + 1] = {
      kind = "file",
      name = path_util.basename(entry.path),
      path = entry.path,
      id = node_id(opts.id_prefix, entry.path),
      children = {},
      entry = entry,
      paths = { entry.path },
      depth = 0,
    }
  end

  -- Propagate the descendant path lists upwards, then sort: directories
  -- before files, each alphabetically, which is what every file tree does.
  local function finalize(node, depth)
    node.depth = depth

    if flatten and node ~= root and node.kind == "directory" and #node.children == 1 then
      local only = node.children[1]
      if only.kind == "directory" then
        -- Merge the child into this node rather than rendering two rows.
        node.name = node.name .. "/" .. only.name
        node.path = only.path
        node.id = only.id
        node.children = only.children
        return finalize(node, depth)
      end
    end

    table.sort(node.children, function(a, b)
      if a.kind ~= b.kind then
        return a.kind == "directory"
      end
      return a.name < b.name
    end)

    for _, child in ipairs(node.children) do
      finalize(child, depth + 1)
      for _, path in ipairs(child.paths) do
        node.paths[#node.paths + 1] = path
      end
    end
  end

  finalize(root, -1)
  return root.children
end

---Build a flat list (no directories), which is what narrow terminals and the
---`tree = false` configuration use.
---@param entries GitFileEntry[]
---@param opts { id_prefix: string }
---@return GitUITreeNode[]
function M.flat(entries, opts)
  local nodes = {}
  for _, entry in ipairs(entries) do
    nodes[#nodes + 1] = {
      kind = "file",
      name = entry.path,
      path = entry.path,
      id = node_id(opts.id_prefix, entry.path),
      children = {},
      entry = entry,
      paths = { entry.path },
      depth = 0,
    }
  end
  table.sort(nodes, function(a, b)
    return a.path < b.path
  end)
  return nodes
end

---Walk the tree in display order, skipping collapsed subtrees.
---@param nodes GitUITreeNode[]
---@param is_expanded fun(node: GitUITreeNode): boolean
---@param visit fun(node: GitUITreeNode, expanded: boolean)
function M.walk(nodes, is_expanded, visit)
  for _, node in ipairs(nodes) do
    if node.kind == "directory" then
      local expanded = is_expanded(node)
      visit(node, expanded)
      if expanded then
        M.walk(node.children, is_expanded, visit)
      end
    else
      visit(node, false)
    end
  end
end

---Every directory id in a tree, so "expand all" / "collapse all" can act on
---the whole structure at once.
---@param nodes GitUITreeNode[]
---@return string[]
function M.directory_ids(nodes)
  local ids = {}
  local function collect(list)
    for _, node in ipairs(list) do
      if node.kind == "directory" then
        ids[#ids + 1] = node.id
        collect(node.children)
      end
    end
  end
  collect(nodes)
  return ids
end

---Count the files in a tree.
---@param nodes GitUITreeNode[]
---@return integer
function M.count(nodes)
  local total = 0
  for _, node in ipairs(nodes) do
    total = total + #node.paths
  end
  return total
end

return M
