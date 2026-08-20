--- neorg-project-manager.picker: Browse and filter project items by status.
---
--- Provides :NeorgPMPick command to browse all WBS items with optional
--- status filtering. Uses vim.ui.select for universal compatibility
--- (works with telescope via dressing.nvim, fzf-lua, etc.).
---
--- @module neorg-project-manager.picker

local M = {}

local project = require("neorg-project-manager.project")
local status = require("neorg-project-manager.status")
local index = require("neorg-project-manager.index")
local helpers = require("neorg-project-manager.helpers")

--- State name to display character mapping (matches status.lua).
local state_chars = {
    done = "x", undone = " ", pending = "-", on_hold = "=",
    cancelled = "_", important = "!", recurring = "+", ambiguous = "?",
}

--- Build a display string for a todo marker (handles compound).
--- @param state string|nil
--- @param qualifiers string[]|nil
--- @return string
local function marker_str(state, qualifiers)
    if not state then return "   " end
    local parts = { state_chars[state] or " " }
    if qualifiers then
        for _, q in ipairs(qualifiers) do
            table.insert(parts, state_chars[q] or " ")
        end
    end
    if #parts == 1 then
        return "(" .. parts[1] .. ")"
    end
    return "(" .. table.concat(parts, "|") .. ")"
end

--- Flatten a status tree into a list of pick-able items.
--- @param tree table  StatusNode tree from status.build_project_tree
--- @return table[]    List of {prefix, title, state, qualifiers, done, total, is_dir, depth}
local function flatten_tree(tree)
    local items = {}

    local function collect(node, depth)
        if node.prefix then
            table.insert(items, {
                prefix = node.prefix,
                title = node.title,
                state = node.state,
                qualifiers = node.qualifiers or {},
                done = node.done,
                total = node.total,
                is_dir = node.is_dir,
                depth = depth,
            })
        end
        for _, child in ipairs(node.children or {}) do
            collect(child, depth + 1)
        end
    end

    collect(tree, 0)
    return items
end

--- Format a single item for display in the picker.
--- @param item table
--- @return string
local function format_item(item)
    local indent = string.rep("  ", item.depth)
    local marker = marker_str(item.state, item.qualifiers)
    local progress = item.total > 0 and string.format(" [%d/%d]", item.done, item.total) or ""
    return string.format("%s%s %s%s%s", indent, marker, item.prefix, ". " .. item.title, progress)
end

--- Filter items by state name(s).
--- @param items table[]
--- @param filter string|string[]  State name or list of state names to include
--- @return table[]
local function filter_by_state(items, filter)
    local allowed = {}
    if type(filter) == "string" then
        allowed[filter] = true
    else
        for _, f in ipairs(filter) do
            allowed[f] = true
        end
    end

    local result = {}
    for _, item in ipairs(items) do
        if item.state and allowed[item.state] then
            table.insert(result, item)
        end
        -- Also check qualifiers
        if item.qualifiers then
            for _, q in ipairs(item.qualifiers) do
                if allowed[q] and not (item.state and allowed[item.state]) then
                    table.insert(result, item)
                    break
                end
            end
        end
    end
    return result
end

--- Resolve a picked item to a file and jump to it.
--- @param item table  Pick item with prefix, is_dir fields
--- @param root string  Project root path
local function jump_to_item(item, root)
    if not item then return end

    -- Try to find the file via the index
    index.invalidate_project_cache()
    local entries = project.scan(root)

    -- Find matching entry
    for _, entry in ipairs(entries) do
        if entry.prefix == item.prefix then
            if entry.is_dir then
                -- Open the directory's status file
                local status_file = project.find_status_file(entry.filepath)
                if status_file then
                    vim.cmd("edit " .. vim.fn.fnameescape(status_file))
                end
            else
                vim.cmd("edit " .. vim.fn.fnameescape(entry.filepath))
            end
            return
        end
    end

    -- Fallback: search status files for the heading
    local root_status = project.find_status_file(root)
    if root_status then
        local headings = index.get_file_headings(root_status,
            project.extract_prefix(vim.fn.fnamemodify(root_status, ":t")))
        local target = headings[item.prefix]
        if target then
            vim.cmd("edit " .. vim.fn.fnameescape(root_status))
            vim.api.nvim_win_set_cursor(0, { target.line + 1, 0 })
            return
        end
    end

    vim.notify("Could not find " .. item.prefix, vim.log.levels.WARN)
end

--- Open the state filter picker, then show items matching the selected state.
function M.pick_by_state()
    local states = {
        { name = "undone",    char = "( )", desc = "Not started" },
        { name = "pending",   char = "(-)", desc = "In progress" },
        { name = "done",      char = "(x)", desc = "Complete" },
        { name = "on_hold",   char = "(=)", desc = "On hold" },
        { name = "cancelled", char = "(_)", desc = "Cancelled" },
        { name = "ambiguous", char = "(?)", desc = "Uncertain" },
        { name = "important", char = "(!)", desc = "Urgent" },
    }

    local display = {}
    for _, s in ipairs(states) do
        table.insert(display, string.format("%s  %s — %s", s.char, s.name, s.desc))
    end

    vim.ui.select(display, {
        prompt = "Filter by status:",
    }, function(_, idx)
        if idx then
            M.pick({ filter = states[idx].name })
        end
    end)
end

--- Open the owner filter picker, then show items owned by the selected owner.
function M.pick_by_owner()
    local buf = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)

    if not root then
        vim.notify("No project root found.", vim.log.levels.ERROR)
        return
    end

    local fields = require("neorg-project-manager.fields")
    local owners = fields.get_project_owners(root)

    if #owners == 0 then
        vim.notify("No Owner: fields found in project files.", vim.log.levels.INFO)
        return
    end

    vim.ui.select(owners, {
        prompt = "Filter by owner:",
    }, function(owner)
        if owner then
            M.pick({ owner = owner })
        end
    end)
end

--- Open the project item picker.
--- @param opts table|nil  {filter = string|string[]|nil, owner = string|nil}
function M.pick(opts)
    opts = opts or {}
    local buf = vim.api.nvim_get_current_buf()
    local filepath = vim.api.nvim_buf_get_name(buf)
    local root = project.find_root(filepath)

    if not root then
        vim.notify("No project root found.", vim.log.levels.ERROR)
        return
    end

    index.invalidate_project_cache()
    local root_status = project.find_status_file(root)
    local skip_file = root_status and vim.fn.fnamemodify(root_status, ":t") or nil
    local tree = status.build_project_tree(root, skip_file)
    local items = flatten_tree(tree)

    -- Apply state filter if provided
    if opts.filter then
        items = filter_by_state(items, opts.filter)
    end

    -- Apply owner filter if provided
    if opts.owner then
        local fields_mod = require("neorg-project-manager.fields")
        local filtered = {}
        local entries = project.scan(root)

        -- Build prefix → owner map
        local prefix_owners = {}
        for _, entry in ipairs(entries) do
            if not entry.is_dir then
                local lines = vim.fn.readfile(entry.filepath)
                local data = fields_mod.extract_from_lines(lines)
                if data.owner then
                    prefix_owners[entry.prefix] = data.owner
                end
            end
        end

        for _, item in ipairs(items) do
            local item_owner = prefix_owners[item.prefix] or ""
            if item_owner:find(opts.owner, 1, true) then
                table.insert(filtered, item)
            end
        end
        items = filtered
    end

    if #items == 0 then
        local msg = "No project items found"
        if opts.filter then
            msg = msg .. " with state: " .. (type(opts.filter) == "table" and table.concat(opts.filter, ", ") or opts.filter)
        end
        if opts.owner then
            msg = msg .. " owned by: " .. opts.owner
        end
        vim.notify(msg .. ".", vim.log.levels.INFO)
        return
    end

    -- Build display strings
    local display_items = {}
    for _, item in ipairs(items) do
        table.insert(display_items, format_item(item))
    end

    local prompt_parts = { "Project Items" }
    if opts.filter then
        table.insert(prompt_parts, "[" .. (type(opts.filter) == "table" and table.concat(opts.filter, ",") or opts.filter) .. "]")
    end
    if opts.owner then
        table.insert(prompt_parts, "[" .. opts.owner .. "]")
    end

    vim.ui.select(display_items, {
        prompt = table.concat(prompt_parts, " ") .. ":",
        kind = "neorg_pm_pick",
    }, function(_, idx)
        if idx then
            jump_to_item(items[idx], root)
        end
    end)
end

return M
