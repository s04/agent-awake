#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

if ! grep -Eq 'p\.arguments = \["-dims"\]' main.swift; then
  echo "FAIL: caffeinate must use -dims to prevent display, idle-system, disk, and AC sleep" >&2
  exit 1
fi

echo "PASS: caffeinate includes the display-sleep assertion"
