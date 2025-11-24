"""
MCP Tools for Qdrant Vector Database

Tools for semantic code search using Qdrant.
"""

# QdrantClient will be available from parent module scope

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

        data = JSON.parse(String(response.body))
        return Float64.(get(data, "embedding", []))
    catch e
        @debug "Ollama embedding not available" exception = e
        return Float64[]
    end
end

# ============================================================================
# MCP Tool Definitions
# ============================================================================

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
                "description" => "Collection name to search (optional, defaults to first available)",
            ),
            "limit" => Dict(
                "type" => "integer",
                "description" => "Maximum number of results (default: 5)",
            ),
            "embedding_model" => Dict(
                "type" => "string",
                "description" => "Ollama model for embeddings (default: nomic-embed-text)",
            ),
        ),
        "required" => ["query"],
    ),
    function (args)
        query = get(args, "query", "")
        limit = get(args, "limit", 5)
        embedding_model = get(args, "embedding_model", "nomic-embed-text")

        if isempty(query)
            return "Error: query is required"
        end

        # Get collection name
        collection = get(args, "collection", nothing)
        if collection === nothing
            collections = QdrantClient.list_collections()
            if isempty(collections)
                return "Error: No collections found"
            end
            collection = collections[1]
        end

        # Get embedding for query
        embedding = get_ollama_embedding(query; model = embedding_model)

        if isempty(embedding)
            return "Error: Failed to generate embedding. Make sure Ollama is running with model '$embedding_model'."
        end

        # Search
        results = QdrantClient.search(collection, embedding; limit = limit)

        if isempty(results)
            return "No results found for query: \"$query\""
        end

        # Format results
        output = "🔍 Search Results for: \"$query\"\n"
        output *= "Collection: $collection\n\n"

        for (i, result) in enumerate(results)
            score = get(result, "score", 0.0)
            payload = get(result, "payload", Dict())

            output *= "$i. Score: $(round(score, digits=3))\n"

            # Display payload fields
            for (key, value) in payload
                if key == "text" || key == "content" || key == "code"
                    # Truncate long text
                    text_str = string(value)
                    if length(text_str) > 200
                        text_str = text_str[1:200] * "..."
                    end
                    output *= "   $key: $text_str\n"
                else
                    output *= "   $key: $value\n"
                end
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

# ============================================================================
# Tool Registration
# ============================================================================

function create_qdrant_tools()
    return [
        qdrant_list_collections_tool,
        qdrant_collection_info_tool,
        qdrant_search_code_tool,
        qdrant_browse_collection_tool,
    ]
end
