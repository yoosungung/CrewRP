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

# 실 GitHub CRUD E2E (공지·톡·자료 JVM; 할 일은 project 토큰 또는 로그인된 에뮬 앱 세션)
CREWRP_E2E_TOKEN=… CREWRP_E2E_REPO=owner/repo ../scripts/e2e-crud.sh
# 기기 전체 CRUD(세션 유지): adb install -r … && adb shell am instrument -w -e class app.crewrp.DeviceCrudSmokeTest …
```

할 일 Projects v2 번호는 `BuildConfig.PROJECT_NUMBER`(기본 1)를 쓰되, 없으면 `ProjectsClient.resolveProjectNumber`가 기존 프로젝트를 고르거나 `CrewRP` 프로젝트를 만든다.




에뮬레이터는 Python `start_new_session=True`로 띄운다(`./scripts/start-emulator.sh`). 셸이 끝나도 프로세스를 죽이지 않는다. 규칙은 `.cursor/rules/android-emulator.mdc`.

## 셸

화면 계산(역할 문구, 칸반 분류, 홈 섹션, 자료 블록, 마감 표기)은 `crewrp-core`의 `ShellPresentation`이다. 앱 모듈은 그리기만 한다.

- 테마는 `ui/Theme.kt`. 밝은 화면은 종이색 배경과 틸 포인트, 어두운 화면은 같은 색의 어두운 쌍.
- 화면은 `ui/Shell.kt`. 로그인, 크루 시작, 하단 4탭.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. 홈은 오늘 할 일, 고정 공지, 다가오는 할 일이다.
- 불러오기 실패는 원인 원문 대신 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- OAuth PKCE `state`/`code_verifier`는 EncryptedSharedPreferences에 둔다. 브라우저에서 돌아올 때 Activity가 다시 만들어져도 교환이 된다. 토큰 교환은 백그라운드 스레드에서 한다.
- 공지·할 일·자료실·소통은 앱에서 CRUD한다. 탭의 `+`로 작성, 항목 탭으로 상세·수정·삭제. 운영진은 전 항목, 멤버는 본인 작성분만 수정·삭제.
- OAuth scope는 `read:org repo project`(authorize URL에 포함). Projects v2 쓰기는 `project`가 필요하므로 스코프 변경 후에는 재로그인한다.
- 스레드 톡은 제목 `스레드 톡` Issue(없으면 `#1`, 그것도 없으면 생성)의 댓글이다.
- JVM `HttpURLConnection`은 PATCH를 거부하므로 `UrlHttpTransport`는 POST + `X-HTTP-Method-Override: PATCH`로 보낸다(댓글·이슈 상태·자료 갱신).
- 홈(TopAppBar)·크루 시작 화면에 **로그아웃**이 있다. 토큰·대기 OAuth·세션을 지우고 로그인 화면으로 돌아간다.
- 모든 쓰기(등록·저장·삭제·댓글)는 백그라운드 스레드에서 하고, 실패 시 원인 원문 대신 “저장하지 못했습니다”류(스코프 부족이면 재로그인 안내)만 보여 준다.
