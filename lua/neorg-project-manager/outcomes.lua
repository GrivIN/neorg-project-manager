--- neorg-project-manager.outcomes: Outcome/deliverable tracking with virtual text.
---
--- Detects "Outcome:" / "Outcomes:" sections in headings, counts completed
--- deliverables, and displays:
---   - [X/Y outcomes]          — progress count on headings with outcomes
---   - [OUTCOMES INCOMPLETE]   — warning if heading is done but outcomes aren't
---
--- @module neorg-project-manager.outcomes

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local sections = require("neorg-project-manager.sections")

--- Refresh outcome tracking virtual text for all headings in a buffer.
---
--- @param buf number      Buffer handle
--- @param ns number       Extmark namespace ID
--- @param root TSNode|nil Pre-parsed root node
function M.refresh(buf, ns, root)
    root = root or helpers.get_norg_root(buf)
    if not root then
        return
    end

    local pattern = config.get("outcome_pattern", "Outcomes?:")
    local format_fn = config.get("outcome_format", function(done, total)
        return string.format("[%d/%d outcomes]", done, total)
    end)
    local hl = config.get("outcome_highlight", "DiagnosticInfo")
    local warn = config.get("outcome_incomplete_warning", true)
    local warn_hl = config.get("outcome_warning_highlight", "DiagnosticWarn")
    local warn_text = config.get("outcome_warning_text", "[OUTCOMES INCOMPLETE]")

    helpers.walk_headings(root, function(node, _)
        local state = helpers.get_todo_state(node)
        local section = sections.detect_list(node, buf, pattern)
        if not section or #section.items == 0 then return end

        -- Count items with todo states
        local done, total = 0, 0
        for _, item in ipairs(section.items) do
            if item.state then
                total = total + 1
                if item.state == "done" then
                    done = done + 1
                end
            end
        end

        -- If no items have todo states, count all items as undone
        if total == 0 then
            total = #section.items
        end

        if total == 0 then return end

        local row = node:start()
        local virt = {}

        -- Progress count
        table.insert(virt, { " " .. format_fn(done, total), hl })

        -- Warning: heading claims done but outcomes are incomplete
        if warn and state == "done" and done < total then
            table.insert(virt, { " " .. warn_text, warn_hl })
        end

        vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
            virt_text = virt,
            virt_text_pos = "eol",
            hl_mode = "combine",
        })
    end)
end

return M
