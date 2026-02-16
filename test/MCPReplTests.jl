module MCPReplTests

using ReTest

# Include all test files
include("security_tests.jl")
include("setup_tests.jl")
include("server_tests.jl")
include("session_tests.jl")
include("call_tool_tests.jl")
include("lsp_tests.jl")
include("generate_tests.jl")
include("ast_stripping_tests.jl")
include("ex_quiet_error_tests.jl")
include("standalone_mode_tests.jl")
include("version_tests.jl")
include("proxy_state_tests.jl")
include("proxy_registration_tests.jl")
include("proxy_registration_validation_tests.jl")
include("database_dual_session_tests.jl")
include("session_name_preservation_test.jl")
include("session_id_name_integrity_test.jl")
include("logs_endpoint_test.jl")
include("tool_duration_test.jl")
include("proxy_mcp_session_test.jl")
include("qdrant_indexer_tests.jl")
include("session_status_tests.jl")
include("request_buffering_tests.jl")
include("request_buffering_integration_tests.jl")
include("resources_prompts_tests.jl")
include("tui_analytics_tests.jl")

end # module
