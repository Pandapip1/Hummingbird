#!/bin/sh
# Pulls the latest commit of the SwiftOpenUI fork's `jaybird` branch into the Vendor/SwiftOpenUI submodule.
set -e
cd "$(dirname "$0")/.."
git -C Vendor/SwiftOpenUI fetch -q origin jaybird
git -C Vendor/SwiftOpenUI checkout -q FETCH_HEAD
git -C Vendor/SwiftOpenUI log --oneline | head -1
