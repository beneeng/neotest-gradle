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

--- Waits for a marker file to exist, indicating that test results are ready.
--- Polls for the file with exponential backoff up to a maximum timeout.
--- Uses nio.sleep() for non-blocking wait that yields to event loop.
--- Returns true if marker file found, false if timeout reached.
---
--- @param marker_file_path string|nil - Path to marker file
--- @param timeout_seconds number - Maximum time to wait (default: 30)
--- @return boolean - true if marker found, false if timeout
local function wait_for_marker_file(marker_file_path, timeout_seconds)
  -- If no marker file specified, return immediately (non-DAP mode)
  if not marker_file_path or marker_file_path == '' then
    return true
  end

  timeout_seconds = timeout_seconds or 30
  local start_time = os.time()
  local sleep_ms = 100  -- Start with 100ms
  local max_sleep_ms = 1000  -- Cap at 1 second

  local timestamp = os.date('%H:%M:%S')
  print(string.format('[%s] RESULTS() waiting for marker file: %s', timestamp, marker_file_path))

  while os.difftime(os.time(), start_time) < timeout_seconds do
    -- Check if marker file exists
    local stat = vim.loop.fs_stat(marker_file_path)
    if stat then
      timestamp = os.date('%H:%M:%S')
      print(string.format('[%s] RESULTS() marker file found after %.1fs',
        timestamp, os.difftime(os.time(), start_time)))
      -- Clean up marker file
      os.remove(marker_file_path)
      return true
    end

    -- Non-blocking sleep - yields to event loop
    nio.sleep(sleep_ms)
    sleep_ms = math.min(sleep_ms * 1.5, max_sleep_ms)
  end

  -- Timeout reached
  timestamp = os.date('%H:%M:%S')
  print(string.format('[%s] WARNING: RESULTS() timeout waiting for marker file after %ds',
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
return function(build_specfication, _, tree)
  -- LOGGING: Track when results() is called
  local timestamp = os.date('%H:%M:%S')
  print(string.format('[%s] RESULTS() CALLED - Reading from: %s',
    timestamp, build_specfication.context.test_results_directory))

  -- Wait for marker file if DAP strategy was used
  local marker_file = build_specfication.context.marker_file
  local marker_found = wait_for_marker_file(marker_file, 30)

  if not marker_found then
    -- Timeout waiting for marker file - return failure results
    print(string.format('[%s] ERROR: Test results not ready - marker file timeout', timestamp))
    local results = {}
    for _, position in tree:iter() do
      if position and position.type == 'test' then
        results[position.id] = {
          status = STATUS_FAILED,
          errors = {
            {
              message = 'Test results not available: Gradle may have crashed or timed out writing results. Check Gradle output for errors.',
            }
          }
        }
      end
    end
    return results
  end

  local results = {}
  local position = tree:data()
  local results_directory = build_specfication.context.test_results_directory

  local juris_reports = parse_xml_files_from_directory(results_directory)

  -- LOGGING: Report what we found
  print(string.format('[%s] Found %d XML file(s)', timestamp, #juris_reports))

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
