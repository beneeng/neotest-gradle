--- @class NeotestGradleConfig
--- @field dap_adapter_type? string DAP adapter type (default: 'kotlin')
--- @field dap_port? number Debug port for DAP (default: 5005)

--- @type NeotestGradleConfig
local M = {}

M.config = {
  dap_adapter_type = 'kotlin',
  dap_port = 5005,
}

--- @param user_config? NeotestGradleConfig
--- @return table Neotest adapter
return setmetatable(M, {
  __call = function(_, user_config)
    M.config = vim.tbl_deep_extend('force', M.config, user_config or {})
    return M
  end,
  __index = function(_, key)
    local adapter = {
      name = 'gradle-test',
      root = require('neotest-gradle.hooks.find_project_directory'),
      is_test_file = require('neotest-gradle.hooks.is_test_file'),
      discover_positions = require('neotest-gradle.hooks.discover_positions'),
      build_spec = require('neotest-gradle.hooks.build_run_specification'),
      results = require('neotest-gradle.hooks.collect_results'),
    }
    return adapter[key]
  end
})
