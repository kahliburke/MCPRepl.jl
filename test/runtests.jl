using ReTest

# Include the tests module (registers all testsets)
include("MCPReplTests.jl")
using .MCPReplTests

# Run all tests with ReTest
if isempty(ARGS)
    retest()
else
    retest(ARGS[1])
end