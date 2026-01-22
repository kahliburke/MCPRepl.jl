# High-Quality Embedding Models for M3 with 64GB RAM

## Recommended: Best Available via Ollama

### 1. **mxbai-embed-large** (Current - Already Installed)
- **Dimensions**: 1024
- **Parameters**: 334M
- **Context**: 512 tokens
- **Quality**: Excellent for code
- **Memory**: ~670MB
- **Status**: ✅ Currently using

### 2. **snowflake-arctic-embed:latest** (Recommended Upgrade)
- **Dimensions**: 1024
- **Parameters**: 335M
- **Context**: 512 tokens
- **Quality**: State-of-art retrieval (beats OpenAI ada-002)
- **Memory**: ~670MB
- **Install**: `ollama pull snowflake-arctic-embed:latest`
- **Advantage**: Better at understanding technical/scientific content

### 3. **bge-large-en-v1.5** (Via Ollama)
- **Dimensions**: 1024
- **Parameters**: 335M
- **Context**: 512 tokens
- **Quality**: Excellent general purpose
- **Install**: `ollama pull bge-large`

## Long-Context Options (Not via Ollama)

### **Jina Embeddings v2** (8192 token context!)
- **Dimensions**: 768 or 1024
- **Context**: 8192 tokens (16x more!)
- **Install**: Would need custom integration via Jina API or local deployment
- **Advantage**: Can embed entire functions without truncation

### **OpenAI text-embedding-3-large**
- **Dimensions**: 3072 (highest quality)
- **Context**: 8191 tokens
- **Cost**: ~$0.00013 per 1K tokens
- **Advantage**: Best semantic understanding, no truncation needed

## Current Token Budget Issue

**Problem**: Code is token-dense. A 2000-char function can easily exceed 512 tokens because:
- Variable names: `compute_gradient_descent_optimization` = 7 tokens
- Type annotations: `::Vector{Float64}` = 6 tokens
- Comments and strings add tokens

**Solution**: Set `context_chars=1000` to stay well under 512-token limit.

## Recommendation

**Immediate (No changes needed)**:
- Stay with `mxbai-embed-large` at 1000 chars/chunk
- Quality is already excellent

**Best Upgrade (if you want even better results)**:
```bash
ollama pull snowflake-arctic-embed:latest
```
Then change `DEFAULT_EMBEDDING_MODEL = "snowflake-arctic-embed:latest"` in qdrant_indexer.jl

**Ultimate (for long-context needs)**:
- Add Jina API integration for 8K token context
- Would eliminate all truncation issues
- Can embed complete files if needed

## Performance on M3 with 64GB

With your hardware:
- Any of these models will run instantly
- 64GB RAM can easily hold multiple models simultaneously
- M3 Neural Engine will accelerate inference
- Expect <100ms per embedding (plenty fast for indexing)

## My Suggestion

1. **Short-term**: Fix current errors by reducing context_chars to 1000 ✅ Done
2. **Medium-term**: Pull `snowflake-arctic-embed` and test quality improvement
3. **Long-term**: If chunks are getting truncated too much, add Jina API support for 8K context
