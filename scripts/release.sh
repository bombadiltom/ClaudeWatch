#!/usr/bin/env bash
# Releases ClaudeWatch.
#
#   scripts/release.sh <version>
#       Normal release: tags the current (pushed) commit as v<version> and pushes the tag.
#       The "Release" GitHub Action then builds, signs, notarizes, publishes the GitHub
#       release and updates the cask in bombadiltom/homebrew-tap.
#
#   scripts/release.sh <version> --build-only
#       Builds, signs and notarizes into dist/ without publishing anything.
#
#   scripts/release.sh <version> --publish-existing-tag
#       What the GitHub Action runs: build + notarize the checked-out tag v<version>, then
#       publish the GitHub release and update the cask. Also works locally as a fallback if
#       the Action is unavailable (check out the tag first).
#
# Local prerequisites for --build-only / --publish-existing-tag (see README.md → Releasing):
#   - a "Developer ID Application" certificate in the keychain
#   - notarization credentials stored with:
#       xcrun notarytool store-credentials BluetoothBatteryWatch --apple-id <apple-id> --team-id <team-id>
#   - gh logged in as $GH_USER (default: bombadiltom), or GH_TOKEN set
#
# Environment overrides used by CI: NOTARY_KEYCHAIN (keychain holding the notary profile),
# TAP_DEPLOY_KEY (SSH private key with write access to the tap), GH_TOKEN.
set -euo pipefail

usage="usage: scripts/release.sh <version> [--build-only | --publish-existing-tag]"
VERSION="${1:?$usage}"
MODE="${2:-tag}"
case "$MODE" in
  tag | --build-only | --publish-existing-tag) ;;
  *) echo "$usage" >&2; exit 2 ;;
esac
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || { echo "error: version must look like 1.2 or 1.2.3" >&2; exit 2; }

APP_NAME="ClaudeWatch"
REPO="bombadiltom/ClaudeWatch"
TAP_REPO="bombadiltom/homebrew-tap"
CASK_TOKEN="claudewatch"
BUNDLE_ID="de.lorenz-unna.claudewatch"
NOTARY_PROFILE="${NOTARY_PROFILE:-BluetoothBatteryWatch}"  # the team-wide notarytool profile on the release Mac
SIGN_IDENTITY="${SIGN_IDENTITY:-Developer ID Application}"
TEAM_ID="${TEAM_ID:-K6QN2C7Q55}"
GH_USER="${GH_USER:-bombadiltom}"
TAG="v$VERSION"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

die() { echo "error: $*" >&2; exit 1; }

# --- Mode: tag ------------------------------------------------------------------------------

if [[ "$MODE" == "tag" ]]; then
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean — commit first."
  git fetch --quiet origin
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse '@{u}')" ]] \
    || die "HEAD isn't the same as its upstream — push (or pull) first so the Action builds this commit."
  ! git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG already exists."
  git tag -a "$TAG" -m "$APP_NAME $VERSION"
  git push --quiet origin "$TAG"
  echo "==> Pushed $TAG. The Release action is now building it:"
  echo "    https://github.com/$REPO/actions/workflows/release.yml"
  exit 0
fi

# --- Build, sign, notarize -----------------------------------------------------------------

if [[ "$MODE" == "--publish-existing-tag" ]]; then
  [[ -z "$(git status --porcelain)" ]] || die "working tree is not clean."
  git rev-parse -q --verify "refs/tags/$TAG" >/dev/null || die "tag $TAG doesn't exist."
  [[ "$(git rev-parse HEAD)" == "$(git rev-parse "$TAG^{commit}")" ]] || die "HEAD is not at $TAG — check out the tag first."
  if [[ -z "${GH_TOKEN:-}" ]]; then
    GH_TOKEN="$(gh auth token --user "$GH_USER")"
    export GH_TOKEN
  fi
  ! gh release view "$TAG" --repo "$REPO" >/dev/null 2>&1 || die "GitHub release $TAG already exists."
fi

security find-identity -v -p codesigning | grep -q "$SIGN_IDENTITY" \
  || die "no \"$SIGN_IDENTITY\" certificate in the keychain."

NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
[[ -n "${NOTARY_KEYCHAIN:-}" ]] && NOTARY_AUTH+=(--keychain "$NOTARY_KEYCHAIN")

BUILD_DIR="$ROOT/build/release"
DIST_DIR="$ROOT/dist"
APP="$BUILD_DIR/Build/Products/Release/$APP_NAME.app"
ZIP="$DIST_DIR/$APP_NAME-$VERSION.zip"

echo "==> Building $APP_NAME $VERSION"
xcodegen generate --quiet
rm -rf "$BUILD_DIR"
mkdir -p "$DIST_DIR"
xcodebuild -project "$APP_NAME.xcodeproj" -scheme "$APP_NAME" -configuration Release \
  -derivedDataPath "$BUILD_DIR" \
  -destination "generic/platform=macOS" \
  MARKETING_VERSION="$VERSION" \
  CURRENT_PROJECT_VERSION="$(git rev-list --count HEAD)" \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  CODE_SIGN_STYLE=Manual \
  CODE_SIGN_IDENTITY="$SIGN_IDENTITY" \
  OTHER_CODE_SIGN_FLAGS="--timestamp" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  build | grep -E "error|warning: |BUILD" || true
[[ -d "$APP" ]] || die "build failed"

codesign --verify --deep --strict --verbose=2 "$APP"

echo "==> Notarizing (this usually takes a few minutes)"
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SUBMISSION="$(xcrun notarytool submit "$ZIP" "${NOTARY_AUTH[@]}" --wait --output-format json)"
SUBMISSION_ID="$(plutil -extract id raw - <<<"$SUBMISSION")"
STATUS="$(plutil -extract status raw - <<<"$SUBMISSION")"
echo "    submission $SUBMISSION_ID: $STATUS"
if [[ "$STATUS" != "Accepted" ]]; then
  echo "error: notarization was not accepted. Apple's log:" >&2
  xcrun notarytool log "$SUBMISSION_ID" "${NOTARY_AUTH[@]}" >&2
  exit 1
fi
xcrun stapler staple "$APP"
spctl --assess --type execute --verbose=2 "$APP"

# Re-zip so the download contains the stapled ticket.
rm -f "$ZIP"
ditto -c -k --keepParent "$APP" "$ZIP"
SHA256="$(shasum -a 256 "$ZIP" | awk '{print $1}')"
echo "==> $ZIP"
echo "    sha256 $SHA256"

if [[ "$MODE" == "--build-only" ]]; then
  echo "==> --build-only: nothing published."
  exit 0
fi

# --- Publish -------------------------------------------------------------------------------

echo "==> Publishing GitHub release $TAG"
gh release create "$TAG" "$ZIP" --repo "$REPO" --title "$APP_NAME $VERSION" --verify-tag --generate-notes

echo "==> Updating the Homebrew cask in $TAP_REPO"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT
if [[ -n "${TAP_DEPLOY_KEY:-}" ]]; then
  printf '%s\n' "$TAP_DEPLOY_KEY" > "$WORK_DIR/tap_key"
  chmod 600 "$WORK_DIR/tap_key"
  export GIT_SSH_COMMAND="ssh -i $WORK_DIR/tap_key -o IdentitiesOnly=yes -o StrictHostKeyChecking=accept-new"
fi
TAP_DIR="$WORK_DIR/tap"
git clone --quiet "git@github.com:$TAP_REPO.git" "$TAP_DIR"
mkdir -p "$TAP_DIR/Casks"
cat > "$TAP_DIR/Casks/$CASK_TOKEN.rb" <<EOF
cask "$CASK_TOKEN" do
  version "$VERSION"
  sha256 "$SHA256"

  url "https://github.com/$REPO/releases/download/v#{version}/$APP_NAME-#{version}.zip"
  name "$APP_NAME"
  desc "Menu bar Claude plan limits, token usage and Claude Code costs"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :sonoma

  app "$APP_NAME.app"

  uninstall quit: "$BUNDLE_ID"

  zap trash: [
    "~/Library/Caches/$BUNDLE_ID",
    "~/Library/Preferences/$BUNDLE_ID.plist",
  ]
end
EOF
GIT_IDENTITY=()
if [[ -n "${GITHUB_ACTIONS:-}" ]]; then
  GIT_IDENTITY=(-c user.name="github-actions[bot]" -c user.email="41898282+github-actions[bot]@users.noreply.github.com")
fi
git -C "$TAP_DIR" add "Casks/$CASK_TOKEN.rb"
# ${arr[@]+...} keeps macOS's bash 3.2 happy with an empty array under `set -u`.
git -C "$TAP_DIR" ${GIT_IDENTITY[@]+"${GIT_IDENTITY[@]}"} commit --quiet -m "$CASK_TOKEN $VERSION"
git -C "$TAP_DIR" push --quiet origin HEAD

echo "==> Released $APP_NAME $VERSION"
echo "    brew upgrade --cask $CASK_TOKEN"
