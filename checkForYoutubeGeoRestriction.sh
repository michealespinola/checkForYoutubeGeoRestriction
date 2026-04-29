#!/bin/bash
# A script to automagically check for YouTube geo-restrictions.
# Author @michealespinola https://github.com/michealespinola/checkForYoutubeGeoRestriction
# shellcheck disable=SC1112
# shellcheck source=/dev/null
#
# Usage examples:
#   bash ./checkForYoutubeGeoRestriction.sh "https://www.youtube.com/watch?v=_hSiqy9v9FM"
#   bash ./checkForYoutubeGeoRestriction.sh -b "https://youtu.be/_hSiqy9v9FM"
#   bash ./checkForYoutubeGeoRestriction.sh --iso-url "https://raw.githubusercontent.com/lukes/ISO-3166-Countries-with-Regional-Codes/master/slim-2/slim-2.json"
#   bash ./checkForYoutubeGeoRestriction.sh --refresh-iso

set -euo pipefail
IFS=$'\n\t'

# Default manual ISO JSON URL (used only if --iso-url is provided)
DEFAULT_ISO_URL="https://raw.githubusercontent.com/lukes/ISO-3166-Countries-with-Regional-Codes/master/slim-2/slim-2.json"

# Default scrape source (used when generating ISO JSON without --iso-url)
IBAN_COUNTRY_CODES_URL="https://www.iban.com/country-codes"

JSON_NAME="iso-3166-1-slim-2.json"

usage() {
  printf "%s\n" "Usage: $0 [options] \"https://www.youtube.com/watch?v=...\" [more-urls...]"
  printf "%s\n" ""
  printf "%s\n" "Options:"
  printf "%s\n" "  -b                 Show inferred blocked countries"
  printf "%s\n" "  -c                 Show chart output"
  printf "%s\n" "  -j                 Save extracted ytInitialPlayerResponse JSON"
  printf "%s\n" "  --iso-url URL      Download ISO JSON from URL (shim for manual source)"
  printf "%s\n" "  --refresh-iso      Force rebuild/download of ISO JSON cache"
  printf "%s\n" "  -h, --help         Show this help"
}

if [[ $# -lt 1 ]]; then
  usage
  exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SCRIPT_BASE="$(basename -- "${BASH_SOURCE[0]%.*}")"
JSON_PATH="${SCRIPT_DIR}/${JSON_NAME}"




# Translate ISO country codes to names using COUNTRY_MAP
translate_codes() {
  local input="$1"
  local label="$2"
  local NAME=""
  local CODE=""

  if [[ -z "$input" || "$input" == "null" ]]; then
    printf "%s\n" "${label%:}"
    return 0
  fi

  printf "%s\n\n" "$label"

  while IFS= read -r CODE; do
    CODE=${CODE%$'\r'}
    [[ ${CODE//[[:space:]]/} ]] || continue

    NAME="${COUNTRY_NAME_BY_CODE[$CODE]-}"
    if [[ -n "$NAME" ]]; then
      printf "* %s - %s\n" "$CODE" "$NAME"
    else
      printf "* %s - [Unknown]\n" "$CODE"
    fi
  done <<<"$input"
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
missing_tools=0
for cmd in curl jq sed awk grep cut sort comm tr; do
  if ! command -v "$cmd" &>/dev/null; then
    printf "Error: Required command '%s' not found.\n" "$cmd" >&2
    missing_tools=1
  fi
done
if (( missing_tools )); then
  exit 1
fi

html_unescape_stream() {
  awk '''
    function decode_named(s) {
      # Core
      gsub(/&amp;/,    "&",    s)
      gsub(/&lt;/,     "<",    s)
      gsub(/&gt;/,     ">",    s)
      gsub(/&quot;/,   "\"",   s)
      gsub(/&apos;/,   "\047", s)
      gsub(/&nbsp;/,   " ",    s)

      # Latin-1 named entities (symbols/punctuation)
      gsub(/&iexcl;/,  "¡",    s); gsub(/&cent;/,   "¢", s); gsub(/&pound;/,  "£", s); gsub(/&curren;/, "¤", s)
      gsub(/&yen;/,    "¥",    s); gsub(/&brvbar;/, "¦", s); gsub(/&sect;/,   "§", s); gsub(/&uml;/,    "¨", s)
      gsub(/&copy;/,   "©",    s); gsub(/&ordf;/,   "ª", s); gsub(/&laquo;/,  "«", s); gsub(/&not;/,    "¬", s)
      gsub(/&shy;/,    "­",     s); gsub(/&reg;/,    "®", s); gsub(/&macr;/,   "¯", s); gsub(/&deg;/,    "°", s)
      gsub(/&plusmn;/, "±",    s); gsub(/&sup2;/,   "²", s); gsub(/&sup3;/,   "³", s); gsub(/&acute;/,  "´", s)
      gsub(/&micro;/,  "µ",    s); gsub(/&para;/,   "¶", s); gsub(/&middot;/, "·", s); gsub(/&cedil;/,  "¸", s)
      gsub(/&sup1;/,   "¹",    s); gsub(/&ordm;/,   "º", s); gsub(/&raquo;/,  "»", s); gsub(/&frac14;/, "¼", s)
      gsub(/&frac12;/, "½",    s); gsub(/&frac34;/, "¾", s); gsub(/&iquest;/, "¿", s)
      gsub(/&times;/,  "×",    s); gsub(/&divide;/, "÷", s)

      # Latin-1 named entities (uppercase)
      gsub(/&Agrave;/, "À",    s); gsub(/&Aacute;/, "Á", s); gsub(/&Acirc;/,  "Â", s); gsub(/&Atilde;/, "Ã", s)
      gsub(/&Auml;/,   "Ä",    s); gsub(/&Aring;/,  "Å", s); gsub(/&AElig;/,  "Æ", s); gsub(/&Ccedil;/, "Ç", s)
      gsub(/&Egrave;/, "È",    s); gsub(/&Eacute;/, "É", s); gsub(/&Ecirc;/,  "Ê", s); gsub(/&Euml;/,   "Ë", s)
      gsub(/&Igrave;/, "Ì",    s); gsub(/&Iacute;/, "Í", s); gsub(/&Icirc;/,  "Î", s); gsub(/&Iuml;/,   "Ï", s)
      gsub(/&ETH;/,    "Ð",    s); gsub(/&Ntilde;/, "Ñ", s)
      gsub(/&Ograve;/, "Ò",    s); gsub(/&Oacute;/, "Ó", s); gsub(/&Ocirc;/,  "Ô", s); gsub(/&Otilde;/, "Õ", s)
      gsub(/&Ouml;/,   "Ö",    s); gsub(/&Oslash;/, "Ø", s)
      gsub(/&Ugrave;/, "Ù",    s); gsub(/&Uacute;/, "Ú", s); gsub(/&Ucirc;/,  "Û", s); gsub(/&Uuml;/,   "Ü", s)
      gsub(/&Yacute;/, "Ý",    s); gsub(/&THORN;/,  "Þ", s); gsub(/&szlig;/,  "ß", s)

      # Latin-1 named entities (lowercase)
      gsub(/&agrave;/, "à",    s); gsub(/&aacute;/, "á", s); gsub(/&acirc;/,  "â", s); gsub(/&atilde;/, "ã", s)
      gsub(/&auml;/,   "ä",    s); gsub(/&aring;/,  "å", s); gsub(/&aelig;/,  "æ", s); gsub(/&ccedil;/, "ç", s)
      gsub(/&egrave;/, "è",    s); gsub(/&eacute;/, "é", s); gsub(/&ecirc;/,  "ê", s); gsub(/&euml;/,   "ë", s)
      gsub(/&igrave;/, "ì",    s); gsub(/&iacute;/, "í", s); gsub(/&icirc;/,  "î", s); gsub(/&iuml;/,   "ï", s)
      gsub(/&eth;/,    "ð",    s); gsub(/&ntilde;/, "ñ", s)
      gsub(/&ograve;/, "ò",    s); gsub(/&oacute;/, "ó", s); gsub(/&ocirc;/,  "ô", s); gsub(/&otilde;/, "õ", s)
      gsub(/&ouml;/,   "ö",    s); gsub(/&oslash;/, "ø", s)
      gsub(/&ugrave;/, "ù",    s); gsub(/&uacute;/, "ú", s); gsub(/&ucirc;/,  "û", s); gsub(/&uuml;/,   "ü", s)
      gsub(/&yacute;/, "ý",    s); gsub(/&thorn;/,  "þ", s); gsub(/&yuml;/,   "ÿ", s)

      # Additional common named entities outside Latin-1
      gsub(/&OElig;/,  "Œ",    s); gsub(/&oelig;/, "œ", s); gsub(/&Yuml;/,    "Ÿ", s)
      gsub(/&Scaron;/, "Š",    s); gsub(/&scaron;/,"š", s); gsub(/&Zcaron;/,  "Ž", s); gsub(/&zcaron;/,"ž", s)
      gsub(/&fnof;/,   "ƒ",    s)
      gsub(/&circ;/,   "ˆ",    s); gsub(/&tilde;/, "˜", s)
      gsub(/&ensp;/,   " ",    s); gsub(/&emsp;/,  " ", s); gsub(/&thinsp;/,  " ", s)
      gsub(/&zwnj;/,   "",     s); gsub(/&zwj;/,   "",  s); gsub(/&lrm;/,      "", s); gsub(/&rlm;/,    "", s)
      gsub(/&ndash;/,  "–",    s); gsub(/&mdash;/, "—", s)
      gsub(/&lsquo;/,  "‘",    s); gsub(/&rsquo;/, "’", s); gsub(/&sbquo;/,  "‚", s)
      gsub(/&ldquo;/,  "“",    s); gsub(/&rdquo;/, "”", s); gsub(/&bdquo;/,  "„", s)
      gsub(/&dagger;/, "†",    s); gsub(/&Dagger;/,"‡", s); gsub(/&bull;/,   "•", s)
      gsub(/&hellip;/, "…",    s); gsub(/&permil;/,"‰", s)
      gsub(/&prime;/,  "′",    s); gsub(/&Prime;/, "″", s)
      gsub(/&lsaquo;/, "‹",    s); gsub(/&rsaquo;/,"›", s)
      gsub(/&oline;/,  "‾",    s); gsub(/&frasl;/, "⁄", s)
      gsub(/&euro;/,   "€",    s); gsub(/&trade;/, "™", s)
      gsub(/&minus;/,  "−",    s)

      return s
    }

    { print decode_named($0) }
  '''
}

# Build ISO JSON by scraping IBAN country table.
# Output schema matches lukes slim-2 style for the fields we use:
#   [{"name":"Afghanistan","alpha-2":"AF","country-code":"004"}, ...]
build_iso_json_from_iban() {
  # Produce a compact JSON array.
  # Notes:
  # - This is not a full HTML parser. It relies on the current table structure.
  curl -fsSL "$IBAN_COUNTRY_CODES_URL" |
    sed -n '/<tbody>/,/<\/tbody>/p' |
    html_unescape_stream |
    sed 's/<[^>]*>/ /g' |
    awk '
      function trim(s){ gsub(/^[ \t\r\n]+|[ \t\r\n]+$/, "", s); return s }
      BEGIN { first=1; printf("[") }
      NF {
        row[++i]=trim($0)
        if(i==4){
          country=row[1]
          alpha2=row[2]
          numeric=row[4]
          if(!first) printf(",")
          first=0
          printf("{\"name\":\"%s\",\"alpha-2\":\"%s\",\"country-code\":\"%s\"}", country, alpha2, numeric)
          i=0
        }
      }
      END { printf("]\n") }
    '
}

# Get the source/public IP country and format it for STATUS output.
# Empty output is intentional on lookup failure so STATUS output still works offline.
get_origin_country_suffix() {
  local CODE=""
  local NAME=""

  CODE="$(curl -fsSL --max-time 3 https://ipapi.co/country/ 2>/dev/null || true)"
  CODE="$(printf '%s' "$CODE" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

  if [[ ! "$CODE" =~ ^[A-Z][A-Z]$ ]]; then
    return 0
  fi

  NAME="${COUNTRY_NAME_BY_CODE[$CODE]-}"
  if [[ -n "$NAME" ]]; then
    printf ' (%s - %s)' "$CODE" "$NAME"
  else
    printf ' (%s - [Unknown])' "$CODE"
  fi
}

# Write atomically: generate to temp then mv.
write_file_atomic() {
  local dest="$1"
  local tmp="${dest}.tmp.$$"
  cat >"$tmp"
  mv -f -- "$tmp" "$dest"
}

# --- options parsing ---
SHOW_CHART=0
SAVE_JSON=0
SHOW_BLOCKED=0
REFRESH_ISO=0
ISO_URL=""

ARGS_URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) SHOW_BLOCKED=1; shift ;;
    -c) SHOW_CHART=1; shift ;;
    -j) SAVE_JSON=1; shift ;;
    --iso-url)
      shift
      [[ $# -gt 0 ]] || { printf "%s\n" "Error: --iso-url requires a URL argument" >&2; exit 2; }
      ISO_URL="$1"
      shift
      ;;
    --refresh-iso) REFRESH_ISO=1; shift ;;
    -h|--help) usage; exit 0 ;;
    --) shift; break ;;
    -*) ARGS_URLS+=("$1"); shift ;;
    *) ARGS_URLS+=("$1"); shift ;;
  esac
done
# append any remaining args after --
for arg in "$@"; do ARGS_URLS+=("$arg"); done
set -- "${ARGS_URLS[@]}"
# --- end options parsing ---

URLS=("$@")

# Ensure ISO JSON exists (or rebuild/download it), then validate and load maps.
need_iso=0
if [[ $REFRESH_ISO -eq 1 ]]; then
  need_iso=1
elif [[ ! -f "$JSON_PATH" ]]; then
  need_iso=1
fi

if [[ $need_iso -eq 1 ]]; then
  if [[ -n "$ISO_URL" ]]; then
    printf "%s\n\n" "* ISO-3166 JSON refresh requested. Downloading from --iso-url..."
    if ! curl -fsSL --retry 3 --retry-delay 1 -o "$JSON_PATH" "$ISO_URL"; then
      printf "%s\n" "Download failed: $ISO_URL" >&2
      exit 1
    fi
  else
    printf "%s\n\n" "* ISO-3166 JSON refresh requested. Building from IBAN country table..."
    if ! build_iso_json_from_iban | write_file_atomic "$JSON_PATH"; then
      printf "%s\n" "Build failed from: $IBAN_COUNTRY_CODES_URL" >&2
      exit 1
    fi
  fi
fi

# Validate JSON
if ! jq -e . "$JSON_PATH" >/dev/null 2>&1; then
  printf "%s\n" "Invalid JSON in $JSON_PATH." >&2
  printf "%s\n" "Tip: try --refresh-iso or --iso-url \"$DEFAULT_ISO_URL\"" >&2
  exit 1
fi

declare -Ag COUNTRY_NAME_BY_CODE=()
ALL_ISO_CODES=""
while IFS=$'\t' read -r code name; do
  [[ -n "$code" ]] || continue
  COUNTRY_NAME_BY_CODE["$code"]="$name"
  ALL_ISO_CODES+="$code"$'\n'
done < <(jq -r ''' .[] | select(.["alpha-2"] and .name and (.["alpha-2"] | length > 0)) | [.["alpha-2"], .name] | @tsv ''' "$JSON_PATH" | sort -u)
ISOCODE_COUNT=$(count_nonempty_lines <<<"$ALL_ISO_CODES")

ISOCODE_COUNT=$(count_nonempty_lines <<<"$ALL_ISO_CODES")
ORIGIN_COUNTRY="$(get_origin_country_suffix)"

for VIDEO_URL in "${URLS[@]}"; do
  # normalize youtube.com
  VIDEO_URL="$(printf "%s" "$VIDEO_URL" | sed -E 's#https?://(m\.|music\.|gaming\.|youtube-nocookie\.)?youtube\.com#https://www.youtube.com#')"
  # normalize youtu.be
  if [[ "$VIDEO_URL" =~ ^https://youtu\.be/([a-zA-Z0-9_-]+) ]]; then
    ID="${BASH_REMATCH[1]}"
    VIDEO_URL="https://www.youtube.com/watch?v=${ID}"
  else
    ID="$(printf "%s" "$VIDEO_URL" | sed -E 's#.*v=([^&]+).*#\1#')"
  fi

  JSON="$(curl -fsSL "$VIDEO_URL" | grep -oP 'ytInitialPlayerResponse\s*=\s*\{.*?\};' | sed -e 's/^ytInitialPlayerResponse\s*=\s*//' -e 's/;*$//')"
  if [[ "$SAVE_JSON" -eq 1 ]]; then
    printf '%s' "$JSON" | jq -S . >"${SCRIPT_DIR}/${SCRIPT_BASE}.${ID}.json"
  fi

  # defaults
  STATUS="[error]"
  REASON="Could not extract player response JSON"
  SUBREASON=""
  STATUS_REASON=""
  STATUS_SUBREASON=""
  STATUS_MESSAGES=""
  ALLOWED_CODES=""
  BLOCKED_CODES=""
  ALLOWED_COUNT=0
  BLOCKED_COUNT=0

  if [[ -n "$JSON" ]]; then
    mapfile -t JSON_FIELDS < <(
      printf "%s\n" "$JSON" | jq -r '
        (.playabilityStatus.status // "[null]"),
        (.playabilityStatus.reason // "[null]"),
        (.playabilityStatus.errorScreen.playerErrorMessageRenderer.reason.simpleText // "[null]"),
        (
          .playabilityStatus.errorScreen.playerErrorMessageRenderer.subreason.simpleText
          // (.playabilityStatus.errorScreen.playerErrorMessageRenderer.subreason.runs? // [] | map(.text) | join(""))
          // ""
        ),
        (
          .playabilityStatus.messages?
          | if type == "array" then map(tostring) | join(" ")
            elif type == "string" then .
            else ""
            end
        ),
        (.microformat.playerMicroformatRenderer.isUnlisted // "[null]"),
        ((.microformat.playerMicroformatRenderer.availableCountries? // []) | unique | length),
        ((.microformat.playerMicroformatRenderer.availableCountries? // []) | unique[])
      '
    )

    STATUS="${JSON_FIELDS[0]:-[null]}"
    REASON="${JSON_FIELDS[1]:-[null]}"
    STATUS_REASON="${JSON_FIELDS[2]:-[null]}"
    STATUS_SUBREASON="${JSON_FIELDS[3]-}"
    STATUS_MESSAGES="${JSON_FIELDS[4]-}"

    if [[ "$REASON" == "[null]" && "$STATUS_REASON" != "[null]" ]]; then
      REASON="$STATUS_REASON"
    fi

    if [[ "$REASON" == "[null]" && -n "$STATUS_MESSAGES" ]]; then
      REASON="$STATUS_MESSAGES"
    fi

    SUBREASON="$STATUS_SUBREASON"
    if [[ -n "$SUBREASON" && "$SUBREASON" != "[null]" ]]; then
      if [[ "$REASON" == "[null]" ]]; then
        REASON="$SUBREASON"
      else
        REASON="${REASON} - ${SUBREASON}"
      fi
    fi

    ALLOWED_COUNT="${JSON_FIELDS[6]:-0}"
    ALLOWED_CODES=""
    if (( ${#JSON_FIELDS[@]} > 7 )); then
      ALLOWED_CODES="$(printf '%s\n' "${JSON_FIELDS[@]:7}")"
    fi

    HIDDEN="${JSON_FIELDS[5]:-[null]}"
    if [[ "$HIDDEN" == "true" ]]; then
      HIDDEN="(hidden)"
    else
      HIDDEN=""
    fi

    if [[ "$SHOW_BLOCKED" -eq 1 ]]; then
      BLOCKED_CODES="$(comm -23         <(printf '%s\n' "$ALL_ISO_CODES" | LC_ALL=C sort -u)         <(printf '%s\n' "$ALLOWED_CODES" | LC_ALL=C sort -u)
      )"
      BLOCKED_COUNT=$((ISOCODE_COUNT - ALLOWED_COUNT))
    elif [[ "$SHOW_CHART" -eq 1 || ${#URLS[@]} -gt 1 ]]; then
      BLOCKED_COUNT=$((ISOCODE_COUNT - ALLOWED_COUNT))
    fi
  fi

  if [[ "$SHOW_CHART" -eq 1 || ${#URLS[@]} -gt 1 ]]; then
    printf "| Video ID    | Status | Allowed(#)  | Blocked(#) | Reason |\n"
    printf "|-------------|--------|------------:|-----------:|--------|\n"
    printf "| %s          | %s     |          %s |         %s | %s         |\n" "$ID" "$STATUS" "$ALLOWED_COUNT" "$BLOCKED_COUNT" "$REASON"
    printf "\n"
  fi

  if [[ ${#URLS[@]} -eq 1 ]]; then
    printf "%12s: %s\n" "URL" "$VIDEO_URL"
#   printf "%12s: %s %s\n" "STATUS" "$STATUS" "$HIDDEN"
    printf "%12s: %s%s%s\n" "STATUS" "$STATUS" "$ORIGIN_COUNTRY" "${HIDDEN:+ $HIDDEN}"

    if [[ $STATUS == LOGIN_REQUIRED ]]; then
      printf "%12s: %s\n" "AVAILABILITY" "Unknown (authentication required to verify access)"
    elif [[ $STATUS == UNPLAYABLE ]]; then
      if ((${ALLOWED_COUNT:-0} > 0)); then
        printf "%12s: %s\n" "AVAILABILITY" "Limited ($ALLOWED_COUNT of $ISOCODE_COUNT country codes)"
      else
        printf "%12s: %s\n" "AVAILABILITY" "Nowhere (no access is allowed)"
      fi
    elif [[ $STATUS == OK ]]; then
      if ((ALLOWED_COUNT == ISOCODE_COUNT && ISOCODE_COUNT > 0)); then
        printf "%12s: %s\n" "AVAILABILITY" "Everywhere (all countries explicitly specified)"
      elif ((${ALLOWED_COUNT:-0} < 1)); then
        printf "%12s: %s\n" "AVAILABILITY" "Everywhere (no countries explicitly specified)"
      elif ((${ALLOWED_COUNT:-0} < ${ISOCODE_COUNT:-0})); then
        printf "%12s: %s\n" "AVAILABILITY" "Limited ($ALLOWED_COUNT of $ISOCODE_COUNT country codes)"
      fi
    fi

    printf "%12s: %s\n" "REASON" "$REASON"
  fi

  if [[ $STATUS != LOGIN_REQUIRED ]]; then
    printf "\n"
    translate_codes "$ALLOWED_CODES" "Allowed Countries ($ALLOWED_COUNT of $ISOCODE_COUNT):"

    if [[ "$SHOW_BLOCKED" -eq 1 ]]; then
      printf "\n"
      translate_codes "$BLOCKED_CODES" "Blocked Countries ($BLOCKED_COUNT of $ISOCODE_COUNT), inferred from ISO-3166:"
    fi
  fi
done
