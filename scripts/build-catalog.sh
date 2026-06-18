#!/usr/bin/env bash
#
# Build an augmented OLM catalog image with per-operator lifecycle metadata.
#
# Fetches operator lifecycle data from the PLCC API, extracts the base catalog
# image, generates lifecycle.json for each valid operator, and builds a new
# image with the lifecycle files overlaid onto /configs/.
#
# Usage:
#   ./scripts/build-catalog.sh <dest-image>
#
# Examples:
#   ./scripts/build-catalog.sh quay.io/myorg/redhat-operator-index:v4.22-lifecycle
#   CONTAINER_TOOL=podman ./scripts/build-catalog.sh localhost/catalog:latest
#
# Environment variables:
#   CATALOG_BASE_IMAGE  Base catalog image (default: registry.redhat.io/redhat/redhat-operator-index:v4.22)
#   CONTAINER_TOOL      Container tool: docker or podman (default: docker)
#
# Prerequisites: make build, docker/podman, jq
#
# Intermediate artifacts are cached in _build/ — re-runs skip fetching and
# extraction. Delete _build/ to force a clean run.
#
set -euo pipefail

CATALOG_BASE_IMAGE="${CATALOG_BASE_IMAGE:-registry.redhat.io/redhat/redhat-operator-index:v4.22}"
CONTAINER_TOOL="${CONTAINER_TOOL:-docker}"
BUILDDIR="_build"
PLCC_CACHE="${BUILDDIR}/plcc-cache.json"
CATALOG_DIR="${BUILDDIR}/catalog"
CONFIGS_DIR="${CATALOG_DIR}/configs"
LIFECYCLE_DIR="${CATALOG_DIR}/lifecycle-overlay"

DEST_IMAGE="${1:-}"

usage() {
    echo "Usage: $0 <dest-image>"
    echo ""
    echo "  dest-image   Target image reference (e.g. quay.io/user/redhat-operator-index:v4.22-lifecycle)"
    echo ""
    echo "Environment variables:"
    echo "  CATALOG_BASE_IMAGE  Base catalog image (default: registry.redhat.io/redhat/redhat-operator-index:v4.22)"
    echo "  CONTAINER_TOOL      Container tool (default: docker)"
    exit 1
}

info()  { echo "==> $*"; }
warn()  { echo "WARNING: $*" >&2; }
error() { echo "ERROR: $*" >&2; exit 1; }

validate_prerequisites() {
    info "Checking prerequisites..."
    command -v "${CONTAINER_TOOL}" >/dev/null 2>&1 || error "${CONTAINER_TOOL} is not installed"
    command -v jq >/dev/null 2>&1 || error "jq is not installed"
    [[ -x bin/plcc2fbc ]] || error "bin/plcc2fbc not found. Run 'make build' first."
}

fetch_plcc_data() {
    if [[ -f "${PLCC_CACHE}" ]]; then
        info "Using cached PLCC data from ${PLCC_CACHE}"
        return
    fi
    info "Fetching PLCC data..."
    mkdir -p "${BUILDDIR}"
    bin/plcc2fbc --dump-plcc -l "${BUILDDIR}/plcc-fetch.log" "${PLCC_CACHE}"
    info "PLCC data cached at ${PLCC_CACHE}"
}

extract_catalog() {
    if [[ -d "${CONFIGS_DIR}" ]]; then
        info "Using previously extracted catalog from ${CONFIGS_DIR}"
        return
    fi
    info "Extracting /configs/ from ${CATALOG_BASE_IMAGE}..."
    mkdir -p "${CATALOG_DIR}"

    local cid
    cid=$("${CONTAINER_TOOL}" create "${CATALOG_BASE_IMAGE}" /bin/true)
    trap "${CONTAINER_TOOL} rm ${cid} >/dev/null 2>&1" EXIT
    "${CONTAINER_TOOL}" cp "${cid}:/configs" "${CONFIGS_DIR}"
    "${CONTAINER_TOOL}" rm "${cid}" >/dev/null
    trap - EXIT
    info "Extracted $(ls -1 "${CONFIGS_DIR}" | wc -l) operator directories"
}

diagnose() {
    info "Cross-referencing catalog operators with PLCC data..."

    # 4a: Which catalog operators have PLCC data?
    jq -r '.data[].package | select(. != "")' "${PLCC_CACHE}" | sort -u > "${BUILDDIR}/plcc-packages.txt"
    ls -1 "${CONFIGS_DIR}" | sort > "${BUILDDIR}/catalog-packages.txt"
    comm -12 "${BUILDDIR}/plcc-packages.txt" "${BUILDDIR}/catalog-packages.txt" > "${BUILDDIR}/matched-packages.txt"

    local plcc_count catalog_count matched_count
    plcc_count=$(wc -l < "${BUILDDIR}/plcc-packages.txt")
    catalog_count=$(wc -l < "${BUILDDIR}/catalog-packages.txt")
    matched_count=$(wc -l < "${BUILDDIR}/matched-packages.txt")

    echo ""
    echo "--- Package counts ---"
    echo "  PLCC packages (with non-empty name): ${plcc_count}"
    echo "  Catalog operators:                   ${catalog_count}"
    echo "  Matched (in both):                   ${matched_count}"
    echo ""

    # PLCC packages NOT in catalog
    local plcc_only
    plcc_only=$(comm -23 "${BUILDDIR}/plcc-packages.txt" "${BUILDDIR}/catalog-packages.txt")
    if [[ -n "${plcc_only}" ]]; then
        echo "--- PLCC packages NOT in catalog (expected, informational) ---"
        echo "${plcc_only}" | sed 's/^/  /'
        echo ""
    fi

    # 4b: Which matched operators produce valid FBC vs get dropped?
    info "Generating FBC for all matched operators..."
    local matched_list
    matched_list=$(paste -sd, "${BUILDDIR}/matched-packages.txt")

    local rc=0
    bin/plcc2fbc -i "${PLCC_CACHE}" -p "${matched_list}" -o json \
        -l "${BUILDDIR}/generate.log" \
        "${BUILDDIR}/all-lifecycles.json" 2>"${BUILDDIR}/validation.log" || rc=$?

    if [[ ${rc} -eq 2 ]]; then
        warn "No FBC data generated at all from matched packages"
        echo "Check ${BUILDDIR}/validation.log for details"
        return 1
    elif [[ ${rc} -ne 0 ]]; then
        error "plcc2fbc failed with exit code ${rc}"
    fi

    # Extract produced package names
    jq -r 'if type == "array" then .[].package else .package end' \
        "${BUILDDIR}/all-lifecycles.json" | sort > "${BUILDDIR}/produced-packages.txt"

    local produced_count
    produced_count=$(wc -l < "${BUILDDIR}/produced-packages.txt")

    # Dropped = matched but not produced
    comm -23 "${BUILDDIR}/matched-packages.txt" "${BUILDDIR}/produced-packages.txt" \
        > "${BUILDDIR}/dropped-packages.txt"
    local dropped_count
    dropped_count=$(wc -l < "${BUILDDIR}/dropped-packages.txt")

    echo "--- FBC generation results ---"
    echo "  Valid FBC produced: ${produced_count}"
    echo "  Dropped by filters: ${dropped_count}"
    echo ""

    if [[ ${dropped_count} -gt 0 ]]; then
        echo "--- Dropped packages (review ${BUILDDIR}/validation.log for reasons) ---"
        while IFS= read -r pkg; do
            local reasons
            reasons=$(grep -F "\"package\":\"${pkg}\"" "${BUILDDIR}/validation.log" 2>/dev/null | head -1 || echo "  (no validation entry found)")
            echo "  ${pkg}:"
            echo "    ${reasons}"
        done < "${BUILDDIR}/dropped-packages.txt"
        echo ""
    fi

    echo "--- Operators that WILL get lifecycle.json ---"
    cat "${BUILDDIR}/produced-packages.txt" | sed 's/^/  /'
    echo ""

    info "Diagnostic complete. Review the output above."
    info "Validation log: ${BUILDDIR}/validation.log"
    info "Generation log: ${BUILDDIR}/generate.log"
}

generate_lifecycle_files() {
    info "Generating per-operator lifecycle.json files..."
    rm -rf "${LIFECYCLE_DIR}"
    local count=0 failures=0
    while IFS= read -r pkg; do
        if [[ -d "${CONFIGS_DIR}/${pkg}" ]]; then
            mkdir -p "${LIFECYCLE_DIR}/${pkg}"
            if bin/plcc2fbc -i "${PLCC_CACHE}" -p "${pkg}" -o json-pretty \
                "${LIFECYCLE_DIR}/${pkg}/lifecycle.json" 2>/dev/null; then
                count=$((count + 1))
            else
                failures=$((failures + 1))
                warn "Failed to generate lifecycle.json for ${pkg}"
            fi
        fi
    done < "${BUILDDIR}/produced-packages.txt"
    info "Generated lifecycle.json for ${count} operators (${failures} failures)"
}

build_image() {
    [[ -n "${DEST_IMAGE}" ]] || error "No destination image specified"

    info "Building augmented catalog image..."
    "${CONTAINER_TOOL}" build -t "${DEST_IMAGE}" \
        --build-arg "CATALOG_IMAGE=${CATALOG_BASE_IMAGE}" \
        -f scripts/Dockerfile.catalog "${CATALOG_DIR}"
    info "Image built: ${DEST_IMAGE}"
}

push_image() {
    [[ -n "${DEST_IMAGE}" ]] || error "No destination image specified"
    info "Pushing ${DEST_IMAGE}..."
    "${CONTAINER_TOOL}" push "${DEST_IMAGE}"
    info "Push complete"
}

# --- Main ---

if [[ -z "${DEST_IMAGE}" ]]; then
    usage
fi

validate_prerequisites
fetch_plcc_data
extract_catalog
diagnose || error "Diagnosis failed — no valid FBC data to build from"
generate_lifecycle_files
build_image
# push_image
