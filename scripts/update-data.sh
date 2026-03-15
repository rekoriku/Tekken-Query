#!/usr/bin/env bash
# Fetch raw Tekken 8 frame data from tekkendocs GitHub repo,
# then convert each character to clean CSV via our verified parser.
#
# No hardcoded character list — discovers all characters from GitHub.
# Display names are auto-generated from directory names:
#   "devil-jin" → "Devil Jin", "jack-8" → "Jack-8"
#
# Usage:
#   ./scripts/update-data.sh            # update all characters
#   ./scripts/update-data.sh jin kazuya  # update specific characters only
#
# Requires: curl, jq
# Run from project root.
set -euo pipefail

BASE_URL="https://raw.githubusercontent.com/pbruvoll/tekkendocs/refs/heads/main/data/wavuConvertedCsv"
API_URL="https://api.github.com/repos/pbruvoll/tekkendocs/contents/data/wavuConvertedCsv"
COMMITS_URL="https://api.github.com/repos/pbruvoll/tekkendocs/commits?path=data/wavuConvertedCsv&per_page=1"
RAW_DIR="data/raw"
CLEAN_DIR="data/clean"
MANIFEST="data/characters.json"
BINARY=".lake/build/bin/tekken_query"

# Ensure directories exist
mkdir -p "$RAW_DIR" "$CLEAN_DIR"

# Check binary exists
if [ ! -f "$BINARY" ]; then
  echo "Binary not found at $BINARY — run 'lake build' first."
  exit 1
fi

# Convert character ID to display name: "devil-jin" → "Devil Jin"
to_display_name() {
  echo "$1" | tr '-' ' ' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) tolower(substr($i,2))}1'
}

# Get character list
if [ $# -gt 0 ]; then
  # Specific characters from arguments
  CHARACTERS="$*"
  echo "Updating $# character(s): $CHARACTERS"
else
  # Fetch full list from GitHub API — no hardcoded fallback
  echo "Fetching character list from GitHub..."
  CHARACTERS=$(curl -sf "$API_URL" | jq -r '.[] | select(.type == "dir") | .name' | grep -iv '^test$' | sort)

  if [ -z "$CHARACTERS" ]; then
    echo "Failed to fetch character list. Check network or GitHub API rate limit."
    exit 1
  fi

  COUNT=$(echo "$CHARACTERS" | wc -w)
  echo "Found $COUNT characters"

  # Detect new characters
  for char in $CHARACTERS; do
    if [ ! -f "$RAW_DIR/$char.csv" ]; then
      echo "  NEW: $char ($(to_display_name "$char"))"
    fi
  done
fi

echo ""

# Counters
UPDATED=0
FAILED=0
SKIPPED=0

# Build manifest entries
MANIFEST_ENTRIES=""

for char in $CHARACTERS; do
  RAW_FILE="$RAW_DIR/$char.csv"
  CLEAN_FILE="$CLEAN_DIR/$char.csv"

  # Try primary URL, then fallback
  PRIMARY_URL="$BASE_URL/$char/$char-special.csv"
  FALLBACK_URL="$BASE_URL/$char.csv"

  if curl -sf "$PRIMARY_URL" -o "$RAW_FILE.tmp" 2>/dev/null; then
    mv "$RAW_FILE.tmp" "$RAW_FILE"
  elif curl -sf "$FALLBACK_URL" -o "$RAW_FILE.tmp" 2>/dev/null; then
    mv "$RAW_FILE.tmp" "$RAW_FILE"
  else
    echo "  SKIP $char (fetch failed)"
    rm -f "$RAW_FILE.tmp"
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Convert to clean CSV
  if lake env "$BINARY" --export "$RAW_FILE" > "$CLEAN_FILE" 2>/dev/null; then
    MOVES=$(tail -n +2 "$CLEAN_FILE" | wc -l)
    DISPLAY_NAME=$(to_display_name "$char")
    echo "  OK   $char ($MOVES moves)"
    UPDATED=$((UPDATED + 1))

    # Add to manifest
    if [ -n "$MANIFEST_ENTRIES" ]; then
      MANIFEST_ENTRIES="$MANIFEST_ENTRIES,"
    fi
    MANIFEST_ENTRIES="$MANIFEST_ENTRIES
    {\"id\": \"$char\", \"name\": \"$DISPLAY_NAME\", \"moves\": $MOVES}"
  else
    echo "  FAIL $char (parse error)"
    FAILED=$((FAILED + 1))
  fi
done

# Fetch latest commit SHA for version tracking
COMMIT_SHA=$(curl -sf "$COMMITS_URL" | jq -r '.[0].sha // empty' || true)
COMMIT_MSG=$(curl -sf "$COMMITS_URL" | jq -r '.[0].commit.message // empty' | head -1 || true)

if [ -z "$COMMIT_SHA" ]; then
  echo "Warning: could not fetch commit SHA (rate limit?)"
  COMMIT_SHA="unknown"
  COMMIT_MSG=""
fi

# Write manifest (auto-generated character registry)
cat > "$MANIFEST" <<EOF
{
  "updated": "$(date -u +%Y-%m-%dT%H:%M:%SZ)",
  "source": "pbruvoll/tekkendocs",
  "commit_sha": "$COMMIT_SHA",
  "commit_message": "$COMMIT_MSG",
  "characters": [$MANIFEST_ENTRIES
  ]
}
EOF

echo ""
echo "Done: $UPDATED ok, $FAILED failed, $SKIPPED skipped"
echo "Manifest: $MANIFEST"
echo "Raw:      $RAW_DIR/"
echo "Clean:    $CLEAN_DIR/"
