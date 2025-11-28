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
  -- Safety check for nil project_directory
  if not project_directory or project_directory == '' then
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
        return test_results_dir .. lib.files.sep .. 'test'
      end
    end
  end

  -- Fallback to standard Gradle test results directory
  return project_directory .. lib.files.sep .. 'build' .. lib.files.sep .. 'test-results' .. lib.files.sep .. 'test'
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
  local project_directory = find_project_directory(position.path)
  local gradle_executable = get_gradle_executable(project_directory)
  local test_filter_args = get_test_filter_arguments(arguments.tree, position)

  local context = {}
  context.test_results_directory = get_test_results_directory(gradle_executable, project_directory)

  -- Build the Gradle command
  local command = { gradle_executable, '--project-dir', project_directory, 'test' }

  -- For DAP debugging, force re-run and rebuild of tests
  -- Otherwise Gradle may skip test execution or use cached build artifacts
  if arguments.strategy == 'dap' then
    table.insert(command, '--rerun-tasks')     -- Force re-run tests even if up-to-date
    table.insert(command, '--no-build-cache')  -- Disable build cache to always recompile
    table.insert(command, '--no-daemon')       -- Don't use daemon for clean process lifecycle
  end

  vim.list_extend(command, test_filter_args)

  -- Handle DAP debugging strategy
  if arguments.strategy == 'dap' then
    -- Clean test results directory to ensure we only read fresh results
    local results_dir = context.test_results_directory
    if results_dir and results_dir ~= '' then
      local stat = vim.loop.fs_stat(results_dir)
      if stat then
        -- Remove all XML files from previous runs using fs_scandir
        local handle = vim.loop.fs_scandir(results_dir)
        local old_files = {}
        if handle then
          while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if type == 'file' and name:match('%.xml$') then
              local filepath = results_dir .. '/' .. name
              os.remove(filepath)
              table.insert(old_files, filepath)
            end
          end
        end
        print(string.format('[DAP] Cleaned %d old XML file(s) from %s', #old_files, results_dir))
      end
    end

    -- Create a temporary Gradle init script that configures test JVM for debugging
    -- This is necessary because --debug-jvm debugs Gradle itself, not the test JVM
    local init_script_content = [[
allprojects {
  tasks.withType(Test) {
    jvmArgs '-agentlib:jdwp=transport=dt_socket,server=y,suspend=y,address=5005'
  }
}
]]

    -- Create temporary init script file
    local init_script_path = os.tmpname()
    local init_file = io.open(init_script_path, 'w')
    if not init_file then
      error('Failed to create temporary Gradle init script')
    end
    init_file:write(init_script_content)
    init_file:close()

    -- Insert init-script argument before 'test' task
    local test_index = nil
    for i, arg in ipairs(command) do
      if arg == 'test' then
        test_index = i
        break
      end
    end

    if test_index then
      table.insert(command, test_index, init_script_path)
      table.insert(command, test_index, '--init-script')
    end

    -- Build the full Gradle command as a properly escaped string
    local gradle_cmd_parts = {}
    for _, part in ipairs(command) do
      -- Escape single quotes in each part for shell safety
      local escaped = part:gsub("'", "'\\''")
      table.insert(gradle_cmd_parts, "'" .. escaped .. "'")
    end
    local gradle_cmd = table.concat(gradle_cmd_parts, ' ')

    -- Create temp file for Gradle output (so we can parse it)
    local output_file = os.tmpname() .. '.log'

    -- Create a wrapper script that runs Gradle and protects it from SIGINT
    -- This ensures Gradle completes and writes test results even when DAP session ends
    local wrapper_script = string.format([[
#!/bin/bash
# Ignore SIGINT to protect Gradle from being interrupted when DAP ends
trap '' INT

# Execute Gradle (replace shell with Gradle process)
exec %s
]], gradle_cmd)

    -- Write wrapper script to temp file
    local wrapper_file = os.tmpname() .. '.sh'
    local wrapper_handle = io.open(wrapper_file, 'w')
    if not wrapper_handle then
      os.remove(init_script_path)
      error('Failed to create Gradle wrapper script')
    end
    wrapper_handle:write(wrapper_script)
    wrapper_handle:close()

    -- Make wrapper script executable
    os.execute('chmod +x ' .. wrapper_file)

    -- Start wrapper script in background and capture PID
    -- Redirect stdin to /dev/null to prevent JDWP from monitoring stdin and exiting when it closes
    local start_cmd = 'nohup sh ' .. wrapper_file .. ' < /dev/null > ' .. output_file .. ' 2>&1 & echo $!'

    local handle = io.popen(start_cmd)
    local pid = handle:read('*l')
    handle:close()

    -- Give Gradle a moment to initialize
    os.execute('sleep 0.5')

    if not pid or pid == '' then
      -- Clean up init script
      os.remove(init_script_path)
      error('Failed to start Gradle process for DAP debugging')
    end

    -- Parse Gradle output until we see "Listening for transport dt_socket"
    -- This is much more reliable than port checking and platform-independent!
    local port_ready = false
    local dap_attached = false
    for i = 1, 100 do  -- 10 seconds total (100 * 0.1s)
      -- Check if Gradle process is still running
      local proc_alive = os.execute('kill -0 ' .. pid .. ' 2>/dev/null')

      -- Read Gradle output and check for "Listening" message
      local file = io.open(output_file, 'r')
      if file then
        local content = file:read('*all')
        file:close()

        -- Look for "Listening for transport dt_socket" (with error tolerance - no specific port)
        if content:match('Listening for transport dt_socket') then
          dap_attached = true
          port_ready = true
          break
        end
      end

      -- If Gradle process died, check if DAP was already attached
      if not (proc_alive == 0 or proc_alive == true) then
        if dap_attached then
          -- Process ended after DAP attached - this is OK (test completed quickly)
          print('Gradle process ended after DAP attached (test may have completed)')
          port_ready = true
          break
        else
          -- Process died before we saw "Listening" - this is an error
          print('WARNING: Gradle process ' .. pid .. ' died before debug port was ready!')
          -- Print last lines of output for debugging
          local file = io.open(output_file, 'r')
          if file then
            local content = file:read('*all')
            file:close()
            local last_lines = {}
            for line in content:gmatch('[^\r\n]+') do
              table.insert(last_lines, line)
            end
            print('Last Gradle output lines:')
            for i = math.max(1, #last_lines - 5), #last_lines do
              print('  ' .. last_lines[i])
            end
          end
          break
        end
      end

      os.execute('sleep 0.1')
    end

    -- Clean up output file
    os.remove(output_file)

    if not port_ready then
      -- Kill the Gradle process since port didn't open
      os.execute('kill ' .. pid .. ' 2>/dev/null')
      os.remove(init_script_path)
      error('Timeout: Did not see "Listening for transport dt_socket" in Gradle output within 10 seconds')
    end

    -- Gradle is running and port is ready, return RunSpec with command that waits for Gradle
    -- The command just waits for the background Gradle process
    -- The actual synchronization happens in results() via marker file polling
    -- This ensures DAP can detach cleanly while Gradle completes writing results
    local wait_script = string.format([[
      # Ignore SIGINT to ensure we wait for Gradle to complete
      # This prevents premature termination when DAP session ends
      trap '' INT

      # LOGGING: Track wait_script lifecycle
      echo "[$(date +'%%H:%%M:%%S')] WAIT_SCRIPT STARTED - Waiting for Gradle PID %s"

      # Wait for Gradle wrapper process to finish
      while kill -0 %s 2>/dev/null; do
        sleep 0.5
      done
      echo "[$(date +'%%H:%%M:%%S')] Gradle process ended"

      # Give filesystem a moment to sync (NFS, slow disks, etc.)
      sleep 1

      echo "[$(date +'%%H:%%M:%%S')] WAIT_SCRIPT ENDING - Cleanup"

      # Clean up temporary files (marker file cleaned by results())
      rm -f %s
      rm -f %s
    ]], pid, pid, init_script_path, wrapper_file)

    return {
      command = {'sh', '-c', wait_script},
      context = context,
      strategy = {
        type = 'kotlin',
        request = 'attach',  -- Attach to already running Gradle process
        name = 'Attach to Gradle Test',
        projectRoot = project_directory,
        hostName = 'localhost',
        port = 5005,
        timeout = 30000,  -- 30 seconds for DAP connection attempts
      }
    }
  end

  -- Default integrated strategy
  return {
    command = command,
    context = context,
  }
end
