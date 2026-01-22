"""
MCP Prompts support for MCPRepl.

Prompts are reusable prompt templates that can be exposed through the MCP protocol.
They help agents get started quickly with best practices for using the Julia REPL tools.
"""

module Prompts

export get_prompts, get_prompt

# Define available prompts
const PROMPT_DEFINITIONS = [
    Dict(
        "name" => "getting-started",
        "description" => "Learn how to use MCPRepl's powerful Julia code discovery tools effectively. Start here for new sessions!",
        "arguments" => [],  # No arguments needed
    ),
    Dict(
        "name" => "semantic-search-guide",
        "description" => "Comprehensive guide to using semantic code search with qdrant_search_code instead of grep",
        "arguments" => [],
    ),
    Dict(
        "name" => "type-exploration",
        "description" => "How to deeply inspect Julia types, hierarchies, and structures using type_info",
        "arguments" => [],
    ),
]

"""
Get list of all available prompts.
Returns array of prompt definitions with name, description, and arguments.
"""
function get_prompts()
    return PROMPT_DEFINITIONS
end

"""
Get a specific prompt by name.
Returns the prompt content as a string.
"""
function get_prompt(name::String)
    if name == "getting-started"
        return """
# Getting Started with MCPRepl

Welcome! MCPRepl provides powerful Julia-specific code discovery tools that are **far superior to grep or shell commands** for Julia codebases.

## 🌟 TOP PRIORITY TOOLS - Use These First!

### 🔍 Semantic Code Search
**Tool:** `qdrant_search_code(query="natural language description")`

**Why it's better than grep:**
- Finds code by **meaning**, not just keyword matching
- Discovers relevant implementations even when they use different terminology
- Searches across function bodies, comments, and structure

**Examples:**
```julia
# Find HTTP routing code even if it doesn't contain "route"
qdrant_search_code(query="function that handles HTTP requests and dispatches to handlers")

# Find validation logic
qdrant_search_code(query="code that validates user input or checks constraints")
```

**Setup:** Requires Ollama running with model `nomic-embed-text`. If you get errors about embeddings, check that Ollama is running.

---

### 🔬 Deep Type Introspection
**Tool:** `type_info("TypeName")`

**Why it's better than grep:**
- Shows complete type hierarchy (supertypes and subtypes)
- Lists ALL fields with their types (not just those visible in one file)
- Displays type parameters and their constraints
- Shows methods defined for that type

**Examples:**
```julia
# Understand a type's structure and hierarchy
type_info("HTTPRequest")

# Explore parametric types
type_info("Vector{Int}")

# See abstract type hierarchies
type_info("AbstractArray")
```

---

### 🎯 Method Discovery
**Tool:** `search_methods("function_name")`

**Why it's better than grep:**
- Finds **all method signatures** across all modules
- Shows argument types and return types
- Reveals methods you wouldn't find with text search (operator overloads, etc.)

**Examples:**
```julia
# Find all implementations of a function
search_methods("parse")

# Discover all overloads
search_methods("convert")

# See specialized methods
search_methods("sort")
```

---

### 📚 Symbol Discovery
**Tool:** `list_names("ModuleName")`

**Why it's better than grep:**
- Lists **exported** names (the public API)
- Can show non-exported names with `all=true`
- Discovers symbols that may not appear in source files (generated, imported, etc.)

**Examples:**
```julia
# See what's available in a module
list_names("Base")

# Explore a package's public API
list_names("HTTP")

# Include non-exported symbols
list_names("MyModule", all=true)
```

---

### 🧭 LSP Navigation
**Tools:** `lsp_goto_definition()`, `lsp_find_references()`, `lsp_workspace_symbols(query="...")`

**Why they're better than grep:**
- **Semantic awareness**: Understands Julia scoping, imports, and namespaces
- `lsp_goto_definition`: Jumps to where a symbol is defined (not just where it's mentioned)
- `lsp_find_references`: Finds **actual usage**, not just string matches
- `lsp_workspace_symbols`: Smart symbol search across entire codebase

**Examples:**
```julia
# Find all places a function is called (not just mentioned in comments)
lsp_find_references(file_path="src/handler.jl", line=42, column=10)

# Jump to definition
lsp_goto_definition(file_path="src/main.jl", line=100, column=5)

# Search for symbols by name
lsp_workspace_symbols(query="HTTPServer")
```

---

## Quick Execution Guide

**Primary Tool:** `ex(e="julia code")`
- Use `ex` for **everything**: running code, loading packages, checking values
- Default quiet mode (`q=true`) saves tokens by suppressing return values
- Only use `q=false` when you need the return value to make a decision

**Examples:**
```julia
# Run code (default quiet mode)
ex(e="using DataFrames")

# Get a result you need
ex(e="println(VERSION)", q=false)

# Execute multi-line code
ex(e="x = [1,2,3]
sum(x)")
```

---

## Environment & Packages

- `investigate_environment()` - Check current packages, project, Revise status
- `pkg_add(packages=["Name"])` - Add packages to current environment
- `ping()` - Verify server is responsive

---

## When to Use What

**For code search:**
- ✅ `qdrant_search_code` - Find code by what it does
- ✅ `lsp_workspace_symbols` - Find symbols by name
- ❌ `grep` or shell commands - Less effective for Julia

**For understanding types:**
- ✅ `type_info` - Complete type structure and hierarchy
- ❌ Reading files manually - Misses generated content, shows partial view

**For finding function implementations:**
- ✅ `search_methods` - All method signatures
- ✅ `lsp_find_references` - Actual usage sites
- ❌ `grep` - Text matches only, misses semantic relationships

**For running code:**
- ✅ `ex(e="code")` - Primary execution tool
- ❌ `run_in_terminal` with julia commands - Unnecessary complexity

---

## Common Mistakes to Avoid

1. **Don't use grep for Julia code search** - Use `qdrant_search_code` or LSP tools
2. **Don't use println to communicate with user** - User sees REPL output directly; use TEXT responses
3. **Don't default to `q=false`** - Use quiet mode (default `q=true`) unless you need the return value
4. **Don't forget about semantic search** - It's your most powerful discovery tool!

---

## Next Steps

1. Try `investigate_environment()` to see what packages are available
2. Use `qdrant_search_code` to find relevant code for your task
3. Run code with `ex(e="your code here")`
4. Use `tool_help("tool_name")` for detailed help on any tool

Happy coding! 🚀
"""
    elseif name == "semantic-search-guide"
        return """
# Semantic Code Search Guide

Comprehensive guide to using `qdrant_search_code` for finding Julia code by meaning, not keywords.

## Why Semantic Search?

Traditional grep searches for exact text matches. Semantic search understands **meaning**:

- Finds code that implements a concept even if it uses different words
- Discovers relevant implementations across the codebase
- Understands context and relationships between code elements

## How It Works

`qdrant_search_code` uses embeddings (vector representations) of code chunks to find semantically similar code.

**Requirements:**
- Ollama running locally with model `nomic-embed-text`
- Code indexed in Qdrant (happens automatically in background)

## Best Practices

### 1. Describe What You're Looking For

**Good queries:**
```julia
qdrant_search_code(query="function that validates HTTP request headers")
qdrant_search_code(query="code that parses JSON and handles errors")
qdrant_search_code(query="implementation of authentication middleware")
```

**Poor queries:**
```julia
qdrant_search_code(query="validate")  # Too vague
qdrant_search_code(query="function")  # Too generic
```

### 2. Be Specific About Behavior

**Instead of:**
```julia
qdrant_search_code(query="server")
```

**Try:**
```julia
qdrant_search_code(query="code that starts an HTTP server and listens for connections")
```

### 3. Increase Limit for Broader Searches

Default limit is 5 results. Increase for more coverage:

```julia
qdrant_search_code(query="authentication logic", limit=10)
```

### 4. Specify Collection (Optional)

If you have multiple indexed projects:

```julia
qdrant_search_code(query="routing code", collection="MyProject")
```

## Common Use Cases

### Finding Feature Implementations
```julia
qdrant_search_code(query="code that implements user authentication and session management")
```

### Discovering Error Handling
```julia
qdrant_search_code(query="functions that catch exceptions and log errors")
```

### Locating Data Processing
```julia
qdrant_search_code(query="code that transforms or processes data structures")
```

### Understanding Configuration
```julia
qdrant_search_code(query="code that reads configuration from files or environment variables")
```

## Troubleshooting

**Error: "Failed to generate embedding"**
- Ensure Ollama is running: `ollama serve`
- Check model is available: `ollama pull nomic-embed-text`

**No results found:**
- Code may not be indexed yet (indexing happens in background)
- Try broader query terms
- Check collection name if using multiple projects

**Too many irrelevant results:**
- Make query more specific
- Reduce limit parameter
- Add more context about what you're looking for

## Comparison: Grep vs Semantic Search

**Task:** Find HTTP routing code

**With grep:**
```bash
grep -r "route" .
# Returns: routes/, router.jl, "absolute", "route_table", comments mentioning "route"
```

**With semantic search:**
```julia
qdrant_search_code(query="code that maps HTTP paths to handler functions")
# Returns: Actual routing implementation, dispatcher logic, path matching code
```

The semantic search finds the **functionality**, not just the keyword.

## Pro Tips

1. **Start broad, then narrow** - Begin with general queries, refine based on results
2. **Combine with LSP** - Use semantic search to find relevant files, then LSP for precise navigation
3. **Index check** - Use `qdrant_collection_info(collection="ProjectName")` to verify code is indexed
4. **Multiple angles** - Try rephrasing queries if first attempt doesn't find what you need

## Next Steps

- Try `qdrant_browse_collection(collection="ProjectName")` to see what's indexed
- Use `qdrant_sync_index()` to update index after code changes
- Combine with `type_info` and `search_methods` for comprehensive code understanding
"""
    elseif name == "type-exploration"
        return """
# Julia Type Exploration Guide

Master Julia's type system using `type_info` for deep introspection.

## Why type_info?

Julia's type system is rich and complex. `type_info` reveals:

- **Complete type hierarchy** - Supertypes and subtypes
- **All fields** - Including inherited and generated fields
- **Type parameters** - Constraints and variance
- **Methods** - Functions defined for the type
- **Memory layout** - Field types and structure

This is information you **cannot get from grep** or reading source files alone.

## Basic Usage

```julia
type_info("String")
type_info("Vector{Int}")
type_info("AbstractArray")
```

## What You'll See

### 1. Type Hierarchy
```
Supertypes: String <: AbstractString <: Any
```

Shows the inheritance chain from the type to `Any`.

### 2. Field Information
```
Fields:
  len::Int64
  data::Ptr{UInt8}
```

Lists all fields with their types (even private/internal fields).

### 3. Type Parameters
```
Type parameters: T
Constraints: T <: Number
```

For parametric types, shows parameter names and constraints.

### 4. Subtypes
```
Subtypes:
  - ConcreteType1
  - ConcreteType2
```

All types that inherit from this type (for abstract types).

## Common Use Cases

### Understanding Data Structures
```julia
# What fields does this have?
type_info("DataFrame")

# How is this structured?
type_info("HTTP.Request")
```

### Exploring Type Hierarchies
```julia
# What are the number types?
type_info("Number")

# What array types exist?
type_info("AbstractArray")
```

### Working with Parametric Types
```julia
# How does Dict work?
type_info("Dict")

# What about specific instantiations?
type_info("Dict{String,Int}")
```

### Debugging Type Issues
```julia
# Why doesn't this method match?
type_info("MyCustomType")

# What's the relationship between these types?
type_info("Vector")
type_info("AbstractVector")
```

## Advanced Patterns

### Comparing Related Types
```julia
# Compare abstract vs concrete
type_info("AbstractString")
type_info("String")

# Understand specialized types
type_info("Array")
type_info("Vector")  # Vector is Array{T,1}
type_info("Matrix")  # Matrix is Array{T,2}
```

### Finding Implementable Interfaces
```julia
# What do I need to implement?
type_info("AbstractArray")
# Shows what methods AbstractArray types should define
```

### Understanding Container Types
```julia
# What's in a Task?
type_info("Task")

# How does Channel work?
type_info("Channel")
```

## Pro Tips

1. **Start with abstract types** - Understand the interface before concrete implementations
2. **Check supertypes** - Reveals which methods will work with a type
3. **Inspect parametric forms** - Both `Vector` and `Vector{Int}` provide insights
4. **Compare similar types** - Side-by-side comparison reveals differences

## Common Patterns

### Pattern 1: Understand Library Types
```julia
# Working with HTTP.jl
type_info("HTTP.Request")
type_info("HTTP.Response")
type_info("HTTP.Server")
```

### Pattern 2: Debug Method Dispatch
```julia
# Why isn't my method being called?
type_info("MyType")
search_methods("myfunction")  # Combine with method search
```

### Pattern 3: Design Type Hierarchies
```julia
# What should my abstract type inherit from?
type_info("AbstractVector")
type_info("AbstractDict")
```

### Pattern 4: Optimize Performance
```julia
# What's the memory layout?
type_info("MyStruct")
# Use field information to optimize struct layout
```

## Troubleshooting

**"Type not found":**
- Ensure type is loaded: `ex(e="using PackageName")`
- Check spelling and capitalization
- Use fully qualified names: `type_info("HTTP.Request")`

**Too much output:**
- Focus on specific sections (hierarchy, fields, etc.)
- Combine with other tools for targeted exploration

**Need method information:**
- Use `search_methods("TypeName")` to see all methods for a type
- Use `list_names("Module")` to see what's exported

## Complementary Tools

Combine `type_info` with:
- `search_methods("func")` - Find all methods
- `list_names("Module")` - Discover available types
- `lsp_goto_definition()` - Jump to source
- `qdrant_search_code()` - Find usage examples

## Next Steps

1. Try `type_info("Any")` to see the root of the type hierarchy
2. Explore types in packages you use frequently
3. Use with `search_methods` to understand complete APIs
4. Combine with semantic search to find usage patterns
"""
    else
        return nothing
    end
end

end # module Prompts
