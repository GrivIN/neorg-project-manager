--- Tests for the helpers module.
--- Covers: get_todo_state, get_heading_level, get_list_level, get_norg_root,
---         replace_link_numbers, prefix_depth, extract_link_number_from_line

local cfg = require("neorg-project-manager.config")
local helpers = require("neorg-project-manager.helpers")

cfg.set({ number_separator = "." })

describe("helpers.get_todo_state", function()
    it("extracts done state from a heading node", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* (x) Done Heading" })
        vim.bo[buf].filetype = "norg"
        local root = helpers.get_norg_root(buf)
        assert_true(root ~= nil, "got root")
        if root then
            -- First child should be a heading1
            local heading = root:named_child(0)
            if heading then
                local state = helpers.get_todo_state(heading)
                assert_eq(state, "done", "heading state is done")
            end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns nil for headings without todo state", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Plain Heading" })
        vim.bo[buf].filetype = "norg"
        local root = helpers.get_norg_root(buf)
        if root then
            local heading = root:named_child(0)
            if heading then
                local state = helpers.get_todo_state(heading)
                assert_nil(state, "no state for plain heading")
            end
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("helpers.get_heading_level", function()
    it("returns correct level for heading nodes", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* H1", "** H2", "*** H3" })
        vim.bo[buf].filetype = "norg"
        local root = helpers.get_norg_root(buf)
        if root then
            local h1 = root:named_child(0)
            assert_eq(helpers.get_heading_level(h1), 1, "level 1")
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("returns nil for non-heading nodes", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "Just text" })
        vim.bo[buf].filetype = "norg"
        local root = helpers.get_norg_root(buf)
        if root then
            assert_nil(helpers.get_heading_level(root), "root is not a heading")
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("helpers.get_norg_root", function()
    it("returns root node for valid norg buffer", function()
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "* Hello" })
        vim.bo[buf].filetype = "norg"
        local root = helpers.get_norg_root(buf)
        assert_true(root ~= nil, "root not nil")
        if root then
            assert_eq(root:type(), "document", "root type is document")
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("helpers.replace_link_numbers", function()
    it("replaces matching link numbers", function()
        local lines = {
            "Some text {* 1.1.1} more text",
            "Another {* 2.3} line",
            "No links here",
        }
        local result, modified = helpers.replace_link_numbers(lines, function(text)
            if text == "1.1.1" then return "1.1.2" end
            return nil
        end)
        assert_true(modified, "was modified")
        assert_match(result[1], "{%* 1.1.2}", "link updated")
        assert_match(result[2], "{%* 2.3}", "unmatched link unchanged")
        assert_eq(result[3], "No links here", "non-link line unchanged")
    end)

    it("returns modified=false when nothing changes", function()
        local lines = { "No links" }
        local _, modified = helpers.replace_link_numbers(lines, function() return nil end)
        assert_eq(modified, false, "not modified")
    end)
end)

describe("helpers.prefix_depth", function()
    it("handles various depths", function()
        assert_eq(helpers.prefix_depth(nil), 0, "nil")
        assert_eq(helpers.prefix_depth(""), 0, "empty")
        assert_eq(helpers.prefix_depth("1"), 1, "single")
        assert_eq(helpers.prefix_depth("1.2"), 2, "two parts")
        assert_eq(helpers.prefix_depth("1.2.3.4.5"), 5, "five parts")
    end)
end)

describe("helpers.extract_link_number_from_line", function()
    it("extracts number from managed heading", function()
        local num = helpers.extract_link_number_from_line("*** (x) 1.1.1. Setup {* 1.1.1}")
        assert_eq(num, "1.1.1", "extracted number")
    end)

    it("returns nil for non-managed heading", function()
        local num = helpers.extract_link_number_from_line("*** My Manual Heading")
        assert_nil(num, "nil for no link")
    end)

    it("handles multi-star links", function()
        local num = helpers.extract_link_number_from_line("Text {*** 1.2.3} more")
        assert_eq(num, "1.2.3", "extracted from multi-star")
    end)
end)

describe("helpers.natural_sort_prefixes", function()
    it("sorts single-digit numerics correctly", function()
        assert_true(helpers.natural_sort_prefixes("1", "2"), "1 < 2")
        assert_true(not helpers.natural_sort_prefixes("2", "1"), "not 2 < 1")
    end)

    it("sorts multi-part numerics correctly", function()
        assert_true(helpers.natural_sort_prefixes("1.1", "1.2"), "1.1 < 1.2")
        assert_true(helpers.natural_sort_prefixes("1.2", "1.10"), "1.2 < 1.10 (natural)")
        assert_true(helpers.natural_sort_prefixes("1.9", "1.10"), "1.9 < 1.10")
    end)

    it("handles different depths", function()
        assert_true(helpers.natural_sort_prefixes("1.1", "1.1.1"), "1.1 < 1.1.1 (shorter first)")
        assert_true(not helpers.natural_sort_prefixes("1.1.1", "1.1"), "not 1.1.1 < 1.1")
    end)

    it("handles equal prefixes", function()
        assert_true(not helpers.natural_sort_prefixes("1.1.1", "1.1.1"), "equal returns false")
    end)

    it("handles alpha parts (for non-numeric styles)", function()
        assert_true(helpers.natural_sort_prefixes("1.A", "1.B"), "1.A < 1.B")
        assert_true(helpers.natural_sort_prefixes("1.A.1", "1.B.1"), "1.A.1 < 1.B.1")
    end)
end)
