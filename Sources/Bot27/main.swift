// The same binary is also the computer-use MCP server Bot27 hands to the claude CLI.
if CommandLine.arguments.contains("--computer-mcp") {
    ComputerMCP.run()
} else {
    Bot27App.main()
}
