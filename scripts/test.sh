#!/bin/sh
# Runs every test: the policy checks, then enforce.sh against a fake pmset.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/SleepGuard/Policy.swift Tests/PolicyTests/main.swift -o build/policy-tests
build/policy-tests
sh Tests/enforce-test.sh
