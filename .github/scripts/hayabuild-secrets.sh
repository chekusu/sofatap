#!/bin/sh
# Fetches this job's secrets from Hayabuild with the job's GitHub OIDC token, masks them and exports them to the
# following steps. Hayabuild gives a secret only to the repository, ref and workflow it was kept for (never to a pull
# request), so this needs `permissions: id-token: write` and runs on main. Values that are files are kept base64.
set -eu
: "${ACTIONS_ID_TOKEN_REQUEST_URL:?the job needs permissions: id-token: write}"
api=${HAYABUILD_API:-https://api.haya.build}
oidc=$(curl -fsS -H "Authorization: bearer $ACTIONS_ID_TOKEN_REQUEST_TOKEN" "$ACTIONS_ID_TOKEN_REQUEST_URL&audience=hayabuild" | jq -r .value)
answer=$(curl -fsS -X POST -H "Authorization: Bearer $oidc" "$api/github/oidc/secrets")
names=$(printf '%s' "$answer" | jq -r '.secrets | keys[]')
[ -n "$names" ] || { echo "::error::Hayabuild gave no secrets to $(printf '%s' "$answer" | jq -r '.repository + " " + .ref')"; exit 1; }
for name in $names; do
  value=$(printf '%s' "$answer" | jq -r --arg n "$name" '.secrets[$n]')
  printf '%s\n' "$value" | while IFS= read -r line; do [ -n "$line" ] && echo "::add-mask::$line"; done
  delim="HAYABUILD_$(openssl rand -hex 8)"
  { echo "$name<<$delim"; printf '%s\n' "$value"; echo "$delim"; } >> "$GITHUB_ENV"
  echo "secret $name"
done
