--- neorg-project-manager.bidir: Bidirectional status propagation.
---
--- When a user manually changes a todo state on a managed heading in a status file,
--- this module propagates that change back to the source file's heading.
---
--- Flow:
---   1. User edits a managed heading in a status file (e.g., changes `( )` to `(x)`)
---   2. On BufWritePre, we snapshot the managed heading states
---   3. On BufWritePost, we compare against the project's actual states
---   4. Any differences = user manually changed a state → propagate to source
---
--- @module neorg-project-manager.bidir

local M = {}

local project = require("neorg-project-manager.project")
local index = require("neorg-project-manager.index")
local helpers = require("neorg-project-manager.helpers")

--- Snapshot of managed heading states before save.
--- @type table<number, table<string, string>>  buf → { number → state_char }
local snapshots = {}

--- Valid norg todo characters for marker detection.
local valid_todo_chars = {
    ["x"] = true, [" "] = true, ["-"] = true, ["="] = true,
    ["_"] = true, ["!"] = true, ["+"] = true, ["?"] = true,
}

--- Character to state name mapping (reverse of state_to_char).
local char_to_state = {
    ["x"] = "done", [" "] = "undone", ["-"] = "pending", ["="] = "on_hold",
    ["_"] = "cancelled", ["!"] = "important", ["+"] = "recurring", ["?"] = "ambiguous",
}

--- Extract the primary todo state character from a heading line.
--- Handles both simple `(x)` and compound `(?|-)` markers.
--- Uses role-based detection: qualifiers (? !) are identified and skipped,
--- the remaining character is the primary state.
--- @param line string
--- @return string|nil  The primary state character
local function extract_state_char(line)
    local inner = line:match("^%*+%s+%(([^%)]+)%)")
    if not inner then return nil end

    -- Split on | and find the primary (non-qualifier) character
    local qualifier_chars = { ["?"] = true, ["!"] = true }
    local primary = nil
    for part in (inner .. "|"):gmatch("([^|]*)|") do
        if #part == 1 and valid_todo_chars[part] then
            if not qualifier_chars[part] then
                primary = part
                break
            end
        end
    end

    -- If only qualifiers found, use the first valid char
    if not primary then
        local first = inner:sub(1, 1)
        if valid_todo_chars[first] then
            return first
        end
    end

    return primary
end

--- Collect managed heading states from buffer lines.
--- @param lines string[]
--- @return table<string, string>  { number → primary_state_char }
local function collect_managed_states(lines)
    local states = {}
    for _, line in ipairs(lines) do
        local number = helpers.extract_link_number_from_line(line)
        if number then
            local state_char = extract_state_char(line)
            if state_char then
                states[number] = state_char
            end
        end
    end
    return states
end

--- Take a snapshot of managed heading states in the current buffer.
--- Call this on BufWritePre for status files.
--- @param buf number
function M.snapshot(buf)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
    snapshots[buf] = collect_managed_states(lines)
end

--- Compare post-save buffer state against snapshot and propagate changes.
--- Call this on BufWritePost for status files, BEFORE auto_update_parent_index.
--- @param buf number
function M.propagate(buf)
    local pre = snapshots[buf]
    if not pre then return end
    snapshots[buf] = nil

    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)
    if not root then return end

    -- Re-read the file (just saved) to get post-save states
    local lines = vim.fn.readfile(filepath)
    local post = collect_managed_states(lines)

    -- Find changes: numbers where state_char differs
    local changes = {}
    for number, post_char in pairs(post) do
        local pre_char = pre[number]
        if pre_char and pre_char ~= post_char then
            table.insert(changes, { number = number, new_char = post_char })
        end
    end

    if #changes == 0 then return end

    -- Resolve each changed number to its source file and update
    index.invalidate_project_cache()
    local entries = project.scan(root)

    for _, change in ipairs(changes) do
        local new_state = char_to_state[change.new_char]
        if not new_state then goto continue end

        -- Find source file for this number
        local resolved = project.resolve_number_to_file(change.number, entries)
        if not resolved then goto continue end

        -- Read the source file and find the heading
        local source_lines = vim.fn.readfile(resolved.filepath)
        local source_prefix = resolved.prefix
        local headings = index.get_file_headings(resolved.filepath, source_prefix)
        local target = headings[change.number]

        if target then
            local line_idx = target.line + 1 -- 1-indexed for readfile
            if line_idx <= #source_lines then
                local source_line = source_lines[line_idx]
                -- Replace the todo state in the source heading
                local updated = source_line:gsub("%b()", function(match)
                    local inner = match:sub(2, -2)
                    -- Check if it's a single-char todo marker
                    if #inner == 1 and valid_todo_chars[inner] then
                        if inner ~= change.new_char then
                            return "(" .. change.new_char .. ")"
                        end
                    end
                    return match
                end, 1)

                if updated ~= source_line then
                    source_lines[line_idx] = updated
                    vim.fn.writefile(source_lines, resolved.filepath)

                    -- Invalidate cache for the modified file
                    index.invalidate(resolved.filepath)

                    -- If the source file is open in a buffer, reload it
                    for _, b in ipairs(vim.api.nvim_list_bufs()) do
                        if vim.api.nvim_buf_is_loaded(b) then
                            local bname = vim.api.nvim_buf_get_name(b)
                            if bname == resolved.filepath then
                                vim.api.nvim_buf_call(b, function()
                                    vim.cmd("edit!")
                                end)
                                break
                            end
                        end
                    end
                end
            end
        end

        ::continue::
    end

    if #changes > 0 then
        vim.notify(
            string.format("Propagated %d status change(s) to source files.", #changes),
            vim.log.levels.INFO
        )
    end

    return #changes > 0
end

--- Clean up snapshot for a buffer (on detach/delete).
--- @param buf number
function M.cleanup(buf)
    snapshots[buf] = nil
end

return M
