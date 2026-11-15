#!/bin/sh
# Runs every test: the policy checks, then enforce.sh and uninstall.sh against a fake pmset and
# a scratch copy of the folders they touch, then install.sh the same way.
set -eu
cd "$(dirname "$0")/.."
mkdir -p build
swiftc Sources/SleepGuard/Policy.swift Tests/PolicyTests/main.swift -o build/policy-tests
build/policy-tests
sh Tests/enforce-test.sh
sh Tests/install-test.sh
