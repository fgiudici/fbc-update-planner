#!/usr/bin/env bash
# Copyright 2026.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

usage() {
    cat <<EOF
Usage: $(basename "$0") [-o <output-dir>] <operators-file>

Run plcc2fbc in strict mode against a list of operators and summarize results.

Arguments:
  <operators-file>   File with one operator name per line (blank lines and
                     lines starting with # are ignored)

Options:
  -o <dir>           Output directory for generated files (default: current directory)
  -h                 Show this help

Example usage:
./run-operators.sh -o $(date +%y%m%d) top-operators > summary.txt
EOF
}

outdir="."
while getopts "o:h" opt; do
    case "$opt" in
        o) outdir="$OPTARG" ;;
        h) usage; exit 0 ;;
        *) usage >&2; exit 1 ;;
    esac
done
shift $((OPTIND - 1))

if [[ $# -ne 1 ]]; then
    usage >&2
    exit 1
fi

operators_file="$1"

if [[ ! -f "$operators_file" ]]; then
    echo "Error: operators file not found: $operators_file" >&2
    exit 1
fi

if ! command -v jq &>/dev/null; then
    echo "Error: jq is required but not found in PATH" >&2
    exit 1
fi

mkdir -p "$outdir"

# Read operator names, skipping blank lines and comments.
operators=()
while IFS= read -r line; do
    line="${line%%#*}"
    line="$(echo "$line" | xargs)"
    [[ -z "$line" ]] && continue
    operators+=("$line")
done < "$operators_file"

if [[ ${#operators[@]} -eq 0 ]]; then
    echo "Error: no operator names found in $operators_file" >&2
    exit 1
fi

pkg_list="$(IFS=,; echo "${operators[*]}")"

echo "Building plcc2fbc..."
make -C "$ROOT_DIR" build --quiet

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

fbc_out="$tmpdir/fbc.yaml"
log_out="$tmpdir/slog.json"
val_out="$tmpdir/validation.jsonl"

echo "Running plcc2fbc with ${#operators[@]} operators (strict mode)..."
set +e
"$ROOT_DIR/bin/plcc2fbc" --strict -o yaml -l "$log_out" -p "$pkg_list" "$fbc_out" 2>"$val_out"
exit_code=$?
set -e

# --- Parse results ---

# Missing operators: slog warnings about packages not found in PLCC data.
missing=()
while IFS= read -r name; do
    [[ -n "$name" ]] && missing+=("$name")
done < <(jq -r 'select(.msg == "requested package not found in PLCC data") | .package' "$log_out" 2>/dev/null)

# Operators with validation issues: stderr JSONL entries with valid=false.
issues_json="$(jq -s '[.[] | select(.valid == false)]' "$val_out" 2>/dev/null || echo '[]')"

# Build a set of package names that have issues.
issue_names=()
while IFS= read -r name; do
    [[ -n "$name" ]] && issue_names+=("$name")
done < <(echo "$issues_json" | jq -r '.[].packageName')

# Compute max operator name length for aligned output.
max_len=0
for name in "${operators[@]}"; do
    (( ${#name} > max_len )) && max_len=${#name}
done

# --- Copy output files ---
cp -f "$fbc_out" "$outdir/fbc-output.yaml" 2>/dev/null || true
cp -f "$val_out" "$outdir/validation.jsonl"
cp -f "$log_out" "$outdir/slog.json"

# --- Print summary ---

echo ""
echo "=== Requested operators ==="
for name in "${operators[@]}"; do
    is_missing=false
    for m in "${missing[@]}"; do
        [[ "$m" == "$name" ]] && is_missing=true && break
    done
    has_issues=false
    for m in "${issue_names[@]}"; do
        [[ "$m" == "$name" ]] && has_issues=true && break
    done

    if $is_missing; then
        printf "  ✗  %-${max_len}s  [NOT FOUND]\n" "$name"
    elif $has_issues; then
        printf "  !  %-${max_len}s  [WITH ISSUES]\n" "$name"
    else
        printf "  ✓  %s\n" "$name"
    fi
done

echo ""
echo "=== Validation issues detail ==="
issues_count="$(echo "$issues_json" | jq 'length')"
if [[ "$issues_count" -eq 0 ]]; then
    echo "  (none)"
else
    echo "$issues_json" | jq -r '.[] | "  \(.packageName):", ("    " + (.reasons // [] | .[] | "- " + .))'
fi

echo ""
echo "Output files saved to: $outdir/"
echo "  fbc-output.yaml      FBC blobs"
echo "  validation.jsonl     PLCC validator results"
echo "  slog.json            Operational log"
