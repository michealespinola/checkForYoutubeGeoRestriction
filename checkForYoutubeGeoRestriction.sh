#!/usr/bin/env bash
# A script to automagically check for YouTube geo-restrictions.
# Author @michealespinola https://github.com/michealespinola/checkForYoutubeGeoRestriction
# shellcheck disable=SC1112,SC2034
# shellcheck source=/dev/null
#
# Usage examples:
#   bash ./checkForYoutubeGeoRestriction.sh "https://www.youtube.com/watch?v=_hSiqy9v9FM"
#   bash ./checkForYoutubeGeoRestriction.sh -b "https://youtu.be/_hSiqy9v9FM"
#   bash ./checkForYoutubeGeoRestriction.sh --iso-url "https://raw.githubusercontent.com/lukes/ISO-3166-Countries-with-Regional-Codes/master/slim-2/slim-2.json"
#   bash ./checkForYoutubeGeoRestriction.sh --refresh-iso

SCRIPT_VERSION=2.2.0

set -euo pipefail
IFS=$'\n\t'

get_source_info() {                                                                               # FUNCTION TO GET SOURCE SCRIPT INFORMATION
  srcScrpVer="${SCRIPT_VERSION}"                                                                  # Source script version
  srcFullDir="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"                             # Source script absolute physical directory
  srcFullPth="${srcFullDir}/$(basename -- "${BASH_SOURCE[0]}")"                                   # Source script absolute path
  srcFileNam="${srcFullPth##*/}"                                                                  # Source script file name
}
get_source_info

# Primary ISO country-code JSON source
DEBIAN_ISO_CODES_URL="https://salsa.debian.org/iso-codes-team/iso-codes/-/raw/main/data/iso_3166-1.json"

# Fallback scrape source
IBAN_COUNTRY_CODES_URL="https://www.iban.com/country-codes"

# Default manual ISO JSON URL shown in error tips
DEFAULT_ISO_URL="$DEBIAN_ISO_CODES_URL"

JSON_NAME="geo-cache.json"

usage() {
  printf "%s\n\n" "Usage: $srcFileNam [options] [URL]"
  printf "%s\n"   "Options:"
  print_wrap 18 2  "  -b              " "Show only inferred blocked countries per ISO-3166"
  print_wrap 18 2  "  -f AA,BB,CC,... " "Show only specific country codes that are allowed"
  print_wrap 18 2  "  -j              " "Save Youtube JSON response"
  print_wrap 18 2  "  -q              " "Quiet output; print only comma-separated country codes"
  print_wrap 18 2  "  --iso-url URL   " "Download ISO-3166 JSON from URL (manual shim)"
  print_wrap 18 2  "  --refresh-iso   " "Force rebuild/download of geo cache country list from Debian iso-codes, with IBAN fallback"
  print_wrap 18 2  "  -h, --help      " "Show this help"
}

get_term_cols() {                                                                                 # FUNCTION TO GET TERMINAL COLUMN WIDTH
  local cols
  cols=$(stty size 2>/dev/null | awk '{print $2}')                                                # 1) stty (works when stdout is a tty)
  if [[ $cols =~ ^[0-9]+$ ]] && (( cols > 0 )); then
    printf '%s\n' "$cols"
    return
  fi
  if [[ ${COLUMNS:-} =~ ^[0-9]+$ ]] && (( COLUMNS > 0 )); then                                    # 2) COLUMNS env var (sometimes set by shells)
    printf '%s\n' "$COLUMNS"
    return
  fi
  printf '80\n'                                                                                   # 3) Standard fallback
}

print_wrap() { # <resume_col> <right_margin> <left_text> <right_text>                             # FUNCTION TO PRINT WRAPPED HELP LINE
  local resume_col=$1
  local right_margin=$2
  local cols wrap wrapped text_col

  cols=$(get_term_cols)
  text_col=$((resume_col + 1))
  wrap=$((cols - right_margin - text_col))
  ((wrap < 20)) && wrap=20                                                                        # Sanity floor

  wrapped=$(printf '%s\n' "$4" | fold -s -w "$wrap")

  printf '%'"$resume_col"'s %s\n' \
    "$3" \
    "$(printf '%s\n' "$wrapped" | sed -n '1p')" >&2                                               # First line: left column + first wrapped line

  printf '%s\n' "$wrapped" |                                                                      # Continuation lines:
    sed -n '2,$p' |                                                                               # Right margin wrap
    awk -v col="$text_col" '{ printf "%*s%s\n", col, "", $0 }' >&2                                # Indent to resume column
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

normalize_country_code_list() {
  local input="$1"

  printf '%s\n' "$input" |
    tr ',' '\n' |
    tr '[:lower:]' '[:upper:]' |
    sed 's/^[[:space:]]*//;s/[[:space:]]*$//' |
    awk '
      /^[A-Z][A-Z]$/ {
        if (!seen[$0]++) {
          print
        }
        next
      }

      NF {
        bad=1
      }

      END {
        exit bad
      }
    ' |
    LC_ALL=C sort -u
}

validate_country_codes_known() {
  local input="$1"
  local unknown_codes=""

  unknown_codes="$(
    comm -23 \
      <(printf '%s\n' "$input" | LC_ALL=C sort -u) \
      <(printf '%s\n' "$ALL_ISO_CODES" | LC_ALL=C sort -u)
  )"

  if [[ -n "$unknown_codes" ]]; then
    printf "%s\n" "Error: Unsupported ISO-3166 country code supplied to -f:" >&2

    while IFS= read -r code; do
      [[ -n "$code" ]] || continue
      printf "  %s\n" "$code" >&2
    done <<<"$unknown_codes"

    return 1
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

join_lines_csv() {
  awk '
    NF {
      printf "%s%s", sep, $0
      sep=","
    }

    END {
      printf "\n"
    }
  ' <<<"$1"
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

validate_iso_country_json() {
  local json=""
  local valid_count=""

  json="$(cat)"

  if [[ -z "${json//[[:space:]]/}" ]]; then
    printf "%s\n" "Error: ISO country list is empty." >&2
    return 1
  fi

  if ! valid_count="$(
    jq -r '
      if type == "array" then
        [.[] | select(.["alpha-2"] and (.["alpha-2"] | test("^[A-Z]{2}$")))]
      elif type == "object" and (.countries | type == "array") then
        [.countries[] | select(.["alpha-2"] and (.["alpha-2"] | test("^[A-Z]{2}$")))]
      else
        []
      end
      | length
    ' <<<"$json" 2>/dev/null
  )"; then
    printf "%s\n" "Error: ISO country list is not valid JSON." >&2
    return 1
  fi

  if [[ ! "$valid_count" =~ ^[0-9]+$ || "$valid_count" -lt 1 ]]; then
    printf "%s\n" "Error: ISO country list does not contain usable alpha-2 country codes." >&2
    return 1
  fi

  printf '%s\n' "$json"
}

# Build ISO JSON from Debian iso-codes.
# Input schema:
#   {"3166-1":[{"alpha_2":"AF","alpha_3":"AFG","name":"Afghanistan","numeric":"004"}, ...]}
# Output schema matches the slim format used by this script:
#   [{"name":"Afghanistan","alpha-2":"AF","country-code":"004"}, ...]
build_iso_json_from_debian_iso_codes() {
  curl -fsSL --retry 3 --retry-delay 1 "$DEBIAN_ISO_CODES_URL" |
    jq -c '
      if type == "object" and (.["3166-1"] | type == "array") then
        .["3166-1"]
      else
        error("expected Debian iso-codes object with 3166-1 array")
      end
      | map(
          select(.alpha_2 and .name and .numeric)
          | select(.alpha_2 | test("^[A-Z]{2}$"))
          | {
              name: (.common_name // .name),
              "alpha-2": .alpha_2,
              "country-code": .numeric
            }
        )
      | unique_by(."alpha-2")
      | sort_by(."alpha-2")
    '
}

# Write ISO country data into the unified geo cache, preserving existing origin data.
# Write ISO country data into the unified geo cache, preserving existing origin data.
write_country_cache_atomic() {
  local dest="$1"
  local provider="$2"
  local source_url="$3"
  local tmp="${dest}.tmp.$$"
  local origin="{}"
  local checked_at=""
  local checked_epoch=""
  local json=""

  json="$(cat)"

  if [[ -z "${json//[[:space:]]/}" ]]; then
    printf "%s\n" "Error: no ISO country JSON was provided to cache writer." >&2
    return 1
  fi

  checked_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  checked_epoch="$(date -u '+%s')"

  if [[ -s "$dest" ]]; then
    origin="$(
      jq -c '
        if type == "object" and (.origin | type == "object") then
          .origin
        else
          {}
        end
      ' "$dest" 2>/dev/null || printf '{}'
    )"
  fi

  if ! jq -e 'type == "object"' >/dev/null 2>&1 <<<"$origin"; then
    origin="{}"
  fi

  if jq -e \
    --arg checked_at "$checked_at" \
    --arg checked_epoch "$checked_epoch" \
    --arg provider "$provider" \
    --arg source_url "$source_url" \
    --argjson origin "$origin" '
      (
        if type == "array" then .
        elif type == "object" and (.countries | type == "array") then .countries
        else error("expected ISO country array or geo cache object with countries array")
        end
      ) as $countries
      | {
          cache: {
            schema: 2,
            countries_updated_at: $checked_at
          },
          origin: $origin,
          countries_meta: {
            provider: $provider,
            source_url: $source_url,
            checked_at: $checked_at,
            checked_epoch: ($checked_epoch | tonumber),
            count: ($countries | length)
          },
          countries: $countries
        }
    ' <<<"$json" >"$tmp"; then
    mv -f -- "$tmp" "$dest"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

get_cached_origin_ip() {
  jq -r 'if type == "object" then (.origin.external_ip // "") else "" end' "$JSON_PATH" 2>/dev/null
}

get_cached_origin_country_code() {
  jq -r 'if type == "object" then (.origin.country_code // "") else "" end' "$JSON_PATH" 2>/dev/null
}

get_cached_origin_lookup_failed_epoch() {
  jq -r 'if type == "object" then (.origin.lookup_failed_epoch // "0") else "0" end' "$JSON_PATH" 2>/dev/null
}

update_origin_cache() {
  local external_ip="$1"
  local country_code="$2"
  local result="$3"
  local checked_at=""
  local checked_epoch=""
  local tmp="${JSON_PATH}.tmp.$$"

  checked_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"
  checked_epoch="$(date -u '+%s')"

  if jq \
    --arg external_ip "$external_ip" \
    --arg country_code "$country_code" \
    --arg ip_provider "api.ipify.org" \
    --arg country_provider "ipapi.co" \
    --arg checked_at "$checked_at" \
    --arg checked_epoch "$checked_epoch" \
    --arg result "$result" '
      if type == "array" then
        {
          cache: {
            schema: 2
          },
          origin: {},
          countries: .
        }
      else
        .
      end
      | .cache.schema = 2
      | .origin.external_ip = $external_ip
      | .origin.country_code = $country_code
      | .origin.ip_provider = $ip_provider
      | .origin.country_provider = $country_provider
      | .origin.checked_at = $checked_at
      | .origin.checked_epoch = ($checked_epoch | tonumber)
      | .origin.result = $result
      | if $result == "failure" then
          .origin.lookup_failed_at = $checked_at
          | .origin.lookup_failed_epoch = ($checked_epoch | tonumber)
        else
          del(.origin.lookup_failed_at, .origin.lookup_failed_epoch)
        end
    ' "$JSON_PATH" >"$tmp"; then
    mv -f -- "$tmp" "$JSON_PATH"
  else
    rm -f -- "$tmp"
    return 1
  fi
}

get_current_external_ip() {
  local ip=""

  ip="$(curl -fsSL --connect-timeout 5 --max-time 10 https://api.ipify.org/ 2>/dev/null || true)"
  ip="$(printf '%s' "$ip" | tr -d '[:space:]')"

  if [[ "$ip" =~ ^[0-9A-Fa-f:.]+$ ]]; then
    printf '%s' "$ip"
  fi
}

lookup_origin_country_code() {
  local code=""

  code="$(curl -fsSL --connect-timeout 5 --max-time 10 https://ipapi.co/country/ 2>/dev/null || true)"
  code="$(printf '%s' "$code" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

  if [[ "$code" =~ ^[A-Z][A-Z]$ ]]; then
    printf '%s' "$code"
  fi
}

# Get the source/public IP country.
# Uses the cached country code when the cached external IP still matches.
get_origin_country() {
  local current_ip=""
  local cached_ip=""
  local code=""
  local name=""
  local failed_epoch="0"
  local now_epoch=""
  local failure_cooldown=$((6 * 60 * 60))

  current_ip="$(get_current_external_ip)"
  cached_ip="$(get_cached_origin_ip)"
  code="$(get_cached_origin_country_code)"
  code="$(printf '%s' "$code" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

  if [[ -z "$current_ip" ]]; then
    if [[ ! "$code" =~ ^[A-Z][A-Z]$ ]]; then
      return 0
    fi
  elif [[ "$current_ip" != "$cached_ip" || ! "$code" =~ ^[A-Z][A-Z]$ ]]; then
    failed_epoch="$(get_cached_origin_lookup_failed_epoch)"
    now_epoch="$(date -u '+%s')"

    if [[ "$current_ip" == "$cached_ip" && "$failed_epoch" =~ ^[0-9]+$ && $((now_epoch - failed_epoch)) -lt $failure_cooldown ]]; then
      return 0
    fi

    code="$(lookup_origin_country_code)"
    code="$(printf '%s' "$code" | tr -d '[:space:]' | tr '[:lower:]' '[:upper:]')"

    if [[ "$code" =~ ^[A-Z][A-Z]$ ]]; then
      update_origin_cache "$current_ip" "$code" "success"
    else
      update_origin_cache "$current_ip" "" "failure"
      return 0
    fi
  fi

  name="${COUNTRY_NAME_BY_CODE[$code]-}"
  if [[ -n "$name" ]]; then
    printf '%s - %s' "$code" "$name"
  else
    printf '%s - [Unknown]' "$code"
  fi
}

# --- options parsing ---
SAVE_JSON=0
SHOW_BLOCKED=0
REFRESH_ISO=0
FILTER=0
QUIET=0
FILTER_CODES=""
FILTER_COUNT=0
ISO_URL=""

ARGS_URLS=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    -b) SHOW_BLOCKED=1; shift ;;
    -f|--filter)
      shift
      [[ $# -gt 0 ]] || { printf "%s\n" "Error: -f requires a comma-separated country code list" >&2; exit 2; }
      FILTER=1
      if ! FILTER_CODES="$(normalize_country_code_list "$1")" || [[ -z "$FILTER_CODES" ]]; then
        printf "%s\n" "Error: -f requires comma-separated ISO-3166 alpha-2 country codes, for example: -f GB,IE,NO" >&2
        exit 2
      fi
      FILTER_COUNT="$(count_nonempty_lines <<<"$FILTER_CODES")"
      shift
      ;;
    -j) SAVE_JSON=1; shift ;;
    -q) QUIET=1; shift ;;
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

if (( ${#ARGS_URLS[@]} > 1 )); then
  printf "%s\n" "Error: only one URL may be supplied." >&2
  usage >&2
  exit 2
fi

set -- "${ARGS_URLS[@]}"
# --- end options parsing ---

if [[ "$SHOW_BLOCKED" -eq 1 && "$FILTER" -eq 1 ]]; then
  printf "%s\n" "Error: -b and -f are mutually exclusive display options." >&2
  exit 2
fi

if [[ "$QUIET" -eq 0 ]]; then
  printf "\n%s\n\n" "CHECK FOR YOUTUBE GEORESTRICTION v$srcScrpVer"
fi

URL="${1-}"

# Ensure geo cache exists (or rebuild/download its country list), then validate and load maps.
need_iso=0
if [[ $REFRESH_ISO -eq 1 ]]; then
  need_iso=1
elif [[ ! -f "$JSON_PATH" ]]; then
  need_iso=1
fi

if [[ $need_iso -eq 1 ]]; then
  if [[ -n "$ISO_URL" ]]; then
    printf "%s\n\n" "* ISO-3166 JSON refresh requested. Downloading from --iso-url..."
    if ! curl -fsSL --retry 3 --retry-delay 1 "$ISO_URL" |
      validate_iso_country_json |
      write_country_cache_atomic "$JSON_PATH" "manual-iso-url" "$ISO_URL"; then
      printf "%s\n" "Download or JSON formatting failed: $ISO_URL" >&2
      exit 1
    fi
  else
    printf "%s\n\n" "* ISO-3166 JSON refresh requested. Downloading from Debian iso-codes..."

    if build_iso_json_from_debian_iso_codes | validate_iso_country_json | write_country_cache_atomic "$JSON_PATH" "debian-iso-codes" "$DEBIAN_ISO_CODES_URL"; then
      :
    else
      printf "%s\n\n" "* Debian iso-codes refresh failed. Falling back to IBAN country table..." >&2

      if ! build_iso_json_from_iban | validate_iso_country_json | write_country_cache_atomic "$JSON_PATH" "iban.com" "$IBAN_COUNTRY_CODES_URL"; then
        printf "%s\n" "Build or JSON formatting failed from both sources." >&2
        printf "%s\n" "Primary:  $DEBIAN_ISO_CODES_URL" >&2
        printf "%s\n" "Fallback: $IBAN_COUNTRY_CODES_URL" >&2
        exit 1
      fi
    fi
  fi
fi

# Validate geo cache JSON and country list
if ! jq -e '
  if type == "array" then
    length > 0
  elif type == "object" then
    (.countries | type == "array" and length > 0)
  else
    false
  end
' "$JSON_PATH" >/dev/null 2>&1; then
  printf "%s\n" "Invalid geo cache JSON in $JSON_PATH." >&2
  printf "%s\n" "Tip: try --refresh-iso or --iso-url \"$DEFAULT_ISO_URL\"" >&2
  exit 1
fi

declare -Ag COUNTRY_NAME_BY_CODE=()
ALL_ISO_CODES=""
while IFS=$'\t' read -r code name; do
  [[ -n "$code" ]] || continue
  COUNTRY_NAME_BY_CODE["$code"]="$name"
  ALL_ISO_CODES+="$code"$'\n'
done < <(jq -r ''' if type == "array" then .[] elif type == "object" then .countries[] else empty end | select(.["alpha-2"] and .name and (.["alpha-2"] | length > 0)) | [.["alpha-2"], .name] | @tsv ''' "$JSON_PATH" | sort -u)
ISOCODE_COUNT=$(count_nonempty_lines <<<"$ALL_ISO_CODES")

if [[ "$FILTER" -eq 1 ]]; then
  validate_country_codes_known "$FILTER_CODES" || exit 2
fi

ORIGIN_COUNTRY="$(get_origin_country)"
if [[ -z "$ORIGIN_COUNTRY" ]]; then
  ORIGIN_COUNTRY="[Unavailable]"
fi

if [[ -z "$URL" ]]; then
  exit 0
fi

VIDEO_URL="$URL"
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
FILTER_ALLOWED_CODES=""
ALLOWED_COUNT=0
BLOCKED_COUNT=0
FILTER_ALLOWED_COUNT=0
HIDDEN=""
FILTER_TEXT=""

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
    BLOCKED_CODES="$(comm -23 <(printf '%s\n' "$ALL_ISO_CODES" | LC_ALL=C sort -u) <(printf '%s\n' "$ALLOWED_CODES" | LC_ALL=C sort -u)
    )"
    BLOCKED_COUNT=$((ISOCODE_COUNT - ALLOWED_COUNT))
  fi
fi

if [[ "$FILTER" -eq 1 ]]; then
  if (( ${ALLOWED_COUNT:-0} > 0 )); then
    FILTER_ALLOWED_CODES="$(
      comm -12 \
        <(printf '%s\n' "$FILTER_CODES" | LC_ALL=C sort -u) \
        <(printf '%s\n' "$ALLOWED_CODES" | LC_ALL=C sort -u)
    )"
  fi

  FILTER_ALLOWED_COUNT="$(count_nonempty_lines <<<"$FILTER_ALLOWED_CODES")"
fi

if [[ "$FILTER" -eq 1 ]]; then
  FILTER_TEXT="Allowed country codes $(join_lines_csv "$FILTER_CODES")"
elif [[ "$SHOW_BLOCKED" -eq 1 ]]; then
  FILTER_TEXT="Blocked countries inferred from ISO-3166"
else
  FILTER_TEXT="Allowed countries reported by YouTube"
fi

if [[ "$QUIET" -eq 1 ]]; then
  if [[ "$FILTER" -eq 1 ]]; then
    join_lines_csv "$FILTER_ALLOWED_CODES"
  elif [[ "$SHOW_BLOCKED" -eq 1 ]]; then
    join_lines_csv "$BLOCKED_CODES"
  else
    join_lines_csv "$ALLOWED_CODES"
  fi

  exit 0
fi

print_wrap     7 2    "URL:" "$VIDEO_URL"
print_wrap     7 2 "LOCALE:" "$ORIGIN_COUNTRY ${HIDDEN:+ $HIDDEN}"
print_wrap     7 2 "STATUS:" "$STATUS ${HIDDEN:+ $HIDDEN}"
print_wrap     7 2 "REASON:" "$REASON"

if [[ $STATUS == LOGIN_REQUIRED ]]; then
  print_wrap   7 2 "ACCESS:" "Unknown - authentication required to verify access"
elif [[ $STATUS == ERROR ]]; then
  if ((${ALLOWED_COUNT:-0} > 0)); then
    print_wrap 7 2 "ACCESS:" "Limited - $ALLOWED_COUNT of $ISOCODE_COUNT country codes"
  else
    print_wrap 7 2 "ACCESS:" "Unavailable - no country access is listed"
  fi
elif [[ $STATUS == UNPLAYABLE ]]; then
  if ((${ALLOWED_COUNT:-0} > 0)); then
    print_wrap 7 2 "ACCESS:" "Limited - $ALLOWED_COUNT of $ISOCODE_COUNT country codes"
  else
    print_wrap 7 2 "ACCESS:" "Nowhere - no country access is allowed"
  fi
elif [[ $STATUS == OK ]]; then
  if ((ALLOWED_COUNT == ISOCODE_COUNT && ISOCODE_COUNT > 0)); then
    print_wrap 7 2 "ACCESS:" "Everywhere - all countries explicitly specified"
  elif ((${ALLOWED_COUNT:-0} < 1)); then
    print_wrap 7 2 "ACCESS:" "Everywhere - no countries explicitly specified"
  elif ((${ALLOWED_COUNT:-0} < ${ISOCODE_COUNT:-0})); then
    print_wrap 7 2 "ACCESS:" "Limited - $ALLOWED_COUNT of $ISOCODE_COUNT country codes"
  fi
fi
print_wrap     7 2 "FILTER:" "$FILTER_TEXT"

if [[ $STATUS != LOGIN_REQUIRED && $STATUS != ERROR ]]; then
  printf "\n"

  if [[ "$FILTER" -eq 1 ]]; then
    translate_codes "$FILTER_ALLOWED_CODES" "Filtered Allowed Countries ($FILTER_ALLOWED_COUNT of $FILTER_COUNT requested):"
  elif [[ "$SHOW_BLOCKED" -eq 1 ]]; then
    translate_codes "$BLOCKED_CODES" "Blocked Countries ($BLOCKED_COUNT of $ISOCODE_COUNT), inferred from ISO-3166:"
  else
    translate_codes "$ALLOWED_CODES" "Allowed Countries ($ALLOWED_COUNT of $ISOCODE_COUNT):"
  fi
fi
