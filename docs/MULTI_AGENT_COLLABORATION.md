# Multi-Agent Collaboration with Boucle

Boucle transforms from a single-agent memory system into a powerful infrastructure platform for multi-agent collaboration through its MCP (Model Context Protocol) server capabilities.

## The Vision

Traditional AI agents work in isolation, each maintaining their own memory and context. Boucle changes this by providing:

- **Shared Memory Infrastructure**: Multiple agents can read from and write to the same structured memory
- **Zero-Configuration Collaboration**: No complex setup or external dependencies required
- **Persistent Knowledge Sharing**: Work persists across agent sessions and system restarts
- **Relationship Mapping**: Agents can create and query relationships between different pieces of information

## How It Works

### 1. MCP Server Foundation

Boucle exposes its Broca memory system as an MCP server, implementing the JSON-RPC 2.0 protocol over stdin/stdout:

```bash
# Start Boucle as an MCP server
boucle mcp --stdio
```

This makes all Broca memory operations available to any MCP-compatible AI agent or application.

### 2. Available Tools

The MCP server exposes these collaborative tools:

- **`broca_remember`**: Store new information with type, title, content, and tags
- **`broca_recall`**: Query memory with relevance scoring and fuzzy matching
- **`broca_search_tags`**: Find entries by specific tags
- **`broca_show`**: Get detailed information about specific entries
- **`broca_relate`**: Create relationships between memory entries
- **`broca_journal`**: Add timestamped journal entries
- **`broca_supersede`**: Mark entries as superseded by newer information
- **`broca_list`**: Browse paginated memory with filtering
- **`broca_stats`**: Get memory system statistics

### 3. Collaboration Patterns

#### Research Teams

Multiple agents can collaborate on research projects:

```python
# Agent 1: Data Collector
collector.remember("research", "Market Analysis", content, ["markets", "analysis"])

# Agent 2: Analyst
data = analyst.recall("market analysis")
analyst.remember("insight", "Key Trends", analysis_result, ["trends", "insights"])

# Agent 3: Reporter
insights = reporter.search_tags(["insights"])
reporter.remember("report", "Final Report", synthesis, ["reports", "final"])
```

#### Knowledge Building

Agents can build on each other's work:

```python
# Agent A discovers something
agent_a.remember("discovery", "New Pattern", details, ["patterns"])

# Agent B extends the discovery
base_research = agent_b.recall("new pattern")
agent_b.remember("analysis", "Pattern Implications", extended_analysis, ["patterns", "implications"])

# Create relationship
agent_b.relate(discovery_id, analysis_id, "extended_by")
```

#### Temporal Collaboration

Agents working at different times can coordinate:

```python
# Morning agent leaves notes
morning_agent.remember("todo", "Research X", "Need to investigate X for project Y", ["todos", "research"])

# Evening agent picks up the work
todos = evening_agent.search_tags(["todos"])
evening_agent.remember("completed", "Research X Results", findings, ["research", "completed"])
```

## Example: Multi-Agent Research Team

The `/examples/multi_agent_research_team.py` script demonstrates a complete multi-agent collaboration scenario:

### Agents:
1. **DataCollector**: Gathers initial research data
2. **Analyst**: Processes and analyzes the collected data
3. **Synthesizer**: Creates final summaries and insights

### Workflow:
1. DataCollector stores foundational research with appropriate tags
2. Analyst queries the shared memory, finds the data, and stores analysis
3. Synthesizer retrieves all previous work and creates a comprehensive synthesis
4. All agents create relationships between their work for future reference

### Running the Example:

```bash
cd Boucle-framework
python3 examples/multi_agent_research_team.py --topic "quantum computing"
```

This creates a complete research workflow stored in Boucle's memory, demonstrating how agents can collaborate seamlessly.

## Integration Approaches

### With Claude Desktop

Claude Desktop supports MCP servers directly. Configure it to use Boucle:

```json
{
  "mcpServers": {
    "boucle": {
      "command": "/path/to/boucle",
      "args": ["mcp", "--stdio"]
    }
  }
}
```

### With Custom Applications

Any application can use Boucle as collaborative memory:

```python
import subprocess
import json

# Start MCP server
process = subprocess.Popen(
    ["boucle", "mcp", "--stdio"],
    stdin=subprocess.PIPE,
    stdout=subprocess.PIPE,
    text=True
)

# Send MCP requests
request = {
    "jsonrpc": "2.0",
    "id": 1,
    "method": "tools/call",
    "params": {
        "name": "broca_remember",
        "arguments": {
            "type": "note",
            "title": "Meeting Notes",
            "content": "Key decisions from today's meeting...",
            "tags": ["meetings", "decisions"]
        }
    }
}

process.stdin.write(json.dumps(request) + "\n")
response = json.loads(process.stdout.readline())
```

### With Existing Agent Frameworks

Boucle can integrate with existing agent frameworks as shared memory:

```python
# LangChain integration example
from langchain.tools import Tool

def boucle_remember(input_str):
    # Parse input and call Boucle MCP server
    return store_in_boucle(input_str)

def boucle_recall(query):
    # Query Boucle memory and return results
    return query_boucle(query)

tools = [
    Tool(name="remember", func=boucle_remember, description="Store information"),
    Tool(name="recall", func=boucle_recall, description="Retrieve information")
]
```

## Benefits of File-Based Collaboration

### 1. Zero Infrastructure
- No databases or external services required
- Works entirely with local files
- Git-compatible for version control and backup

### 2. Transparency
- All memory is human-readable markdown files
- Easy to inspect, debug, and audit agent interactions
- Clear data ownership and modification history

### 3. Portability
- Memory travels with the project
- No vendor lock-in or complex migrations
- Works across different environments and systems

### 4. Resilience
- No single points of failure
- Graceful degradation if parts of the system fail
- Self-healing through file system operations

## Use Cases

### Development Teams
- Agents collaborating on code review, testing, and documentation
- Shared knowledge about system architecture and decisions
- Coordinated deployment and maintenance tasks

### Research Organizations
- Multi-agent research workflows like the example above
- Knowledge accumulation across different research domains
- Collaborative analysis and insight generation

### Content Creation
- Agents specializing in research, writing, editing, and formatting
- Shared style guides and brand guidelines
- Collaborative fact-checking and source verification

### Business Operations
- Customer support agents sharing context and solutions
- Sales agents coordinating leads and account information
- Project management with distributed agent teams

## Getting Started

1. **Install Boucle**: Build the framework from source
2. **Initialize Memory**: Run `boucle init` in your project directory
3. **Start MCP Server**: Use `boucle mcp --stdio` to expose collaborative tools
4. **Connect Agents**: Configure your AI agents to use the MCP server
5. **Define Workflows**: Design collaboration patterns for your use case

The multi-agent future isn't just about smarter individual agents—it's about agents working together effectively. Boucle provides the infrastructure foundation to make that collaboration seamless, transparent, and reliable.