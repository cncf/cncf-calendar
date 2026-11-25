#!/bin/bash

set -euo pipefail

required_vars=(LFX_CLIENT_ID LFX_CLIENT_SECRET LFX_AUTH0_TOKEN_URL LFX_API_AUDIENCE)
for variable_name in "${required_vars[@]}"; do
  if [[ -z "${!variable_name:-}" ]]; then
    echo "Error: ${variable_name} is not set." >&2
    exit 1
  fi
done

response_file=$(mktemp)
trap 'rm -f "$response_file"' EXIT

http_status=$(jq -n \
  --arg client_id "$LFX_CLIENT_ID" \
  --arg client_secret "$LFX_CLIENT_SECRET" \
  --arg audience "$LFX_API_AUDIENCE" \
  '{grant_type: "client_credentials", client_id: $client_id, client_secret: $client_secret, audience: $audience}' \
  | curl --silent --show-error --output "$response_file" --write-out '%{http_code}' \
      --request POST "$LFX_AUTH0_TOKEN_URL" \
      --header 'content-type: application/json' \
      --data-binary @-)

if [[ "$http_status" != "200" ]]; then
  echo "Error: LFX token request returned HTTP ${http_status}." >&2
  exit 1
fi

if ! jq -e '(.access_token | strings | length > 0)
    and ((.token_type // "") | ascii_downcase == "bearer")' "$response_file" >/dev/null; then
  echo "Error: LFX token response did not contain a usable bearer token." >&2
  exit 1
fi

access_token=$(jq -r '.access_token' "$response_file")
if [[ -z "${GITHUB_OUTPUT:-}" ]]; then
  echo "Error: GITHUB_OUTPUT is not set." >&2
  exit 1
fi

printf '::add-mask::%s\n' "$access_token"
printf 'token=%s\n' "$access_token" >> "$GITHUB_OUTPUT"
echo "Production V1 token issued, expires in $(jq -r '.expires_in' "$response_file") seconds."
