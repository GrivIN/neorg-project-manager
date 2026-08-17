--- neorg-project-manager.mixed: Mixed-type todo propagation (virtual text).
---
--- Extends Neorg's built-in propagation by counting BOTH child headings
--- AND list items with todo states under a heading. Displays [done/total]
--- as virtual text at end of line. Read-only — does not modify buffer.
---
--- For managed headings with {* number} links that resolve to extracted files,
--- cross-file child counting is used when no local children exist.
---
--- @module neorg-project-manager.mixed

local M = {}

local helpers = require("neorg-project-manager.helpers")

--- Count todo items among direct children of a heading node.
--- Counts both child headings (one level deeper) AND list items with todo states.
---
--- @param heading_node TSNode
--- @param heading_level number
--- @return number done
--- @return number total
function M.count_children_todos(heading_node, heading_level)
    local done = 0
    local total = 0

    for child in heading_node:iter_children() do
        -- Count child headings (one level deeper)
        local child_level = helpers.get_heading_level(child)
        if child_level and child_level == heading_level + 1 then
            local state = helpers.get_todo_state(child)
            if state then
                total = total + 1
                if state == "done" then
                    done = done + 1
                end
            end
        end

        -- Count top-level list items directly under this heading
        if helpers.get_list_level(child) then
            local state = helpers.get_todo_state(child)
            if state then
                total = total + 1
                if state == "done" then
                    done = done + 1
                end
            end
        end

        -- Check for generic_list nodes that contain unordered lists
        if child:type() == "generic_list" then
            for list_child in child:iter_children() do
                if helpers.get_list_level(list_child) then
                    local state = helpers.get_todo_state(list_child)
                    if state then
                        total = total + 1
                        if state == "done" then
                            done = done + 1
                        end
                    end
                end
            end
        end
    end

    return done, total
end

--- Count top-level children in an extracted file via the project index.
--- Used when a managed heading has no local children but links to a file.
---
--- @param buf number        Buffer handle (for project root detection)
--- @param link_number string The number from the {* number} link
--- @return number done
--- @return number total
local function count_cross_file_children(buf, link_number)
    local project = require("neorg-project-manager.project")
    local index = require("neorg-project-manager.index")

    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)
    if not root then
        return 0, 0
    end

    local entries = project.scan(root)

    -- Find the file that corresponds to this number
    local target_filepath = nil
    local target_prefix = nil

    -- Check if number is a file prefix
    for _, entry in ipairs(entries) do
        if not entry.is_dir and entry.prefix == link_number then
            target_filepath = entry.filepath
            target_prefix = entry.prefix
            break
        end
    end

    if not target_filepath then
        return 0, 0
    end

    -- Get headings from that file
    local file_headings = index.get_file_headings(target_filepath, target_prefix)

    local done = 0
    local total = 0

    for num, info in pairs(file_headings) do
        -- Count level-1 headings that are NOT the file-title heading (num ~= prefix)
        if info.level == 1 and num ~= target_prefix and info.state then
            total = total + 1
            if info.state == "done" then
                done = done + 1
            end
        end
    end

    return done, total
end

--- Refresh mixed-type propagation virtual text for all headings in the buffer.
---
--- @param buf number        Buffer handle
--- @param ns number         Namespace ID for extmarks
--- @param cfg table         Plugin config
--- @param root TSNode|nil   Pre-parsed root node (skips re-parsing if provided)
function M.refresh(buf, ns, cfg, root)
    root = root or helpers.get_norg_root(buf)
    if not root then
        return
    end

    local function process_node(node)
        local level = helpers.get_heading_level(node)
        if level then
            local state = helpers.get_todo_state(node)
            if state then
                local done, total = M.count_children_todos(node, level)

                -- Cross-file fallback: if no local children, check linked file
                if total == 0 then
                    local row = node:start()
                    local line = vim.api.nvim_buf_get_lines(buf, row, row + 1, false)[1]
                    if line then
                        local link_num = helpers.extract_link_number_from_line(line)
                        if link_num then
                            done, total = count_cross_file_children(buf, link_num)
                        end
                    end
                end

                if total > 0 then
                    local row = node:start()
                    local text = cfg.mixed_format(done, total)
                    vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                        virt_text = { { " " .. text, cfg.mixed_progress_highlight } },
                        virt_text_pos = "eol",
                        hl_mode = "combine",
                    })
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
