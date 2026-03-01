#!/usr/bin/env python3
"""
Multi-Agent Research Team Example

This example demonstrates how multiple AI agents can collaborate through
Boucle's MCP server to conduct comprehensive research. Three specialized
agents work together:

1. Data Collector - Gathers initial information
2. Analyst - Processes and analyzes the data
3. Synthesizer - Creates final summaries and insights

Each agent stores its work in Boucle's shared memory system, enabling
seamless collaboration and knowledge sharing.

Requirements:
- Boucle framework running with MCP server
- anthropic or openai Python packages for AI agents
- Python 3.8+

Usage:
    python3 multi_agent_research_team.py --topic "quantum computing"
"""

import argparse
import json
import subprocess
import sys
import time
from typing import Dict, List, Optional
import uuid


class BroncaMCPClient:
    """Client for interacting with Boucle's MCP server"""

    def __init__(self, boucle_path: str = "./target/release/boucle"):
        self.boucle_path = boucle_path
        self.process = None
        self.request_id = 0

    def start_server(self):
        """Start the MCP server process"""
        self.process = subprocess.Popen(
            [self.boucle_path, "mcp", "--stdio"],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Initialize the MCP connection
        init_request = {
            "jsonrpc": "2.0",
            "id": self._get_id(),
            "method": "initialize",
            "params": {
                "protocolVersion": "2024-11-05",
                "capabilities": {"tools": {}},
                "clientInfo": {"name": "research-team", "version": "1.0.0"}
            }
        }

        self._send_request(init_request)
        response = self._read_response()

        if "error" in response:
            raise Exception(f"Failed to initialize MCP: {response['error']}")

        print("✅ MCP server connected")
        return response

    def stop_server(self):
        """Stop the MCP server process"""
        if self.process:
            self.process.terminate()
            self.process.wait()

    def remember(self, entry_type: str, title: str, content: str, tags: List[str] = None) -> str:
        """Store information in shared memory"""
        request = {
            "jsonrpc": "2.0",
            "id": self._get_id(),
            "method": "tools/call",
            "params": {
                "name": "broca_remember",
                "arguments": {
                    "type": entry_type,
                    "title": title,
                    "content": content,
                    "tags": tags or []
                }
            }
        }

        self._send_request(request)
        response = self._read_response()

        if "error" in response:
            raise Exception(f"Failed to remember: {response['error']}")

        return response["result"]["content"]

    def recall(self, query: str, limit: int = 5) -> List[Dict]:
        """Retrieve information from shared memory"""
        request = {
            "jsonrpc": "2.0",
            "id": self._get_id(),
            "method": "tools/call",
            "params": {
                "name": "broca_recall",
                "arguments": {
                    "query": query,
                    "limit": limit
                }
            }
        }

        self._send_request(request)
        response = self._read_response()

        if "error" in response:
            raise Exception(f"Failed to recall: {response['error']}")

        return response["result"]["content"]

    def search_tags(self, tags: List[str], limit: int = 10) -> List[Dict]:
        """Search by tags"""
        request = {
            "jsonrpc": "2.0",
            "id": self._get_id(),
            "method": "tools/call",
            "params": {
                "name": "broca_search_tags",
                "arguments": {
                    "tags": tags,
                    "limit": limit
                }
            }
        }

        self._send_request(request)
        response = self._read_response()

        if "error" in response:
            raise Exception(f"Failed to search tags: {response['error']}")

        return response["result"]["content"]

    def relate(self, from_id: str, to_id: str, relationship: str):
        """Create relationships between entries"""
        request = {
            "jsonrpc": "2.0",
            "id": self._get_id(),
            "method": "tools/call",
            "params": {
                "name": "broca_relate",
                "arguments": {
                    "from_id": from_id,
                    "to_id": to_id,
                    "relationship": relationship
                }
            }
        }

        self._send_request(request)
        response = self._read_response()

        if "error" in response:
            raise Exception(f"Failed to create relationship: {response['error']}")

        return response["result"]["content"]

    def _get_id(self) -> int:
        self.request_id += 1
        return self.request_id

    def _send_request(self, request: Dict):
        """Send a JSON-RPC request"""
        request_str = json.dumps(request) + "\n"
        self.process.stdin.write(request_str)
        self.process.stdin.flush()

    def _read_response(self) -> Dict:
        """Read a JSON-RPC response"""
        response_line = self.process.stdout.readline().strip()
        if not response_line:
            raise Exception("No response from MCP server")
        return json.loads(response_line)


class ResearchAgent:
    """Base class for research agents"""

    def __init__(self, name: str, role: str, mcp_client: BroncaMCPClient):
        self.name = name
        self.role = role
        self.mcp = mcp_client
        self.agent_id = str(uuid.uuid4())[:8]

    def log(self, message: str):
        """Log agent activity"""
        print(f"[{self.name}] {message}")

    def work(self, topic: str) -> str:
        """Override in subclasses"""
        raise NotImplementedError


class DataCollectorAgent(ResearchAgent):
    """Agent responsible for gathering initial research data"""

    def __init__(self, mcp_client: BroncaMCPClient):
        super().__init__("DataCollector", "Information Gathering", mcp_client)

    def work(self, topic: str) -> str:
        self.log(f"Starting data collection on: {topic}")

        # Simulate gathering different types of information
        data_sources = [
            {
                "type": "definition",
                "title": f"What is {topic}?",
                "content": f"Core definition and fundamental concepts of {topic}. This includes basic principles, key terminology, and foundational understanding.",
                "tags": ["definition", "fundamentals", topic]
            },
            {
                "type": "research",
                "title": f"Current state of {topic}",
                "content": f"Recent developments and current research directions in {topic}. Including major breakthroughs, ongoing challenges, and active research areas.",
                "tags": ["current-state", "research", topic]
            },
            {
                "type": "application",
                "title": f"Applications of {topic}",
                "content": f"Practical applications and real-world uses of {topic}. Commercial implementations, industry adoption, and practical benefits.",
                "tags": ["applications", "practical", topic]
            }
        ]

        entry_ids = []
        for data in data_sources:
            self.log(f"Collecting: {data['title']}")
            result = self.mcp.remember(
                data["type"],
                data["title"],
                data["content"],
                data["tags"]
            )
            # Extract entry ID from result
            if "Entry saved:" in result:
                entry_id = result.split("Entry saved: ")[1].strip()
                entry_ids.append(entry_id)
            time.sleep(1)  # Simulate work time

        # Store collection summary
        summary = f"Data collection completed for {topic}. Gathered {len(data_sources)} initial research entries covering definitions, current state, and applications."
        summary_result = self.mcp.remember(
            "summary",
            f"Data Collection Summary: {topic}",
            summary,
            ["data-collection", "summary", topic, self.agent_id]
        )

        if "Entry saved:" in summary_result:
            summary_id = summary_result.split("Entry saved: ")[1].strip()
            # Create relationships to collected data
            for entry_id in entry_ids:
                try:
                    self.mcp.relate(summary_id, entry_id, "summarizes")
                except:
                    pass  # Ignore relationship failures for demo

        self.log("Data collection completed")
        return summary_id if 'summary_id' in locals() else ""


class AnalystAgent(ResearchAgent):
    """Agent responsible for analyzing and processing data"""

    def __init__(self, mcp_client: BroncaMCPClient):
        super().__init__("Analyst", "Data Analysis", mcp_client)

    def work(self, topic: str) -> str:
        self.log(f"Starting analysis of {topic} research")

        # Find data collected by the DataCollector
        collected_data = self.mcp.search_tags([topic], limit=10)
        self.log(f"Found {len(collected_data)} entries to analyze")

        if not collected_data:
            self.log("No data found for analysis")
            return ""

        # Perform analysis on different aspects
        analyses = []

        # Trend analysis
        trend_analysis = f"Trend analysis for {topic}: Based on available research, key trends include technological advancement, increased adoption, and growing research interest. Market indicators show positive trajectory."
        trend_result = self.mcp.remember(
            "analysis",
            f"Trend Analysis: {topic}",
            trend_analysis,
            ["analysis", "trends", topic, self.agent_id]
        )

        if "Entry saved:" in trend_result:
            trend_id = trend_result.split("Entry saved: ")[1].strip()
            analyses.append(trend_id)

        # Gap analysis
        gap_analysis = f"Gap analysis for {topic}: Identified areas needing further research include scalability challenges, standardization needs, and broader adoption barriers."
        gap_result = self.mcp.remember(
            "analysis",
            f"Gap Analysis: {topic}",
            gap_analysis,
            ["analysis", "gaps", topic, self.agent_id]
        )

        if "Entry saved:" in gap_result:
            gap_id = gap_result.split("Entry saved: ")[1].strip()
            analyses.append(gap_id)

        # Store analysis summary
        analysis_summary = f"Comprehensive analysis completed for {topic}. Generated {len(analyses)} analytical insights covering trends, gaps, and strategic implications."
        summary_result = self.mcp.remember(
            "summary",
            f"Analysis Summary: {topic}",
            analysis_summary,
            ["analysis", "summary", topic, self.agent_id]
        )

        if "Entry saved:" in summary_result:
            summary_id = summary_result.split("Entry saved: ")[1].strip()
            # Relate analysis to source data
            for data_entry in collected_data[:3]:  # Relate to first 3 entries
                try:
                    self.mcp.relate(summary_id, data_entry["id"], "analyzes")
                except:
                    pass

        self.log("Analysis completed")
        return summary_id if 'summary_id' in locals() else ""


class SynthesizerAgent(ResearchAgent):
    """Agent responsible for creating final synthesis and insights"""

    def __init__(self, mcp_client: BroncaMCPClient):
        super().__init__("Synthesizer", "Synthesis & Insights", mcp_client)

    def work(self, topic: str) -> str:
        self.log(f"Starting synthesis for {topic}")

        # Gather all previous work
        all_research = self.mcp.search_tags([topic], limit=20)
        data_entries = [e for e in all_research if "data-collection" in e.get("tags", [])]
        analysis_entries = [e for e in all_research if "analysis" in e.get("tags", [])]

        self.log(f"Synthesizing {len(data_entries)} data entries and {len(analysis_entries)} analyses")

        # Create comprehensive synthesis
        synthesis_content = f"""
# Comprehensive Research Synthesis: {topic}

## Executive Summary
This synthesis combines insights from {len(data_entries)} data collection efforts and {len(analysis_entries)} analytical assessments to provide a comprehensive overview of {topic}.

## Key Findings
- {topic} represents a significant area of technological and research interest
- Current developments show promising trends and growing adoption
- Several challenges and gaps remain that present opportunities for innovation
- Applications span multiple industries with varying levels of maturity

## Strategic Implications
1. **Immediate Opportunities**: Areas where {topic} can provide immediate value
2. **Long-term Vision**: Future potential and transformational possibilities
3. **Risk Factors**: Key challenges and mitigation strategies
4. **Investment Recommendations**: Priority areas for resource allocation

## Research Methodology
This synthesis was generated through collaborative multi-agent research:
- Data collection from foundational sources
- Analytical processing of trends and gaps
- Cross-referencing and relationship mapping
- Final synthesis and insight generation

## Conclusions
{topic} presents a compelling research and development opportunity with strong fundamentals, clear applications, and significant future potential. Continued research and strategic investment are recommended.
        """.strip()

        # Store the synthesis
        synthesis_result = self.mcp.remember(
            "synthesis",
            f"Research Synthesis: {topic}",
            synthesis_content,
            ["synthesis", "final-report", topic, self.agent_id]
        )

        if "Entry saved:" in synthesis_result:
            synthesis_id = synthesis_result.split("Entry saved: ")[1].strip()

            # Create relationships to all source material
            for entry in all_research[:10]:  # Limit to prevent overwhelming
                try:
                    self.mcp.relate(synthesis_id, entry["id"], "synthesizes")
                except:
                    pass

        self.log("Synthesis completed")
        return synthesis_id if 'synthesis_id' in locals() else ""


def run_research_team(topic: str, boucle_path: str):
    """Orchestrate the multi-agent research team"""
    print(f"🚀 Starting Multi-Agent Research on: {topic}")
    print("=" * 60)

    # Initialize MCP client and agents
    mcp_client = BroncaMCPClient(boucle_path)

    try:
        mcp_client.start_server()

        # Create agent team
        collector = DataCollectorAgent(mcp_client)
        analyst = AnalystAgent(mcp_client)
        synthesizer = SynthesizerAgent(mcp_client)

        print("\n🤖 Agent Team Assembled:")
        print(f"  • {collector.name} - {collector.role}")
        print(f"  • {analyst.name} - {analyst.role}")
        print(f"  • {synthesizer.name} - {synthesizer.role}")
        print()

        # Execute research workflow
        print("📊 Phase 1: Data Collection")
        collector_result = collector.work(topic)
        print()

        print("🔍 Phase 2: Analysis")
        analyst_result = analyst.work(topic)
        print()

        print("📝 Phase 3: Synthesis")
        synthesizer_result = synthesizer.work(topic)
        print()

        # Final summary
        print("✅ Research Complete!")
        print(f"Final synthesis stored in Boucle memory: {synthesizer_result}")

        # Show final results
        if synthesizer_result:
            final_results = mcp_client.recall(f"synthesis {topic}", limit=1)
            if final_results:
                print("\n📋 Final Research Summary:")
                print("-" * 40)
                print(final_results[0].get("content", "")[:500] + "...")

        print(f"\n🔗 View all {topic} research: `boucle memory search_tag {topic}`")

    except Exception as e:
        print(f"❌ Error during research: {e}")
        return 1

    finally:
        mcp_client.stop_server()

    return 0


def main():
    parser = argparse.ArgumentParser(description="Multi-Agent Research Team Demo")
    parser.add_argument("--topic", required=True, help="Research topic")
    parser.add_argument("--boucle-path", default="./target/release/boucle",
                       help="Path to Boucle binary")

    args = parser.parse_args()

    return run_research_team(args.topic, args.boucle_path)


if __name__ == "__main__":
    sys.exit(main())