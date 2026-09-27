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

## 셸

화면 계산(역할 문구, 칸반 분류, 홈 섹션, 자료 블록, 마감 표기)은 `crewrp-core`의 `ShellPresentation`이다. 앱 모듈은 그리기만 한다.

- 테마는 `ui/Theme.kt`. 밝은 화면은 종이색 배경과 틸 포인트, 어두운 화면은 같은 색의 어두운 쌍.
- 화면은 `ui/Shell.kt`. 로그인, 크루 시작, 하단 4탭.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. 홈은 오늘 할 일, 고정 공지, 다가오는 할 일이다.
- 불러오기 실패는 원인 원문 대신 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- OAuth PKCE `state`/`code_verifier`는 EncryptedSharedPreferences에 둔다. 브라우저에서 돌아올 때 Activity가 다시 만들어져도 교환이 된다. 토큰 교환은 백그라운드 스레드에서 한다.
