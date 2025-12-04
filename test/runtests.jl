using ReTest

# Include the tests module (registers all testsets)
include("MCPReplTests.jl")
using .MCPReplTests

# Run all tests with ReTest
retest()
