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
Usage: $(basename "$0") [options] [operators-file]

Run plcc2fbc against a list of operators and summarize results. If
<operators-file> is omitted, all packages found in the PLCC data are
processed.

Arguments:
  [operators-file]   File with one operator name per line (blank lines and
                     lines starting with # are ignored). If omitted, every
                     package present in the PLCC data is checked.

Options:
  -o <dir>           Output directory for generated files (default: current directory)
  --plcc             Validate PLCC data only (skip FBC generation)
  --validators <v>   Comma-separated validators to run (passed through to plcc2fbc;
                     use "none" to skip PLCC validation entirely)
  -h                 Show this help

Example usage:
./plcc-check.sh -o \$(date +%y%m%d) top-operators > summary.txt
./plcc-check.sh -o \$(date +%y%m%d) > summary.txt
./plcc-check.sh --plcc -o \$(date +%y%m%d) top-operators > summary.txt
./plcc-check.sh --validators none -o \$(date +%y%m%d) top-operators > summary.txt
./plcc-check.sh --validators syntax -o \$(date +%y%m%d) top-operators > summary.txt
EOF
}

# Globals populated by parse_args() and consumed throughout the script.
OUTDIR="."
VALIDATEONLY=false
PLCCVALIDATORS=""
OPERATORSFILE=""

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            -o)
                if [[ $# -lt 2 ]]; then
                    echo "Error: -o requires a value" >&2
                    usage >&2
                    exit 1
                fi
                OUTDIR="$2"; shift 2 ;;
            --plcc) VALIDATEONLY=true; shift ;;
            --validators)
                if [[ $# -lt 2 ]]; then
                    echo "Error: --validators requires a value" >&2
                    usage >&2
                    exit 1
                fi
                PLCCVALIDATORS="$2"; shift 2 ;;
            -h) usage; exit 0 ;;
            -*) usage >&2; exit 1 ;;
            *) break ;;
        esac
    done

    if [[ $# -eq 0 ]]; then
        OPERATORSFILE=""
    elif [[ $# -eq 1 ]]; then
        OPERATORSFILE="$1"
    else
        usage >&2
        exit 1
    fi
}

log_info() {
    echo -e "$@" | tee -a $FILE_SUM
}

log_error() {
    echo -e "$@" >&2
}

check_dependencies() {
    if ! command -v jq &>/dev/null; then
        log_error "Error: jq is required but not found in PATH"
        exit 1
    fi
    if ! command -v tee &>/dev/null; then
        log_error "Error: tee is required but not found in PATH"
    fi
}

build_plcc2fbc() {
    log_info "Building plcc2fbc..."
    make -C "$ROOT_DIR" build --quiet
}

# Reads OPERATORSFILE into the "operators" array, skipping blank lines and
# comments. Sets "operators_number" and appends the comma-separated package
# list to plcc2fbc_args via the "pkg_list" global.
read_operators_file() {
    operators=()
    while IFS= read -r line; do
        line="${line%%#*}"
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" ]] && continue
        operators+=("$line")
    done < "$OPERATORSFILE"

    if [[ ${#operators[@]} -eq 0 ]]; then
        log_error "Error: no operator names found in $OPERATORSFILE"
        exit 1
    fi
    operators_number=${#operators[@]}

    pkg_list="$(IFS=,; echo "${operators[*]}")"
    plcc2fbc_args+=(--allow-missing -p "$pkg_list")
}

# Builds plcc2fbc_args, runs the binary, and aborts on fatal errors.
run_plcc2fbc() {
    plcc2fbc_args=(-o yaml -l "$FILE_VAL")

    operators_number="all"
    if [[ -n "$OPERATORSFILE" ]]; then
        read_operators_file
    fi

    if [[ -n "$PLCCVALIDATORS" ]]; then
        plcc2fbc_args+=(--validators "$PLCCVALIDATORS")
    fi
    if $VALIDATEONLY; then
        plcc2fbc_args+=(--dump-plcc)
        log_info "Running plcc2fbc with ${operators_number} operators (PLCC validation only)..."
    else
        log_info "Running plcc2fbc with ${operators_number} operators..."
    fi

    set +e
    "$ROOT_DIR/bin/plcc2fbc" "${plcc2fbc_args[@]}" "$FILE_FBC" >"$FILE_LOG" 2>"$TMPDIR/stderr.log"
    exit_code=$?
    set -e

    if [[ "$exit_code" -eq 1 ]]; then
        log_error "Error: plcc2fbc failed with a fatal error"
        if [[ -s "$TMPDIR/stderr.log" ]]; then
            cat "$TMPDIR/stderr.log" >&2
        fi
        exit 1
    fi
}

# Parses missing/failed operators out of FILE_LOG and FILE_VAL. Populates
# "RESULTS_MISSING" (packages not found), "RESULTS_ISSUES" (validation failures,
# packageName kept exactly as PLCC recorded it), and "RESULTS_OPWITHISSUES"
# (sorted unique set of individual package names with issues).
parse_results() {
    # Missing operators: slog warnings about packages not found in PLCC data.
    while IFS= read -r name; do
        [[ -n "$name" ]] && RESULTS_MISSING+=("$name")
    done < <(jq -r 'select(.level == "WARN" and .msg == "requested package not found in PLCC data") | .package' "$FILE_LOG" 2>/dev/null)

    # Operators with validation issues: stderr JSONL entries with valid=false.
    # packageName is kept exactly as PLCC recorded it (may be a comma-separated
    # list for products not yet expanded into separate packages).
    RESULTS_ISSUES="$(jq -s '[.[] | select((.reasons | length) > 0)]' "$FILE_VAL" 2>/dev/null || echo '[]')"

    # Build the set of individual operator names with issues, splitting any
    # comma-separated packageName so it lines up with individual operator names.
    while IFS= read -r name; do
        [[ -n "$name" ]] && RESULTS_OPWITHISSUES+=("$name")
    done < <(echo "$RESULTS_ISSUES" | jq -r '.[].packageName' \
        | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//' | sort -u)
}

# In "all packages" mode we don't know package names ahead of time, so
# derive the operator list from the run's own output: packages present in
# the generated FBC (or PLCC dump) passed, packages present in the
# validation log with issues did not. Missing packages can't be detected in
# this mode since no -p flag is passed to plcc2fbc.
derive_operators_from_output() {
    [[ -n "$OPERATORSFILE" ]] && return

    operators=()
    if $VALIDATEONLY; then
        while IFS= read -r name; do
            [[ -n "$name" ]] && operators+=("$name")
        done < <(jq -r '.data[]?.package // empty' "$FILE_FBC" 2>/dev/null | tr ',' '\n' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')
    else
        while IFS= read -r name; do
            [[ -n "$name" ]] && operators+=("$name")
        done < <(grep '^package:' "$FILE_FBC" 2>/dev/null | sed -e 's/^package:[[:space:]]*//' -e 's/^"//' -e 's/"$//')
    fi
    operators+=("${RESULTS_OPWITHISSUES[@]}")
    if [[ ${#operators[@]} -gt 0 ]]; then
        readarray -t operators < <(printf '%s\n' "${operators[@]}" | sort -u)
    fi
}

print_operator_list() {
    local max_len=0
    for name in "${operators[@]}"; do
        (( ${#name} > max_len )) && max_len=${#name}
    done

    log_info ""
    log_info "=== Requested operators ==="
    for name in "${operators[@]}"; do
        local is_missing=false
        if [[ ${#RESULTS_MISSING[@]} -gt 0 ]]; then
            for m in "${RESULTS_MISSING[@]}"; do
                [[ "$m" == "$name" ]] && is_missing=true && break
            done
        fi
        local has_issues=false
        if [[ ${#RESULTS_OPWITHISSUES[@]} -gt 0 ]]; then
            for m in "${RESULTS_OPWITHISSUES[@]}"; do
                [[ "$m" == "$name" ]] && has_issues=true && break
            done
        fi

        if $is_missing; then
            log_info "$(printf "  ✗  %-${max_len}s  [NOT FOUND]\n" "$name")"
        elif $has_issues; then
            log_info "$(printf "  !  %-${max_len}s  [WITH ISSUES]\n" "$name")"
        else
            log_info "$(printf "  ✓  %s\n" "$name")"
        fi
    done
}

print_summary() {
    log_info ""
    log_info "=== Summary ==="
    local total=${#operators[@]}
    local missing_count=${#RESULTS_MISSING[@]}
    local issues_count=${#RESULTS_OPWITHISSUES[@]}
    local passed_count=$((total - missing_count - issues_count))
    log_info "$(printf "  %-14s %d\n" "Total:" "$total")"
    log_info "$(printf "  %-14s %d\n" "Passed:" "$passed_count")"
    log_info "$(printf "  %-14s %d\n" "Not found:" "$missing_count")"
    log_info "$(printf "  %-14s %d\n" "With issues:" "$issues_count")"
}

print_issues_detail() {
    log_info ""
    log_info "=== Validation issues detail ==="
    local json_issues_count
    json_issues_count="$(echo "$RESULTS_ISSUES" | jq 'length')"
    if [[ "$json_issues_count" -eq 0 ]]; then
        log_info "  (none)"
    else
        log_info "$(echo "$RESULTS_ISSUES" | jq --indent 2 -r '.[] | "  \(.packageName):", ("    " + (.reasons // [] | .[] | "- " + .))')"
    fi
}

copy_output_files() {
    local out_dat msg_dat
    local out_val="$OUTDIR/validation.jsonl"    msg_val="Validation results"
    local out_log="$OUTDIR/slog.json"           msg_log="Operational log"
    local out_sum="$OUTDIR/summary.txt"         msg_sum="Summary"
    local txt

    if $VALIDATEONLY; then
        out_dat="$OUTDIR/plcc-dump.json"
        msg_dat="Filtered PLCC data"
    else
        out_dat="$OUTDIR/fbc-output.yaml"
        msg_dat="FBC blobs"
    fi
    if [[ ! -f "$FILE_FBC" ]]; then
        log_error "no output file produced (exit code $exit_code)"
    fi
    cp -f "$FILE_FBC" "$out_dat"
    cp -f "$FILE_VAL" "$OUTDIR/validation.jsonl"
    cp -f "$FILE_LOG" "$OUTDIR/slog.json"
    cp -f "$FILE_SUM" "$OUTDIR/summary.txt"

    log_info "Generated files:"
    for txt in sum dat val log; do
        local -n out_ref="out_$txt"
        local -n msg_ref="msg_$txt"
        log_info "$(printf "  %-24s %s" "$out_ref" "$msg_ref")"
    done
}

main() {
    TMPDIR="$(mktemp -d)"
    FILE_FBC="$TMPDIR/fbc.yaml"
    FILE_LOG="$TMPDIR/slog.json"
    FILE_VAL="$TMPDIR/validation.jsonl"
    FILE_SUM="$TMPDIR/summary.txt"
    trap 'rm -rf "$TMPDIR"' EXIT

    parse_args "$@"
    check_dependencies

    mkdir -p "$OUTDIR"

    build_plcc2fbc
    run_plcc2fbc

    RESULTS_MISSING=()
    RESULTS_OPWITHISSUES=()
    RESULTS_ISSUES=""
    parse_results
    derive_operators_from_output

    print_operator_list
    print_summary
    print_issues_detail

    copy_output_files
}

main "$@"
