# android

Android 클라이언트. `crewrp-core` + `:app` 셸. 로그인 후 admin private repo를 골라 크루를 등록한다. 테스트용 샘플 저장소는 [SIMULATION.md](../SIMULATION.md).

## Commands

```bash
cd android
./gradlew :crewrp-core:test
./gradlew :app:assembleDebug

# 에뮬레이터: 에이전트/터미널 종료와 분리해서 기동 (닫히지 않게)
./scripts/start-emulator.sh
adb install -r app/build/outputs/apk/debug/app-debug.apk
adb shell am start -n app.crewrp/.MainActivity
```

에뮬레이터는 Python `start_new_session=True`로 띄운다(`./scripts/start-emulator.sh`). 셸이 끝나도 프로세스를 죽이지 않는다. 규칙은 `.cursor/rules/android-emulator.mdc`.
