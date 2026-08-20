--- neorg-project-manager.sections: Generic section detection engine.
---
--- Provides shared detection logic for list-based sections (Pre-requisites:,
--- Outcomes:) and single-line value fields (Owner:, Effort:) within heading
--- descriptions. Used by prereqs.lua, outcomes.lua, and fields.lua.
---
--- @module neorg-project-manager.sections

local M = {}

local helpers = require("neorg-project-manager.helpers")

--- Valid norg todo characters for item state detection.
local todo_chars = {
    ["x"] = "done", [" "] = "undone", ["-"] = "pending", ["="] = "on_hold",
    ["_"] = "cancelled", ["!"] = "important", ["+"] = "recurring", ["?"] = "ambiguous",
}

--- Parse a single list item line into structured data.
--- Extracts: todo state (from `(x)` prefix), text content, `{* N}` links.
---
--- @param line string
--- @return {text: string, state: string|nil, links: string[]}
function M.parse_item(line)
    local item = { text = "", state = nil, links = {} }

    -- Strip leading whitespace and list marker "- "
    local content = line:match("^%s*%-%s*(.*)")
    if not content then
        content = line:match("^%s*(.*)")
    end

    -- Extract todo state: (x), (-), ( ), etc.
    local state_char, rest = content:match("^%((.-)%)%s+(.*)")
    if state_char and #state_char == 1 and todo_chars[state_char] then
        item.state = todo_chars[state_char]
        content = rest
    end

    item.text = content or ""

    -- Extract {* number} links
    for link_text in item.text:gmatch("{%*+%s+([^}]+)}") do
        table.insert(item.links, vim.trim(link_text))
    end

    return item
end

---------------------------------------------------------------------------
--- LIST SECTION DETECTION (Pre-requisites:, Outcomes:)
---------------------------------------------------------------------------

--- Get the direct content range of a heading (before first child heading).
--- @param heading_node TSNode
--- @return number start_row  Absolute 0-indexed start
--- @return number end_row    Absolute 0-indexed end (exclusive)
local function get_direct_content_range(heading_node)
    local start_row = heading_node:start()
    local end_row = nil

    for child in heading_node:iter_children() do
        if helpers.get_heading_level(child) then
            end_row = child:start()
            break
        end
    end

    if not end_row then
        local _, _, er, _ = heading_node:range()
        end_row = er
    end

    return start_row, end_row
end

--- Detect a list section within a heading's direct content (buffer).
--- Finds a line matching `pattern`, then collects subsequent list items
--- until a non-list/non-blank line.
---
--- @param heading_node TSNode
--- @param buf number
--- @param pattern string  Lua pattern (e.g., "Pre%-requisites:", "Outcomes?:")
--- @return table|nil      { start_line, end_line, items = [{text, state, links, line}] }
function M.detect_list(heading_node, buf, pattern)
    local start_row, end_row = get_direct_content_range(heading_node)
    local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)

    local section_start = nil
    local items = {}

    for i, line in ipairs(lines) do
        if not section_start then
            if line:match(pattern) then
                section_start = start_row + i - 1
            end
        else
            if line:match("^%s*%-") then
                local item = M.parse_item(line)
                item.line = start_row + i - 1
                table.insert(items, item)
            elseif not line:match("^%s*$") then
                -- Non-list, non-blank = end of section
                return { start_line = section_start, end_line = start_row + i - 2, items = items }
            end
        end
    end

    if section_start then
        return { start_line = section_start, end_line = end_row, items = items }
    end
    return nil
end

--- Detect a list section from raw file lines (for cross-file scanning).
---
--- @param lines string[]
--- @param pattern string      Lua pattern to match
--- @param start_offset number|nil  Line offset for first heading (default: find first heading)
--- @return table|nil          { items = [{text, state, links}] }
function M.detect_list_from_lines(lines, pattern, start_offset)
    local in_section = false
    local items = {}

    -- Find the first heading, then scan for the pattern within its direct content
    local first_heading_found = false
    local first_heading_level = nil

    for i, line in ipairs(lines) do
        local stars = line:match("^(%*+)%s")

        if stars then
            if not first_heading_found then
                first_heading_found = true
                first_heading_level = #stars
            elseif #stars <= first_heading_level then
                break
            else
                if in_section then break end
            end
        elseif first_heading_found then
            if not in_section then
                if line:match(pattern) then
                    in_section = true
                end
            else
                if line:match("^%s*%-") then
                    local item = M.parse_item(line)
                    table.insert(items, item)
                elseif not line:match("^%s*$") then
                    break
                end
            end
        end
    end

    if #items > 0 then
        return { items = items }
    end
    return nil
end

---------------------------------------------------------------------------
--- VALUE FIELD DETECTION (Owner:, Effort:)
---------------------------------------------------------------------------

--- Detect a single-line value field within a heading's direct content.
--- Finds a line matching `pattern` and extracts the value after the match.
---
--- @param heading_node TSNode
--- @param buf number
--- @param pattern string  Lua pattern (e.g., "Owner:", "Effort:")
--- @return {value: string, line: number}|nil
function M.detect_field(heading_node, buf, pattern)
    local start_row, end_row = get_direct_content_range(heading_node)
    local lines = vim.api.nvim_buf_get_lines(buf, start_row, end_row, false)

    for i, line in ipairs(lines) do
        local match_start, match_end = line:find(pattern)
        if match_start then
            local value = vim.trim(line:sub(match_end + 1))
            if value ~= "" then
                return { value = value, line = start_row + i - 1 }
            end
        end
    end
    return nil
end

--- Detect a value field from raw file lines (for cross-file scanning).
---
--- @param lines string[]
--- @param pattern string
--- @return {value: string}|nil
function M.detect_field_from_lines(lines, pattern)
    local first_heading_found = false
    local first_heading_level = nil

    for _, line in ipairs(lines) do
        local stars = line:match("^(%*+)%s")

        if stars then
            if not first_heading_found then
                first_heading_found = true
                first_heading_level = #stars
            elseif #stars <= first_heading_level then
                break
            end
        elseif first_heading_found then
            local match_start, match_end = line:find(pattern)
            if match_start then
                local value = vim.trim(line:sub(match_end + 1))
                if value ~= "" then
                    return { value = value }
                end
            end
        end
    end
    return nil
end

return M
