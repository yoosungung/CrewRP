# ios

iOS 클라이언트. `CrewRPCore` 패키지 + `CrewRPApp` 셸. 로그인 후 admin private repo를 골라 크루를 등록한다. 테스트용 샘플 저장소는 [SIMULATION.md](../SIMULATION.md).

## Commands

```bash
cd ios
swift test
# 앱: CrewRPApp.xcodeproj 를 Xcode에서 열어 시뮬레이터 실행
# 실기기: Xcode Signing Team 지정 후 (첫 실행은 폰에서 개발자 앱 신뢰)
xcodebuild -project CrewRPApp.xcodeproj -scheme CrewRP -destination 'generic/platform=iOS' -allowProvisioningUpdates build
xcrun devicectl list devices
xcrun devicectl device install app --device <id> <DerivedData>/Build/Products/Debug-iphoneos/CrewRP.app

# 실기기 (App Store / TestFlight 아님). USB Trust → Developer Mode → Xcode Run:
# 1) 기기 Settings → Privacy & Security → Developer Mode (Xcode 페어링 후에만 보임) → Restart → Enable
# 2) Xcode: scheme CrewRP, destination=연결된 iPhone, Signing & Capabilities → Automatically manage signing + Team
# 3) Run. Personal Team 개발 프로파일은 약 7일 만료 가능(유료 계정은 사람 결정).
# CLI (기기가 xctrace에서 Offline이 아닐 때):
# xcodebuild -project CrewRPApp.xcodeproj -scheme CrewRP -destination 'id=<UDID>' build
# 설치 후 기동은 Xcode Run이 담당. 코어 CRUD는 호스트 e2e-crud.sh; 셸 UI는 수동 체크리스트(공지/톡/자료/할 일 C-U-D).

# 실 GitHub CRUD E2E (코어 클라이언트 = 앱과 동일 경로)
CREWRP_E2E_TOKEN=… CREWRP_E2E_REPO=owner/repo ../scripts/e2e-crud.sh
# 공지·톡·자료는 repo면 충분. 할 일은 project 스코프 또는 Android DeviceCrudSmokeTest(앱 세션).
# iOS만: … swift test --filter CrudE2ETests
```

할 일 Projects v2 번호는 Info `ProjectNumber`(기본 1)를 쓰되, 없으면 `ProjectsClient.resolveProjectNumber`가 기존 프로젝트를 고르거나 `CrewRP` 프로젝트를 만든다.

## 셸

화면 계산은 `CrewRPCore`의 `ShellPresentation`이다. SwiftUI 셸은 `CrewRPApp.swift`.

- 포인트 색은 틸이고, 배경은 시스템 grouped 색을 따른다. 앱 아이콘은 `CrewRPApp/Assets.xcassets`의 틸 배경·세 명 실루엣이다.
- 소통에서 입력 중 칸 밖(메시지 목록)을 누르면 포커스를 해제하고 키보드를 닫아 탭이 다시 보인다.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. compact(폰) 칸반은 레인별 세로 섹션(전체 너비)이고, 와이드는 다열을 유지한다. 홈은 오늘 할 일, 고정 공지, 다가오는 할 일이다.
- 할 일 상세는 상태(세그먼트)와 납기(YYYY-MM-DD)를 보여 주고 Projects v2 Status·날짜 필드에 저장한다. 보드에 날짜 필드가 없으면 `Due date`(DATE)를 만든다. `updateTask`는 Due를 보낸다.
- 불러오기 실패는 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- 공지·할 일·자료실·소통은 앱에서 CRUD한다. 탭의 `+`로 작성, 항목으로 상세·수정·삭제. 운영진은 전 항목, 멤버는 본인 작성분만 수정·삭제.
- 자료실은 목록(파일·폴더) → 시트 상세(렌더·편집·삭제). `listDocs(path:)`로 폴더 드릴다운·상위 복귀. 검색어가 있으면 `listDocsTree` 재귀 인덱스에서 이름·경로 필터(폴더 안 파일 포함). compact에서 목록+본문 split을 쓰지 않는다.
- OAuth scope는 `read:org repo project`. Projects v2 쓰기는 `project`가 필요하므로 스코프 변경 후에는 재로그인한다.
- 스레드 톡은 제목 `스레드 톡` Issue(없으면 `#1`, 그것도 없으면 생성)의 댓글이다.
- 홈·크루 시작 화면 상단에 **로그아웃**이 있다. 토큰·대기 OAuth·세션을 지우고 로그인 화면으로 돌아간다.
- 로그인은 외부 Safari(`UIApplication.open`) + `crewrp://` 콜백이다. PKCE pending은 UserDefaults. 액세스 토큰은 Keychain 우선, entitlement 없으면 UserDefaults 폴백(폴백이 있으면 Keychain보다 우선). HTTP는 ephemeral URLSession.
- `CacheStore`(SQLite)는 락 + FULLMUTEX로 직렬화하고, 손상 시 파일을 지우고 다시 연다. ETag 캐시 쓰기는 best-effort라 캐시 실패로 자료실 로드가 깨지지 않는다.
- `refreshHomeData`는 네트워크·JSON 디코드를 `Task.detached`에서 돌리고 섹션을 `async let`으로 병렬화한다. GraphQL 목록(`listTasks`/`listNotices`)은 `GraphQLFreshness`(TTL 60s, `graphql_cursor`+`cache_entry`)로 신선하면 네트워크를 생략한다. 당겨서 새로고침·쓰기 후 갱신은 `forceNetwork: true`.
- 모든 쓰기는 async로 하고, 실패 시 “저장하지 못했습니다”류(스코프 부족이면 재로그인 안내)만 보여 준다.
