--- Test runner for neorg-project-manager.
--- Run with: nvim --headless -u NONE -l tests/run.lua
---
--- Sets up the minimal environment (runtimepath, tree-sitter parsers)
--- and executes all test files in this directory.

-- Setup runtimepath for norg parser and the plugin itself
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy-rocks/tree-sitter-norg/lib/lua/5.1")
vim.opt.runtimepath:prepend(vim.fn.stdpath("data") .. "/lazy-rocks/tree-sitter-norg-meta/lib/lua/5.1")

-- Add the plugin to runtimepath (tests/ is inside the plugin dir)
local plugin_root = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h:h")
vim.opt.runtimepath:prepend(plugin_root)

-- Minimal test framework
local passed = 0
local failed = 0
local errors = {}

function _G.assert_eq(actual, expected, msg)
    if actual == expected then
        passed = passed + 1
    else
        failed = failed + 1
        local err = string.format("FAIL: %s\n  expected: %s\n  actual:   %s",
            msg or "assertion", vim.inspect(expected), vim.inspect(actual))
        table.insert(errors, err)
        print(err)
    end
end

function _G.assert_true(value, msg)
    assert_eq(not not value, true, msg)
end

function _G.assert_nil(value, msg)
    assert_eq(value, nil, msg)
end

function _G.assert_match(str, pattern, msg)
    if str and str:match(pattern) then
        passed = passed + 1
    else
        failed = failed + 1
        local err = string.format("FAIL: %s\n  string: %s\n  pattern: %s",
            msg or "match", vim.inspect(str), pattern)
        table.insert(errors, err)
        print(err)
    end
end

function _G.describe(name, fn)
    print("\n=== " .. name .. " ===")
    fn()
end

function _G.it(name, fn)
    local ok, err = pcall(fn)
    if not ok then
        failed = failed + 1
        local msg = string.format("  ERROR: %s\n    %s", name, err)
        table.insert(errors, msg)
        print(msg)
    end
end

-- Run test files
local test_dir = vim.fn.fnamemodify(debug.getinfo(1, "S").source:sub(2), ":p:h")
local test_files = vim.fn.glob(test_dir .. "/test_*.lua", false, true)
table.sort(test_files)

for _, file in ipairs(test_files) do
    print("\n--- Running: " .. vim.fn.fnamemodify(file, ":t") .. " ---")
    dofile(file)
end

-- Summary
print("\n" .. string.rep("=", 50))
print(string.format("Results: %d passed, %d failed", passed, failed))
if failed > 0 then
    print("\nFailures:")
    for _, err in ipairs(errors) do
        print("  " .. err)
    end
end
print(string.rep("=", 50))

vim.cmd("qa!")
