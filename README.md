# Neotest Gradle

![Tests](https://github.com/kobbikobb/neotest-gradle/workflows/Tests/badge.svg)

[Neotest](https://github.com/nvim-neotest/neotest) adapter for _Kotlin_ and
_Java_ projects using [Gradle](https://gradle.org/) test with reports in JUnit
XML format.

> [!WARNING]
> This is primarily an export from my personal NeoVim configuration. Please don't
> expect any support! It might not work for any Gradle/project setup. Please feel
> free to open PRs when you managed to make the adapter more versatile.


# Setup

Install with your favorite plugin management toolchain and register it as
adatper to Neotest.

<details>
<summary>Adapter Registration</summary>

```lua
require('neotest').setup({
    adapters = {
        require('neotest-gradle'),
        -- more adapters ...
    },
    -- more configuration ...
})
```
</details>

<details>
<summary>DAP Debug Configuration</summary>

To enable debugging support:

1. Install a JVM debug adapter like [kotlin-debug-adapter](https://github.com/fwcd/kotlin-debug-adapter)

2. Configure nvim-dap:

```lua
local dap = require('dap')

dap.adapters.kotlin = {
  type = 'executable',
  command = 'kotlin-debug-adapter',  -- Ensure this is in your PATH
}

-- Optional: You can also configure dap.configurations.kotlin
-- but neotest-gradle provides its own configuration
```

3. Run tests in debug mode:

```lua
-- Debug the nearest test
:lua require('neotest').run.run({strategy = 'dap'})

-- Or map it to a key
vim.keymap.set('n', '<leader>td', function()
  require('neotest').run.run({strategy = 'dap'})
end, { desc = 'Debug nearest test' })
```

**How it works:**
- The adapter automatically starts Gradle with `--debug-jvm` flag
- Gradle waits for debugger on port 5005
- neotest launches your DAP adapter with the correct configuration
- Tests run with full debugging support (breakpoints, stepping, etc.)

**Note:** The DAP configuration includes `projectRoot` which is required
by kotlin-debug-adapter to properly resolve source files.

</details>

# Supported Features

**Noteworthy:**
- diagnostics for failed tests
- test description annotations
- nested test classes

**Debugging Support:**
- ✅ DAP (Debug Adapter Protocol) strategy support
- Compatible with [kotlin-debug-adapter](https://github.com/fwcd/kotlin-debug-adapter) and other JVM debug adapters
- Use `:lua require('neotest').run.run({strategy = 'dap'})` to debug tests

# Contribution

I tried to produce somewhat "clean code" including documentation to help anyone
getting into the adapter internals himself. Here are some notes of the higher
level ideas to understand the adapter by how I tried to match the Neotest
concepts with the Gradle test ones.
Please be aware that I'm no expert for Gradle in general and the adapter might
not work for all cases in every project. Please feel free to contribute such
improvements. It mainly works for the projects I'm working on right now. Though
I might no more work on them by now.

- (nested) test classes are interpreted as Neotest namespace positions
- test methods are interpreted as Neotest test positions
- running test files just runs all namespaces within this file
- Neotest position identifiers are set to the fully qualified Java pattern with
  package path, classes and method name as provided to `gradle test --tests
  <pattern>`
- no globs are used for test filtering, rather multiple filters are set
- the report directory is determined by asking for the `testResultsDir` property
  of the project
- test reports are expected to be XML files in JUnit format
- there is some "prettifying" of test cases for UI purposes
