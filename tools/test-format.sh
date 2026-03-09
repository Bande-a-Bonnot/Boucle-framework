#!/bin/bash
# Wrapper: runs the Python format regression test
exec python3 "$(dirname "$0")/test_format.py" "$@"
