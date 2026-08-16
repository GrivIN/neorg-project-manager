--- neorg-project-manager.numbering: Heading auto-numbering and link updating.
---
--- This module handles:
---   - Assigning hierarchical numbers to headings based on their position/level
---   - Writing numbers into heading titles in the buffer
---   - Updating number-based links when headings are renumbered
---   - Building a number→heading index for link resolution
---
--- The numbering format is fully configurable via:
---   - `numbering_styles`: per-level style (numeric, alpha_upper, alpha_lower, roman_upper, roman_lower)
---   - `number_separator`: character(s) between number parts (default ".")
---   - `number_title_separator`: string between the number and heading title (default ". ")
---   - `number_format`: optional custom function for full control over formatting
---
--- @module neorg-project-manager.numbering

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")

--- Per-buffer cache for number index. Keyed by buffer handle.
--- Each entry stores the changedtick at time of computation and the index table.
--- @type table<number, {tick: number, index: table}>
local index_cache = {}

---------------------------------------------------------------------------
--- STYLE CONVERTERS
--- These functions convert an integer counter to a string representation.
---------------------------------------------------------------------------

--- Roman numeral lookup tables for conversion.
local roman_numerals = {
    { 1000, "m" }, { 900, "cm" }, { 500, "d" }, { 400, "cd" },
    { 100, "c" }, { 90, "xc" }, { 50, "l" }, { 40, "xl" },
    { 10, "x" }, { 9, "ix" }, { 5, "v" }, { 4, "iv" }, { 1, "i" },
}

--- Convert an integer to a lowercase roman numeral string (1-3999).
--- @param n number
--- @return string
local function to_roman_lower(n)
    if n <= 0 then return tostring(n) end
    local result = {}
    for _, pair in ipairs(roman_numerals) do
        local value, numeral = pair[1], pair[2]
        while n >= value do
            table.insert(result, numeral)
            n = n - value
        end
    end
    return table.concat(result)
end

--- Convert an integer to an uppercase roman numeral string.
--- @param n number
--- @return string
local function to_roman_upper(n)
    return to_roman_lower(n):upper()
end

--- Convert an integer to an uppercase alphabetic string (1→A, 27→AA).
--- @param n number
--- @return string
local function to_alpha_upper(n)
    local result = {}
    while n > 0 do
        n = n - 1
        table.insert(result, 1, string.char(65 + (n % 26)))
        n = math.floor(n / 26)
    end
    return table.concat(result)
end

--- Convert an integer to a lowercase alphabetic string (1→a, 27→aa).
--- @param n number
--- @return string
local function to_alpha_lower(n)
    return to_alpha_upper(n):lower()
end

--- Map of style names to converter functions.
local style_converters = {
    numeric = tostring,
    alpha_upper = to_alpha_upper,
    alpha_lower = to_alpha_lower,
    roman_upper = to_roman_upper,
    roman_lower = to_roman_lower,
}

--- Format a single counter value using the specified style.
--- Exported so custom `number_format` functions can reuse built-in converters.
---
--- @param counter number  The counter value (positive integer)
--- @param style string    One of: "numeric", "alpha_upper", "alpha_lower", "roman_upper", "roman_lower"
--- @return string         The formatted counter value
function M.format_counter(counter, style)
    local converter = style_converters[style]
    if not converter then
        return tostring(counter)
    end
    return converter(counter)
end

---------------------------------------------------------------------------
--- NUMBER FORMATTING
---------------------------------------------------------------------------

--- Build a formatted number string from counters, level, and optional prefix.
---
--- When a prefix is provided (from filename), styles are indexed by TOTAL DEPTH
--- (prefix_depth + local_level), ensuring consistent formatting across files.
---
--- @param counters number[]   Array of 6 counters (one per heading level)
--- @param level number        Current heading level (1-6)
--- @param prefix string|nil   File prefix (e.g., "1.1.3") or nil for standalone files
--- @return string             Formatted number string (e.g., "1.1.3.1" or "I.A.iii")
function M.format_number(counters, level, prefix)
    -- Custom format function takes full control if provided
    local custom_fn = config.get("number_format", nil)
    if custom_fn then
        return custom_fn(counters, level, prefix)
    end

    local styles = config.get("numbering_styles", { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" })
    local separator = config.get("number_separator", ".")
    local prefix_depth = helpers.prefix_depth(prefix)

    -- Format local counters using total-depth indexed styles
    local parts = {}
    for i = 1, level do
        local total_depth = prefix_depth + i
        local style = styles[total_depth] or styles[#styles] or "numeric"
        parts[i] = M.format_counter(counters[i], style)
    end
    local local_number = table.concat(parts, separator)

    -- Prepend prefix if present
    if prefix and prefix ~= "" then
        return prefix .. separator .. local_number
    end
    return local_number
end

---------------------------------------------------------------------------
--- TITLE PARSING
---------------------------------------------------------------------------

--- Parse a heading's paragraph_segment text to separate the number from the title.
--- Uses `number_title_separator` to split on the FIRST occurrence.
---
--- The paragraph_segment may include a leading space (tree-sitter inserts one
--- after the todo extension). This whitespace is preserved for correct buffer writes.
---
--- @param text string       The full paragraph_segment text
--- @return string|nil       number_str: The number portion, or nil if none found
--- @return string           bare_title: The title without number prefix
--- @return string           leading_ws: Any leading whitespace
function M.parse_number_and_title(text)
    local leading_ws, rest = text:match("^(%s*)(.*)")
    if not rest then
        rest = text
        leading_ws = ""
    end

    local sep = config.get("number_title_separator", ". ")
    local sep_start, sep_end = rest:find(sep, 1, true)

    if sep_start and sep_start > 1 then
        local number_part = rest:sub(1, sep_start - 1)
        local title_part = rest:sub(sep_end + 1)

        -- Validate: number part should not contain spaces
        if not number_part:match("%s") then
            return number_part, title_part, leading_ws
        end
    end

    return nil, rest, leading_ws
end

---------------------------------------------------------------------------
--- FILE PREFIX
---------------------------------------------------------------------------

--- Get the file prefix for a buffer (extracted from its filename).
---
--- @param buf number  Buffer handle
--- @return string|nil  The file prefix, or nil if no number in filename
function M.get_file_prefix(buf)
    local file_prefix_cfg = config.get("file_prefix", nil)
    if file_prefix_cfg then
        if type(file_prefix_cfg) == "string" then
            return file_prefix_cfg
        elseif type(file_prefix_cfg) == "function" then
            return file_prefix_cfg(vim.api.nvim_buf_get_name(buf))
        end
    end

    local filepath = vim.api.nvim_buf_get_name(buf)
    if filepath == "" then
        return nil
    end

    local filename = vim.fn.fnamemodify(filepath, ":t")
    if filename == "index.norg" or filename == "project.norg" then
        return nil
    end

    local project = require("neorg-project-manager.project")
    local prefix, _ = project.extract_prefix(filename)
    return prefix
end

---------------------------------------------------------------------------
--- HEADING COLLECTION
---------------------------------------------------------------------------

--- Get all heading nodes from a buffer in document order.
---
--- @param buf number  Buffer handle
--- @return table[]    List of {node, level, line, title_node, title_col}
local function get_headings(buf)
    local root = helpers.get_norg_root(buf)
    if not root then
        return {}
    end

    local headings = {}

    local function collect_headings(node)
        local level = helpers.get_heading_level(node)
        if level then
            local title_node = nil
            for child in node:iter_children() do
                if child:type() == "paragraph_segment" then
                    title_node = child
                    break
                end
            end

            if title_node then
                local row, col = title_node:start()
                table.insert(headings, {
                    node = node,
                    level = level,
                    line = row,
                    title_node = title_node,
                    title_col = col,
                })
            end

            -- Recurse into children (sub-headings are nested)
            for child in node:iter_children() do
                collect_headings(child)
            end
            return
        end

        -- Non-heading nodes: recurse
        for child in node:iter_children() do
            collect_headings(child)
        end
    end

    collect_headings(root)

    table.sort(headings, function(a, b)
        return a.line < b.line
    end)

    return headings
end

---------------------------------------------------------------------------
--- NUMBER INDEX
---------------------------------------------------------------------------

--- Build the number index from current file content (read-only).
--- Maps formatted number strings to heading line numbers.
--- Cached per buffer using changedtick — repeated calls within the same
--- buffer state return instantly.
---
--- @param buf number  Buffer handle
--- @return table      { number_string → {line=number, level=number} }
function M.build_number_index(buf)
    -- Check cache: if buffer hasn't changed since last build, reuse
    local tick = vim.api.nvim_buf_get_changedtick(buf)
    local cached = index_cache[buf]
    if cached and cached.tick == tick then
        return cached.index
    end

    local headings = get_headings(buf)
    local index = {}
    local counters = { 0, 0, 0, 0, 0, 0 }
    local prefix = M.get_file_prefix(buf)

    for _, h in ipairs(headings) do
        local title_text = vim.treesitter.get_node_text(h.title_node, buf)
        local existing_num, _, _ = M.parse_number_and_title(title_text)

        if existing_num then
            index[existing_num] = { line = h.line, level = h.level }
        else
            counters[h.level] = counters[h.level] + 1
            for i = h.level + 1, 6 do
                counters[i] = 0
            end
            index[M.format_number(counters, h.level, prefix)] = { line = h.line, level = h.level }
        end
    end

    -- Cache the result
    index_cache[buf] = { tick = tick, index = index }

    return index
end

---------------------------------------------------------------------------
--- RENUMBERING
---------------------------------------------------------------------------

--- Compute the updated title for a heading given its correct number.
--- Returns nil if no change is needed.
---
--- @param title_text string       Current paragraph_segment text
--- @param correct_number string   The number this heading should have
--- @param title_sep string        Separator between number and title
--- @return string|nil new_title   The new title text (nil if unchanged)
--- @return string|nil old_number  The previous number (nil if heading was unnumbered)
local function compute_heading_update(title_text, correct_number, title_sep)
    local existing_num, bare_title, leading_ws = M.parse_number_and_title(title_text)
    local new_title = leading_ws .. correct_number .. title_sep .. bare_title

    if title_text == new_title then
        return nil, existing_num
    end
    return new_title, existing_num
end

--- Renumber all headings in the buffer and update links.
--- Prefix-aware: uses total-depth styles for consistent formatting.
---
--- @param buf number  Buffer handle
function M.renumber(buf)
    if not vim.api.nvim_buf_is_valid(buf) then
        return
    end

    local headings = get_headings(buf)
    if #headings == 0 then
        return
    end

    local counters = { 0, 0, 0, 0, 0, 0 }
    local title_sep = config.get("number_title_separator", ". ")
    local prefix = M.get_file_prefix(buf)

    local old_to_new = {}
    local changes = {}

    for _, h in ipairs(headings) do
        counters[h.level] = counters[h.level] + 1
        for i = h.level + 1, 6 do
            counters[i] = 0
        end

        local correct_number = M.format_number(counters, h.level, prefix)
        local title_text = vim.treesitter.get_node_text(h.title_node, buf)
        local new_title, old_number = compute_heading_update(title_text, correct_number, title_sep)

        if old_number and old_number ~= correct_number then
            old_to_new[old_number] = correct_number
        end

        if new_title then
            local _, _, title_end_row, title_end_col = h.title_node:range()
            table.insert(changes, {
                line = h.line,
                col = h.title_col,
                end_line = title_end_row,
                end_col = title_end_col,
                new_title = new_title,
            })
        end
    end

    if #changes == 0 and vim.tbl_isempty(old_to_new) then
        return
    end

    -- Apply in reverse order to preserve positions
    for i = #changes, 1, -1 do
        local c = changes[i]
        vim.api.nvim_buf_set_text(buf, c.line, c.col, c.end_line, c.end_col, { c.new_title })
    end

    if not vim.tbl_isempty(old_to_new) then
        M.update_links(buf, old_to_new)
    end
end

--- Update all number-based links in the buffer using an old→new mapping.
---
--- @param buf number       Buffer handle
--- @param old_to_new table Maps old number strings to new number strings
function M.update_links(buf, old_to_new)
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    local _, modified = helpers.replace_link_numbers(lines, function(text)
        return old_to_new[text]
    end)

    if modified then
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    end
end

--- Compute the correct prefix for an item at a given position within a parent.
--- Used by rename.lua to determine what a file/directory's prefix should be.
---
--- @param parent_prefix string|nil  The parent directory's prefix (nil for root)
--- @param position number           Sequential position (1-based) within the parent
--- @return string                   The correctly formatted prefix
function M.format_prefix_for_position(parent_prefix, position)
    local styles = config.get("numbering_styles", { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" })
    local separator = config.get("number_separator", ".")

    local parent_depth = helpers.prefix_depth(parent_prefix)
    local total_depth = parent_depth + 1
    local style = styles[total_depth] or styles[#styles] or "numeric"
    local formatted = M.format_counter(position, style)

    if parent_prefix and parent_prefix ~= "" then
        return parent_prefix .. separator .. formatted
    end
    return formatted
end

return M
