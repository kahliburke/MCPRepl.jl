"""
MCP Tools for Qdrant Vector Database

Tools for semantic code search using Qdrant.
"""

using Logging
import ..QdrantClient

# Note: Embeddings are maintained by external process
# The search tool below requires embeddings to be generated externally or via Ollama
# The browse/list tools work without needing embeddings

# ============================================================================
# Optional: Ollama Embeddings Helper (if needed for search)
# ============================================================================

"""
    get_ollama_embedding(text::String; model::String="nomic-embed-text") -> Vector{Float64}

Get embedding for text using Ollama API (optional, for search functionality).
"""
function get_ollama_embedding(text::String; model::String = "nomic-embed-text")
    try
        body = Dict("model" => model, "prompt" => text)

        response = HTTP.post(
            "http://localhost:11434/api/embeddings",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )
        body_text = String(response.body)

        if response.status != 200
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding request failed" status = response.status model = model body =
                preview
            return Float64[]
        end

        data = try
            JSON.parse(body_text)
        catch e
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding response parse failed" model = model body = preview exception =
                e
            return Float64[]
        end

        embedding = get(data, "embedding", [])
        if isempty(embedding)
            preview = body_text
            if length(preview) > 500
                preview = first(preview, 500) * "..."
            end
            @warn "Ollama embedding empty" model = model body = preview
        end

        return Float64.(embedding)
    catch e
        @warn "Ollama embedding request error" model = model exception = e
        return Float64[]
    end
end

# ============================================================================
# MCP Tool Definitions
# ============================================================================

mutable struct QdrantIndexLogger <: AbstractLogger
    records::Vector{NamedTuple}
    min_level::LogLevel
end

QdrantIndexLogger(; min_level::LogLevel = Logging.Warn) =
    QdrantIndexLogger(NamedTuple[], min_level)

Logging.min_enabled_level(logger::QdrantIndexLogger) = logger.min_level
Logging.shouldlog(logger::QdrantIndexLogger, level, _module, group, id) =
    level >= logger.min_level

function Logging.handle_message(
    logger::QdrantIndexLogger,
    level,
    message,
    _module,
    group,
    id,
    file,
    line;
    kwargs...,
)
    push!(
        logger.records,
        (
            level = level,
            message = message,
            mod = _module,
            file = file,
            line = line,
            kwargs = kwargs,
        ),
    )
end

function format_indexing_report(message::String, records::Vector{NamedTuple})
    error_count = count(r -> r.level >= Logging.Error, records)
    warn_count = count(r -> r.level == Logging.Warn, records)

    output = message
    if error_count > 0 || warn_count > 0
        output *= "\n\n⚠️  Indexing reported $warn_count warnings and $error_count errors."
        max_records = 20
        for (i, record) in enumerate(records)
            if i > max_records
                output *= "\n... (truncated; total $(length(records)) records)"
                break
            end
            level = record.level
            msg = record.message
            output *= "\n- [$level] $msg"
            if !isempty(record.kwargs)
                details = join([string(k, "=", v) for (k, v) in pairs(record.kwargs)], ", ")
                output *= " (" * details * ")"
            end
        end
    end

    return output
end

qdrant_list_collections_tool = @mcp_tool(
    :qdrant_list_collections,
    "List all available Qdrant vector collections. Shows which code collections are available for semantic search.",
    Dict("type" => "object", "properties" => Dict(), "required" => []),
    function (args)
        collections = QdrantClient.list_collections()

        if isempty(collections)
            return "No collections found. Make sure Qdrant is running on http://localhost:6333"
        end

        result = "📚 Available Collections:\n\n"
        for (i, name) in enumerate(collections)
            info = QdrantClient.get_collection_info(name)
            vector_count = get(get(info, "vectors_count", Dict()), "count", "unknown")
            result *= "$i. $name (vectors: $vector_count)\n"
        end

        return result
    end
)

qdrant_collection_info_tool = @mcp_tool(
    :qdrant_collection_info,
    "Get detailed information about a Qdrant collection including vector count, size, and configuration.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
        ),
        "required" => ["collection"],
    ),
    function (args)
        collection = get(args, "collection", "")

        if isempty(collection)
            return "Error: collection name is required"
        end

        info = QdrantClient.get_collection_info(collection)

        if haskey(info, "error")
            return "Error: $(info["error"])"
        end

        # Format the info nicely
        result = "📊 Collection: $collection\n\n"

        if haskey(info, "vectors_count")
            result *= "Vectors: $(info["vectors_count"])\n"
        end

        if haskey(info, "points_count")
            result *= "Points: $(info["points_count"])\n"
        end

        if haskey(info, "config")
            config = info["config"]
            if haskey(config, "params") && haskey(config["params"], "vectors")
                vectors_config = config["params"]["vectors"]
                if haskey(vectors_config, "size")
                    result *= "Vector dimension: $(vectors_config["size"])\n"
                end
                if haskey(vectors_config, "distance")
                    result *= "Distance metric: $(vectors_config["distance"])\n"
                end
            end
        end

        return result
    end
)

qdrant_search_code_tool = @mcp_tool(
    :qdrant_search_code,
    "Semantic search over indexed codebase using natural language queries. Finds relevant code snippets based on meaning, not just keywords.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "query" => Dict(
                "type" => "string",
                "description" => "Natural language search query (e.g., 'function that handles HTTP routing')",
            ),
            "collection" => Dict(
                "type" => "string",
                "description" => "Collection name to search (optional, defaults to current project's collection)",
            ),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Maximum number of results (default: 5)",
            ),
            "chunk_type" => Dict(
                "type" => "string",
                "description" => "Filter by chunk type: 'definitions' (functions/structs only), 'windows' (sliding window chunks only), or 'all' (default: all)",
                "enum" => ["all", "definitions", "windows"],
            ),
            "embedding_model" => Dict(
                "type" => "string",
                "description" => "Ollama model for embeddings (default: snowflake-arctic-embed:latest)",
            ),
        ),
        "required" => ["query"],
    ),
    function (args)
        query = get(args, "query", "")
        limit = Int(get(args, "limit", 5))
        chunk_type = get(args, "chunk_type", "all")
        embedding_model = get(args, "embedding_model", "snowflake-arctic-embed:latest")

        if isempty(query)
            return "Error: query is required"
        end

        # Get collection name - default to current project's collection
        collection = get(args, "collection", nothing)
        if collection === nothing || (collection isa String && isempty(collection))
            collection = String(get_project_collection_name(pwd()))

            # Verify the collection exists
            collections = QdrantClient.list_collections()
            if !(collection in collections)
                return "Error: Collection '$collection' not found for current project. Available collections: $(join(collections, ", ")). Run index_project first or specify a collection name."
            end
        end

        # Get embedding for query
        embedding = get_ollama_embedding(query; model = embedding_model)

        if isempty(embedding)
            return "Error: Failed to generate embedding. Make sure Ollama is running with model '$embedding_model'."
        end

        # Build filter based on chunk_type
        filter = nothing
        if chunk_type == "definitions"
            # Filter for definition types (function, struct, macro, const, tool)
            filter = Dict(
                "should" => [
                    Dict("key" => "type", "match" => Dict("value" => "function")),
                    Dict("key" => "type", "match" => Dict("value" => "struct")),
                    Dict("key" => "type", "match" => Dict("value" => "macro")),
                    Dict("key" => "type", "match" => Dict("value" => "const")),
                    Dict("key" => "type", "match" => Dict("value" => "tool")),
                ],
            )
        elseif chunk_type == "windows"
            filter = Dict(
                "must" => [Dict("key" => "type", "match" => Dict("value" => "window"))],
            )
        end

        # Search
        results =
            QdrantClient.search(collection, embedding; limit = limit, filter = filter)

        if isempty(results)
            return "No results found for query: \"$query\""
        end

        # Format results (optimized for minimal tokens)
        output = "🔍 \"$query\" in $collection:\n\n"

        for (i, result) in enumerate(results)
            score = get(result, "score", 0.0)
            payload = get(result, "payload", Dict())

            # Extract key fields
            file = get(payload, "file", "")
            name = get(payload, "name", "")
            start_line = get(payload, "start_line", 0)
            end_line = get(payload, "end_line", 0)
            chunk_type = get(payload, "type", "")
            text = get(payload, "text", "")

            # Extract rich metadata
            signature = get(payload, "signature", "")
            parameters = get(payload, "parameters", [])
            type_params = get(payload, "type_params", [])
            parent_type = get(payload, "parent_type", "")
            is_mutable = get(payload, "is_mutable", false)

            # Use relative path if possible
            if !isempty(file) && startswith(file, pwd())
                file = relpath(file, pwd())
            end

            # Compact format: [score] name @ file:L10-20 (type)
            output *= "[$i $(round(score, digits=2))] "

            # Show name with signature if available
            if !isempty(signature)
                output *= "$signature @ "
            elseif !isempty(name)
                output *= "$name @ "
            end

            output *= "$file:L$start_line"
            output *= start_line != end_line ? "-$end_line" : ""

            # Show type with additional metadata
            type_info = chunk_type
            if chunk_type == "struct" && is_mutable
                type_info = "mutable struct"
            end
            if !isempty(parent_type)
                type_info *= " <: $parent_type"
            end
            if !isempty(type_params)
                type_info *= "{" * join(type_params, ",") * "}"
            end
            output *= isempty(type_info) ? "" : " ($type_info)"
            output *= "\n"

            # Only show text preview if it's meaningful (>20 chars after strip)
            text_preview = strip(string(text))
            if length(text_preview) > 20
                # Truncate to 150 chars
                if length(text_preview) > 150
                    text_preview = first(text_preview, 150) * "..."
                end
                output *= "  $text_preview\n"
            end
            output *= "\n"
        end

        return output
    end
)

qdrant_browse_collection_tool = @mcp_tool(
    :qdrant_browse_collection,
    "Browse points in a collection with pagination. Useful for exploring what's indexed.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "collection" =>
                Dict("type" => "string", "description" => "Name of the collection"),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Number of points to retrieve (default: 10)",
            ),
        ),
        "required" => ["collection"],
    ),
    function (args)
        collection = get(args, "collection", "")
        limit = get(args, "limit", 10)

        if isempty(collection)
            return "Error: collection name is required"
        end

        result = QdrantClient.scroll_points(collection; limit = limit)

        if haskey(result, "error")
            return "Error: $(result["error"])"
        end

        points = get(result, "points", [])

        if isempty(points)
            return "No points found in collection: $collection"
        end

        output = "📄 Points in $collection (showing $(length(points))):\n\n"

        for (i, point) in enumerate(points)
            point_id = get(point, "id", "unknown")
            payload = get(point, "payload", Dict())

            output *= "$i. ID: $point_id\n"

            for (key, value) in payload
                value_str = string(value)
                if length(value_str) > 100
                    value_str = value_str[1:100] * "..."
                end
                output *= "   $key: $value_str\n"
            end
            output *= "\n"
        end

        next_offset = get(result, "next_page_offset", nothing)
        if next_offset !== nothing
            output *= "More results available (next offset: $next_offset)\n"
        end

        return output
    end
)

qdrant_index_project_tool = @mcp_tool(
    :qdrant_index_project,
    "Index a Julia project into Qdrant. Creates or recreates the collection and indexes project source files.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path to index (default: current working directory)",
            ),
            "collection" => Dict(
                "type" => "string",
                "description" => "Collection name to use (optional, defaults to project name)",
            ),
            "recreate" => Dict(
                "type" => "boolean",
                "description" => "Recreate the collection before indexing (default: false)",
            ),
            "extra_dirs" => Dict(
                "type" => "array",
                "items" => Dict("type" => "string"),
                "description" => "Additional directories to index beyond src/ (e.g., [\"frontend/src\", \"dashboard-ui/src\"])",
            ),
            "extensions" => Dict(
                "type" => "array",
                "items" => Dict("type" => "string"),
                "description" => "File extensions to index (default: [\".jl\", \".ts\", \".tsx\", \".jsx\", \".md\"])",
            ),
        ),
        "required" => [],
    ),
    function (args)
        project_path = get(args, "project_path", pwd())
        collection = get(args, "collection", nothing)
        recreate = get(args, "recreate", false)

        # Convert to Vector{String} (args from JSON may be Vector{Any})
        extra_dirs = Vector{String}(get(args, "extra_dirs", String[]))
        extensions = Vector{String}(get(args, "extensions", DEFAULT_INDEX_EXTENSIONS))

        if collection isa String && isempty(collection)
            collection = nothing
        end

        chunks = index_project(
            project_path;
            collection = collection,
            recreate = recreate,
            extra_dirs = extra_dirs,
            extensions = extensions,
        )

        col_name =
            collection === nothing ? get_project_collection_name(project_path) : collection

        return "✓ Indexed $chunks chunks into '$col_name' from $(1 + length(extra_dirs)) director$(length(extra_dirs) == 0 ? "y" : "ies")."
    end
)

qdrant_sync_index_tool = @mcp_tool(
    :qdrant_sync_index,
    "Sync Qdrant index with current files. Reindexes changed files and removes deleted ones. Uses the directory and extension configuration from the initial index_project call.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path to sync (default: current working directory)",
            ),
            "collection" => Dict(
                "type" => "string",
                "description" => "Collection name to sync (optional, defaults to project name)",
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Print progress to stdout (default: true)",
            ),
        ),
        "required" => [],
    ),
    function (args)
        project_path = get(args, "project_path", pwd())
        collection = get(args, "collection", nothing)
        verbose = get(args, "verbose", true)

        if collection isa String && isempty(collection)
            collection = nothing
        end

        result = sync_index(project_path; collection = collection, verbose = verbose)

        col_name =
            collection === nothing ? get_project_collection_name(project_path) : collection
        return "✓ Sync complete for '$col_name': $(result.reindexed) files reindexed, $(result.deleted) files removed, $(result.chunks) chunks indexed."
    end
)

qdrant_reindex_file_tool = @mcp_tool(
    :qdrant_reindex_file,
    "Re-index a single file: delete old chunks then index fresh.",
    Dict(
        "type" => "object",
        "properties" => Dict(
            "file_path" =>
                Dict("type" => "string", "description" => "File path to re-index"),
            "collection" =>
                Dict("type" => "string", "description" => "Collection name"),
            "project_path" => Dict(
                "type" => "string",
                "description" => "Project path for index tracking (default: current working directory)",
            ),
            "verbose" => Dict(
                "type" => "boolean",
                "description" => "Print progress to stdout (default: true)",
            ),
        ),
        "required" => ["file_path", "collection"],
    ),
    function (args)
        file_path = get(args, "file_path", "")
        collection = get(args, "collection", "")
        project_path = get(args, "project_path", pwd())
        verbose = get(args, "verbose", true)

        if isempty(file_path)
            return "Error: file_path is required"
        end
        if isempty(collection)
            return "Error: collection is required"
        end

        chunks = reindex_file(
            file_path,
            collection;
            project_path = project_path,
            verbose = verbose,
        )
        return "✓ Re-indexed $chunks chunks for $(basename(file_path)) in '$collection'."
    end
)

# ============================================================================
# Tool Registration
# ============================================================================

function create_qdrant_tools()
    return [
        qdrant_list_collections_tool,
        qdrant_collection_info_tool,
        qdrant_search_code_tool,
        qdrant_browse_collection_tool,
        qdrant_index_project_tool,
        qdrant_sync_index_tool,
        qdrant_reindex_file_tool,
    ]
end
