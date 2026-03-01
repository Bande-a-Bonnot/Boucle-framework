#!/usr/bin/env python3
"""
Simple MCP server test for Boucle framework
Tests basic functionality without requiring complex clients
"""

import json
import subprocess
import sys
import time

def test_mcp_server():
    """Test MCP server basic functionality"""

    # Test tools/list first
    test_request = {
        "jsonrpc": "2.0",
        "id": 1,
        "method": "tools/list"
    }

    try:
        # Start MCP server
        proc = subprocess.Popen(
            ['../target/release/boucle', 'mcp', '--stdio'],
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True
        )

        # Send request
        request_json = json.dumps(test_request) + '\n'
        stdout, stderr = proc.communicate(request_json, timeout=5)

        # Check response
        if stdout.strip():
            response = json.loads(stdout.strip())
            if 'result' in response and 'tools' in response['result']:
                tools = response['result']['tools']
                tool_names = [tool['name'] for tool in tools]
                print(f"✅ MCP server working! Found {len(tools)} tools:")
                for name in tool_names:
                    print(f"  - {name}")
                return True
            else:
                print(f"❌ Unexpected response format: {response}")
                return False
        else:
            print(f"❌ No response from server. stderr: {stderr}")
            return False

    except subprocess.TimeoutExpired:
        print("❌ MCP server timed out")
        proc.kill()
        return False
    except Exception as e:
        print(f"❌ Error testing MCP server: {e}")
        return False

if __name__ == "__main__":
    print("Testing Boucle MCP server...")
    success = test_mcp_server()
    sys.exit(0 if success else 1)