#!/usr/bin/env bash
# One-time setup of the secrets the Release GitHub Action needs. Run it yourself in a terminal:
# it asks for your .p12 and passwords and sends them straight to GitHub's encrypted secrets.
#
#   scripts/setup-ci-secrets.sh
#
# Before running it, export the Developer ID certificate *with its private key* as a .p12:
# Keychain Access → login → My Certificates → right-click
# "Developer ID Application: Tom Lorenz (K6QN2C7Q55)" → Export… → choose a password.
set -euo pipefail

REPO="bombadiltom/ClaudeWatch"
TAP_REPO="bombadiltom/homebrew-tap"
GH_USER="${GH_USER:-bombadiltom}"
DEPLOY_KEY_TITLE="ClaudeWatch release action"

GH_TOKEN="$(gh auth token --user "$GH_USER")"
export GH_TOKEN

read -rp "Path to the exported Developer ID .p12: " P12_PATH
P12_PATH="${P12_PATH/#\~/$HOME}"
[[ -f "$P12_PATH" ]] || { echo "error: $P12_PATH not found" >&2; exit 1; }
read -rsp "Password of the .p12: " P12_PASSWORD; echo
read -rp "Apple ID for notarization: " NOTARY_APPLE_ID
read -rsp "App-specific password for that Apple ID: " NOTARY_PASSWORD; echo

echo "==> Setting repository secrets on $REPO"
base64 -i "$P12_PATH" | gh secret set DEVELOPER_ID_P12 --repo "$REPO"
printf '%s' "$P12_PASSWORD" | gh secret set DEVELOPER_ID_P12_PASSWORD --repo "$REPO"
printf '%s' "$NOTARY_APPLE_ID" | gh secret set NOTARY_APPLE_ID --repo "$REPO"
printf '%s' "$NOTARY_PASSWORD" | gh secret set NOTARY_PASSWORD --repo "$REPO"

echo "==> Creating a write deploy key on $TAP_REPO for cask updates"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
ssh-keygen -q -t ed25519 -N "" -C "$DEPLOY_KEY_TITLE" -f "$WORK_DIR/tap_key"
# Also removes the key from when the app was called TokenTally.
OLD_KEY_IDS="$(gh api "repos/$TAP_REPO/keys" --jq ".[] | select(.title == \"$DEPLOY_KEY_TITLE\" or .title == \"TokenTally release action\") | .id")"
for id in $OLD_KEY_IDS; do gh api -X DELETE "repos/$TAP_REPO/keys/$id"; done
gh repo deploy-key add "$WORK_DIR/tap_key.pub" --repo "$TAP_REPO" --title "$DEPLOY_KEY_TITLE" --allow-write
gh secret set TAP_DEPLOY_KEY --repo "$REPO" < "$WORK_DIR/tap_key"

echo "==> Done. Secrets on $REPO:"
gh secret list --repo "$REPO"
echo
echo "You can delete the exported .p12 now: rm \"$P12_PATH\""
