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

# 실 GitHub CRUD E2E (공지·톡·자료 JVM; 할 일은 project 토큰 또는 로그인된 기기/에뮬 앱 세션)
CREWRP_E2E_TOKEN=… CREWRP_E2E_REPO=owner/repo ../scripts/e2e-crud.sh
# 기기 전체 CRUD(세션 유지): adb install -r … && adb shell am instrument -w -e class app.crewrp.DeviceCrudSmokeTest …

# 실기기 USB (Play Store 아님). 개발자 옵션 → USB debugging → 호스트 승인 후:
export PATH="${ANDROID_HOME:-/opt/homebrew/share/android-commandlinetools}/platform-tools:$PATH"
adb devices -l                    # 상태가 device (unauthorized면 폰에서 Allow USB debugging)
./gradlew :app:installDebug       # 또는 assembleDebug 후 adb -d install -r app/build/outputs/apk/debug/app-debug.apk
adb -d shell am start -n app.crewrp/.MainActivity
# e2e-crud.sh는 adb devices에 device가 있으면 DeviceCrudSmokeTest를 돌림.
# 에뮬+USB 동시면 USB만: adb -d … 또는 ANDROID_SERIAL=<usb-serial>
# 수동 CRUD: 로그인·크루 등록 후 공지/톡/자료/할 일 각 1회 작성·수정·삭제
```

할 일 Projects v2 번호는 `BuildConfig.PROJECT_NUMBER`(기본 1)를 쓰되, 없으면 `ProjectsClient.resolveProjectNumber`가 기존 프로젝트를 고르거나 `CrewRP` 프로젝트를 만든다.




에뮬레이터는 Python `start_new_session=True`로 띄운다(`./scripts/start-emulator.sh`). 셸이 끝나도 프로세스를 죽이지 않는다. 규칙은 `.cursor/rules/android-emulator.mdc`.

## 셸

화면 계산(역할 문구, 칸반 분류·compact 레이아웃, 홈 섹션, 자료 블록, 마감 표기, 상세 상태·납기)은 `crewrp-core`의 `ShellPresentation`이다. 앱 모듈은 그리기만 한다.

- 테마는 `ui/Theme.kt`. 밝은 화면은 종이색 배경과 틸 포인트, 어두운 화면은 같은 색의 어두운 쌍.
- 화면은 `ui/Shell.kt`. 로그인, 크루 시작, 하단 4탭.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. compact(폰, 너비 < 600dp) 칸반은 레인별 세로 섹션(전체 너비)이고, 와이드는 다열·상단 정렬(마감일 목록과 같음)이다. 홈은 오늘 할 일, 고정 공지, 다가오는 할 일이다.
- 할 일 작성·수정은 제목·내용·상태(드롭다운)·납기(캘린더만) 순이다. 내용은 Issue body, 상태는 Projects Status, 납기는 DATE 필드에 저장한다. 보드에 날짜 필드가 없으면 `Due date`를 만든다.
- 불러오기 실패는 원인 원문 대신 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- OAuth PKCE `state`/`code_verifier`는 EncryptedSharedPreferences에 둔다. 브라우저에서 돌아올 때 Activity가 다시 만들어져도 교환이 된다. 토큰 교환은 백그라운드 스레드에서 한다.
- 공지·할 일·자료실·소통은 앱에서 CRUD한다. 탭의 `+`로 작성, 항목 탭으로 상세·수정·삭제. 운영진은 전 항목, 멤버는 본인 작성분만 수정·삭제.
- 자료실은 **문서(md)** + **첨부(Release Assets)** . 문서: 목록 → 다이얼로그 상세(렌더·편집·삭제). `listDocs(path)` 드릴다운·상위 복귀. 검색 시 `listDocsTree` + 첨부 이름 필터. `+`는 「문서 작성」|「파일 첨부」. 첨부는 `ReleaseAssetClient`로 `crewrp-attachments`에 업로드·목록. 탭 시 이미지/PDF는 `ACTION_VIEW`, 그 외 Share/Download. 검색 중 목록(바깥) 탭으로 포커스·키보드를 닫는다. compact에서 목록+본문 split을 쓰지 않는다.
- OAuth scope는 `read:org repo project`(authorize URL에 포함). Projects v2 쓰기는 `project`가 필요하므로 스코프 변경 후에는 재로그인한다.
- 소통 탭은 Discord다. 탭 선택 시 연동·**활성 크루** `.crewrp/settings.json`의 서버·채널이 있으면 딥링크를 바로 열고, 미연동이면 OAuth 연결을 시작한다. Issue 말풍선은 소통 본체가 아니다. `fetchCrewContent`에서 Issue 톡 API를 호출하지 않는다.
- Discord 연동은 `account_link`에 user id·표시 이름만 두고, Discord 액세스 토큰은 보관하지 않는다. 앱 로그아웃 시 연동도 지운다.
- `BuildConfig`: `DISCORD_CLIENT_ID`(OAuth 공용). 서버·채널 ID는 repo `.crewrp/settings.json`(운영진이 앱에서 등록 가능).
- JVM `HttpURLConnection`은 PATCH를 거부하므로 `UrlHttpTransport`는 POST + `X-HTTP-Method-Override: PATCH`로 보낸다(댓글·이슈 상태·자료 갱신).
- 홈(TopAppBar)·크루 시작 화면에 **로그아웃**이 있다. 토큰·대기 OAuth·세션을 지우고 로그인 화면으로 돌아간다.
- 모든 쓰기(등록·저장·삭제·댓글)는 백그라운드 스레드에서 하고, 실패 시 원인 원문 대신 “저장하지 못했습니다”류(스코프 부족이면 재로그인 안내)만 보여 준다.
- `fetchCrewContent`는 할 일·공지·톡·자료를 스레드 풀로 병렬 로드한다. GraphQL 목록은 `GraphQLFreshness`(TTL 60s)로 신선하면 네트워크를 생략하고, REST `ETagRESTClient`는 응답 `ETag`를 저장해 이후 `If-None-Match`/`304`를 쓴다. 당겨서 새로고침(`refreshTick > 0`)은 `forceNetwork`.
