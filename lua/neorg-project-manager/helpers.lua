--- neorg-project-manager.helpers: Shared tree-sitter and link utilities.
---
--- Provides common functions used across multiple modules to avoid duplication:
---   - Tree-sitter node inspection (todo state, heading level, list level)
---   - Buffer parsing boilerplate (get norg root from buffer)
---   - Link pattern replacement utility
---
--- @module neorg-project-manager.helpers

local M = {}

local config = require("neorg-project-manager.config")

---------------------------------------------------------------------------
--- TREE-SITTER NODE INSPECTION
---------------------------------------------------------------------------

--- Get the todo state from a node's detached_modifier_extension child.
--- Looks for `todo_item_*` nodes within the extension and returns the state name.
---
--- @param node TSNode  A heading or list item node
--- @return string|nil  State name: "done", "undone", "pending", "on_hold", "cancelled",
---                     "recurring", "important", "ambiguous", or nil if no todo state
function M.get_todo_state(node)
    for child in node:iter_children() do
        if child:type() == "detached_modifier_extension" then
            for ext_child in child:iter_children() do
                local ext_type = ext_child:type()
                if ext_type:match("^todo_item_") then
                    return ext_type:sub(#"todo_item_" + 1)
                end
            end
        end
    end
    return nil
end

--- Get the heading level from a node type.
--- Returns nil if the node is not a heading.
---
--- @param node TSNode
--- @return number|nil  Heading level (1-6) or nil
function M.get_heading_level(node)
    local level = node:type():match("^heading(%d)$")
    return level and tonumber(level) or nil
end

--- Get the unordered list level from a node type.
--- Returns nil if the node is not an unordered list item.
---
--- @param node TSNode
--- @return number|nil  List level (1-6) or nil
function M.get_list_level(node)
    local level = node:type():match("^unordered_list(%d)$")
    return level and tonumber(level) or nil
end

---------------------------------------------------------------------------
--- BUFFER PARSING
---------------------------------------------------------------------------

--- Get the tree-sitter root node for a norg buffer.
--- Handles the parse → tree → root boilerplate.
---
--- @param buf number  Buffer handle
--- @return TSNode|nil  Root node, or nil if parsing failed
function M.get_norg_root(buf)
    local ok, parser = pcall(vim.treesitter.get_parser, buf, "norg")
    if not ok or not parser then
        return nil
    end

    local tree = parser:parse()[1]
    if not tree then
        return nil
    end

    return tree:root()
end

---------------------------------------------------------------------------
--- LINK UTILITIES
---------------------------------------------------------------------------

--- Replace number-based links in a list of lines using a resolver function.
--- Finds patterns like {* number} or {*** number} and calls the resolver
--- to determine the replacement text.
---
--- Link pattern: `{<one or more *><space><content>}`
---
--- @param lines string[]                      Lines of norg content
--- @param resolver fun(text: string): string|nil  Called with the trimmed link text.
---                                                Return new text to replace, or nil to keep unchanged.
--- @return string[] lines    The (potentially modified) lines
--- @return boolean modified  Whether any line was changed
function M.replace_link_numbers(lines, resolver)
    local modified = false

    for i, line in ipairs(lines) do
        local new_line = line:gsub("({%*+%s+)(.-)}", function(prefix, content)
            local trimmed = vim.trim(content)
            local replacement = resolver(trimmed)
            if replacement then
                modified = true
                return prefix .. replacement .. "}"
            end
            return prefix .. content .. "}"
        end)

        if new_line ~= line then
            lines[i] = new_line
        end
    end

    return lines, modified
end

---------------------------------------------------------------------------
--- SEPARATOR UTILITIES
---------------------------------------------------------------------------

--- Count the depth (number of parts) in a prefix string.
--- Uses plain string search (safe for any separator character).
---
--- @param prefix string|nil  The prefix string (e.g., "1.1.3")
--- @return number            Depth (0 if prefix is nil/empty, otherwise separators + 1)
function M.prefix_depth(prefix)
    if not prefix or prefix == "" then
        return 0
    end
    local sep = config.get("number_separator", ".")
    local count = 0
    local start = 1
    while true do
        local pos = prefix:find(sep, start, true)
        if not pos then break end
        count = count + 1
        start = pos + #sep
    end
    return count + 1
end

---------------------------------------------------------------------------
--- LINE PARSING
---------------------------------------------------------------------------

--- Extract the number from a `{* <number>}` or `{*** <number>}` link pattern in a line.
--- Matches any number of stars followed by a space and the link text.
---
--- @param line string      A line of norg content
--- @return string|nil      The number text inside the link, or nil if no such link
function M.extract_link_number_from_line(line)
    return line:match("{%*+%s+([^}]+)}")
end

---------------------------------------------------------------------------
--- SORTING
---------------------------------------------------------------------------

--- Natural sort comparator for prefix strings.
--- Splits on the configured separator and compares each part numerically
--- where possible, falling back to string comparison.
--- Correctly sorts "1.2" before "1.10" (unlike lexicographic comparison).
---
--- @param a string  First prefix
--- @param b string  Second prefix
--- @return boolean  True if a should sort before b
function M.natural_sort_prefixes(a, b)
    local sep = config.get("number_separator", ".")
    local a_parts = vim.split(a, sep, { plain = true })
    local b_parts = vim.split(b, sep, { plain = true })

    for i = 1, math.max(#a_parts, #b_parts) do
        local ap = a_parts[i]
        local bp = b_parts[i]

        -- Shorter prefix comes first if all preceding parts are equal
        if not ap then return true end
        if not bp then return false end

        -- Try numeric comparison first
        local an = tonumber(ap)
        local bn = tonumber(bp)
        if an and bn then
            if an ~= bn then return an < bn end
        else
            -- Fallback to string comparison (for alpha/roman styles)
            if ap ~= bp then return ap < bp end
        end
    end

    return false -- equal
end

return M
