--- neorg-project-manager.status: Project status tree generation and surgical updates.
---
--- Two modes of operation:
---   1. Full generation (for empty files): renders the complete project tree as norg content
---   2. Surgical update (for files with existing content): only updates managed headings'
---      todo states and progress counts, preserving all manual content
---
--- A "managed heading" is one that contains a `{* <number>}` link where the number
--- matches a known file/directory prefix. The link serves as the ownership marker —
--- the plugin can update that heading's state but never touches unlinked content.
---
--- @module neorg-project-manager.status

local M = {}

local config = require("neorg-project-manager.config")
local project = require("neorg-project-manager.project")
local index = require("neorg-project-manager.index")
local helpers = require("neorg-project-manager.helpers")

---------------------------------------------------------------------------
--- STATE AGGREGATION
---------------------------------------------------------------------------

--- Aggregate todo state from a list of child states.
---
--- @param child_states string[]  List of state strings
--- @return string state          Aggregated state
--- @return number done           Count of done children
--- @return number total          Count of total children
function M.aggregate_state(child_states)
    local counts = { done = 0, undone = 0, pending = 0, on_hold = 0, cancelled = 0 }
    local total = 0

    for _, state in ipairs(child_states) do
        if state then
            total = total + 1
            if counts[state] then
                counts[state] = counts[state] + 1
            else
                counts.undone = counts.undone + 1
            end
        end
    end

    if total == 0 then
        return "undone", 0, 0
    end

    local done = counts.done

    if done == total then
        return "done", done, total
    elseif counts.on_hold + counts.cancelled == total then
        return "on_hold", done, total
    elseif done > 0 or counts.pending > 0 then
        return "pending", done, total
    else
        return "undone", done, total
    end
end

--- Convert a state name to its norg character.
--- @param state string|nil
--- @return string
local function state_to_char(state)
    local map = {
        done = "x", undone = " ", pending = "-", on_hold = "=",
        cancelled = "_", important = "!", recurring = "+", ambiguous = "?",
    }
    return map[state] or " "
end

---------------------------------------------------------------------------
--- TREE BUILDING (for full generation)
---------------------------------------------------------------------------

--- Build a status tree for a directory (recursive for state aggregation).
---
--- @param dir_path string
--- @return table  StatusNode tree
function M.build_directory_tree(dir_path)
    local entries = {}

    local handle = vim.uv.fs_scandir(dir_path)
    if not handle then
        return { prefix = nil, title = "Unknown", state = "undone", is_dir = true, children = {}, done = 0, total = 0 }
    end

    while true do
        local name, entry_type = vim.uv.fs_scandir_next(handle)
        if not name then break end
        if name:sub(1, 1) == "." or name == "index.norg" or name == "project.norg" then
            goto continue
        end

        local prefix, title = project.extract_prefix(name)
        if prefix then
            if entry_type == "directory" then
                local child_tree = M.build_directory_tree(dir_path .. "/" .. name)
                table.insert(entries, {
                    prefix = prefix, title = title, state = child_tree.state,
                    is_dir = true, filepath = nil, children = child_tree.children,
                    done = child_tree.done, total = child_tree.total,
                })
            elseif entry_type == "file" and name:match("%.norg$") then
                local filepath = dir_path .. "/" .. name
                local file_state = index.get_file_state(filepath, prefix)
                table.insert(entries, {
                    prefix = prefix, title = title, state = file_state,
                    is_dir = false, filepath = filepath, children = {},
                    done = 0, total = 0,
                })
            end
        end
        ::continue::
    end

    table.sort(entries, function(a, b)
        return helpers.natural_sort_prefixes(a.prefix or "", b.prefix or "")
    end)

    local child_states = {}
    for _, entry in ipairs(entries) do table.insert(child_states, entry.state) end
    local agg_state, done, total = M.aggregate_state(child_states)

    local dir_name = vim.fn.fnamemodify(dir_path, ":t")
    local dir_prefix, dir_title = project.extract_prefix(dir_name)

    return {
        prefix = dir_prefix, title = dir_title or dir_name, state = agg_state,
        is_dir = true, filepath = nil, children = entries, done = done, total = total,
    }
end

--- Build full project tree.
--- @param root_path string
--- @return table
function M.build_project_tree(root_path)
    local tree = M.build_directory_tree(root_path)
    tree.title = vim.fn.fnamemodify(root_path, ":t")
    return tree
end

---------------------------------------------------------------------------
--- NORG RENDERING (for full generation of empty files)
---------------------------------------------------------------------------

--- Render a status tree as norg heading lines.
---
--- @param tree table        StatusNode tree
--- @param opts table|nil    {max_depth, base_level}
--- @return string[]         Lines of norg content
function M.render_as_norg(tree, opts)
    opts = opts or {}
    local max_depth = opts.max_depth or 6
    local base_level = opts.base_level or 0
    local lines = {}

    local function render_node(node, level)
        if level > max_depth then return end

        local stars = string.rep("*", level)
        local todo_str = node.state and (" (" .. state_to_char(node.state) .. ")") or ""
        local title_sep = config.get("number_title_separator", ". ")
        local title_str = node.prefix and (" " .. node.prefix .. title_sep .. node.title) or (" " .. node.title)
        local link_str = node.prefix and (" {* " .. node.prefix .. "}") or ""
        local progress_str = node.total > 0 and (" [" .. node.done .. "/" .. node.total .. "]") or ""

        table.insert(lines, stars .. todo_str .. title_str .. link_str .. progress_str)

        for _, child in ipairs(node.children) do
            render_node(child, level + 1)
        end
    end

    render_node(tree, base_level + 1)
    return lines
end

---------------------------------------------------------------------------
--- SURGICAL UPDATE (for files with existing content)
---------------------------------------------------------------------------

--- Build a flat map of project entries with their states.
--- Returns { number → { state, done, total, title, is_dir } }
---
--- @param scope_path string   Directory to scan
--- @param scope_type string   "project" (full recursive) or "index" (direct children)
--- @return table              Map of number → entry data
local function build_entry_states(scope_path, scope_type)
    local tree
    if scope_type == "project" then
        tree = M.build_project_tree(scope_path)
    else
        tree = M.build_directory_tree(scope_path)
    end

    local result = {}

    local function flatten(node, max_depth, depth)
        if depth > max_depth then return end
        if node.prefix then
            result[node.prefix] = {
                state = node.state,
                done = node.done,
                total = node.total,
                title = node.title,
                is_dir = node.is_dir,
            }
        end
        for _, child in ipairs(node.children) do
            flatten(child, max_depth, depth + 1)
        end
    end

    local max_depth = (scope_type == "project") and 100 or 2
    flatten(tree, max_depth, 1)
    return result
end

--- Build a new managed heading line for insertion.
---
--- @param entry table    {state, done, total, title, is_dir, prefix}
--- @param level number   Heading level (number of stars)
--- @return string        Complete norg heading line
local function build_managed_heading_line(entry, level)
    local stars = string.rep("*", level)
    local todo_str = entry.state and (" (" .. state_to_char(entry.state) .. ")") or ""
    local title_sep = config.get("number_title_separator", ". ")
    local title_str = " " .. entry.prefix .. title_sep .. entry.title
    local link_str = " {* " .. entry.prefix .. "}"
    local progress_str = entry.total > 0 and (" [" .. entry.done .. "/" .. entry.total .. "]") or ""
    return stars .. todo_str .. title_str .. link_str .. progress_str
end

--- Update a single managed heading line with new state and count.
--- Returns the updated line text, or nil if no change needed.
---
--- @param line string       Current line text
--- @param new_state string  New state character (e.g., "x", "-", " ")
--- @param new_count string|nil  New count text (e.g., "[3/5]") or nil for no count
--- @return string|nil       Updated line, or nil if unchanged
local function update_managed_line(line, new_state, new_count)
    local updated = line

    -- Update the todo state character: find (X) pattern and replace
    -- Uses %b() to match balanced parentheses, then check if it's a single-char todo state
    updated = updated:gsub("%b()", function(match)
        local inner = match:sub(2, -2)
        if #inner == 1 then
            -- Single char in parens = todo state marker
            if inner ~= new_state then
                return "(" .. new_state .. ")"
            end
        end
        return match
    end, 1) -- only first occurrence

    -- Update or insert the progress count [N/M]
    if new_count then
        if updated:match("%[%d+/%d+%]") then
            -- Replace existing count
            updated = updated:gsub("%[%d+/%d+%]", new_count)
        else
            -- Append count at end of line
            updated = updated .. " " .. new_count
        end
    else
        -- Remove count if present but no longer applicable
        updated = updated:gsub("%s*%[%d+/%d+%]%s*$", "")
    end

    if updated == line then
        return nil
    end
    return updated
end

--- Perform a surgical update of managed headings in a file (on disk).
--- Only updates headings with {* number} links; preserves all other content.
--- Inserts new headings for project entries not yet represented.
---
--- @param filepath string      Path to the .norg file to update
--- @param scope_path string    Directory to scan for project state
--- @param scope_type string    "project" or "index"
function M.update_file(filepath, scope_path, scope_type)
    -- Clear the project entry cache (forces re-scan of directory structure)
    -- but keep per-file caches (mtime check handles staleness)
    index.invalidate_project_cache()

    local lines = vim.fn.readfile(filepath)
    local entry_states = build_entry_states(scope_path, scope_type)

    -- Track which project entries are represented by managed headings
    local represented = {}
    local modified = false

    -- Pass 1: Update existing managed headings
    for i, line in ipairs(lines) do
        local number = helpers.extract_link_number_from_line(line)
        if number and entry_states[number] then
            represented[number] = true
            local entry = entry_states[number]

            local new_state = state_to_char(entry.state)
            local new_count = entry.total > 0 and string.format("[%d/%d]", entry.done, entry.total) or nil
            local updated_line = update_managed_line(line, new_state, new_count)

            if updated_line then
                lines[i] = updated_line
                modified = true
            end
        end
    end

    -- Pass 2: Insert headings for unrepresented entries
    local insertions = {} -- { {after_line_index, text} } (processed in reverse)

    for number, entry in pairs(entry_states) do
        if not represented[number] then
            -- Determine heading level from number depth relative to scope
            local scope_depth = (scope_type == "project") and 0 or helpers.prefix_depth(
                project.extract_prefix(vim.fn.fnamemodify(scope_path, ":t"))
            )
            local entry_depth = helpers.prefix_depth(number)
            local level = entry_depth - scope_depth
            if level < 1 then level = 1 end
            if level > 6 then level = 6 end

            entry.prefix = number
            local new_line = build_managed_heading_line(entry, level)

            -- Find insertion point: after last managed sibling with lower number
            local insert_after = #lines -- default: end of file
            for i, line in ipairs(lines) do
                local line_number = helpers.extract_link_number_from_line(line)
                if line_number and line_number < number then
                    insert_after = i
                end
            end

            table.insert(insertions, { pos = insert_after, text = new_line })
        end
    end

    -- Sort insertions by position (descending) to insert from bottom up
    table.sort(insertions, function(a, b) return a.pos > b.pos end)
    for _, ins in ipairs(insertions) do
        table.insert(lines, ins.pos + 1, ins.text)
        modified = true
    end

    if modified then
        vim.fn.writefile(lines, filepath)
    end
end

--- Perform a surgical update on the current buffer (in-memory, not saved).
--- For use with :NeorgPMStatus on a populated file.
---
--- @param buf number  Buffer handle
function M.update(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        vim.notify("Cannot update status: buffer has no filename", vim.log.levels.WARN)
        return
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")

    local scope_path, scope_type
    if filename == "project.norg" then
        scope_path = dir_path
        scope_type = "project"
    elseif filename == "index.norg" then
        scope_path = dir_path
        scope_type = "index"
    else
        vim.notify("NeorgPMStatus only works in project.norg or index.norg files", vim.log.levels.WARN)
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local entry_states = build_entry_states(scope_path, scope_type)
    local represented = {}
    local modified = false

    -- Pass 1: Update existing managed headings
    for i, line in ipairs(lines) do
        local number = helpers.extract_link_number_from_line(line)
        if number and entry_states[number] then
            represented[number] = true
            local entry = entry_states[number]

            local new_state = state_to_char(entry.state)
            local new_count = entry.total > 0 and string.format("[%d/%d]", entry.done, entry.total) or nil
            local updated_line = update_managed_line(line, new_state, new_count)

            if updated_line then
                lines[i] = updated_line
                modified = true
            end
        end
    end

    -- Pass 2: Insert headings for unrepresented entries
    local insertions = {}

    for number, entry in pairs(entry_states) do
        if not represented[number] then
            local scope_prefix = project.extract_prefix(vim.fn.fnamemodify(scope_path, ":t"))
            local scope_depth = helpers.prefix_depth(scope_prefix)
            local entry_depth = helpers.prefix_depth(number)
            local level = entry_depth - scope_depth
            if level < 1 then level = 1 end
            if level > 6 then level = 6 end

            entry.prefix = number
            local new_line = build_managed_heading_line(entry, level)

            local insert_after = #lines
            for i, line in ipairs(lines) do
                local line_number = helpers.extract_link_number_from_line(line)
                if line_number and line_number < number then
                    insert_after = i
                end
            end

            table.insert(insertions, { pos = insert_after, text = new_line })
        end
    end

    table.sort(insertions, function(a, b) return a.pos > b.pos end)
    for _, ins in ipairs(insertions) do
        table.insert(lines, ins.pos + 1, ins.text)
        modified = true
    end

    if modified then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
end

---------------------------------------------------------------------------
--- GENERATION (for empty files)
---------------------------------------------------------------------------

--- Generate full status content for an empty buffer.
---
--- @param buf number  Buffer handle
function M.generate(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        vim.notify("Cannot generate status: buffer has no filename", vim.log.levels.WARN)
        return
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")
    local tree, render_opts

    if filename == "project.norg" then
        tree = M.build_project_tree(dir_path)
        render_opts = { max_depth = 6, base_level = 0 }
    elseif filename == "index.norg" then
        tree = M.build_directory_tree(dir_path)
        render_opts = { max_depth = 2, base_level = 0 }
    else
        vim.notify("NeorgPMStatus only works in project.norg or index.norg files", vim.log.levels.WARN)
        return
    end

    local norg_lines = M.render_as_norg(tree, render_opts)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, norg_lines)
end

---------------------------------------------------------------------------
--- REGENERATE ALL (for project-wide renaming)
---------------------------------------------------------------------------

--- Regenerate all index.norg + project.norg files using surgical updates.
--- Creates files that don't exist; surgically updates those that do.
---
--- @param root_path string  Project root directory
function M.regenerate_all(root_path)
    -- Update project.norg
    local project_file = root_path .. "/project.norg"
    if vim.fn.filereadable(project_file) == 0 then
        local tree = M.build_project_tree(root_path)
        local lines = M.render_as_norg(tree, { max_depth = 6, base_level = 0 })
        vim.fn.writefile(lines, project_file)
    else
        M.update_file(project_file, root_path, "project")
    end

    -- Update all index.norg files in subdirectories
    local function regen_indices(dir_path)
        local handle = vim.uv.fs_scandir(dir_path)
        if not handle then return end

        while true do
            local name, entry_type = vim.uv.fs_scandir_next(handle)
            if not name then break end
            if name:sub(1, 1) == "." then goto continue end

            if entry_type == "directory" then
                local sub_path = dir_path .. "/" .. name
                local prefix, _ = project.extract_prefix(name)
                if prefix then
                    local idx_file = sub_path .. "/index.norg"
                    if vim.fn.filereadable(idx_file) == 0 then
                        local dir_tree = M.build_directory_tree(sub_path)
                        local idx_lines = M.render_as_norg(dir_tree, { max_depth = 2, base_level = 0 })
                        vim.fn.writefile(idx_lines, idx_file)
                    else
                        M.update_file(idx_file, sub_path, "index")
                    end
                end
                regen_indices(sub_path)
            end
            ::continue::
        end
    end

    regen_indices(root_path)
end

return M
