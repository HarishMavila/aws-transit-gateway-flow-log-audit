#!/usr/bin/env bash
#
# Generate the account-to-environment lookup table for Athena.
#
# Writes CSV to stdout:  account_id,account_name,environment
#
# Usage:
#   ./build-account-env-csv.sh > account-env.csv
#   ./build-account-env-csv.sh --tag-key Env > account-env.csv
#
# Then REVIEW IT before uploading. The tag is authoritative where present, but
# the name-based fallback is a guess and will be wrong for some accounts.
#
#   aws s3 cp account-env.csv s3://example-athena-lookups/account-env/
#
# Requires credentials in the Organizations management account or a delegated
# administrator, with organizations:ListAccounts and
# organizations:ListTagsForResource.

set -euo pipefail

TAG_KEY="Environment"

while [[ $# -gt 0 ]]; do
  case "$1" in
    --tag-key) TAG_KEY="$2"; shift 2 ;;
    -h|--help) sed -n '2,26p' "$0"; exit 0 ;;
    *) echo "Unknown argument: $1" >&2; exit 1 ;;
  esac
done

# Normalise whatever the tag says into one of: prod, nonprod, sandbox.
# Adjust the patterns to match your own naming conventions.
normalise_env() {
  local raw
  raw=$(printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]')
  case "$raw" in
    prod|production|prd|live)              echo "prod" ;;
    nonprod|non-prod|npd|dev|development|test|qa|stage|staging|uat|perf|cicd|ci)
                                          echo "nonprod" ;;
    sandbox|sbx|sand|playground)          echo "sandbox" ;;
    "")                                   echo "" ;;
    *)                                    echo "$raw" ;;
  esac
}

# Fall back to the account name when the tag is missing. Order matters:
# "sandbox" and "nonprod" are checked before "prod", since a name like
# "Checkout NonProd" contains "prod" as a substring.
guess_from_name() {
  local name
  name=$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')
  case "$name" in
    *sandbox*|*sbx*)                                  echo "sandbox" ;;
    *nonprod*|*non-prod*|*dev*|*test*|*qa*|*stag*|*uat*|*perf*|*cicd*)
                                                      echo "nonprod" ;;
    *prod*|*prd*)                                     echo "prod" ;;
    *)                                                echo "UNKNOWN" ;;
  esac
}

# CSV-escape a field: wrap in quotes and double any embedded quotes.
csv_quote() {
  printf '"%s"' "${1//\"/\"\"}"
}

aws organizations list-accounts \
  --query 'Accounts[?Status==`ACTIVE`].[Id,Name]' \
  --output text |
while IFS=$'\t' read -r account_id account_name; do
  [[ -z "${account_id:-}" ]] && continue

  tag_value=$(aws organizations list-tags-for-resource \
                --resource-id "$account_id" \
                --query "Tags[?Key=='${TAG_KEY}'].Value | [0]" \
                --output text 2>/dev/null || true)
  [[ "$tag_value" == "None" ]] && tag_value=""

  environment=$(normalise_env "$tag_value")
  if [[ -z "$environment" ]]; then
    environment=$(guess_from_name "$account_name")
    echo "no ${TAG_KEY} tag on ${account_id} (${account_name}); guessed '${environment}'" >&2
  fi

  printf '%s,%s,%s\n' \
    "$(csv_quote "$account_id")" \
    "$(csv_quote "$account_name")" \
    "$(csv_quote "$environment")"
done

echo "Done. Review the output, especially any UNKNOWN rows, before uploading." >&2
