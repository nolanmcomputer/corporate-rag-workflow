#!/usr/bin/env bash

set -euo pipefail

if [ "$#" -ne 1 ]; then
    echo "Usage: ./preprocess.sh <filename>"
    echo "Example: ./preprocess.sh sample.pdf"
    exit 1
fi

# Load stack configuration.
set -a
source .env
set +a

INPUT_NAME="$1"
RAW_DIR="${VAULT_HOST_PATH}/raw"
PROCESSED_DIR="${VAULT_HOST_PATH}/processed"

INPUT_PATH="${RAW_DIR}/${INPUT_NAME}"

BASENAME="${INPUT_NAME%.*}"
OUTPUT_PATH="${PROCESSED_DIR}/${BASENAME}.chunks.json"
TEMP_PATH="${OUTPUT_PATH}.tmp"

if [ ! -f "$INPUT_PATH" ]; then
    echo "ERROR: Input file not found:"
    echo "  $INPUT_PATH"
    exit 1
fi

mkdir -p "$PROCESSED_DIR"

echo "Preprocessing:"
echo "  input:  $INPUT_PATH"
echo "  output: $OUTPUT_PATH"

curl --fail --silent --show-error \
    -X POST \
    "http://localhost:${UNSTRUCTURED_PORT}/general/v0/general" \
    -H "accept: application/json" \
    -F "files=@${INPUT_PATH}" \
    -F "strategy=fast" \
    -F "chunking_strategy=by_title" \
    -F "max_characters=1200" \
    -F "new_after_n_chars=900" \
    -F "combine_under_n_chars=250" \
    -F "overlap=100" \
    -F "overlap_all=false" \
    -F "multipage_sections=false" \
    -F "include_orig_elements=true" \
    -o "$TEMP_PATH"

# Make sure Unstructured returned a JSON array.
if ! jq -e 'type == "array"' "$TEMP_PATH" >/dev/null; then
    echo "ERROR: Unstructured response was not a JSON array."
    rm -f "$TEMP_PATH"
    exit 1
fi

CHUNK_COUNT=$(jq 'length' "$TEMP_PATH")

if [ "$CHUNK_COUNT" -eq 0 ]; then
    echo "ERROR: Unstructured returned zero chunks."
    rm -f "$TEMP_PATH"
    exit 1
fi

mv "$TEMP_PATH" "$OUTPUT_PATH"

echo "Success: produced ${CHUNK_COUNT} chunk(s)."
echo
jq -r '
  to_entries[] |
  "Chunk \(.key + 1): type=\(.value.type), chars=\(.value.text | length), page=\(.value.metadata.page_number // "n/a"), source=\(.value.metadata.filename // "n/a")"
' "$OUTPUT_PATH"
