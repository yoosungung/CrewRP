#!/usr/bin/env bash
# Detach Pixel_API_36 so agent/terminal exit does not kill the emulator.
# macOS has no setsid — use Python start_new_session instead.
set -euo pipefail
export ANDROID_HOME="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}"
export PATH="$ANDROID_HOME/platform-tools:$ANDROID_HOME/emulator:$PATH"
AVD="${1:-Pixel_API_36}"
LOG="${CREWRP_EMU_LOG:-/tmp/crewrp-emu.log}"

if adb devices 2>/dev/null | grep -q $'device$'; then
  echo "emulator already online"
  adb devices -l
  exit 0
fi

python3 - "$AVD" "$LOG" <<'PY'
import os, subprocess, sys
avd, log = sys.argv[1], sys.argv[2]
env = os.environ.copy()
with open(log, "ab", buffering=0) as f:
    subprocess.Popen(
        ["emulator", "-avd", avd, "-netdelay", "none", "-netspeed", "full"],
        stdin=subprocess.DEVNULL,
        stdout=f,
        stderr=subprocess.STDOUT,
        env=env,
        start_new_session=True,
        close_fds=True,
    )
print(f"started detached avd={avd} log={log}")
PY

for _ in $(seq 1 90); do
  if adb devices 2>/dev/null | grep -q emulator; then
    boot="$(adb shell getprop sys.boot_completed 2>/dev/null | tr -d '\r' || true)"
    if [[ "$boot" == "1" ]]; then
      adb devices -l
      exit 0
    fi
  fi
  sleep 2
done
echo "timeout waiting for boot; see $LOG" >&2
exit 1
