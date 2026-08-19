--- neorg-project-manager.hop: Number-based link resolution with cross-file support.
---
--- Provides a buffer-local <CR> mapping that:
---   1. Detects if the cursor is on a link node (any heading level, e.g., {* number})
---   2. Extracts the link location text
---   3. Looks up in local file index first (fast path)
---   4. Falls back to project-wide index (cross-file, lazy-loaded)
---   5. If found locally: jumps within the buffer
---   6. If found in another file: opens that file and jumps to the heading
---   7. If not found anywhere: falls back to Neorg's native hop
---
--- Link format: {* <number>} — single star, number encodes full path.
--- The heading-level prefix (number of stars) is IGNORED for resolution;
--- only the number text matters. This makes links simpler to write.
---
--- @module neorg-project-manager.hop

local M = {}

local numbering = require("neorg-project-manager.numbering")
local index = require("neorg-project-manager.index")

--- Try to find a link node at or near the cursor position.
--- Walks up the tree-sitter AST from the current node looking for a "link" parent.
--- If not found directly under cursor, looks ahead on the same line for { characters.
---
--- @param buf number  Buffer handle
--- @return TSNode|nil  The link node if found, nil otherwise
local function find_link_at_cursor(buf)
    local node = vim.treesitter.get_node({ bufnr = buf })
    if not node then
        return nil
    end

    -- Walk up the tree to find a "link" node
    local current = node
    local max_depth = 10
    while current and max_depth > 0 do
        if current:type() == "link" then
            return current
        end
        current = current:parent()
        max_depth = max_depth - 1
    end

    -- Lookahead: try to find a link on the same line after the cursor
    local cursor = vim.api.nvim_win_get_cursor(0)
    local line = vim.api.nvim_buf_get_lines(buf, cursor[1] - 1, cursor[1], false)[1]
    if not line then
        return nil
    end

    local col = cursor[2]
    local brace_pos = line:find("{", col + 1)
    if not brace_pos then
        return nil
    end

    -- Get the node at the brace position
    node = vim.treesitter.get_node({ bufnr = buf, pos = { cursor[1] - 1, brace_pos - 1 } })
    if not node then
        return nil
    end

    current = node
    max_depth = 10
    while current and max_depth > 0 do
        if current:type() == "link" then
            return current
        end
        current = current:parent()
        max_depth = max_depth - 1
    end

    return nil
end

--- Extract the link location text from a link node.
--- Parses the link's tree-sitter children to find the location paragraph text.
---
--- @param link_node TSNode  A "link" type tree-sitter node
--- @param buf number        Buffer handle
--- @return string|nil       The link location text (e.g., "1.1.3" or "My Heading")
--- @return string|nil       The link type (e.g., "heading3") or nil
local function parse_link_location(link_node, buf)
    local location_text = nil
    local link_type = nil

    for child in link_node:iter_children() do
        if child:type() == "link_location" then
            for loc_child in child:iter_children() do
                local loc_type = loc_child:type()
                -- Detect link target type (heading1-heading6, url, etc.)
                if loc_type:match("^link_target_heading%d$") then
                    link_type = loc_type:sub(#"link_target_" + 1)
                elseif loc_type == "paragraph" then
                    location_text = vim.treesitter.get_node_text(loc_child, buf)
                end
            end
        end
    end

    return location_text, link_type
end

--- Attempt to hop to a heading by looking up the link text.
--- Tries local index first, then project-wide index (cross-file).
---
--- @param buf number  Buffer handle
--- @return boolean    True if we handled the link, false to fall through to default hop
function M.try_number_hop(buf)
    local link_node = find_link_at_cursor(buf)
    if not link_node then
        return false
    end

    local location_text, _ = parse_link_location(link_node, buf)
    if not location_text then
        return false
    end

    -- Clean up the location text
    location_text = vim.trim(location_text)

    -- 1. Try current file's local index (fast path)
    -- Skip if the target is on the same line as the cursor (self-referencing managed heading)
    local cursor_line = vim.api.nvim_win_get_cursor(0)[1] - 1 -- 0-indexed
    local local_index = numbering.build_number_index(buf)
    if local_index[location_text] and local_index[location_text].line ~= cursor_line then
        vim.cmd("normal! m`")
        vim.api.nvim_win_set_cursor(0, { local_index[location_text].line + 1, 0 })
        return true
    end

    -- 2. Try project-wide index (cross-file, lazy-loaded)
    local project_index = index.get(buf)
    local target = project_index[location_text]
    if target then
        vim.cmd("normal! m`")
        vim.cmd("edit " .. vim.fn.fnameescape(target.filepath))
        vim.api.nvim_win_set_cursor(0, { target.line + 1, 0 })
        return true
    end

    -- 3. Try resolving as a directory (open its status file)
    local project_mod = require("neorg-project-manager.project")
    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project_mod.find_root(filepath)
    if root then
        local entries = project_mod.scan(root)
        for _, entry in ipairs(entries) do
            if entry.is_dir and entry.prefix == location_text then
                local status_path = project_mod.find_status_file(entry.filepath)
                if status_path and vim.fn.filereadable(status_path) == 1 then
                    vim.cmd("normal! m`")
                    vim.cmd("edit " .. vim.fn.fnameescape(status_path))
                    return true
                end
            end
        end
    end

    -- 4. Not found — fall through to let default hop try title-based resolution
    return false
end

--- Attach the hop override to a norg buffer.
--- Sets a buffer-local <CR> mapping that tries number-based hop first
--- (local + cross-file), then falls back to Neorg's native hop.
---
--- @param buf number  Buffer handle
function M.attach(buf)
    vim.keymap.set("n", "<CR>", function()
        if not M.try_number_hop(buf) then
            -- Fall back to Neorg's default hop for title-based links
            local plug = vim.api.nvim_replace_termcodes(
                "<Plug>(neorg.esupports.hop.hop-link)", true, false, true
            )
            local ok, _ = pcall(vim.api.nvim_feedkeys, plug, "m", false)
            if not ok then
                -- Ultimate fallback: just press enter normally
                vim.api.nvim_feedkeys(
                    vim.api.nvim_replace_termcodes("<CR>", true, false, true),
                    "n",
                    false
                )
            end
        end
    end, { buffer = buf, desc = "Neorg PM: hop link (number-aware, cross-file)" })
end

return M
