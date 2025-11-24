"""
Qdrant Vector Database Client

Simple HTTP client for interacting with Qdrant vector database.
Assumes Qdrant is running locally (e.g., via Docker).
"""
module QdrantClient

using HTTP
using JSON

# Qdrant server configuration
const QDRANT_URL = Ref("http://localhost:6333")

"""
    set_url(url::String)

Set the Qdrant server URL (default: http://localhost:6333).
"""
function set_url(url::String)
    QDRANT_URL[] = url
end

"""
    list_collections() -> Vector{String}

List all collections in the Qdrant instance.
"""
function list_collections()
    try
        response = HTTP.get("$(QDRANT_URL[])/collections")
        data = JSON.parse(String(response.body))

        if haskey(data, "result") && haskey(data["result"], "collections")
            return [c["name"] for c in data["result"]["collections"]]
        end
        return String[]
    catch e
        @error "Failed to list collections" exception = e
        return String[]
    end
end

"""
    get_collection_info(collection::String) -> Dict

Get information about a specific collection.
"""
function get_collection_info(collection::String)
    try
        response = HTTP.get("$(QDRANT_URL[])/collections/$(collection)")
        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Failed to get collection info" collection = collection exception = e
        return Dict("error" => string(e))
    end
end

"""
    search(collection::String, vector::Vector{Float64}; limit::Int=5, score_threshold::Float64=0.0) -> Vector{Dict}

Search for similar vectors in a collection.

# Arguments
- `collection::String`: Name of the collection to search
- `vector::Vector{Float64}`: Query vector
- `limit::Int`: Maximum number of results (default: 5)
- `score_threshold::Float64`: Minimum similarity score (default: 0.0)

# Returns
Vector of result dictionaries containing id, score, and payload.
"""
function search(
    collection::String,
    vector::Vector{Float64};
    limit::Int = 5,
    score_threshold::Float64 = 0.0,
)
    try
        body = Dict(
            "vector" => vector,
            "limit" => limit,
            "score_threshold" => score_threshold,
            "with_payload" => true,
            "with_vector" => false,
        )

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/search",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "result", [])
    catch e
        @error "Search failed" collection = collection exception = e
        return [Dict("error" => string(e))]
    end
end

"""
    search_with_text(collection::String, query_text::String; limit::Int=5, embed_func::Function) -> Vector{Dict}

Search using text by first converting to embedding.

# Arguments
- `collection::String`: Name of the collection to search
- `query_text::String`: Text query to search for
- `limit::Int`: Maximum number of results (default: 5)
- `embed_func::Function`: Function that takes text and returns Vector{Float64} embedding
"""
function search_with_text(
    collection::String,
    query_text::String;
    limit::Int = 5,
    embed_func::Function,
)
    try
        # Get embedding for query text
        embedding = embed_func(query_text)

        # Search using the embedding
        return search(collection, embedding; limit = limit)
    catch e
        @error "Text search failed" collection = collection exception = e
        return [Dict("error" => string(e))]
    end
end

"""
    scroll_points(collection::String; limit::Int=10, offset=nothing) -> Dict

Retrieve points from a collection with pagination.

# Arguments
- `collection::String`: Name of the collection
- `limit::Int`: Number of points to retrieve (default: 10)
- `offset`: Offset for pagination (optional)
"""
function scroll_points(collection::String; limit::Int = 10, offset = nothing)
    try
        body = Dict("limit" => limit, "with_payload" => true, "with_vector" => false)

        if offset !== nothing
            body["offset"] = offset
        end

        response = HTTP.post(
            "$(QDRANT_URL[])/collections/$(collection)/points/scroll",
            ["Content-Type" => "application/json"],
            JSON.json(body),
        )

        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Scroll failed" collection = collection exception = e
        return Dict("error" => string(e))
    end
end

"""
    get_point(collection::String, point_id) -> Dict

Retrieve a specific point by ID.
"""
function get_point(collection::String, point_id)
    try
        response = HTTP.get("$(QDRANT_URL[])/collections/$(collection)/points/$(point_id)")
        data = JSON.parse(String(response.body))
        return get(data, "result", Dict())
    catch e
        @error "Failed to get point" collection = collection point_id = point_id exception =
            e
        return Dict("error" => string(e))
    end
end

end # module
