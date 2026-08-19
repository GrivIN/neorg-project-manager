--- neorg-project-manager.index: Project-wide number index with lazy loading.
---
--- Maps number strings to their file + line location across all project files.
--- Uses lazy loading: files are only parsed when referenced. Cached with mtime.
---
--- @module neorg-project-manager.index

local M = {}

local config = require("neorg-project-manager.config")
local project = require("neorg-project-manager.project")
local helpers = require("neorg-project-manager.helpers")
local numbering = require("neorg-project-manager.numbering")

--- Cache of indexed files: filepath → {mtime, headings}
--- @type table<string, {mtime: number, headings: table}>
local file_cache = {}

--- Cached project entries (from project.scan).
--- @type {root: string, entries: ProjectEntry[], scan_time: number}|nil
local project_cache = nil

---------------------------------------------------------------------------
--- FILE PARSING
---------------------------------------------------------------------------

--- Parse a single .norg file from disk and extract heading numbers + todo states.
--- Reuses numbering.format_number and numbering.parse_number_and_title for consistency.
---
--- Read a .norg file from disk and parse it into a tree-sitter root node.
---
--- @param filepath string  Absolute path to the .norg file
--- @return TSNode|nil root      The tree-sitter root node
--- @return string|nil content   The file content (needed as source for get_node_text)
local function read_and_parse(filepath)
    local content = table.concat(vim.fn.readfile(filepath), "\n")
    if content == "" then
        return nil, nil
    end

    local ok, parser = pcall(vim.treesitter.get_string_parser, content, "norg")
    if not ok or not parser then
        return nil, nil
    end

    local tree = parser:parse()[1]
    if not tree then
        return nil, nil
    end

    return tree:root(), content
end

--- Walk a tree-sitter AST and collect heading numbers + todo states.
--- Uses numbering module for consistent number formatting and title parsing.
---
--- @param root TSNode        The tree-sitter root node
--- @param content string     The file content (source for get_node_text)
--- @param prefix string|nil  The file's number prefix
--- @return table             { number_string → {line, level, state} }
local function collect_headings_from_tree(root, content, prefix)
    local headings_map = {}
    local counters = { 0, 0, 0, 0, 0, 0 }

    local function collect(node)
        local node_type = node:type()

        for level = 1, 6 do
            if node_type == "heading" .. level then
                counters[level] = counters[level] + 1
                for i = level + 1, 6 do
                    counters[i] = 0
                end

                -- Get title text from paragraph_segment
                local title_text = nil
                for child in node:iter_children() do
                    if child:type() == "paragraph_segment" then
                        title_text = vim.treesitter.get_node_text(child, content)
                        break
                    end
                end

                -- Parse existing number or compute one
                local num
                if title_text then
                    local existing, _, _ = numbering.parse_number_and_title(title_text)
                    num = existing or numbering.format_number(counters, level, prefix)
                else
                    num = numbering.format_number(counters, level, prefix)
                end

                -- Get todo state
                local state = helpers.get_todo_state(node)

                headings_map[num] = { line = node:start(), level = level, state = state }

                for child in node:iter_children() do
                    collect(child)
                end
                return
            end
        end

        for child in node:iter_children() do
            collect(child)
        end
    end

    collect(root)
    return headings_map
end

--- Parse a .norg file from disk and extract heading numbers + todo states.
--- Combines read_and_parse + collect_headings_from_tree.
---
--- @param filepath string    Absolute path to the .norg file
--- @param prefix string|nil  The file's number prefix (from filename)
--- @return table             { number_string → {line, level, state} }
function M.index_file(filepath, prefix)
    local root, content = read_and_parse(filepath)
    if not root then
        return {}
    end
    return collect_headings_from_tree(root, content, prefix)
end

---------------------------------------------------------------------------
--- CACHING
---------------------------------------------------------------------------

--- Get mtime of a file, nil if not found.
--- @param filepath string
--- @return number|nil
local function get_mtime(filepath)
    local stat = vim.uv.fs_stat(filepath)
    return stat and stat.mtime.sec or nil
end

--- Get cached index for a file, re-parsing if stale.
--- @param filepath string
--- @param prefix string|nil
--- @return table
local function get_file_index(filepath, prefix)
    local mtime = get_mtime(filepath)
    if not mtime then
        return {}
    end

    local cached = file_cache[filepath]
    if cached and cached.mtime == mtime then
        return cached.headings
    end

    local headings = M.index_file(filepath, prefix)
    file_cache[filepath] = { mtime = mtime, headings = headings }
    return headings
end

--- Invalidate cache for a file. Called on BufWritePost.
--- @param filepath string
function M.invalidate(filepath)
    file_cache[filepath] = nil
end

--- Force full rebuild of all caches. Called after project-wide renaming.
function M.rebuild()
    file_cache = {}
    project_cache = nil
end

--- Invalidate only the project entry cache (directory scan).
--- Per-file caches are kept — mtime check handles staleness.
--- Use this during surgical updates to pick up new/removed files without
--- re-parsing every file from disk.
function M.invalidate_project_cache()
    project_cache = nil
end

---------------------------------------------------------------------------
--- PROJECT INDEX
---------------------------------------------------------------------------

--- Get project entries (cached, refreshed every 5 seconds).
--- @param root string
--- @return ProjectEntry[]
local function get_project_entries(root)
    local now = os.time()
    if project_cache and project_cache.root == root and (now - project_cache.scan_time) < 5 then
        return project_cache.entries
    end

    local entries = project.scan(root)
    project_cache = { root = root, entries = entries, scan_time = now }
    return entries
end

--- Get the unified project index for a buffer.
--- Returns a lazy proxy table: lookups parse files on demand and cache results.
--- Uses a prefix lookup table for O(1) file resolution instead of linear scan.
---
--- @param buf number  Buffer handle
--- @return table      Proxy: index[number] → {filepath, line, level, state} or nil
function M.get(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)
    if not root then
        return {}
    end

    local entries = get_project_entries(root)

    -- Pre-build prefix → entry lookup table (O(1) instead of O(n) per access)
    local prefix_to_entry = {}
    for _, entry in ipairs(entries) do
        if not entry.is_dir then
            prefix_to_entry[entry.prefix] = entry
        end
    end

    return setmetatable({}, {
        __index = function(_, number_key)
            -- Try resolving via longest prefix match
            local resolved = project.resolve_number_to_file(number_key, entries)
            if not resolved then
                -- Maybe number IS a file prefix (target = file itself)
                local entry = prefix_to_entry[number_key]
                if entry then
                    local file_headings = get_file_index(entry.filepath, entry.prefix)
                    local target = file_headings[number_key]
                    if target then
                        return { filepath = entry.filepath, line = target.line, level = target.level, state = target.state }
                    end
                    return { filepath = entry.filepath, line = 0, level = 0, state = nil }
                end

                -- Fallback: search in status files for each directory
                -- Headings that only exist inside status files (not as standalone files)
                local status_files_to_check = {}
                local root_status = project.find_status_file(root)
                if root_status and vim.fn.filereadable(root_status) == 1 then
                    table.insert(status_files_to_check, root_status)
                end
                -- Also check status files in directories found by the scan
                for _, dir_entry in ipairs(entries) do
                    if dir_entry.is_dir then
                        local dir_status = project.find_status_file(dir_entry.filepath)
                        if dir_status and vim.fn.filereadable(dir_status) == 1 then
                            table.insert(status_files_to_check, dir_status)
                        end
                    end
                end

                for _, status_file in ipairs(status_files_to_check) do
                    local status_prefix, _ = project.extract_prefix(vim.fn.fnamemodify(status_file, ":t"))
                    local headings = get_file_index(status_file, status_prefix)
                    local target_in_status = headings[number_key]
                    if target_in_status then
                        return {
                            filepath = status_file,
                            line = target_in_status.line,
                            level = target_in_status.level,
                            state = target_in_status.state,
                        }
                    end
                end

                return nil
            end

            local file_headings = get_file_index(resolved.filepath, resolved.prefix)
            local target = file_headings[number_key]
            if target then
                return { filepath = resolved.filepath, line = target.line, level = target.level, state = target.state }
            end
            return nil
        end,
    })
end

--- Get all indexed headings for a specific file.
--- @param filepath string
--- @param prefix string|nil
--- @return table
function M.get_file_headings(filepath, prefix)
    return get_file_index(filepath, prefix)
end

--- Get the top-level state of a file (state of its first heading).
--- @param filepath string
--- @param prefix string|nil
--- @return string|nil
function M.get_file_state(filepath, prefix)
    local headings = get_file_index(filepath, prefix)
    local first_state = nil
    local first_line = math.huge

    for _, info in pairs(headings) do
        if info.line < first_line then
            first_line = info.line
            first_state = info.state
        end
    end

    return first_state
end

return M
