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

  vim.list_extend(command, test_filter_args)

  -- Handle DAP debugging strategy
  if arguments.strategy == 'dap' then
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

    print('DEBUG: Created init script at: ' .. init_script_path)

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

    print('DEBUG: Starting Gradle with command: ' .. vim.inspect(command))

    -- Start Gradle process using vim.loop.spawn (platform-independent)
    local gradle_args = {}
    for i = 2, #command do
      table.insert(gradle_args, command[i])
    end

    local gradle_handle
    local gradle_pid
    local gradle_exited = false

    gradle_handle, gradle_pid = vim.loop.spawn(
      command[1],  -- Gradle executable
      {
        args = gradle_args,
        cwd = project_directory,
        detached = true,
      },
      function(code, signal)
        gradle_exited = true
        print('DEBUG: Gradle exited with code: ' .. tostring(code) .. ', signal: ' .. tostring(signal))
      end
    )

    if not gradle_handle then
      os.remove(init_script_path)
      error('Failed to start Gradle process for DAP debugging')
    end

    print('DEBUG: Started Gradle with PID: ' .. gradle_pid)

    -- Helper function to check if TCP port is open using vim.loop (platform-independent)
    local function check_port_open(host, port, timeout_ms)
      local tcp = vim.loop.new_tcp()
      if not tcp then
        return false
      end

      local connected = false
      local finished = false

      tcp:connect(host, port, function(err)
        connected = not err
        finished = true
        tcp:close()
      end)

      -- Wait for connection attempt to complete
      vim.wait(timeout_ms or 100, function()
        return finished
      end, 10)

      if not finished then
        tcp:close()
      end

      return connected
    end

    -- Helper function to check if process is alive (platform-independent)
    local function is_process_alive(pid)
      local success = pcall(vim.loop.kill, pid, 0)
      return success
    end

    -- Synchronous port polling using vim.wait - BLOCKS until port is ready or timeout
    -- This ensures DAP will only start AFTER the port is available
    print('Starting Gradle with PID ' .. gradle_pid .. ', waiting for debug port 5005...')

    local attempt = 0
    local port_ready = vim.wait(10000, function()  -- 10 seconds timeout
      attempt = attempt + 1

      -- Check if Gradle process died
      if gradle_exited or not is_process_alive(gradle_pid) then
        print('WARNING: Gradle process ' .. gradle_pid .. ' is not running anymore!')
        return true  -- Stop waiting
      end

      -- Check if port is open
      local port_open = check_port_open('localhost', 5005, 100)

      if attempt % 10 == 0 then  -- Print every ~1 second
        print(string.format('DEBUG: Attempt %d - Port open: %s, Process alive: %s',
          attempt, tostring(port_open), tostring(is_process_alive(gradle_pid))))
      end

      return port_open
    end, 100)  -- Check every 100ms

    if not port_ready then
      -- Kill the Gradle process since port didn't open
      pcall(vim.loop.kill, gradle_pid, 'sigterm')
      os.remove(init_script_path)
      error('Timeout: Gradle debug port 5005 did not open within 10 seconds')
    end

    print('Port 5005 is ready - DAP can now attach')
    print('DEBUG: Returning RunSpec with wait command')

    -- Gradle is running and port is ready, return RunSpec with command that waits for Gradle
    -- The command just monitors the Gradle process until it completes
    -- Also clean up the init script when done
    local wait_script = string.format([[
      echo "Gradle is running (PID %s), waiting for completion..."
      while kill -0 %s 2>/dev/null; do
        sleep 0.5
      done
      echo "Gradle process completed"
      rm -f %s
    ]], gradle_pid, gradle_pid, init_script_path)

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
