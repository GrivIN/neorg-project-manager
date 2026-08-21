--- Tests for the promote module.
--- Covers: promote (basic, nested, labeled sections, edge cases)

local cfg = require("neorg-project-manager.config")
local promote = require("neorg-project-manager.promote")

cfg.set({
    numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
    number_separator = ".",
    number_format = nil,
    number_title_separator = ". ",
})

--- Helper to create a buffer with content and position cursor on a given line.
local function make_buf(lines, cursor_line)
    local buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].filetype = "norg"
    -- Need to switch to this buffer for cursor operations
    vim.api.nvim_set_current_buf(buf)
    vim.api.nvim_win_set_cursor(0, { cursor_line or 1, 0 })
    return buf
end

--- Helper to get all lines from a buffer.
local function get_lines(buf)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
end

describe("promote.promote", function()
    it("promotes free list items to subsections", function()
        local buf = make_buf({
            "** (-) Notifications",
            "   - (-) Rich notification content",
            "   - ( ) Push notification scheduling",
            "   - (x) Basic notification display",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- Should have 4 lines: parent heading + 3 child headings (renumbered)
        assert_eq(#result, 4, "line count after promote")
        assert_match(result[1], "^%*%* %(%-%) ", "parent heading preserved")
        assert_match(result[2], "^%*%*%* %(%-%) ", "first child is pending heading")
        assert_match(result[3], "^%*%*%* %( %) ", "second child is undone heading")
        assert_match(result[4], "^%*%*%* %(x%) ", "third child is done heading")

        -- Check titles are present
        assert_match(result[2], "Rich notification content", "first title preserved")
        assert_match(result[3], "Push notification scheduling", "second title preserved")
        assert_match(result[4], "Basic notification display", "third title preserved")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("preserves body text above subsections", function()
        local buf = make_buf({
            "** (-) Feature",
            "   High priority for Q2.",
            "   - (-) Task one",
            "   - ( ) Task two",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- Body text should stay, followed by the heading line and new subsections
        assert_match(result[1], "^%*%* %(%-%) ", "parent heading")
        assert_match(result[2], "High priority for Q2", "body text preserved")
        assert_match(result[3], "^%*%*%* %(%-%) ", "first promoted heading")
        assert_match(result[4], "^%*%*%* %( %) ", "second promoted heading")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("preserves labeled sections", function()
        local buf = make_buf({
            "** (-) Feature",
            "   Pre-requisites:",
            "   - (x) Backend service ready",
            "",
            "   - (-) Free task to promote",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- "Pre-requisites:" and its item should be preserved
        local has_prereq_label = false
        local has_backend_item = false
        for _, line in ipairs(result) do
            if line:match("Pre%-requisites:") then has_prereq_label = true end
            if line:match("Backend service ready") and line:match("^%s*%-") then
                has_backend_item = true
            end
        end
        assert_true(has_prereq_label, "Pre-requisites label preserved")
        assert_true(has_backend_item, "labeled list item preserved as list item")

        -- Free task should be promoted to a heading
        local has_promoted = false
        for _, line in ipairs(result) do
            if line:match("^%*%*%*") and line:match("Free task to promote") then
                has_promoted = true
            end
        end
        assert_true(has_promoted, "free item promoted to heading")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("keeps sub-items as body content under new heading", function()
        local buf = make_buf({
            "** (-) Feature",
            "   - (-) Rich content",
            "     - Image preview",
            "     - Action buttons",
            "   - ( ) Simple task",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- "Rich content" should be a heading, with sub-items as body
        local rich_idx = nil
        for i, line in ipairs(result) do
            if line:match("^%*%*%*") and line:match("Rich content") then
                rich_idx = i
                break
            end
        end
        assert_true(rich_idx ~= nil, "Rich content promoted to heading")

        -- Sub-items should follow as list items (not headings)
        if rich_idx then
            local has_image = result[rich_idx + 1] and result[rich_idx + 1]:match("Image preview")
            local has_buttons = result[rich_idx + 2] and result[rich_idx + 2]:match("Action buttons")
            assert_true(has_image ~= nil, "sub-item Image preview kept")
            assert_true(has_buttons ~= nil, "sub-item Action buttons kept")
            -- They should NOT be headings
            assert_true(not result[rich_idx + 1]:match("^%*"), "sub-item is not a heading")
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("inserts after existing child headings", function()
        local buf = make_buf({
            "** (-) Feature",
            "   - (-) New task",
            "*** (x) Existing child",
            "    Some content here.",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- Find positions
        local existing_idx = nil
        local new_idx = nil
        for i, line in ipairs(result) do
            if line:match("Existing child") then existing_idx = i end
            if line:match("New task") and line:match("^%*%*%*") then new_idx = i end
        end

        assert_true(existing_idx ~= nil, "existing child present")
        assert_true(new_idx ~= nil, "new promoted heading present")
        if existing_idx and new_idx then
            assert_true(new_idx > existing_idx, "new heading inserted after existing child")
        end

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("errors on level 6 heading", function()
        local buf = make_buf({
            "****** (-) Deep heading",
            "   - (-) Cannot promote this",
        }, 1)

        -- Should not error (just notify), and content should be unchanged
        local original = get_lines(buf)
        promote.promote(buf)
        local result = get_lines(buf)
        assert_eq(#result, #original, "no changes on level 6")
        assert_eq(result[2], original[2], "list item unchanged")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("no-ops when no free list items exist", function()
        local buf = make_buf({
            "** (-) Feature",
            "   Just some body text.",
            "   No list items here.",
        }, 1)

        local original = get_lines(buf)
        promote.promote(buf)
        local result = get_lines(buf)
        assert_eq(#result, #original, "no changes when no items")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("promotes items without todo state", function()
        local buf = make_buf({
            "** (-) Feature",
            "   - Item without state",
            "   - (x) Item with state",
        }, 1)

        promote.promote(buf)
        local result = get_lines(buf)

        -- Item without state should become heading without todo extension
        -- After renumber: "*** 1. Item without state" (no "(x)" part)
        local no_state_heading = false
        local with_state_heading = false
        for _, line in ipairs(result) do
            -- No-state: starts with *** then a digit (number), no "(" before the number
            if line:match("^%*%*%* %d") and line:match("Item without state") then
                no_state_heading = true
            end
            -- With-state: starts with *** then "(x)"
            if line:match("^%*%*%* %(x%)") and line:match("Item with state") then
                with_state_heading = true
            end
        end
        assert_true(no_state_heading, "item without state promoted without todo extension")
        assert_true(with_state_heading, "item with state promoted with todo extension")

        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)
