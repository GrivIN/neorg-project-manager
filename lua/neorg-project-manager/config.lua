--- neorg-project-manager.config: Shared configuration storage.
---
--- Single source of truth for plugin configuration. All modules access config
--- through this module rather than maintaining their own config references.
---
--- Usage:
---   local config = require("neorg-project-manager.config")
---   local sep = config.get("number_separator", ".")
---
--- @module neorg-project-manager.config

local M = {}

--- The active configuration values. Populated by init.lua during setup().
--- @type table
M.values = {}

--- Get a config value with a fallback default.
---
--- @param key string       Config key name
--- @param default any      Value to return if key is not set
--- @return any             The config value or default
function M.get(key, default)
    local val = M.values[key]
    if val ~= nil then
        return val
    end
    return default
end

--- Set the full config table. Called once by init.lua during setup().
---
--- @param cfg table  The merged configuration
function M.set(cfg)
    M.values = cfg
end

return M
