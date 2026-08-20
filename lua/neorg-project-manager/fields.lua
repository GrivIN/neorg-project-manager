--- neorg-project-manager.fields: Metadata field extraction (Owner, Effort).
---
--- Detects "Owner:" and "Effort:" fields in heading descriptions and makes
--- them available for display, filtering, and aggregation. Can optionally
--- show compact badges as virtual text.
---
--- @module neorg-project-manager.fields

local M = {}

local config = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")
local sections = require("neorg-project-manager.sections")
local project = require("neorg-project-manager.project")

--- Known effort sizes for parsing/aggregation.
local effort_sizes = { "XS", "S", "M", "L", "XL", "XXL" }
local effort_set = {}
for _, s in ipairs(effort_sizes) do effort_set[s] = true end

--- Parse an effort value string into structured data.
--- @param raw string  e.g., "M (2-3 sprints)" or "XL"
--- @return {raw: string, size: string|nil}
local function parse_effort(raw)
    -- Try to extract a T-shirt size at the beginning
    local size = raw:match("^(%u+)")
    if size and effort_set[size] then
        return { raw = raw, size = size }
    end
    return { raw = raw, size = nil }
end

--- Extract metadata fields from a heading's description (buffer).
--- @param heading_node TSNode
--- @param buf number
--- @return {owner: string|nil, effort: {raw: string, size: string|nil}|nil}
function M.extract(heading_node, buf)
    local owner_pattern = config.get("owner_pattern", "Owner:")
    local effort_pattern = config.get("effort_pattern", "Effort:")

    local result = { owner = nil, effort = nil }

    local owner_field = sections.detect_field(heading_node, buf, owner_pattern)
    if owner_field then
        result.owner = owner_field.value
    end

    local effort_field = sections.detect_field(heading_node, buf, effort_pattern)
    if effort_field then
        result.effort = parse_effort(effort_field.value)
    end

    return result
end

--- Extract metadata fields from raw file lines (for disk scanning).
--- @param lines string[]
--- @return {owner: string|nil, effort: {raw: string, size: string|nil}|nil}
function M.extract_from_lines(lines)
    local owner_pattern = config.get("owner_pattern", "Owner:")
    local effort_pattern = config.get("effort_pattern", "Effort:")

    local result = { owner = nil, effort = nil }

    local owner_field = sections.detect_field_from_lines(lines, owner_pattern)
    if owner_field then
        result.owner = owner_field.value
    end

    local effort_field = sections.detect_field_from_lines(lines, effort_pattern)
    if effort_field then
        result.effort = parse_effort(effort_field.value)
    end

    return result
end

--- Refresh field virtual text badges for all headings in a buffer.
--- Only displays if field_display == "virtual" in config.
---
--- @param buf number      Buffer handle
--- @param ns number       Extmark namespace ID
--- @param root TSNode|nil Pre-parsed root node
function M.refresh(buf, ns, root)
    root = root or helpers.get_norg_root(buf)
    if not root then
        return
    end

    local hl = config.get("field_highlight", "Comment")

    helpers.walk_headings(root, function(node, _)
        local data = M.extract(node, buf)
        if not data.owner and not data.effort then return end

        local row = node:start()
        local parts = {}

        if data.owner then
            table.insert(parts, data.owner)
        end
        if data.effort then
            table.insert(parts, "[" .. (data.effort.size or data.effort.raw) .. "]")
        end

        if #parts > 0 then
            vim.api.nvim_buf_set_extmark(buf, ns, row, 0, {
                virt_text = { { "  " .. table.concat(parts, "  "), hl } },
                virt_text_pos = "eol",
                hl_mode = "combine",
            })
        end
    end)
end

--- Get all unique owners across a project.
--- Scans all project files and extracts Owner: fields.
---
--- @param root_path string  Project root directory
--- @return string[]         Sorted unique owner list
function M.get_project_owners(root_path)
    local owners_set = {}
    local entries = project.scan(root_path)

    for _, entry in ipairs(entries) do
        if not entry.is_dir then
            local lines = vim.fn.readfile(entry.filepath)
            local data = M.extract_from_lines(lines)
            if data.owner then
                -- Handle comma-separated owners: "@backend-team, @mobile-team"
                for owner in data.owner:gmatch("[^,]+") do
                    owners_set[vim.trim(owner)] = true
                end
            end
        end
    end

    local owners = vim.tbl_keys(owners_set)
    table.sort(owners)
    return owners
end

--- Aggregate effort data from a flat list of project entries.
---
--- @param root_path string
--- @return {total: number, by_size: table<string, number>, items: table[]}
function M.aggregate_effort(root_path)
    local result = { total = 0, by_size = {}, items = {} }
    local entries = project.scan(root_path)

    for _, entry in ipairs(entries) do
        if not entry.is_dir then
            local lines = vim.fn.readfile(entry.filepath)
            local data = M.extract_from_lines(lines)
            if data.effort then
                result.total = result.total + 1
                local size = data.effort.size or "?"
                result.by_size[size] = (result.by_size[size] or 0) + 1
                table.insert(result.items, {
                    prefix = entry.prefix,
                    effort = data.effort,
                })
            end
        end
    end

    return result
end

return M
