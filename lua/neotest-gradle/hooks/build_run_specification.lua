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

local function prepare_gradle_env()
  local env = vim.deepcopy(vim.fn.environ())
  env.TERM = env.TERM or 'xterm-256color'
  env.CLICOLOR_FORCE = '1'
  env.FORCE_COLOR = '1'
  local gradle_opts = env.GRADLE_OPTS or ''
  if gradle_opts == '' then
    gradle_opts = '-Dorg.gradle.console=rich'
  elseif not gradle_opts:find('-Dorg%.gradle%.console=rich', 1, false) then
    gradle_opts = gradle_opts .. ' -Dorg.gradle.console=rich'
  end
  env.GRADLE_OPTS = gradle_opts
  local env_list = {}
  for key, value in pairs(env) do
    env_list[#env_list + 1] = key .. '=' .. value
  end
  return env_list
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

  -- Build the Gradle command arguments (without executable)
  local gradle_args = { '--project-dir', project_directory, 'test', '--console=rich' }

  -- For DAP debugging, force re-run and rebuild of tests
  -- Otherwise Gradle may skip test execution or use cached build artifacts
  if arguments.strategy == 'dap' then
    table.insert(gradle_args, '--rerun-tasks')     -- Force re-run tests even if up-to-date
    table.insert(gradle_args, '--no-build-cache')  -- Disable build cache to always recompile
    table.insert(gradle_args, '--no-daemon')       -- Don't use daemon for clean process lifecycle
  end

  vim.list_extend(gradle_args, test_filter_args)

  -- Handle DAP debugging strategy
  if arguments.strategy == 'dap' then
    -- Clean test results directory to ensure we only read fresh results
    local results_dir = context.test_results_directory
    if results_dir and results_dir ~= '' then
      local stat = vim.loop.fs_stat(results_dir)
      if stat then
        -- Remove all XML files from previous runs using fs_scandir
        local handle = vim.loop.fs_scandir(results_dir)
        if handle then
          while true do
            local name, type = vim.loop.fs_scandir_next(handle)
            if not name then break end
            if type == 'file' and name:match('%.xml$') then
              local filepath = results_dir .. '/' .. name
              os.remove(filepath)
            end
          end
        end
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
    for i, arg in ipairs(gradle_args) do
      if arg == 'test' then
        test_index = i
        break
      end
    end

    if test_index then
      table.insert(gradle_args, test_index, init_script_path)
      table.insert(gradle_args, test_index, '--init-script')
    end

    local uv = vim.loop
    local stdout_pipe = uv.new_pipe(false)
    local stderr_pipe = uv.new_pipe(false)

    local gradle_handle, pid_or_err = uv.spawn(gradle_executable, {
      args = gradle_args,
      cwd = project_directory,
      stdio = { nil, stdout_pipe, stderr_pipe },
      env = prepare_gradle_env(),
      detached = true,
    }, function(code, signal)
      stdout_pipe:read_stop()
      stderr_pipe:read_stop()
      stdout_pipe:close()
      stderr_pipe:close()
      stdout_pipe = nil
      stderr_pipe = nil
      context.stdout_pipe = nil
      context.stderr_pipe = nil
      if gradle_handle and not gradle_handle:is_closing() then
        gradle_handle:close()
      end
      if log_file then
        log_file:close()
        log_file = nil
      end
      context.gradle_exit_code = code
      context.gradle_exit_signal = signal
      context.wait_for_port_ready = nil
      if init_script_path then
        os.remove(init_script_path)
        init_script_path = nil
        context.init_script_path = nil
      end
      context.cleanup_resources = nil
    end)

    if not gradle_handle then
      os.remove(init_script_path)
      error('Failed to start Gradle process for DAP debugging: ' .. tostring(pid_or_err))
    end

    local dap = require('dap')
    local backlog = ''
    local flush_scheduled = false
    local BACKLOG_LIMIT = 512 * 1024
    local log_file_path = os.tmpname() .. '.gradle.log'
    local log_file = io.open(log_file_path, 'w')
    if not log_file then
      error('Failed to create Gradle log file')
    end
    context.gradle_log_path = log_file_path
    local LISTENING_TOKEN = 'Listening for transport dt_socket'
    local detection_window = ''
    local port_ready = false

    local function call_listeners(listeners, session, body)
      for key, listener in pairs(listeners) do
        local remove = listener(session, body)
        if remove then
          listeners[key] = nil
        end
      end
    end

    local function schedule_flush()
      if flush_scheduled then
        return
      end
      flush_scheduled = true
      vim.schedule(function()
        flush_scheduled = false
        if backlog == '' then
          return
        end
        local session = dap.session()
        if not session then
          if #backlog > BACKLOG_LIMIT then
            backlog = backlog:sub(-BACKLOG_LIMIT)
          end
          return
        end
        local body = { category = 'stdout', output = backlog }
        backlog = ''
        call_listeners(dap.listeners.before.event_output, session, body)
        session:event_output(body)
        call_listeners(dap.listeners.after.event_output, session, body)
      end)
    end

    local function flush_backlog()
      schedule_flush()
    end

    local function emit_output(text)
      if text and text ~= '' then
        backlog = backlog .. text
        if #backlog > BACKLOG_LIMIT then
          backlog = backlog:sub(-BACKLOG_LIMIT)
        end
      end
      schedule_flush()
    end

    local listener_id = 'neotest-gradle-backlog-' .. tostring(pid_or_err)
    dap.listeners.after.event_initialized[listener_id] = function()
      flush_backlog()
      dap.listeners.after.event_initialized[listener_id] = nil
    end

    local function handle_chunk(chunk)
      if not chunk or chunk == '' then
        return
      end
      if log_file then
        log_file:write(chunk)
        log_file:flush()
      end
      detection_window = (detection_window .. chunk)
      if #detection_window > 256 then
        detection_window = detection_window:sub(-256)
      end
      if not port_ready and detection_window:find(LISTENING_TOKEN, 1, true) then
        port_ready = true
      end
      emit_output(chunk)
    end

    stdout_pipe:read_start(function(err, data)
      if err then
        vim.schedule(function()
          vim.notify('[neotest-gradle] stdout: ' .. err, vim.log.levels.WARN)
        end)
        return
      end
      handle_chunk(data)
    end)

    stderr_pipe:read_start(function(err, data)
      if err then
        vim.schedule(function()
          vim.notify('[neotest-gradle] stderr: ' .. err, vim.log.levels.WARN)
        end)
        return
      end
      handle_chunk(data)
    end)

    local function cleanup_resources()
      if listener_id then
        dap.listeners.after.event_initialized[listener_id] = nil
        listener_id = nil
        context.listener_id = nil
      end
      if stdout_pipe then
        stdout_pipe:read_stop()
        stdout_pipe:close()
        stdout_pipe = nil
        context.stdout_pipe = nil
      end
      if stderr_pipe then
        stderr_pipe:read_stop()
        stderr_pipe:close()
        stderr_pipe = nil
        context.stderr_pipe = nil
      end
      if gradle_handle and not gradle_handle:is_closing() then
        gradle_handle:kill('sigterm')
        gradle_handle:close()
      end
      gradle_handle = nil
      context.gradle_handle = nil
      if init_script_path then
        os.remove(init_script_path)
        init_script_path = nil
        context.init_script_path = nil
      end
      if log_file then
        log_file:close()
        log_file = nil
      end
      context.wait_for_port_ready = nil
      context.cleanup_resources = nil
    end

    local function wait_for_port_ready(timeout_ms)
      timeout_ms = timeout_ms or 60000
      local wait_result = vim.wait(timeout_ms, function()
        return port_ready or context.gradle_exit_code ~= nil
      end, 50)

      if context.gradle_exit_code ~= nil and not port_ready then
        local msg = 'Gradle process exited before debug port was ready (code ' .. tostring(context.gradle_exit_code) .. '). Check the build output for details.'
        lib.notify('[neotest-gradle] ' .. msg, vim.log.levels.ERROR)
        cleanup_resources()
        error(msg, 0)
      end

      if wait_result == -1 or not port_ready then
        local msg = 'Timeout waiting for Gradle debug port (did not see "Listening for transport dt_socket" within '
          .. tostring(math.floor(timeout_ms / 1000)) .. ' seconds).'
        lib.notify('[neotest-gradle] ' .. msg, vim.log.levels.ERROR)
        cleanup_resources()
        error(msg, 0)
      end
    end

    context.cleanup_resources = cleanup_resources
    context.wait_for_port_ready = wait_for_port_ready
    context.gradle_handle = gradle_handle
    context.stdout_pipe = stdout_pipe
    context.stderr_pipe = stderr_pipe
    context.init_script_path = init_script_path
    context.listener_id = listener_id

    return {
      context = context,
      strategy = {
        type = 'kotlin',
        request = 'attach',  -- Attach to already running Gradle process
        name = 'Attach to Gradle Test',
        projectRoot = project_directory,
        hostName = 'localhost',
        port = 5005,
        timeout = 30000,  -- 30 seconds for DAP connection attempts
        before = function()
          if context.wait_for_port_ready then
            local ok, err = pcall(context.wait_for_port_ready, 60000)
            context.wait_for_port_ready = nil
            if not ok then
              error(err)
            end
          end
        end,
      }
    }
  end

  -- Default integrated strategy
  local command = { gradle_executable }
  vim.list_extend(command, gradle_args)
  return {
    command = command,
    context = context,
  }
end
