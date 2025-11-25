local lib = require('neotest.lib')
local find_project_directory = require('neotest-gradle.hooks.find_project_directory')

--- Fiends either an executable file named `gradlew` in any parent directory of
--- the project or falls back to a binary called `gradle` that must be available
--- in the users PATH.
---
--- @param project_directory string
--- @return string - absolute path to wrapper of binary name
local function get_gradle_executable(project_directory)
  local gradle_wrapper_folder = lib.files.match_root_pattern('gradlew')(project_directory)
  local gradle_wrapper_found = gradle_wrapper_folder ~= nil

  if gradle_wrapper_found then
    return gradle_wrapper_folder .. lib.files.sep .. 'gradlew'
  else
    return 'gradle'
  end
end

--- Runs the given Gradle executable in the respective project directory to
--- query the `testResultsDir` property. Has to do so some plain text parsing of
--- the Gradle command output. The child folder named `test` is always added to
--- this path.
--- Falls back to standard Gradle test results directory if property cannot be determined.
---
--- @param gradle_executable string
--- @param project_directory string
--- @return string - absolute path of test results directory
local function get_test_results_directory(gradle_executable, project_directory)
  -- Debug logging
  vim.notify(
    string.format('[neotest-gradle] Project directory: %s', project_directory or 'nil'),
    vim.log.levels.INFO
  )
  vim.notify(
    string.format('[neotest-gradle] Gradle executable: %s', gradle_executable or 'nil'),
    vim.log.levels.INFO
  )

  -- Safety check for nil project_directory
  if not project_directory or project_directory == '' then
    vim.notify(
      '[neotest-gradle] ERROR: project_directory is nil or empty!',
      vim.log.levels.ERROR
    )
    return ''
  end

  local command = {
    gradle_executable,
    '--project-dir',
    project_directory,
    'properties',
    '--property',
    'testResultsDir',
  }
  local _, output = lib.process.run(command, { stdout = true })
  local output_lines = vim.split(output.stdout or '', '\n')

  for _, line in pairs(output_lines) do
    if line:match('testResultsDir: ') then
      local test_results_dir = line:gsub('testResultsDir: ', '')
      -- Check if value is valid (not empty, not 'null' string, not 'nil' string)
      if test_results_dir ~= '' and test_results_dir ~= 'null' and test_results_dir ~= 'nil' then
        local full_path = test_results_dir .. lib.files.sep .. 'test'
        vim.notify(
          string.format('[neotest-gradle] Using testResultsDir from Gradle: %s', full_path),
          vim.log.levels.INFO
        )
        return full_path
      else
        vim.notify(
          string.format('[neotest-gradle] testResultsDir from Gradle is invalid: "%s", using fallback', test_results_dir),
          vim.log.levels.WARN
        )
      end
    end
  end

  -- Fallback to standard Gradle test results directory
  local fallback_path = project_directory .. lib.files.sep .. 'build' .. lib.files.sep .. 'test-results' .. lib.files.sep .. 'test'
  vim.notify(
    string.format('[neotest-gradle] Using fallback test results directory: %s', fallback_path),
    vim.log.levels.INFO
  )
  return fallback_path
end

--- Takes a NeoTest tree object and iterate over its positions. For each position
--- it traverses up the tree to find the respective namespace that can be
--- used to filter the tests on execution. The namespace is usually the parent
--- test class.
---
--- @param tree table - see neotest.Tree
--- @return  table[] - list of neotest.Position of `type = "namespace"`
local function get_namespaces_of_tree(tree)
  local namespaces = {}

  for _, position in tree:iter() do
    if position.type == 'namespace' then
      table.insert(namespaces, position)
    end
  end

  return namespaces
end

--- Constructs the additional arguments for the test command to filter the
--- correct tests that should run.
--- Therefore it uses (and possibly repeats) the Gradle test command
--- option `--tests` with the full locator. The locators consist of the
--- package path, plus optional class names and test function name. This value is
--- already attached/pre-calculated to the nodes `id` property in the tree.
--- The position argument defines what the user intended to execute, which can
--- also be a whole file. In that case the paths are unknown and must be
--- collected by some additional logic.
---
--- Note: No quotes around position.id since we're using command arrays.
--- Shell escaping is handled automatically by the process runner.
---
--- @param tree table - see neotest.Tree
--- @param position table - see neotest.Position
--- @return string[] - list of strings for arguments
local function get_test_filter_arguments(tree, position)
  local arguments = {}

  if position.type == 'test' or position.type == 'namespace' then
    vim.list_extend(arguments, { '--tests', position.id })
  elseif position.type == 'file' then
    local namespaces = get_namespaces_of_tree(tree)

    for _, namespace in pairs(namespaces) do
      vim.list_extend(arguments, { '--tests', namespace.id })
    end
  end

  return arguments
end

--- Builds the DAP configuration for debugging Gradle tests with kotlin-debug-adapter
--- or other JVM debug adapters.
---
--- @param gradle_executable string
--- @param project_directory string
--- @param test_filter_args string[]
--- @return table - DAP configuration
local function build_dap_config(gradle_executable, project_directory, test_filter_args)
  local config = require('neotest-gradle').config

  -- Build the Gradle command for debugging
  local debug_args = {
    '--project-dir',
    project_directory,
    'test',
    '--debug-jvm'  -- This makes Gradle wait for a debugger to attach
  }
  vim.list_extend(debug_args, test_filter_args)

  return {
    type = config.dap_adapter_type,
    request = 'attach',
    name = 'Attach to Gradle Test',
    hostName = 'localhost',
    port = config.dap_port,
    timeout = 30000,
    preLaunchTask = {
      type = 'shell',
      command = gradle_executable,
      args = debug_args,
    }
  }
end

--- See Neotest adapter specification.
---
--- In its core, it builds a command to start Gradle correctly in the project
--- directory with a test filter based on the positions.
--- It also determines the folder where the resulsts will be reported to, to
--- collect them later on. That folder path is saved to the context object.
---
--- Supports both integrated and DAP strategies for running/debugging tests.
---
--- @param arguments table - see neotest.RunArgs
--- @return nil | table | table[] - see neotest.RunSpec[]
return function(arguments)
  local position = arguments.tree:data()

  -- Debug logging
  vim.notify(
    string.format('[neotest-gradle] Position path: %s', position.path or 'nil'),
    vim.log.levels.INFO
  )

  local project_directory = find_project_directory(position.path)

  -- Debug logging
  vim.notify(
    string.format('[neotest-gradle] Found project directory: %s', project_directory or 'nil'),
    vim.log.levels.INFO
  )

  local gradle_executable = get_gradle_executable(project_directory)
  local test_filter_args = get_test_filter_arguments(arguments.tree, position)

  local context = {}
  context.test_results_directory = get_test_results_directory(gradle_executable, project_directory)

  -- Determine which strategy to use
  local strategy = arguments.strategy or 'integrated'

  if strategy == 'dap' then
    -- For DAP debugging strategy
    local dap_config = build_dap_config(gradle_executable, project_directory, test_filter_args)
    return {
      strategy = dap_config,
      context = context,
    }
  else
    -- For integrated (default) strategy
    -- Don't set strategy field - neotest will use default integrated strategy
    local command = { gradle_executable, '--project-dir', project_directory, 'test' }
    vim.list_extend(command, test_filter_args)

    return {
      command = command,  -- Return as array, not string
      context = context,
    }
  end
end
