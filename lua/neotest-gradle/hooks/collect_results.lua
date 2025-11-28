local lib = require('neotest.lib')
local xml = require('neotest.lib.xml')
local get_package_name = require('neotest-gradle.hooks.shared_utilities').get_package_name
local nio = require('nio')

local XML_FILE_SUFFIX = '.xml'
local STATUS_PASSED = 'passed' --- see neotest.Result.status
local STATUS_FAILED = 'failed' --- see neotest.Result.status

--- Searches for all files XML files in this directory (not recursive) and
--- parses their content as Lua tables using some Neotest utility.
--- Returns an empty table if the directory doesn't exist.
---
--- @param directory_path string
--- @return table[] - list of parsed XML tables
local function parse_xml_files_from_directory(directory_path)
  -- Check if directory exists
  if not directory_path or directory_path == '' or not vim.loop.fs_stat(directory_path) then
    return {}
  end

  local xml_files = lib.files.find(directory_path, {
    filter_dir = function(file_name)
      return file_name:sub(-#XML_FILE_SUFFIX) == XML_FILE_SUFFIX
    end,
  })

  return vim.tbl_map(function(file_path)
    local content = lib.files.read(file_path)
    return xml.parse(content)
  end, xml_files)
end

--- Waits for test result XML files to exist and be ready.
--- Polls the test results directory with exponential backoff up to a maximum timeout.
--- Uses nio.sleep() for non-blocking wait that yields to event loop.
--- Returns true if XML files found, false if timeout reached.
---
--- @param results_directory string - Path to test results directory
--- @param timeout_seconds number - Maximum time to wait (default: 30)
--- @return boolean - true if results found, false if timeout
local function wait_for_test_results(results_directory, timeout_seconds)
  -- If no directory specified, return immediately
  if not results_directory or results_directory == '' then
    return true
  end

  timeout_seconds = timeout_seconds or 30
  local start_time = os.time()
  local sleep_ms = 100  -- Start with 100ms
  local max_sleep_ms = 500  -- Cap at 500ms (faster polling for XML files)

  local xml_files_found = false

  while os.difftime(os.time(), start_time) < timeout_seconds do
    -- Check if directory exists
    local dir_stat = vim.loop.fs_stat(results_directory)
    if dir_stat then
      -- Check for XML files using fs_scandir
      local xml_count = 0
      local handle = vim.loop.fs_scandir(results_directory)
      if handle then
        while true do
          local name, type = vim.loop.fs_scandir_next(handle)
          if not name then break end
          if type == 'file' and name:match('%.xml$') then
            xml_count = xml_count + 1
          end
        end
      end

      if xml_count > 0 then
        -- Found XML files - wait a bit more to ensure they're fully written
        if not xml_files_found then
          xml_files_found = true
          nio.sleep(500)  -- Wait 500ms for files to be fully written
        end

        return true
      end
    end

    -- Non-blocking sleep - yields to event loop
    nio.sleep(sleep_ms)
    sleep_ms = math.min(sleep_ms * 1.5, max_sleep_ms)
  end

  -- Timeout reached
  timestamp = os.date('%H:%M:%S')
  print(string.format('[%s] WARNING: RESULTS() timeout waiting for XML files after %ds',
    timestamp, timeout_seconds))
  return false
end

--- If the value is a list itself it gets returned as is. Else a new list will be
--- created with the value as first element.
--- E.g.: { 'a', 'b' } => { 'a', 'b' } | 'a' => { 'a' }
---
--- @param value any
--- @return table
local function asList(value)
  return (type(value) == 'table' and #value > 0) and value or { value }
end

--- This tries to find the position in the tree that belongs to this test case
--- result from the JUnit report XML. Therefore it parses the location from the
--- node attributes and compares it with the position information in the tree.
---
--- @param tree table - see neotest.Tree
--- @param test_case_node table - XML node of test case result
--- @return table | nil - see neotest.Position
local function find_position_for_test_case(tree, test_case_node)
  local test_name = test_case_node._attr.name:gsub('%(.*%)$', '') -- Strip parameters
  local class_name = test_case_node._attr.classname

  -- Build multiple candidate IDs to handle different JUnit formats
  -- IMPORTANT: Most specific patterns first!
  local candidate_ids = {
    class_name .. '.' .. test_name,                    -- JUnit4: com.example.Test.method
    class_name:gsub('%$', '.') .. '.' .. test_name,    -- Jupiter: com.example.Test$Inner -> com.example.Test.Inner.method (nested classes)
  }

  -- First try to match test positions (type = 'test')
  for _, position in tree:iter() do
    if position and position.type == 'test' then
      for _, candidate_id in ipairs(candidate_ids) do
        if position.id == candidate_id then
          return position
        end
      end
    end
  end

  return nil
end

--- Convert a JUnit failure report into a Neotest error. It parses the failure
--- message and removes the Exception path from it. Furthermore it tries to parse
--- the stack trace to find a line number within the executed test case.
---
--- @param failure_node table - XML node of failure report in of a test case
--- @param position table - matched Neotest position of this test case (see neotest.Position)
--- @return table - see neotest.Error
local function parse_error_from_failure_xml(failure_node, position)
  local type = failure_node._attr.type
  local message = (failure_node._attr.message:gsub(type .. '.*\n', ''))

  local stack_trace = failure_node[1] or ''
  local package_name = get_package_name(position.path)
  local line_number

  for _, line in ipairs(vim.split(stack_trace, '[\r]?\n')) do
    local pattern = '^.*at.+' .. package_name .. '.*%(.+..+:(%d+)%)$'
    local match = line:match(pattern)

    if match then
      line_number = tonumber(match) - 1
      break
    end
  end

  return { message = message, line = line_number }
end

--- See Neotest adapter specification.
---
--- This builds a list of test run results. Therefore it parses all JUnit report
--- files and traverses trough the reports inside. The reports are matched back
--- to Neotest positions.
--- It also tries to determine why and where a test possibly failed for
--- additional Neotest features like diagnostics.
---
--- @param build_specfication table - see neotest.RunSpec
--- @param tree table - see neotest.Tree
--- @return table<string, table> - see neotest.Result
return function(build_specfication, process_result, tree)
  local context = (build_specfication and build_specfication.context) or {}

  local function assign_output_path()
    if process_result and context and context.gradle_log_path then
      process_result.output = context.gradle_log_path
    end
  end
  -- Wait for test result XML files to be ready
  local results_directory = build_specfication.context.test_results_directory
  local results_found = wait_for_test_results(results_directory, 30)

  if not results_found then
    if build_specfication.context.cleanup_resources then
      build_specfication.context.cleanup_resources()
      build_specfication.context.cleanup_resources = nil
    end
    assign_output_path()
    -- Timeout waiting for results - return failure
    local timestamp = os.date('%H:%M:%S')
    print(string.format('[%s] ERROR: Test results not ready - XML files timeout', timestamp))
    local results = {}
    for _, position in tree:iter() do
      if position and position.type == 'test' then
        results[position.id] = {
          status = STATUS_FAILED,
          errors = {
            {
              message = 'Test results not available: Gradle may have crashed or failed to write XML results. Check Gradle output for errors.',
            }
          }
        }
      end
    end
    return results
  end

  assign_output_path()

  local results = {}
  local position = tree:data()

  local juris_reports = parse_xml_files_from_directory(results_directory)

  -- Collect results for individual test positions
  for _, juris_report in pairs(juris_reports) do
    for _, test_suite_node in pairs(asList(juris_report.testsuite)) do
      for _, test_case_node in pairs(asList(test_suite_node.testcase)) do
        local matched_position = find_position_for_test_case(tree, test_case_node)
        if matched_position ~= nil then
          local failure_node = test_case_node.failure
          local status = failure_node == nil and STATUS_PASSED or STATUS_FAILED
          local short_message = (failure_node or {}).message
          local error = failure_node and parse_error_from_failure_xml(failure_node, matched_position)
          local result = { status = status, short = short_message, errors = { error } }
          results[matched_position.id] = result
        end
      end
    end
  end

  -- Aggregate results for namespace and file positions
  -- Iterate through all positions and aggregate from children to parents
  for _, position in tree:iter() do
    if position and (position.type == 'namespace' or position.type == 'file') then
      -- Check if we already have a result for this position
      if not results[position.id] then
        -- Count child results
        local has_any_result = false
        local has_failure = false

        -- Check all positions in the tree to find children
        for _, potential_child in tree:iter() do
          if potential_child and results[potential_child.id] then
            -- Check if this is a child by seeing if the ID starts with parent ID
            if potential_child.id:sub(1, #position.id) == position.id and potential_child.id ~= position.id then
              has_any_result = true
              if results[potential_child.id].status == STATUS_FAILED then
                has_failure = true
              end
            end
          end
        end

        -- Only set result if we have child results
        if has_any_result then
          results[position.id] = {
            status = has_failure and STATUS_FAILED or STATUS_PASSED
          }
        end
      end
    end
  end

  -- Mark tests without results as failed (e.g., when DAP fails or no XML generated)
  -- This ensures tests don't silently pass when something goes wrong
  for _, position in tree:iter() do
    if position and position.type == 'test' and not results[position.id] then
      results[position.id] = {
        status = STATUS_FAILED,
        errors = {
          {
            message = 'No test result found. Test may not have executed or DAP debugging failed.',
          }
        }
      }
    end
  end

  return results
end
