--- neorg-project-manager.prereqs: Prerequisite tracking with virtual text indicators.
---
--- Scans headings for "Pre-requisites:" sections, resolves linked headings
--- (local + cross-file), checks their todo states, and displays:
---   - [BLOCKED: X/Y prereqs done]  — if any prerequisite is not done
---   - [READY_FOR_IMPLEMENTATION]    — if all prereqs done AND item hasn't started
---
--- @module neorg-project-manager.prereqs

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local sections = require("neorg-project-manager.sections")

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
--- @param number_index table  Local number index
--- @param root TSNode|nil     Pre-parsed root node (skips re-parsing if provided)
function M.refresh(buf, ns, number_index, root)
    root = root or helpers.get_norg_root(buf)
    if not root then
        return
    end

    helpers.walk_headings(root, function(node, level)
        local state = helpers.get_todo_state(node)
        if state then
            local prereq_pattern = config.get("prereq_pattern", "Pre%-requisites:")

            -- Detect prereq section and extract items with links
            local section = sections.detect_list(node, buf, prereq_pattern)
            local prereq_links = {}
            if section then
                for _, item in ipairs(section.items) do
                    for _, link in ipairs(item.links) do
                        table.insert(prereq_links, { text = link })
                    end
                end
            end

            -- Cross-file fallback: if no local prereqs, check linked file
            if #prereq_links == 0 then
                local row = node:start()
                local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
                if line then
                    local link_num = helpers.extract_link_number_from_line(line)
                    if link_num then
                        local project_mod = require("neorg-project-manager.project")
                        local buf_filepath = vim.api.nvim_buf_get_name(buf)
                        local root_path = project_mod.find_root(buf_filepath)
                        if root_path then
                            local entries = project_mod.scan(root_path)
                            for _, entry in ipairs(entries) do
                                if not entry.is_dir and entry.prefix == link_num then
                                    local file_section = sections.detect_list_from_lines(
                                        vim.fn.readfile(entry.filepath), prereq_pattern
                                    )
                                    if file_section then
                                        for _, item in ipairs(file_section.items) do
                                            for _, link in ipairs(item.links) do
                                                table.insert(prereq_links, { text = link })
                                            end
                                        end
                                    end
                                    break
                                end
                            end
                        end
                    end
                end
            end

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
                    local blocked_format = config.get("blocked_format")
                    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                        virt_text = { { " " .. blocked_format(done, total), config.get("blocked_highlight") } },
                        virt_text_pos = "eol",
                        hl_mode = "combine",
                    })
                elseif done == total then
                    local started = has_started_children(node, level)
                    if not started and state == "undone" then
                        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                            virt_text = { { " " .. config.get("ready_text"), config.get("ready_highlight") } },
                            virt_text_pos = "eol",
                            hl_mode = "combine",
                        })
                    end
                end
            end
        end
    end)
end

return M
