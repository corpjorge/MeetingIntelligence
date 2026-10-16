#!/bin/zsh
# Runs a swift command and prints only compiler errors/warnings (ANSI stripped, CLT linker noise removed).
"$@" 2>&1 | sed -E $'s/\x1b\\[[0-9;]*m//g; s/\x1b\\]8;;[^\x1b]*\x1b\\\\//g' \
  | grep -E "error:|warning:|Build complete|passed|failed|✘|issue" \
  | grep -v "search path '/Library/Developer/CommandLineTools" \
  | grep -v "^ *|" | awk '!seen[$0]++' | head -${MAX_LINES:-60}
