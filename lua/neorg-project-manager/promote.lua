--- neorg-project-manager.promote: Promote list items to subsections.
---
--- Converts direct (free) list items under the current heading into child
--- headings (subsections) at level + 1. Labeled sections (e.g., "Pre-requisites:")
--- and non-list body text are preserved in place. Nested sub-items become body
--- content under their new heading. Auto-renumbers after promotion.
---
--- @module neorg-project-manager.promote

local M = {}

local helpers = require("neorg-project-manager.helpers")
local sections = require("neorg-project-manager.sections")
local numbering = require("neorg-project-manager.numbering")

--- Reverse map: state name → norg todo character.
local state_to_char = {
    done = "x",
    undone = " ",
    pending = "-",
    on_hold = "=",
    cancelled = "_",
    important = "!",
    recurring = "+",
    ambiguous = "?",
}

---------------------------------------------------------------------------
--- INTERNAL HELPERS
---------------------------------------------------------------------------

--- Find the heading at or above the cursor position.
--- Returns the 1-indexed line number, the heading level, and the tree-sitter node.
---
--- @param buf number  Buffer handle
--- @return number|nil line       1-indexed heading line
--- @return number|nil level      Heading level (1-6)
--- @return TSNode|nil node       The heading tree-sitter node
local function find_heading_at_cursor(buf)
    local cursor_row = vim.api.nvim_win_get_cursor(0)[1] -- 1-indexed

    local root = helpers.get_norg_root(buf)
    if not root then
        return nil, nil, nil
    end

    -- Walk headings and find the deepest one that contains the cursor row.
    local best_node = nil
    local best_level = nil
    local best_line = nil

    helpers.walk_headings(root, function(node, level)
        local start_row = node:start() -- 0-indexed
        local _, _, end_row, _ = node:range()
        -- Check if cursor is within this heading's range (1-indexed cursor vs 0-indexed TS)
        if (start_row + 1) <= cursor_row and cursor_row <= end_row then
            -- Pick the deepest (most specific) heading containing the cursor
            if not best_level or level > best_level or
                (level == best_level and (start_row + 1) > (best_line or 0)) then
                best_node = node
                best_level = level
                best_line = start_row + 1
            end
        end
    end)

    return best_line, best_level, best_node
end

--- Get the direct content range of a heading (before first child heading).
--- Returns 0-indexed rows [start, end) — start is the line AFTER the heading line.
---
--- @param heading_node TSNode
--- @return number start_row  0-indexed first content line (line after heading)
--- @return number end_row    0-indexed exclusive end
local function get_direct_content_range(heading_node)
    local heading_start = heading_node:start() -- 0-indexed
    local content_start = heading_start + 1 -- skip the heading line itself

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

    return content_start, end_row
end

--- Get the insertion point for new subsections (after all existing child headings).
--- Returns the 0-indexed row where new headings should be inserted.
---
--- @param heading_node TSNode
--- @return number row  0-indexed insertion row
local function get_insertion_point(heading_node)
    -- Find the last child heading and return the row after its full subtree ends.
    local last_child_end = nil
    for child in heading_node:iter_children() do
        if helpers.get_heading_level(child) then
            local _, _, er, _ = child:range()
            last_child_end = er
        end
    end

    if last_child_end then
        return last_child_end
    end

    -- No existing child headings — insert at end of heading node
    local _, _, er, _ = heading_node:range()
    return er
end

--- Determine the base indentation level of a list item line.
--- Returns the number of leading whitespace characters.
---
--- @param line string
--- @return number
local function indent_level(line)
    local ws = line:match("^(%s*)")
    return ws and #ws or 0
end

--- Check if a line is a label line (e.g., "Pre-requisites:", "Outcomes:").
--- A label is a non-blank, non-list line that ends with a colon.
---
--- @param line string
--- @return boolean
local function is_label_line(line)
    if line:match("^%s*%-") then
        return false -- list item, not a label
    end
    if not line:match("%S") then
        return false -- blank
    end
    return line:match(":%s*$") ~= nil
end

--- Check if a line is a list item.
---
--- @param line string
--- @return boolean
local function is_list_item(line)
    return line:match("^%s*%-") ~= nil
end

---------------------------------------------------------------------------
--- MAIN PROMOTE LOGIC
---------------------------------------------------------------------------

--- Promote direct list items under the current heading into child subsections.
--- Labeled sections and body text are preserved. Sub-items become body content
--- under their new parent heading. Auto-renumbers after promotion.
---
--- @param buf number  Buffer handle
function M.promote(buf)
    buf = buf or vim.api.nvim_get_current_buf()

    -- Step 1: Find current heading
    local _, level, heading_node = find_heading_at_cursor(buf)
    if not heading_node or not level then
        vim.notify("No heading found at cursor position.", vim.log.levels.WARN)
        return
    end

    -- Step 2: Validate max depth
    if level >= 6 then
        vim.notify("Cannot promote: max heading depth reached, split to subfile first",
            vim.log.levels.ERROR)
        return
    end

    -- Step 3: Get direct content range (lines between heading and first child heading)
    local content_start, content_end = get_direct_content_range(heading_node)
    if content_start >= content_end then
        vim.notify("No list items to promote.", vim.log.levels.INFO)
        return
    end

    local lines = vim.api.nvim_buf_get_lines(buf, content_start, content_end, false)
    if #lines == 0 then
        vim.notify("No list items to promote.", vim.log.levels.INFO)
        return
    end

    -- Step 4: Classify lines into segments
    -- We need to identify "free" list items (not part of a labeled section)
    -- and separate them from body text and labeled sections.

    --- @class PromoteGroup
    --- @field type "body"|"free_item"
    --- @field lines string[]
    --- @field item_state string|nil   Todo state name (for free_item groups)
    --- @field item_text string|nil    Item text (for free_item groups)

    local preserved_lines = {} -- lines to keep in place (body + labeled sections)
    local free_groups = {} -- groups of {heading_line, sub_lines}

    local i = 1
    local after_label = false -- whether we just saw a label line

    while i <= #lines do
        local line = lines[i]

        if is_label_line(line) then
            -- Label line: preserve it and mark that following list items are labeled
            table.insert(preserved_lines, line)
            after_label = true
            i = i + 1
        elseif is_list_item(line) then
            if after_label then
                -- List items belonging to a labeled section: preserve them
                table.insert(preserved_lines, line)
                i = i + 1
            else
                -- Free list item: determine if it's a top-level item
                local base_indent = indent_level(line)
                local group_lines = { line }
                i = i + 1

                -- Collect sub-items (deeper indentation following this item)
                while i <= #lines do
                    local next_line = lines[i]
                    if is_list_item(next_line) and indent_level(next_line) > base_indent then
                        table.insert(group_lines, next_line)
                        i = i + 1
                    elseif next_line:match("^%s*$") and i < #lines then
                        -- Blank line within sub-items: peek ahead
                        local peek = lines[i + 1]
                        if peek and is_list_item(peek) and indent_level(peek) > base_indent then
                            table.insert(group_lines, next_line)
                            i = i + 1
                        else
                            break
                        end
                    else
                        break
                    end
                end

                -- Parse the top-level item
                local item = sections.parse_item(group_lines[1])
                table.insert(free_groups, {
                    state = item.state,
                    text = item.text,
                    sub_lines = { unpack(group_lines, 2) }, -- everything after the first line
                })
            end
        elseif line:match("^%s*$") then
            -- Blank line: always breaks the labeled-section context.
            -- A blank line is a clear separator between labeled items and free items.
            table.insert(preserved_lines, line)
            after_label = false
            i = i + 1
        else
            -- Non-list, non-blank, non-label body text: preserve
            table.insert(preserved_lines, line)
            after_label = false
            i = i + 1
        end
    end

    -- Step 5: Check we have something to promote
    if #free_groups == 0 then
        vim.notify("No list items to promote.", vim.log.levels.INFO)
        return
    end

    -- Step 6: Build new heading lines for each free group
    local new_level = level + 1
    local stars = string.rep("*", new_level)
    local new_heading_lines = {}

    for _, group in ipairs(free_groups) do
        -- Build the heading line
        local todo_part = ""
        if group.state then
            local char = state_to_char[group.state]
            if char then
                todo_part = " (" .. char .. ")"
            end
        end

        local heading_line = stars .. todo_part .. " " .. group.text
        table.insert(new_heading_lines, heading_line)

        -- Add sub-items as body content under the new heading
        -- Dedent sub-items relative to the parent list item's indent
        if #group.sub_lines > 0 then
            for _, sub_line in ipairs(group.sub_lines) do
                -- Keep sub-items with standard indent (3 spaces under heading)
                -- Strip the extra indentation that was relative to the parent list nesting
                local stripped = sub_line:match("^%s*(.*)$")
                table.insert(new_heading_lines, "   " .. stripped)
            end
        end
    end

    -- Step 7: Apply buffer changes
    -- 7a: Replace the direct content area with preserved lines (removing free items)
    -- Remove trailing blank lines from preserved content
    while #preserved_lines > 0 and preserved_lines[#preserved_lines]:match("^%s*$") do
        table.remove(preserved_lines)
    end

    vim.api.nvim_buf_set_lines(buf, content_start, content_end, false, preserved_lines)

    -- 7b: Find the new insertion point (after existing child headings)
    -- Re-parse the tree after the edit
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "norg")
    if ok and parser then
        parser:parse()
    end

    -- Re-find the heading node after the buffer modification
    local _, _, updated_node = find_heading_at_cursor(buf)
    if not updated_node then
        -- Fallback: insert at end of file
        local line_count = vim.api.nvim_buf_line_count(buf)
        vim.api.nvim_buf_set_lines(buf, line_count, line_count, false, new_heading_lines)
    else
        local insert_row = get_insertion_point(updated_node)
        vim.api.nvim_buf_set_lines(buf, insert_row, insert_row, false, new_heading_lines)
    end

    -- Step 8: Auto-renumber
    -- Re-parse tree before renumbering
    local ok2, parser2 = pcall(vim.treesitter.get_parser, buf, "norg")
    if ok2 and parser2 then
        parser2:parse()
    end
    numbering.renumber(buf)

    -- Step 9: Notify
    vim.notify("Promoted " .. #free_groups .. " item(s) to subsections.", vim.log.levels.INFO)
end

return M
