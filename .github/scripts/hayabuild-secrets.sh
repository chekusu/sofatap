#!/bin/bash
# Fetches this job's secrets from Hayabuild's secret store with the job's GitHub OIDC token (no GitHub Actions secrets).
# Hayabuild answers only .github/workflows/testflight.yml on refs/heads/main of this repository.
# Writes the App Store Connect key to $RUNNER_TEMP and exports ASC_KEY_ID, ASC_ISSUER_ID and ASC_KEY_PATH.
# Any extra names given as arguments are exported too. Values are masked and never printed.
set -euo pipefail
oidc=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=hayabuild" | plutil -extract value raw -o - -)
echo "::add-mask::$oidc"
out="$RUNNER_TEMP/secrets.json"
trap 'rm -f "$out"' EXIT
curl -fsS -X POST -H "Authorization: Bearer $oidc" "$HAYABUILD_API/github/oidc/secrets" -o "$out"
get() { plutil -extract "secrets.$1" raw -o - "$out" 2>/dev/null || { echo "Hayabuild has no secret $1 for this repository, ref and workflow" >&2; exit 1; }; }
key_id=$(get ASC_KEY_ID); issuer=$(get ASC_ISSUER_ID); p8=$(get ASC_KEY_P8)
echo "::add-mask::$issuer"
path="$RUNNER_TEMP/AuthKey_$key_id.p8"
(umask 077 && printf '%s\n' "$p8" > "$path")
{ echo "ASC_KEY_ID=$key_id"; echo "ASC_ISSUER_ID=$issuer"; echo "ASC_KEY_PATH=$path"; } >> "$GITHUB_ENV"
for name in "$@"; do
  value=$(get "$name")
  [ -n "$value" ] && echo "::add-mask::$value"
  echo "$name=$value" >> "$GITHUB_ENV"
done
