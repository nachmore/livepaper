#!/bin/bash
# Lints the repository's shell scripts (shellcheck) and GitHub workflows (actionlint, which also
# shellchecks every `run:` block). Run by CI; locally: brew install shellcheck actionlint.
#
#   scripts/ci/lint.sh
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
cd "$ROOT"
for tool in shellcheck actionlint; do
  command -v "$tool" >/dev/null || { echo "✗ $tool not found (brew install $tool)" >&2; exit 1; }
done

# Every tracked file with a sh/bash shebang, wherever it lives.
scripts=()
while IFS= read -r -d '' f; do
  [ -f "$f" ] && [ ! -L "$f" ] || continue
  head -n1 "$f" 2>/dev/null | grep -qE '^#!(/usr/bin/env )?/?(usr/)?(bin/)?(ba)?sh( |$)' && scripts+=("$f")
done < <(git ls-files -z)
[ "${#scripts[@]}" -gt 0 ] || { echo "✗ no shell scripts found" >&2; exit 1; }

echo "▸ shellcheck $(shellcheck --version | sed -n 's/^version: //p') — ${#scripts[@]} scripts"
shellcheck -x "${scripts[@]}"
echo "▸ actionlint $(actionlint --version | head -n1)"
actionlint
echo "✓ lint clean"
