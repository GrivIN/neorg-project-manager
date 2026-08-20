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
--- Rules:
---   - Cancelled children are excluded from the active pool (don't inflate totals).
---   - If every child is cancelled, the parent is cancelled with 0/0.
---   - All active ambiguous → primary is ambiguous (no qualifier needed).
---   - Otherwise, ambiguous propagates as a qualifier: if any active child has
---     ambiguous as primary state or qualifier, the parent gets an ambiguous qualifier.
---   - Important is local-only: treated as undone for aggregation purposes.
---   - All active done → done.
---   - All active on_hold (or on_hold + ambiguous) → on_hold.
---   - Any done or pending among active → pending.
---   - Otherwise → undone.
---
--- Accepts either plain state strings (backward compatible) or tables with
--- {state = string, qualifiers = string[]}.
---
--- @param child_states (string|{state: string, qualifiers: string[]})[]
--- @return string state          Aggregated primary state
--- @return number done           Count of done children (active only)
--- @return number total          Count of active children (excludes cancelled)
--- @return string[] qualifiers   Propagated qualifier list (e.g., {"ambiguous"})
function M.aggregate_state(child_states)
    local counts = { done = 0, undone = 0, pending = 0, on_hold = 0, cancelled = 0, ambiguous = 0 }
    local total = 0
    local has_ambiguous_qualifier = false

    for _, child in ipairs(child_states) do
        local state, qualifiers
        if type(child) == "table" then
            state = child.state
            qualifiers = child.qualifiers or {}
        else
            state = child
            qualifiers = {}
        end

        if state then
            total = total + 1
            if counts[state] ~= nil then
                counts[state] = counts[state] + 1
            else
                -- important, recurring, and any unknown states count as undone
                counts.undone = counts.undone + 1
            end
        end

        -- Track ambiguous from qualifiers
        for _, q in ipairs(qualifiers) do
            if q == "ambiguous" then
                has_ambiguous_qualifier = true
            end
        end
    end

    if total == 0 then
        return "undone", 0, 0, {}
    end

    -- Exclude cancelled from active pool
    local active = total - counts.cancelled
    local done = counts.done

    -- All items cancelled → parent is cancelled
    if active == 0 then
        return "cancelled", 0, 0, {}
    end

    -- All active items are ambiguous → primary is ambiguous (no qualifier)
    if counts.ambiguous == active then
        return "ambiguous", done, active, {}
    end

    -- Compute primary state (ambiguous items count as "not done" for primary)
    local primary
    if done == active then
        primary = "done"
    elseif counts.on_hold + counts.ambiguous == active then
        -- All active items are either on_hold or ambiguous
        primary = "on_hold"
    elseif done > 0 or counts.pending > 0 then
        primary = "pending"
    else
        primary = "undone"
    end

    -- Collect propagated qualifiers
    local agg_qualifiers = {}
    if counts.ambiguous > 0 or has_ambiguous_qualifier then
        table.insert(agg_qualifiers, "ambiguous")
    end

    return primary, done, active, agg_qualifiers
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

--- Valid norg todo characters for marker detection.
local valid_todo_chars = {
    ["x"] = true, [" "] = true, ["-"] = true, ["="] = true,
    ["_"] = true, ["!"] = true, ["+"] = true, ["?"] = true,
}

--- Check if a string inside parentheses is a valid todo marker.
--- Handles both single-char `(x)` and compound `(-|?)` markers.
--- @param inner string  Content between parentheses
--- @return boolean
local function is_todo_marker(inner)
    for part in (inner .. "|"):gmatch("([^|]*)|") do
        if #part ~= 1 or not valid_todo_chars[part] then
            return false
        end
    end
    return #inner > 0
end

--- Characters that the norg scanner also treats as attached modifiers
--- (strikethrough, underline, spoiler). These CANNOT be the first character
--- in a compound marker — the scanner refuses to emit a `|` delimiter after them.
--- When rendering, qualifiers are placed before these characters.
local unsafe_first_chars = { ["-"] = true, ["_"] = true, ["!"] = true }

--- Build the inner content of a norg todo marker from state + qualifiers.
--- Returns single char for simple states, pipe-delimited for compound.
--- Automatically reorders to avoid parser-unsafe first characters:
--- e.g., pending + ambiguous renders as `?|-` (not `-|?` which fails to parse).
--- If no safe ordering exists (all chars are unsafe), drops qualifiers and
--- renders the primary alone.
--- @param state string          Primary state name
--- @param qualifiers string[]|nil  Optional qualifier state names
--- @return string               e.g., "-" or "?|-"
local function build_marker_inner(state, qualifiers)
    if not qualifiers or #qualifiers == 0 then
        return state_to_char(state)
    end

    local primary_char = state_to_char(state)
    local qual_chars = {}
    for _, q in ipairs(qualifiers) do
        table.insert(qual_chars, state_to_char(q))
    end

    if not unsafe_first_chars[primary_char] then
        -- Primary is safe first — normal order: primary|qual1|qual2
        local parts = { primary_char }
        for _, qc in ipairs(qual_chars) do table.insert(parts, qc) end
        return table.concat(parts, "|")
    end

    -- Primary is unsafe first — find a safe qualifier to put first
    local safe_idx = nil
    for i, qc in ipairs(qual_chars) do
        if not unsafe_first_chars[qc] then
            safe_idx = i
            break
        end
    end

    if safe_idx then
        -- Put the safe qualifier first, then the rest
        local parts = { qual_chars[safe_idx] }
        for i, qc in ipairs(qual_chars) do
            if i ~= safe_idx then table.insert(parts, qc) end
        end
        table.insert(parts, primary_char)
        return table.concat(parts, "|")
    end

    -- No safe character exists at all — drop qualifiers to avoid parse failure
    return primary_char
end

--- Build the full norg todo marker string including parentheses.
--- @param state string          Primary state name
--- @param qualifiers string[]|nil  Optional qualifier state names
--- @return string               e.g., "(-)" or "(?|-)"
local function build_norg_marker(state, qualifiers)
    return "(" .. build_marker_inner(state, qualifiers) .. ")"
end

---------------------------------------------------------------------------
--- TREE BUILDING (for full generation)
---------------------------------------------------------------------------

--- Build a status tree for a directory (recursive for state aggregation).
--- Skips the directory's own status file (the file whose prefix matches
--- the directory's prefix) to avoid self-referencing entries.
---
--- @param dir_path string
--- @param skip_file string|nil  Filename to skip (explicit override; if nil, auto-detects)
--- @return table  StatusNode tree
function M.build_directory_tree(dir_path, skip_file)
    local entries = {}

    -- Determine which file to skip: either explicit or auto-detect the status file
    local status_file_path = skip_file and (dir_path .. "/" .. skip_file) or project.find_status_file(dir_path)
    local status_file_name = status_file_path and vim.fn.fnamemodify(status_file_path, ":t") or nil

    helpers.scandir(dir_path, function(name, entry_type, full_path)
        -- Skip the status file for this directory
        if status_file_name and name == status_file_name then
            return
        end

        local prefix, title = project.extract_prefix(name)
        if prefix then
            if entry_type == "directory" then
                local child_tree = M.build_directory_tree(full_path)
                table.insert(entries, {
                    prefix = prefix, title = title, state = child_tree.state,
                    qualifiers = child_tree.qualifiers or {},
                    is_dir = true, filepath = nil, children = child_tree.children,
                    done = child_tree.done, total = child_tree.total,
                })
            elseif entry_type == "file" and name:match("%.norg$") then
                local file_state, file_qualifiers = index.get_file_state(full_path, prefix)
                table.insert(entries, {
                    prefix = prefix, title = title, state = file_state,
                    qualifiers = file_qualifiers or {},
                    is_dir = false, filepath = full_path, children = {},
                    done = 0, total = 0,
                })
            end
        end
    end)

    table.sort(entries, function(a, b)
        return helpers.natural_sort_prefixes(a.prefix or "", b.prefix or "")
    end)

    local child_entries = {}
    for _, entry in ipairs(entries) do
        table.insert(child_entries, { state = entry.state, qualifiers = entry.qualifiers or {} })
    end
    local agg_state, done, total, agg_qualifiers = M.aggregate_state(child_entries)

    local dir_name = vim.fn.fnamemodify(dir_path, ":t")
    local dir_prefix, dir_title = project.extract_prefix(dir_name)

    return {
        prefix = dir_prefix, title = dir_title or dir_name, state = agg_state,
        qualifiers = agg_qualifiers or {},
        is_dir = true, filepath = nil, children = entries, done = done, total = total,
    }
end

--- Build full project tree.
--- @param root_path string
--- @param skip_file string|nil  Filename to skip (e.g., root-level status file)
--- @return table
function M.build_project_tree(root_path, skip_file)
    local tree = M.build_directory_tree(root_path, skip_file)
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
        local todo_str = node.state and (" " .. build_norg_marker(node.state, node.qualifiers)) or ""
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
--- Returns { number → { state, qualifiers, done, total, title, is_dir } }
---
--- @param scope_path string   Directory to scan
--- @param scope_type string   "project" (full recursive) or "index" (direct children)
--- @param skip_file string|nil  Filename to skip (e.g., root-level status file)
--- @return table              Map of number → entry data
local function build_entry_states(scope_path, scope_type, skip_file)
    local tree
    if scope_type == "project" then
        tree = M.build_project_tree(scope_path, skip_file)
    else
        tree = M.build_directory_tree(scope_path, skip_file)
    end

    local result = {}

    local function flatten(node, max_depth, depth)
        if depth > max_depth then return end
        if node.prefix then
            result[node.prefix] = {
                state = node.state,
                qualifiers = node.qualifiers or {},
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
--- @param entry table    {state, qualifiers, done, total, title, is_dir, prefix}
--- @param level number   Heading level (number of stars)
--- @return string        Complete norg heading line
local function build_managed_heading_line(entry, level)
    local stars = string.rep("*", level)
    local todo_str = entry.state and (" " .. build_norg_marker(entry.state, entry.qualifiers)) or ""
    local title_sep = config.get("number_title_separator", ". ")
    local title_str = " " .. entry.prefix .. title_sep .. entry.title
    local link_str = " {* " .. entry.prefix .. "}"
    local progress_str = entry.total > 0 and (" [" .. entry.done .. "/" .. entry.total .. "]") or ""
    return stars .. todo_str .. title_str .. link_str .. progress_str
end

--- Update a single managed heading line with new state and count.
--- Returns the updated line text, or nil if no change needed.
--- Handles both simple `(x)` and compound `(-|?)` todo markers.
---
--- @param line string       Current line text
--- @param new_marker string New marker inner content (e.g., "x", "-", "-|?")
--- @param new_count string|nil  New count text (e.g., "[3/5]") or nil for no count
--- @return string|nil       Updated line, or nil if unchanged
local function update_managed_line(line, new_marker, new_count)
    local updated = line

    -- Update the todo state: find parenthesized todo marker and replace
    updated = updated:gsub("%b()", function(match)
        local inner = match:sub(2, -2)
        if is_todo_marker(inner) then
            if inner ~= new_marker then
                return "(" .. new_marker .. ")"
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

--- Apply status updates to a set of lines (shared algorithm for update_file and update).
--- Pass 1: Updates managed headings' todo states and progress counts.
--- Pass 2: Inserts headings for entries not yet represented.
---
--- @param lines string[]       Lines of norg content
--- @param entry_states table   Map of number → {state, qualifiers, done, total, title, is_dir}
--- @param scope_path string    Directory path (for computing heading levels)
--- @param scope_type string    "project" or "index"
--- @return string[] lines      The (potentially modified) lines
--- @return boolean modified    Whether any line was changed
local function apply_status_updates(lines, entry_states, scope_path, scope_type)
    local represented = {}
    local modified = false

    -- Pass 1: Update existing managed headings
    for i, line in ipairs(lines) do
        local number = helpers.extract_link_number_from_line(line)
        if number and entry_states[number] then
            represented[number] = true
            local entry = entry_states[number]

            local new_marker = build_marker_inner(entry.state, entry.qualifiers)
            local new_count = entry.total > 0 and string.format("[%d/%d]", entry.done, entry.total) or nil
            local updated_line = update_managed_line(line, new_marker, new_count)

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

    return lines, modified
end

--- Perform a surgical update of managed headings in a file (on disk).
--- Only updates headings with {* number} links; preserves all other content.
--- Inserts new headings for project entries not yet represented.
---
--- @param filepath string      Path to the .norg file to update
--- @param scope_path string    Directory to scan for project state
--- @param scope_type string    "project" or "index"
function M.update_file(filepath, scope_path, scope_type)
    index.invalidate_project_cache()

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local lines = vim.fn.readfile(filepath)
    local entry_states = build_entry_states(scope_path, scope_type, filename)

    lines, modified = apply_status_updates(lines, entry_states, scope_path, scope_type)

    if modified then
        vim.fn.writefile(lines, filepath)
    end
end

--- Perform a surgical update on the current buffer (in-memory, not saved).
--- For use with :NeorgPMStatus on a populated file.
--- Works on any status file (root-level numbered file or directory-matching file).
---
--- @param buf number  Buffer handle
function M.update(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        vim.notify("Cannot update status: buffer has no filename", vim.log.levels.WARN)
        return
    end

    if not project.is_status_file(filepath) then
        vim.notify("NeorgPMStatus only works on status files (root-level or directory-matching numbered files)", vim.log.levels.WARN)
        return
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")

    -- Determine scope: root gets full recursive scan, subdirs get direct children
    local root = project.find_root(filepath)
    local scope_type
    if root and vim.fn.fnamemodify(dir_path, ":p") == vim.fn.fnamemodify(root, ":p") then
        scope_type = "project"
    else
        scope_type = "index"
    end

    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    local entry_states = build_entry_states(dir_path, scope_type, filename)

    lines, modified = apply_status_updates(lines, entry_states, dir_path, scope_type)

    if modified then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
end

---------------------------------------------------------------------------
--- GENERATION (for empty files)
---------------------------------------------------------------------------

--- Generate full status content for an empty buffer.
--- Works on any status file (root-level or directory-matching).
---
--- @param buf number  Buffer handle
function M.generate(buf)
    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        vim.notify("Cannot generate status: buffer has no filename", vim.log.levels.WARN)
        return
    end

    if not project.is_status_file(filepath) then
        vim.notify("NeorgPMStatus only works on status files (root-level or directory-matching numbered files)", vim.log.levels.WARN)
        return
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    local dir_path = vim.fn.fnamemodify(filepath, ":p:h")

    -- Determine scope: root gets full recursive, subdirs get direct children
    local root = project.find_root(filepath)
    local tree, render_opts
    if root and vim.fn.fnamemodify(dir_path, ":p") == vim.fn.fnamemodify(root, ":p") then
        tree = M.build_project_tree(dir_path, filename)
        render_opts = { max_depth = 6, base_level = 0 }
    else
        tree = M.build_directory_tree(dir_path, filename)
        render_opts = { max_depth = 2, base_level = 0 }
    end

    local norg_lines = M.render_as_norg(tree, render_opts)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, norg_lines)
end

---------------------------------------------------------------------------
--- REGENERATE ALL (for project-wide renaming)
---------------------------------------------------------------------------

--- Regenerate all status files using surgical updates.
--- Finds and updates status files at root and in each numbered subdirectory.
---
--- @param root_path string  Project root directory
function M.regenerate_all(root_path)
    -- Update root status file
    local root_status = project.find_status_file(root_path)
    if root_status then
        if vim.fn.filereadable(root_status) == 1 then
            M.update_file(root_status, root_path, "project")
        end
    end

    -- Update status files in subdirectories
    local function regen_status_files(dir_path)
        helpers.scandir(dir_path, function(name, entry_type, full_path)
            if entry_type == "directory" then
                local prefix, _ = project.extract_prefix(name)
                if prefix then
                    local sub_status = project.find_status_file(full_path)
                    if sub_status and vim.fn.filereadable(sub_status) == 1 then
                        M.update_file(sub_status, full_path, "index")
                    end
                end
                regen_status_files(full_path)
            end
        end)
    end

    regen_status_files(root_path)
end

return M
