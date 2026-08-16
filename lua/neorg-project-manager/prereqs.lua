--- neorg-project-manager.prereqs: Prerequisite tracking with virtual text indicators.
---
--- Scans headings for "Pre-requisites:" sections, resolves linked headings
--- (local + cross-file), checks their todo states, and displays:
---   - [BLOCKED: X/Y prereqs done]  — if any prerequisite is not done
---   - [READY_FOR_IMPLEMENTATION]    — if all prereqs done AND item hasn't started
---
--- @module neorg-project-manager.prereqs

local M = {}

local helpers = require("neorg-project-manager.helpers")

--- Check if any child of a heading has started (has any non-undone state).
---
--- @param heading_node TSNode
--- @param heading_level number
--- @return boolean
local function has_started_children(heading_node, heading_level)
    for child in heading_node:iter_children() do
        local child_level = helpers.get_heading_level(child)
        if child_level and child_level == heading_level + 1 then
            local state = helpers.get_todo_state(child)
            if state and state ~= "undone" then
                return true
            end
        end

        if helpers.get_list_level(child) then
            local state = helpers.get_todo_state(child)
            if state and state ~= "undone" then
                return true
            end
        end

        if child:type() == "generic_list" then
            for list_child in child:iter_children() do
                if helpers.get_list_level(list_child) then
                    local state = helpers.get_todo_state(list_child)
                    if state and state ~= "undone" then
                        return true
                    end
                end
            end
        end
    end
    return false
end

--- Find all links within a heading's DIRECT content (before child headings)
--- that appear after the prereq pattern.
---
--- @param heading_node TSNode
--- @param buf number
--- Get the line range of the prerequisite section within a heading's direct content.
--- Scans lines for the prereq pattern and determines where the list starts/ends.
---
--- @param heading_node TSNode
--- @param buf number
--- @param prereq_pattern string  Lua pattern to match (e.g., "Pre%-requisites:")
--- @return number|nil start_line  Absolute line where prereq list starts (0-indexed)
--- @return number|nil end_line    Absolute line where prereq list ends (exclusive)
local function get_prereq_line_range(heading_node, buf, prereq_pattern)
    local heading_row = heading_node:start()

    -- Find end of direct content (before first child heading)
    local direct_content_end = nil
    for child in heading_node:iter_children() do
        if helpers.get_heading_level(child) then
            direct_content_end = child:start()
            break
        end
    end
    if not direct_content_end then
        local _, _, end_row, _ = heading_node:range()
        direct_content_end = end_row
    end

    -- Scan lines for the prereq pattern
    local lines = vim.api.nvim_buf_get_lines(buf, heading_row, direct_content_end, false)
    local start_line = nil
    local end_line = nil

    for i, line in ipairs(lines) do
        if not start_line then
            if line:match(prereq_pattern) then
                start_line = heading_row + i - 1
            end
        else
            -- Check if still in prereq section (list item or blank line)
            if not (line:match("^%s*%-") or line:match("^%s*$")) then
                end_line = heading_row + i - 1
                break
            end
        end
    end

    if not start_line then
        return nil, nil
    end
    return start_line, end_line or direct_content_end
end

--- Find all link nodes within a line range of a heading's tree.
--- Walks the heading's tree-sitter children, collecting links that fall
--- within [start_line, end_line).
---
--- @param heading_node TSNode
--- @param buf number
--- @param start_line number  Inclusive start (0-indexed)
--- @param end_line number    Exclusive end (0-indexed)
--- @return table[]           List of {text=string, type=string|nil}
local function find_links_in_range(heading_node, buf, start_line, end_line)
    local links = {}

    local function walk(node)
        -- Skip child headings
        if helpers.get_heading_level(node) and node ~= heading_node then
            return
        end

        if node:type() == "link" then
            local link_row = node:start()
            if link_row >= start_line and link_row < end_line then
                for child in node:iter_children() do
                    if child:type() == "link_location" then
                        local link_text, link_type = nil, nil
                        for loc_child in child:iter_children() do
                            local loc_type = loc_child:type()
                            if loc_type:match("^link_target_heading%d$") then
                                link_type = loc_type:sub(#"link_target_" + 1)
                            elseif loc_type == "paragraph" then
                                link_text = vim.treesitter.get_node_text(loc_child, buf)
                            end
                        end
                        if link_text then
                            table.insert(links, { text = vim.trim(link_text), type = link_type })
                        end
                    end
                end
            end
            return
        end

        for child in node:iter_children() do
            walk(child)
        end
    end

    walk(heading_node)
    return links
end

--- Find all prerequisite links for a heading.
--- Combines range detection + link extraction.
---
--- @param heading_node TSNode
--- @param buf number
--- @param prereq_pattern string
--- @return table[]  List of {text=string, type=string|nil}
local function find_prereq_links(heading_node, buf, prereq_pattern)
    local start_line, end_line = get_prereq_line_range(heading_node, buf, prereq_pattern)
    if not start_line then
        return {}
    end
    return find_links_in_range(heading_node, buf, start_line, end_line)
end

--- Resolve a link text to a heading and check its todo state.
--- Tries local index first, then project-wide index (cross-file).
---
--- @param link_text string      Link location text (e.g., "1.1.1")
--- @param number_index table    Local index: number → {line, level}
--- @param buf number            Buffer handle
--- @return string|nil           Todo state of the target heading
local function resolve_link_state(link_text, number_index, buf)
    -- 1. Try local index
    local target = number_index[link_text]
    if target then
        local node = vim.treesitter.get_node({ bufnr = buf, pos = { target.line, 0 } })
        if node then
            local current = node
            for _ = 1, 10 do
                if not current then break end
                if helpers.get_heading_level(current) then
                    return helpers.get_todo_state(current)
                end
                current = current:parent()
            end
        end
        return nil
    end

    -- 2. Try project-wide index (cross-file)
    local project_index = require("neorg-project-manager.index").get(buf)
    local project_target = project_index[link_text]
    if project_target and project_target.state then
        return project_target.state
    end

    return nil
end

--- Refresh prerequisite tracking virtual text for all headings.
---
--- @param buf number          Buffer handle
--- @param ns number           Namespace ID
--- @param cfg table           Plugin config
--- @param number_index table  Local number index
--- @param root TSNode|nil     Pre-parsed root node (skips re-parsing if provided)
function M.refresh(buf, ns, cfg, number_index, root)
    root = root or helpers.get_norg_root(buf)
    if not root then
        return
    end

    local function process_node(node)
        local level = helpers.get_heading_level(node)
        if level then
            local state = helpers.get_todo_state(node)
            if state then
                local prereq_links = find_prereq_links(node, buf, cfg.prereq_pattern)

                if #prereq_links > 0 then
                    local done = 0
                    local total = #prereq_links

                    for _, link in ipairs(prereq_links) do
                        local link_state = resolve_link_state(link.text, number_index, buf)
                        if link_state == "done" then
                            done = done + 1
                        end
                    end

                    local row = node:start()

                    if done < total then
                        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                            virt_text = { { " " .. cfg.blocked_format(done, total), cfg.blocked_highlight } },
                            virt_text_pos = "eol",
                            hl_mode = "combine",
                        })
                    elseif done == total then
                        local started = has_started_children(node, level)
                        if not started and state == "undone" then
                            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                                virt_text = { { " " .. cfg.ready_text, cfg.ready_highlight } },
                                virt_text_pos = "eol",
                                hl_mode = "combine",
                            })
                        end
                    end
                end
            end

            for child in node:iter_children() do
                process_node(child)
            end
            return
        end

        for child in node:iter_children() do
            process_node(child)
        end
    end

    process_node(root)
end

return M
