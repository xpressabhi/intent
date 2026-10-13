#!/bin/sh
# Shared bundle resolution for the installer and the migrator.
#
# Source this from scripts/*.sh: it resolves the Intent repository root from
# the sourcing script's location and defines bundle_source REL, which prints
# the repository file that backs a bundle path — a template override under
# install/templates/ first, then the repository root — or returns non-zero
# when neither exists.

intent_root=$(CDPATH= cd "$(dirname "$0")/.." && pwd -P)

bundle_source() {
  rel=$1
  rest=${rel#.intent/}
  if [ -f "$intent_root/install/templates/$rel" ]; then
    printf '%s\n' "$intent_root/install/templates/$rel"
  elif [ -f "$intent_root/install/templates/.intent/$rest" ]; then
    printf '%s\n' "$intent_root/install/templates/.intent/$rest"
  elif [ -f "$intent_root/$rest" ]; then
    printf '%s\n' "$intent_root/$rest"
  else
    return 1
  fi
}
