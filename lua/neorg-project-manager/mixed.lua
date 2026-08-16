--- neorg-project-manager.mixed: Mixed-type todo propagation (virtual text).
---
--- Extends Neorg's built-in propagation by counting BOTH child headings
--- AND list items with todo states under a heading. Displays [done/total]
--- as virtual text at end of line. Read-only — does not modify buffer.
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
