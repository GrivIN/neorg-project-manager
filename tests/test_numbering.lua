--- Tests for the numbering module.
--- Covers: format_counter, format_number, parse_number_and_title, renumber (stable), update_links

local cfg = require("neorg-project-manager.config")
local numbering = require("neorg-project-manager.numbering")

describe("numbering.format_counter", function()
    it("numeric style", function()
        assert_eq(numbering.format_counter(1, "numeric"), "1", "numeric 1")
        assert_eq(numbering.format_counter(42, "numeric"), "42", "numeric 42")
    end)

    it("alpha_upper style", function()
        assert_eq(numbering.format_counter(1, "alpha_upper"), "A", "alpha A")
        assert_eq(numbering.format_counter(26, "alpha_upper"), "Z", "alpha Z")
        assert_eq(numbering.format_counter(27, "alpha_upper"), "AA", "alpha AA")
    end)

    it("alpha_lower style", function()
        assert_eq(numbering.format_counter(1, "alpha_lower"), "a", "alpha_lower a")
        assert_eq(numbering.format_counter(3, "alpha_lower"), "c", "alpha_lower c")
    end)

    it("roman_upper style", function()
        assert_eq(numbering.format_counter(1, "roman_upper"), "I", "roman I")
        assert_eq(numbering.format_counter(4, "roman_upper"), "IV", "roman IV")
        assert_eq(numbering.format_counter(9, "roman_upper"), "IX", "roman IX")
        assert_eq(numbering.format_counter(14, "roman_upper"), "XIV", "roman XIV")
    end)

    it("roman_lower style", function()
        assert_eq(numbering.format_counter(3, "roman_lower"), "iii", "roman_lower iii")
    end)

    it("unknown style falls back to numeric", function()
        assert_eq(numbering.format_counter(5, "unknown_style"), "5", "fallback numeric")
    end)
end)

describe("numbering.format_number", function()
    it("default numeric format without prefix", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_format = nil,
        })
        assert_eq(numbering.format_number({ 1, 0, 0, 0, 0, 0 }, 1, nil), "1", "level 1")
        assert_eq(numbering.format_number({ 1, 2, 0, 0, 0, 0 }, 2, nil), "1.2", "level 2")
        assert_eq(numbering.format_number({ 1, 1, 3, 0, 0, 0 }, 3, nil), "1.1.3", "level 3")
    end)

    it("format with prefix", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_format = nil,
        })
        assert_eq(numbering.format_number({ 1, 0, 0, 0, 0, 0 }, 1, "1.1.3"), "1.1.3.1", "prefix.1")
        assert_eq(numbering.format_number({ 2, 1, 0, 0, 0, 0 }, 2, "1.1.3"), "1.1.3.2.1", "prefix.2.1")
    end)

    it("total-depth styles with prefix", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "alpha_upper", "alpha_lower", "roman_lower" },
            number_separator = ".",
            number_format = nil,
        })
        -- prefix "1.1" has depth 2. Local level 1 → total depth 3 → numeric
        assert_eq(numbering.format_number({ 1, 0, 0, 0, 0, 0 }, 1, "1.1"), "1.1.1", "depth 3 numeric")
        -- Local level 2 → total depth 4 → alpha_upper
        assert_eq(numbering.format_number({ 1, 2, 0, 0, 0, 0 }, 2, "1.1"), "1.1.1.B", "depth 4 alpha")
    end)

    it("custom number_format function", function()
        cfg.set({
            number_separator = "-",
            number_format = function(counters, level, prefix)
                local parts = {}
                for i = 1, level do
                    parts[i] = numbering.format_counter(counters[i], "roman_upper")
                end
                local num = table.concat(parts, "-")
                if prefix then return prefix .. "-" .. num end
                return num
            end,
        })
        assert_eq(numbering.format_number({ 3, 2, 0, 0, 0, 0 }, 2, nil), "III-II", "custom fn")
        assert_eq(numbering.format_number({ 1, 0, 0, 0, 0, 0 }, 1, "X"), "X-I", "custom fn with prefix")
    end)
end)

describe("numbering.parse_number_and_title", function()
    it("parses number with default separator", function()
        cfg.set({ number_title_separator = ". " })
        local num, title, ws = numbering.parse_number_and_title("1.1.3. My Title")
        assert_eq(num, "1.1.3", "number part")
        assert_eq(title, "My Title", "title part")
        assert_eq(ws, "", "no leading whitespace")
    end)

    it("preserves leading whitespace", function()
        cfg.set({ number_title_separator = ". " })
        local num, title, ws = numbering.parse_number_and_title(" 1.1. Hello")
        assert_eq(num, "1.1", "number")
        assert_eq(title, "Hello", "title")
        assert_eq(ws, " ", "leading space")
    end)

    it("returns nil number for unnumbered heading", function()
        cfg.set({ number_title_separator = ". " })
        local num, title, ws = numbering.parse_number_and_title(" My Heading")
        assert_nil(num, "no number")
        assert_eq(title, "My Heading", "title is the full text")
        assert_eq(ws, " ", "leading space")
    end)

    it("colon separator", function()
        cfg.set({ number_title_separator = ": " })
        local num, title, _ = numbering.parse_number_and_title("1.1.3: Feature X")
        assert_eq(num, "1.1.3", "number with colon sep")
        assert_eq(title, "Feature X", "title with colon sep")
    end)
end)

describe("numbering.renumber", function()
    it("numbers an unnumbered buffer", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* Project",
            "** Stage 1",
            "*** Task A",
            "*** Task B",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert_eq(lines[1], "* 1. Project", "heading 1")
        assert_eq(lines[2], "** 1.1. Stage 1", "heading 2")
        assert_eq(lines[3], "*** 1.1.1. Task A", "heading 3a")
        assert_eq(lines[4], "*** 1.1.2. Task B", "heading 3b")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("preserves existing numbers (stable numbering)", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 1. Alpha",
            "** 1.2. Beta",
            "** 1.1. Gamma",
            "   Link to beta: {* 1.2}",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        -- Stable numbering: existing valid numbers are never changed
        assert_eq(lines[2], "** 1.2. Beta", "beta keeps 1.2")
        assert_eq(lines[3], "** 1.1. Gamma", "gamma keeps 1.1")
        assert_match(lines[4], "{%* 1.2}", "link unchanged")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("fills gaps between existing numbers", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 1. Project",
            "** 1.1. First",
            "** New Task",
            "** 1.3. Third",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert_eq(lines[1], "* 1. Project", "parent unchanged")
        assert_eq(lines[2], "** 1.1. First", "first unchanged")
        assert_eq(lines[3], "** 1.2. New Task", "new task fills gap at 1.2")
        assert_eq(lines[4], "** 1.3. Third", "third unchanged")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("assigns after max when no gap available", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 1. Project",
            "** 1.1. First",
            "** New Task",
            "** 1.2. Second",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert_eq(lines[2], "** 1.1. First", "first unchanged")
        assert_eq(lines[3], "** 1.3. New Task", "new task gets 1.3 (after max since 1.2 taken)")
        assert_eq(lines[4], "** 1.2. Second", "second unchanged")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("handles multiple unnumbered headings sequentially", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 1. Project",
            "** 1.1. First",
            "** New A",
            "** New B",
            "** 1.5. Fifth",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert_eq(lines[2], "** 1.1. First", "first unchanged")
        assert_eq(lines[3], "** 1.2. New A", "new A gets 1.2")
        assert_eq(lines[4], "** 1.3. New B", "new B gets 1.3")
        assert_eq(lines[5], "** 1.5. Fifth", "fifth unchanged")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("preserves anchored level-1 headings in prefix-less files", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 42. Project Alpha",
            "** Child One",
            "** Child Two",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)

        local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        assert_eq(lines[1], "* 42. Project Alpha", "anchor preserved")
        assert_eq(lines[2], "** 42.1. Child One", "child 1 under anchor")
        assert_eq(lines[3], "** 42.2. Child Two", "child 2 under anchor")
        vim.api.nvim_buf_delete(buf, { force = true })
    end)

    it("is idempotent (running twice produces same result)", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
            number_title_separator = ". ",
            number_format = nil,
            file_prefix = nil,
        })
        local buf = vim.api.nvim_create_buf(false, true)
        vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
            "* 1. Project",
            "** 1.1. Alpha",
            "** 1.3. Gamma",
            "*** 1.3.1. Deep",
        })
        vim.bo[buf].filetype = "norg"
        vim.treesitter.get_parser(buf, "norg"):parse()

        numbering.renumber(buf)
        local after_first = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        vim.treesitter.get_parser(buf, "norg"):parse()
        numbering.renumber(buf)
        local after_second = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

        for i = 1, #after_first do
            assert_eq(after_second[i], after_first[i], "idempotent line " .. i)
        end
        vim.api.nvim_buf_delete(buf, { force = true })
    end)
end)

describe("numbering.format_prefix_for_position", function()
    it("formats position under nil parent", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
        })
        assert_eq(numbering.format_prefix_for_position(nil, 1), "1", "pos 1 no parent")
        assert_eq(numbering.format_prefix_for_position(nil, 3), "3", "pos 3 no parent")
    end)

    it("formats position under a parent prefix", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "numeric", "numeric", "numeric", "numeric" },
            number_separator = ".",
        })
        assert_eq(numbering.format_prefix_for_position("1.1", 3), "1.1.3", "1.1 + pos 3")
    end)

    it("uses total-depth styles", function()
        cfg.set({
            numbering_styles = { "numeric", "numeric", "alpha_upper", "numeric", "numeric", "numeric" },
            number_separator = ".",
        })
        -- parent "1.1" depth=2, position goes to depth 3 → alpha_upper
        assert_eq(numbering.format_prefix_for_position("1.1", 2), "1.1.B", "alpha at depth 3")
    end)
end)
