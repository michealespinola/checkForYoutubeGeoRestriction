#!/usr/bin/env bash
# A script to automagically check for YouTube geo-restrictions.
# Author @michealespinola https://github.com/michealespinola/checkForYoutubeGeoRestriction
# shellcheck source=/dev/null
# bash /volume1/homes/admin/scripts/bash/checkForYoutubeGeoRestriction.sh "https://www.youtube.com/watch?v=_hSiqy9v9FM"

set -euo pipefail
IFS=$'\n\t'
#

JSON_URL="https://raw.githubusercontent.com/lukes/ISO-3166-Countries-with-Regional-Codes/master/slim-2/slim-2.json"
JSON_NAME="iso-3166-1-slim-2.json"
if [[ $# -lt 1 ]]; then
  printf "%s\n" "Usage: $0 [-b] [-c] [-j] \"https://www.youtube.com/watch?v=...\" [more-urls...]"
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_BASE="$(basename -- "${BASH_SOURCE[0]%.*}")"
JSON_PATH="${SCRIPT_DIR}/${JSON_NAME}"

translate_codes() {
  local input="$1"
  local label="$2"
  printf "%s\n\n" "$label"

  if [[ -z "$input" ]]; then
    printf "* [null]\n"
  else
    while IFS= read -r CODE; do
      NAME=$(printf "%s\n" "$COUNTRY_MAP" | $grep -F "${CODE}|" | cut -d'|' -f2-)
      if [[ -n "$NAME" ]]; then
        printf "* %s - %s\n" "$CODE" "$NAME"
      else
        printf "* %s - [Unknown]\n" "$CODE"
      fi
    done <<<"$input"
  fi
}

# Count non-empty lines from stdin, robust to missing trailing newline and CRLF
count_nonempty_lines() {
  local line n=0
  while IFS= read -r line || [[ -n $line ]]; do
    line=${line%$'\r'} # strip Windows CR if present
    [[ ${line//[[:space:]]/} ]] || continue
    ((n++))
  done
  printf '%d\n' "$n"
}

# check required tools
if [[ "$(uname)" =~ ^(Darwin|DragonFly|.*BSD)$ ]]; then
  sed=gsed
  grep=ggrep
else
  sed=sed
  grep=grep
fi

cmds=(jq curl "$sed" "$grep")
for cmd in "${cmds[@]}"; do
  if ! command -v "$cmd" &>/dev/null; then
    printf "Error: Required command '%s' not found.\n" "$cmd"
    exit 1
  fi
done

if [[ ! -f "$JSON_PATH" ]]; then
  printf "%s" "ISO-3166 JSON not found. Downloading..."
  if ! curl -fsSL --retry 3 --retry-delay 1 -o "$JSON_PATH" "$JSON_URL"; then
    printf "%s" "Download failed."
    exit 1
  fi
fi

# Validate JSON
if ! jq -e . "$JSON_PATH" >/dev/null 2>&1; then
  printf "%s\n" "Invalid JSON in $JSON_PATH."
  exit 1
fi
COUNTRY_MAP="$(jq -r '.[] | select(.["alpha-2"] and .name and (.["alpha-2"]|length>0)) | [ .["alpha-2"], .name ] | join("|")' "$JSON_PATH")"
ALL_ISO_CODES="$(jq -r '.[]."alpha-2" | select(length>0)' "$JSON_PATH" | sort -u)"
ISOCODE_COUNT=$(count_nonempty_lines <<<"$ALL_ISO_CODES")

# --- options parsing ---
SHOW_CHART=0
SAVE_JSON=0
SHOW_BLOCKED=0
ARGS_URLS=()
for arg in "$@"; do
  case "$arg" in
  -b) SHOW_BLOCKED=1 ;;
  -c) SHOW_CHART=1 ;;
  -j) SAVE_JSON=1 ;;
  --)
    shift
    break
    ;;
  -*) ARGS_URLS+=("$arg") ;;
  *) ARGS_URLS+=("$arg") ;;
  esac
done
set -- "${ARGS_URLS[@]}"
# --- end options parsing ---

URLS=("$@")
####if [[ "$SHOW_CHART" -eq 1 || ${#ARGS_URLS[@]} -gt 1 ]]; then
####    printf "| Video ID    | Status | Geo-Blocks? | Allowed(#) | Blocked(#) | Reason |\n"
####    printf "|-------------|--------|-------------|-----------:|-----------:|--------|\n"
####fi

for VIDEO_URL in "${URLS[@]}"; do
  # normalize youtube.com
  VIDEO_URL="$(printf "%s" "$VIDEO_URL" | $sed -E 's#https?://(m\.|music\.|gaming\.|youtube-nocookie\.)?youtube\.com#https://www.youtube.com#')"
  # normalize youtu.be
  if [[ "$VIDEO_URL" =~ ^https://youtu\.be/([a-zA-Z0-9_-]+) ]]; then
    ID="${BASH_REMATCH[1]}"
    VIDEO_URL="https://www.youtube.com/watch?v=${ID}"
  else
    ID="$(printf "%s" "$VIDEO_URL" | $sed -E 's#.*v=([^&]+).*#\1#')"
  fi

  HTML="$(curl -fsSL "$VIDEO_URL")"
  JSON="$(printf "%s" "$HTML" | $grep -oP 'ytInitialPlayerResponse\s*=\s*\{.*?\};' | $sed -e 's/^ytInitialPlayerResponse\s*=\s*//' -e 's/;*$//')"
  if [[ "$SAVE_JSON" -eq 1 ]]; then
    printf '%s' "$JSON" | jq -S . >"${SCRIPT_DIR}/${SCRIPT_BASE}.${ID}.json"
  fi

  # defaults
  STATUS="[error]"
  REASON="Could not extract player response JSON"
  SUBREASON=""
  ALLOWED_CODES=""
  BLOCKED_CODES=""
  ALLOWED_COUNT=0
  BLOCKED_COUNT=0
  if [[ -n "$JSON" ]]; then
    STATUS="$(printf "%s\n" "$JSON" | jq -r '.playabilityStatus.status // "[null]"')"
    HIDDEN="$(printf "%s\n" "$JSON" | jq -r '.microformat.playerMicroformatRenderer.isUnlisted // "[null]"')"
    if [[ "$HIDDEN" == "true" ]]; then
      HIDDEN="(hidden)"
    else
      HIDDEN=""
    fi
    REASON="$(printf "%s\n" "$JSON" | jq -r '.playabilityStatus.reason // "[null]"')"
    SUBREASON="$(printf "%s\n" "$JSON" | jq -r '.playabilityStatus.errorScreen.playerErrorMessageRenderer.subreason.runs? // [] | map(.text) | join("")')"
    [[ -n "$SUBREASON" ]] && REASON="${REASON} - ${SUBREASON}"
    ALLOWED_CODES="$(printf "%s\n" "$JSON" | jq -r '.microformat.playerMicroformatRenderer.availableCountries? // empty | .[]' | sort -u)"
    #ALLOWED_COUNT="$(printf "%s\n" "$ALLOWED_CODES" | $sed '/^$/d' | wc -l | tr -d ' ')"
    BLOCKED_CODES="$(comm -23 <(printf "%s\n" "$ALL_ISO_CODES") <(printf "%s\n" "$ALLOWED_CODES"))"
    #BLOCKED_COUNT="$(printf "%s\n" "$BLOCKED_CODES" | $sed '/^$/d' | wc -l | tr -d ' ')"
    # Existing:
    # ALLOWED_COUNT=$(printf "%s" "$ALLOWED_CODES" | wc -l)
    # BLOCKED_COUNT=$(printf "%s" "$BLOCKED_CODES" | wc -l)

    # New:
    ALLOWED_COUNT=$(count_nonempty_lines <<<"$ALLOWED_CODES")
    BLOCKED_COUNT=$(count_nonempty_lines <<<"$BLOCKED_CODES")

    #GEO_BLOCKED=No
    #[[ $STATUS == OK ]] && (( ${ALLOWED_COUNT:-0} < ${ISOCODE_COUNT:-0} )) && GEO_BLOCKED=Yes
  fi

  if [[ "$SHOW_CHART" -eq 1 || ${#URLS[@]} -gt 1 ]]; then
    printf "| Video ID    | Status | Allowed(#)  | Blocked(#) | Reason |\n"
    printf "|-------------|--------|------------:|-----------:|--------|\n"
    printf "| %s          | %s     |          %s |         %s | %s         |\n" "$ID" "$STATUS" "$ALLOWED_COUNT" "$BLOCKED_COUNT" "$REASON"
    printf "\n"
  fi

  ####if [[ ${#ARGS_URLS[@]} -eq 1 ]]; then
  ####    printf "|    |    |\n"
  ####    printf "|---:|----|\n"
  ####    printf "| %s | %s |\n" "   URL" "$VIDEO_URL"
  ####    printf "| %s | %s |\n" "STATUS" "$STATUS"
  ####    printf "| %s | %s |\n" "REASON" "$REASON"
  ####    printf "\n"
  ####fi
  if [[ ${#URLS[@]} -eq 1 ]]; then
    printf "%12s: %s\n" "URL" "$VIDEO_URL"
    printf "%12s: %s %s\n" "STATUS" "$STATUS" "$HIDDEN"
    if [[ $STATUS == UNPLAYABLE ]]; then
      if ((${ALLOWED_COUNT:-0} > 0)); then
        printf "%12s: %s\n" "AVAILABILITY" "Limited ($ALLOWED_COUNT of $ISOCODE_COUNT country codes)"
      else
        printf "%12s: %s\n" "AVAILABILITY" "Nowhere (No access is allowed)"
      fi
    elif [[ $STATUS == OK ]]; then
      if ((ALLOWED_COUNT == ISOCODE_COUNT && ISOCODE_COUNT > 0)); then
        printf "%12s: %s\n" "AVAILABILITY" "Everywhere (All countries explicitly specified)"
      elif ((${ALLOWED_COUNT:-0} < 1)); then
        printf "%12s: %s\n" "AVAILABILITY" "Everywhere (No countries explicitly specified)"
      elif ((${ALLOWED_COUNT:-0} < ${ISOCODE_COUNT:-0})); then
        printf "%12s: %s\n" "AVAILABILITY" "Limited ($ALLOWED_COUNT of $ISOCODE_COUNT country codes)"
      fi
    fi
    printf "%12s: %s\n" "REASON" "$REASON"
    #DEBUG  printf "%12s: %s of %s\n" "EXTRA" "$ALLOWED_COUNT" "$ISOCODE_COUNT"
  fi
  # The allowed list is explicitly listed by YouTube.
  # The blocked list is inferred based on all other known registered countries that are applicably registered as Internet entities.
  printf "\n"
  translate_codes "$ALLOWED_CODES" "Allowed Countries ($ALLOWED_COUNT of $ISOCODE_COUNT):"
  if [[ "$SHOW_BLOCKED" -eq 1 ]]; then
    printf "\n"
    translate_codes "$BLOCKED_CODES" "Blocked Countries ($BLOCKED_COUNT of $ISOCODE_COUNT), inferred from ISO-3166:"
  fi
done
