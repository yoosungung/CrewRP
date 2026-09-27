#!/usr/bin/env bash
# Live GitHub CRUD E2E for iOS + Android core clients (same code paths as the apps).
# Covers: notice (Discussions), talk (issue comments), docs (contents), tasks (Projects v2).
#
# Required:
#   CREWRP_E2E_TOKEN  — classic PAT or OAuth token with at least `repo`
#   CREWRP_E2E_REPO   — owner/repo (private crew repo, e.g. yoosungung/ai-edu)
# Optional:
#   CREWRP_E2E_PROJECT_NUMBER — default 1
#
# Tasks need Projects v2 (`project` / `read:project`). When the host token has `project`,
# JVM + instrumented tests use that token. When it does not, notice/talk/docs still run on
# JVM, and Android DeviceCrudSmokeTest uses the logged-in app session (must include project).
#
# Usage:
#   CREWRP_E2E_TOKEN=... CREWRP_E2E_REPO=owner/repo ./scripts/e2e-crud.sh
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

if [[ -z "${CREWRP_E2E_TOKEN:-}" || -z "${CREWRP_E2E_REPO:-}" ]]; then
  echo "Set CREWRP_E2E_TOKEN and CREWRP_E2E_REPO (owner/repo)." >&2
  exit 2
fi
export CREWRP_E2E_PROJECT_NUMBER="${CREWRP_E2E_PROJECT_NUMBER:-1}"

echo "== token scope check =="
SCOPES="$(curl -sI -H "Authorization: Bearer ${CREWRP_E2E_TOKEN}" -H "Accept: application/vnd.github+json" \
  https://api.github.com/user | tr -d '\r' | awk -F': ' 'tolower($1)=="x-oauth-scopes"{print $2; exit}')"
echo "x-oauth-scopes: ${SCOPES:-<none>}"
HAS_PROJECT=0
if [[ -z "${SCOPES}" ]]; then
  # Fine-grained PATs omit x-oauth-scopes; assume Projects were granted on the token.
  HAS_PROJECT=1
elif grep -Eq '(^|[, ])project([, ]|$)' <<<"${SCOPES}"; then
  HAS_PROJECT=1
fi

echo "== iOS notice/talk/docs E2E =="
(
  cd "$ROOT/ios"
  unset CREWRP_E2E_REQUIRE_PROJECT || true
  swift test --filter 'CrudE2ETests/(notice|talk|docs)'
)

echo "== Android notice/talk/docs E2E =="
(
  cd "$ROOT/android"
  unset CREWRP_E2E_REQUIRE_PROJECT || true
  ./gradlew :crewrp-core:test \
    --tests 'app.crewrp.core.CrudE2ETest.noticeCreateUpdateDelete' \
    --tests 'app.crewrp.core.CrudE2ETest.talkCommentCreateUpdateDelete' \
    --tests 'app.crewrp.core.CrudE2ETest.docsMarkdownSaveAndDelete'
)

export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$ANDROID_HOME/platform-tools:$PATH"
HAS_DEVICE=0
if adb devices 2>/dev/null | grep -q $'device$'; then
  HAS_DEVICE=1
fi

run_device_smoke_injected() {
  cd "$ROOT/android"
  ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest -q
  adb install -r app/build/outputs/apk/debug/app-debug.apk
  adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
  adb shell am instrument -w \
    -e class app.crewrp.DeviceCrudSmokeTest \
    -e e2e_token "${CREWRP_E2E_TOKEN}" \
    -e e2e_repo "${CREWRP_E2E_REPO}" \
    -e e2e_project_number "${CREWRP_E2E_PROJECT_NUMBER}" \
    app.crewrp.test/androidx.test.runner.AndroidJUnitRunner
}

run_device_smoke_app_session() {
  cd "$ROOT/android"
  ./gradlew :app:assembleDebug :app:assembleDebugAndroidTest -q
  # -r keeps EncryptedPrefs / crew session (connectedDebugAndroidTest often clears data).
  adb install -r app/build/outputs/apk/debug/app-debug.apk
  adb install -r app/build/outputs/apk/androidTest/debug/app-debug-androidTest.apk
  adb shell am instrument -w \
    -e class app.crewrp.DeviceCrudSmokeTest \
    app.crewrp.test/androidx.test.runner.AndroidJUnitRunner
}

if [[ "$HAS_PROJECT" -eq 1 ]]; then
  echo "== iOS task E2E =="
  export CREWRP_E2E_REQUIRE_PROJECT=1
  (
    cd "$ROOT/ios"
    swift test --filter 'CrudE2ETests/taskRoundTrip'
  )

  echo "== Android JVM task E2E =="
  (
    cd "$ROOT/android"
    ./gradlew :crewrp-core:test --tests 'app.crewrp.core.CrudE2ETest.taskCreateAndDelete'
  )

  if [[ "$HAS_DEVICE" -eq 1 ]]; then
    echo "== Android device CRUD (injected token) =="
    run_device_smoke_injected
  else
    echo "No adb device — skipped instrumented smoke (JVM task already passed)."
  fi
else
  echo "CREWRP_E2E_TOKEN lacks project — JVM task E2E skipped."
  if [[ "$HAS_DEVICE" -ne 1 ]]; then
    echo "No adb device with a project-scoped app login; cannot verify task CRUD." >&2
    echo "Fix: gh auth refresh -h github.com -s repo -s read:org -s project -s read:project" >&2
    echo "  or sign in on the emulator with OAuth (includes project), then re-run." >&2
    exit 2
  fi
  echo "== Android device CRUD (app session; must have project scope) =="
  run_device_smoke_app_session
fi

echo "e2e-crud OK"
