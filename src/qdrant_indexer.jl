"""
Code Indexer for Qdrant Vector Search

Indexes Julia source files into Qdrant for semantic code search.
Uses Ollama for embeddings (nomic-embed-text model).
"""

# Uses QdrantClient and get_ollama_embedding from parent module

const CHUNK_SIZE = 1500  # Target chunk size in characters
const CHUNK_OVERLAP = 200  # Overlap between chunks

"""
    get_project_collection_name(project_path::String=pwd()) -> String

Generate a collection name based on the project directory.
Uses the directory name, sanitized for Qdrant collection naming rules.
"""
function get_project_collection_name(project_path::String = pwd())
    name = basename(abspath(project_path))
    # Sanitize: lowercase, replace non-alphanumeric with underscore
    name = lowercase(name)
    name = replace(name, r"[^a-z0-9]" => "_")
    name = replace(name, r"_+" => "_")  # Collapse multiple underscores
    name = strip(name, '_')
    return isempty(name) ? "default" : name
end

"""
    chunk_code(content::String, file_path::String) -> Vector{Dict}

Split code into semantic chunks (functions, blocks) with metadata.
Returns vector of dicts with :text, :file, :start_line, :end_line, :type
"""
function chunk_code(content::String, file_path::String)
    chunks = Dict[]

    # Extract definitions using Julia's parser (functions, structs, macros)
    definition_chunks = extract_definitions(content, file_path)
    if !isempty(definition_chunks)
        append!(chunks, definition_chunks)
    end

    # Also create overlapping window chunks for full coverage
    window_chunks = create_window_chunks(content, file_path)
    append!(chunks, window_chunks)

    return chunks
end

"""
    extract_definitions(content::String, file_path::String) -> Vector{Dict}

Extract function, struct, and macro definitions using Julia's parser.
"""
function extract_definitions(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    # Parse the file
    expr = try
        Meta.parseall(content)
    catch e
        @debug "Failed to parse file" file_path exception = e
        return chunks
    end

    # Walk the AST to find definitions
    extract_from_expr!(chunks, expr, lines, file_path)
    return chunks
end

"""
    extract_from_expr!(chunks, expr, lines, file_path)

Recursively extract definitions from an expression.
"""
function extract_from_expr!(
    chunks::Vector{Dict},
    expr,
    lines::Vector{<:AbstractString},
    file_path::String,
)
    if expr isa Expr
        # Check for definition types
        if expr.head == :function || expr.head == :macro
            extract_definition!(chunks, expr, lines, file_path, "function")
        elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
            extract_definition!(chunks, expr, lines, file_path, "struct")
        elseif expr.head == :(=) && length(expr.args) >= 1
            # Short function definition: f(x) = ...
            first_arg = expr.args[1]
            if first_arg isa Expr && first_arg.head == :call
                extract_definition!(chunks, expr, lines, file_path, "function")
            elseif first_arg isa Expr && first_arg.head == :const
                extract_definition!(chunks, expr, lines, file_path, "const")
            end
        elseif expr.head == :const
            extract_definition!(chunks, expr, lines, file_path, "const")
        elseif expr.head == :module
            # Recurse into module
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :toplevel || expr.head == :block
            # Recurse into blocks
            for arg in expr.args
                extract_from_expr!(chunks, arg, lines, file_path)
            end
        elseif expr.head == :macrocall && length(expr.args) >= 1
            macro_name = string(expr.args[1])
            if occursin("mcp_tool", macro_name)
                extract_definition!(chunks, expr, lines, file_path, "tool")
            elseif occursin("@doc", macro_name)
                # Handle docstring: @doc "docstring" definition
                # The function/struct is typically the last argument
                for arg in expr.args
                    if arg isa Expr && arg.head in (:function, :macro, :struct, :(=))
                        extract_from_expr!(chunks, arg, lines, file_path)
                    end
                end
            end
        end
    end
end

"""
    extract_definition!(chunks, expr, lines, file_path, def_type)

Extract a single definition with its source location.
"""
function extract_definition!(
    chunks::Vector{Dict},
    expr::Expr,
    lines::Vector{<:AbstractString},
    file_path::String,
    def_type::String,
)
    # Get the name of the definition
    name = get_definition_name(expr)
    if name === nothing
        return
    end

    # Get source location if available
    start_line, end_line = get_expr_lines(expr, lines)
    if start_line === nothing
        return
    end

    # Extract the text
    text = join(lines[start_line:end_line], "\n")

    # Check for preceding docstring
    if start_line > 1
        prev_line = start_line - 1
        while prev_line >= 1 && isempty(strip(lines[prev_line]))
            prev_line -= 1
        end
        if prev_line >= 1 && endswith(strip(lines[prev_line]), "\"\"\"")
            # Find start of docstring
            doc_end = prev_line
            doc_start = prev_line
            while doc_start > 1
                doc_start -= 1
                if startswith(strip(lines[doc_start]), "\"\"\"")
                    break
                end
            end
            if doc_start < doc_end
                docstring = join(lines[doc_start:doc_end], "\n")
                text = docstring * "\n" * text
                start_line = doc_start
            end
        end
    end

    push!(
        chunks,
        Dict(
            "text" => text,
            "file" => file_path,
            "start_line" => start_line,
            "end_line" => end_line,
            "type" => def_type,
            "name" => name,
        ),
    )
end

"""
    get_definition_name(expr) -> Union{String, Nothing}

Extract the name from a definition expression.
"""
function get_definition_name(expr::Expr)
    if expr.head == :function || expr.head == :macro
        if length(expr.args) >= 1
            sig = expr.args[1]
            if sig isa Expr && sig.head == :call && length(sig.args) >= 1
                return string(sig.args[1])
            elseif sig isa Expr && sig.head == :where
                # f(x::T) where T = ...
                return get_definition_name(Expr(:function, sig.args[1]))
            elseif sig isa Symbol
                return string(sig)
            end
        end
    elseif expr.head == :struct || expr.head == :abstract || expr.head == :primitive
        if length(expr.args) >= 2
            name_expr = expr.args[2]
            if name_expr isa Symbol
                return string(name_expr)
            elseif name_expr isa Expr && name_expr.head == :<:
                return string(name_expr.args[1])
            elseif name_expr isa Expr && name_expr.head == :curly
                return string(name_expr.args[1])
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            return string(first_arg.args[1])
        end
    elseif expr.head == :const && length(expr.args) >= 1
        inner = expr.args[1]
        if inner isa Expr && inner.head == :(=)
            return string(inner.args[1])
        end
    elseif expr.head == :macrocall
        # Try to find tool name from @mcp_tool
        for arg in expr.args
            if arg isa QuoteNode
                return string(arg.value)
            end
        end
    end
    return nothing
end

"""
    get_expr_lines(expr, lines) -> Tuple{Union{Int,Nothing}, Union{Int,Nothing}}

Get the start and end line numbers for an expression.
Uses heuristics based on expression structure.
"""
function get_expr_lines(expr::Expr, lines::Vector{<:AbstractString})
    # For functions/macros, look for the signature
    if expr.head in (:function, :macro) && length(expr.args) >= 1
        name = get_definition_name(expr)
        if name !== nothing
            # Find line containing "function name" or "macro name"
            keyword = expr.head == :function ? "function" : "macro"
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$keyword\\s+$name"), line)
                    # Find matching end
                    depth = 1
                    for j = (i+1):length(lines)
                        l = strip(lines[j])
                        if startswith(l, "function ") ||
                           startswith(l, "macro ") ||
                           startswith(l, "if ") ||
                           startswith(l, "for ") ||
                           startswith(l, "while ") ||
                           startswith(l, "let ") ||
                           startswith(l, "begin") ||
                           startswith(l, "try") ||
                           startswith(l, "struct ") ||
                           startswith(l, "module ")
                            depth += 1
                        elseif l == "end" || startswith(l, "end ")
                            depth -= 1
                            if depth == 0
                                return (i, j)
                            end
                        end
                    end
                end
            end
        end
    elseif expr.head == :struct
        name = get_definition_name(expr)
        if name !== nothing
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*(mutable\\s+)?struct\\s+$name"), line)
                    for j = (i+1):length(lines)
                        if strip(lines[j]) == "end"
                            return (i, j)
                        end
                    end
                end
            end
        end
    elseif expr.head == :(=) && length(expr.args) >= 1
        # Short function definition - single line
        first_arg = expr.args[1]
        if first_arg isa Expr && first_arg.head == :call
            name = string(first_arg.args[1])
            for (i, line) in enumerate(lines)
                if occursin(Regex("^\\s*$name\\s*\\(.*\\)\\s*="), line)
                    return (i, i)
                end
            end
        end
    end

    return (nothing, nothing)
end

"""
    create_window_chunks(content::String, file_path::String) -> Vector{Dict}

Create overlapping window chunks for full file coverage.
"""
function create_window_chunks(content::String, file_path::String)
    chunks = Dict[]
    lines = split(content, '\n')

    if length(content) <= CHUNK_SIZE
        # Small file - single chunk
        push!(
            chunks,
            Dict(
                "text" => content,
                "file" => file_path,
                "start_line" => 1,
                "end_line" => length(lines),
                "type" => "window",
                "name" => basename(file_path),
            ),
        )
        return chunks
    end

    # Create overlapping windows
    chunk_lines = 50  # Approximate lines per chunk
    overlap_lines = 10

    start_line = 1
    while start_line <= length(lines)
        end_line = min(start_line + chunk_lines - 1, length(lines))
        text = join(lines[start_line:end_line], "\n")

        # Extend if we're in the middle of something
        while end_line < length(lines) && length(text) < CHUNK_SIZE
            end_line += 1
            text = join(lines[start_line:end_line], "\n")
        end

        push!(
            chunks,
            Dict(
                "text" => text,
                "file" => file_path,
                "start_line" => start_line,
                "end_line" => end_line,
                "type" => "window",
                "name" => "$(basename(file_path)):$(start_line)-$(end_line)",
            ),
        )

        # Move to next chunk with overlap, but ensure we make progress
        next_start = end_line - overlap_lines + 1
        if next_start <= start_line
            # Prevent infinite loop - move at least one line forward
            next_start = start_line + 1
        end
        start_line = next_start

        # Exit if we've covered the whole file
        if end_line >= length(lines)
            break
        end
    end

    return chunks
end

"""
    index_file(file_path::String, collection::String; verbose::Bool=true) -> Int

Index a single file into Qdrant. Returns number of chunks indexed.
"""
function index_file(file_path::String, collection::String; verbose::Bool = true)
    if !isfile(file_path)
        @warn "File not found" file_path
        return 0
    end

    content = read(file_path, String)
    if isempty(strip(content))
        return 0
    end

    chunks = chunk_code(content, file_path)
    if isempty(chunks)
        return 0
    end

    verbose &&
        println("  Processing $(length(chunks)) chunks from $(basename(file_path))...")

    points = Dict[]
    for (i, chunk) in enumerate(chunks)
        text = chunk["text"]
        if isempty(strip(text))
            continue
        end

        # Get embedding
        embedding = get_ollama_embedding(text)
        if isempty(embedding)
            @warn "Failed to get embedding" file = file_path chunk = i
            continue
        end

        # Create point with UUID
        point_id = string(Base.UUID(rand(UInt128)))
        push!(
            points,
            Dict(
                "id" => point_id,
                "vector" => embedding,
                "payload" => Dict(
                    "file" => chunk["file"],
                    "start_line" => chunk["start_line"],
                    "end_line" => chunk["end_line"],
                    "type" => chunk["type"],
                    "name" => chunk["name"],
                    "text" => first(text, 2000),  # Truncate for storage (Unicode-safe)
                ),
            ),
        )

        # Batch upsert every 10 points
        if length(points) >= 10
            QdrantClient.upsert_points(collection, points)
            points = Dict[]
        end
    end

    # Upsert remaining points
    if !isempty(points)
        QdrantClient.upsert_points(collection, points)
    end

    # Record in database for change tracking
    Database.record_indexed_file(file_path, collection, mtime(file_path), length(chunks))

    return length(chunks)
end

"""
    reindex_file(file_path::String, collection::String; verbose::Bool=true) -> Int

Re-index a single file: delete old chunks, then index fresh.
Returns number of chunks indexed.
"""
function reindex_file(file_path::String, collection::String; verbose::Bool = true)
    verbose && println("  Re-indexing: $(basename(file_path))")

    # Delete old chunks for this file
    QdrantClient.delete_by_file(collection, file_path)

    # Index fresh
    return index_file(file_path, collection; verbose = verbose)
end

"""
    index_directory(dir_path::String, collection::String; pattern::String="*.jl", verbose::Bool=true) -> Int

Index all matching files in a directory. Returns total chunks indexed.
"""
function index_directory(
    dir_path::String,
    collection::String;
    pattern::String = "*.jl",
    verbose::Bool = true,
)
    total_chunks = 0

    # Find all matching files
    files = String[]
    for (root, dirs, filenames) in walkdir(dir_path)
        # Skip hidden directories and node_modules
        filter!(d -> !startswith(d, ".") && d != "node_modules", dirs)

        for filename in filenames
            if endswith(filename, splitext(pattern)[2])
                push!(files, joinpath(root, filename))
            end
        end
    end

    verbose && println("Found $(length(files)) files to index")

    for file_path in files
        rel_path = relpath(file_path, dir_path)
        verbose && println("Indexing: $rel_path")
        chunks = index_file(file_path, collection; verbose = verbose)
        total_chunks += chunks
    end

    verbose && println("\nTotal: $total_chunks chunks indexed into '$collection'")
    return total_chunks
end

"""
    index_project(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, recreate::Bool=false) -> Int

Index a Julia project into Qdrant. Uses project directory name as collection if not specified.
"""
function index_project(
    project_path::String = pwd();
    collection::Union{String,Nothing} = nothing,
    recreate::Bool = false,
)
    # Use project name as collection if not specified
    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    # Find src directory
    src_dir = joinpath(project_path, "src")
    if !isdir(src_dir)
        src_dir = project_path
    end

    if recreate
        println("Recreating collection '$col_name'...")
        QdrantClient.delete_collection(col_name)
        QdrantClient.create_collection(col_name; vector_size = 768)
    end

    println("Indexing project into collection '$col_name'...")
    return index_directory(src_dir, col_name)
end

"""
    sync_index(project_path::String=pwd(); collection::Union{String,Nothing}=nothing, verbose::Bool=true) -> NamedTuple

Sync the Qdrant index with the current state of files on disk.
- Re-indexes files that have been modified since last index
- Removes index entries for deleted files
- Skips unchanged files

Returns a named tuple with counts: (reindexed, deleted, skipped)
"""
function sync_index(
    project_path::String = pwd();
    collection::Union{String,Nothing} = nothing,
    verbose::Bool = true,
)
    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    # Find src directory
    src_dir = joinpath(project_path, "src")
    if !isdir(src_dir)
        src_dir = project_path
    end

    verbose && println("🔄 Syncing index for collection '$col_name'...")

    # Get files that need re-indexing
    stale_files = Database.get_stale_files(src_dir)
    deleted_files = Database.get_deleted_files(col_name)

    reindexed = 0
    deleted = 0
    total_chunks = 0

    # Handle deleted files
    for file_path in deleted_files
        verbose && println("  Removing deleted: $(basename(file_path))")
        QdrantClient.delete_by_file(col_name, file_path)
        Database.remove_indexed_file(file_path)
        deleted += 1
    end

    # Re-index stale files
    for file_path in stale_files
        chunks = reindex_file(file_path, col_name; verbose = verbose)
        total_chunks += chunks
        reindexed += 1
    end

    if verbose
        if reindexed == 0 && deleted == 0
            println("✓ Index is up to date")
        else
            println(
                "✓ Sync complete: $reindexed files re-indexed ($total_chunks chunks), $deleted files removed",
            )
        end
    end

    return (reindexed = reindexed, deleted = deleted, chunks = total_chunks)
end

"""
    setup_revise_hook(project_path::String=pwd(); collection::Union{String,Nothing}=nothing)

Set up a Revise.jl callback to automatically re-index files when they change.
Only works if Revise is loaded in Main.
"""
function setup_revise_hook(
    project_path::String = pwd();
    collection::Union{String,Nothing} = nothing,
)
    if !isdefined(Main, :Revise)
        @warn "Revise.jl not loaded - automatic re-indexing disabled"
        return nothing
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    src_dir = joinpath(project_path, "src")
    if !isdir(src_dir)
        src_dir = project_path
    end

    # Create callback function
    callback = function (files_changed)
        for file_path in files_changed
            # Only index .jl files in our project
            if endswith(file_path, ".jl") && startswith(file_path, src_dir)
                @info "Auto-reindexing changed file" file = basename(file_path)
                try
                    reindex_file(file_path, col_name; verbose = false)
                catch e
                    @warn "Failed to reindex file" file = file_path exception = e
                end
            end
        end
    end

    # Register with Revise
    # Note: Revise.add_callback expects (callback, files) but we want all files
    # We'll use the revision callback approach
    try
        Main.Revise.add_callback(callback)
        @info "Revise hook installed for automatic index updates"
        return callback
    catch e
        @warn "Failed to set up Revise hook" exception = e
        return nothing
    end
end

# Global refs for the scheduler
const INDEX_SYNC_TASK = Ref{Union{Task,Nothing}}(nothing)
const INDEX_SYNC_STOP = Ref{Bool}(false)

"""
    start_index_sync_scheduler(; project_path::String=pwd(), collection::Union{String,Nothing}=nothing, interval_seconds::Int=300)

Start a background task that periodically syncs the Qdrant index with file changes.
Default interval is 5 minutes (300 seconds).

Returns the Task, or nothing if already running.
"""
function start_index_sync_scheduler(;
    project_path::String = pwd(),
    collection::Union{String,Nothing} = nothing,
    interval_seconds::Int = 300,
)
    # Check if already running
    if INDEX_SYNC_TASK[] !== nothing && !istaskdone(INDEX_SYNC_TASK[])
        @warn "Index sync scheduler already running"
        return nothing
    end

    col_name = String(
        collection === nothing ? get_project_collection_name(project_path) : collection,
    )

    INDEX_SYNC_STOP[] = false
    @info "Starting index sync scheduler" collection = col_name interval_seconds =
        interval_seconds

    task = @async begin
        while !INDEX_SYNC_STOP[]
            try
                # Sleep in small increments to check stop flag
                for _ = 1:interval_seconds
                    INDEX_SYNC_STOP[] && break
                    sleep(1)
                end
                INDEX_SYNC_STOP[] && break

                result =
                    sync_index(project_path; collection = col_name, verbose = false)
                if result.reindexed > 0 || result.deleted > 0
                    @info "Index sync completed" reindexed = result.reindexed deleted =
                        result.deleted chunks = result.chunks
                end
            catch e
                if !INDEX_SYNC_STOP[]
                    @error "Index sync scheduler error" exception = (e, catch_backtrace())
                end
                # Continue running despite errors
            end
        end
        @info "Index sync scheduler stopped"
    end

    INDEX_SYNC_TASK[] = task
    return task
end

"""
    stop_index_sync_scheduler()

Stop the background index sync scheduler if running.
"""
function stop_index_sync_scheduler()
    if INDEX_SYNC_TASK[] === nothing || istaskdone(INDEX_SYNC_TASK[])
        @info "Index sync scheduler not running"
        return false
    end

    INDEX_SYNC_STOP[] = true
    @info "Stopping index sync scheduler (will stop within 1 second)..."
    return true
end

"""
    index_sync_status() -> NamedTuple

Get the current status of the index sync scheduler.
"""
function index_sync_status()
    task = INDEX_SYNC_TASK[]
    if task === nothing
        return (running = false, state = :not_started)
    elseif istaskdone(task)
        return (running = false, state = :finished, failed = istaskfailed(task))
    else
        return (running = true, state = task.state)
    end
end
