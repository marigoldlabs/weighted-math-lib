#!/usr/bin/env bash
set -e

if [ "$GITHUB_ACTIONS" == "true" ]; then
    forge coverage --match-path "test/**/*.sol" --report lcov
else
    forge coverage --match-path "test/**/*.sol"
fi
