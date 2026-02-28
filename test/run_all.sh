#!/bin/bash
# Run all Boucle test suites
set -euo pipefail

TEST_DIR="$(cd "$(dirname "$0")" && pwd)"
OVERALL_EXIT=0

echo "==============================="
echo "  Boucle Test Suite"
echo "==============================="
echo ""

for test_file in "$TEST_DIR"/test_*.sh; do
    if [ -f "$test_file" ]; then
        echo ""
        bash "$test_file" || OVERALL_EXIT=1
        echo ""
    fi
done

echo ""
if [ "$OVERALL_EXIT" -eq 0 ]; then
    echo "All test suites passed!"
else
    echo "Some tests failed."
fi

exit $OVERALL_EXIT
