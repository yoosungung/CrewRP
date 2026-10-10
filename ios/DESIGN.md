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

- 포인트 색은 틸이고, 배경은 시스템 grouped 색을 따른다. 앱 아이콘은 `CrewRPApp/Assets.xcassets/AppIcon.appiconset`의 **원작** flat 마크(틸 배경·원형 링·세 명 실루엣·2×2 계획 그리드, 1024×1024 RGB)다. 타사 로고를 쓰지 않는다.
- 소통·자료실 검색에서 입력 중 칸 밖(목록)을 누르면 포커스를 해제하고 키보드를 닫아 탭이 다시 보인다.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. compact(폰) 칸반은 레인별 세로 섹션(전체 너비)이고, 와이드는 다열·상단 정렬(마감일 목록과 같음)이다. 홈은 repo `README.md` 렌더, 오늘 할 일, 다가오는 할 일이다(고정 공지·홈 `+` 없음).
- 할 일 작성·수정은 제목·내용·상태(메뉴)·납기(캘린더만) 순이다. 내용은 Issue body, 상태는 Projects Status, 납기는 DATE 필드에 저장한다. 보드에 날짜 필드가 없으면 `Due date`를 만든다. **수정 시트**에서 `issueNumber`가 있으면 댓글(Issue comments) 목록·작성·본인/운영진 수정·삭제를 보여 준다.
- 불러오기 실패는 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- 할 일·자료실·소통(게시판 글)은 앱에서 CRUD한다. 탭의 `+`로 작성(소통은 카테고리 안에서), 항목으로 상세·수정·삭제. 운영진은 전 항목, 멤버는 본인 작성분만 수정·삭제.
- 자료실은 **문서(md)** + **첨부(Release Assets)** . 문서: 목록(파일·폴더) → 시트 상세(렌더·편집·삭제). `listDocs(path:)` 드릴다운·상위 복귀. 검색 시 `listDocsTree` + 첨부 이름 필터. `+`는 「문서 작성」|「파일 첨부」. 첨부는 `ReleaseAssetClient`로 `crewrp-attachments`에 업로드·목록. 탭 시 이미지/PDF는 QuickLook View, 그 외 Share/Download. compact에서 목록+본문 split을 쓰지 않는다.
- OAuth scope는 `read:org repo project`. Projects v2 쓰기는 `project`가 필요하므로 스코프 변경 후에는 재로그인한다.
- 소통 탭은 **허브**다. 상단 바로 대화(Discord 연동·딥링크·운영진 서버·채널 등록), 하단 Discussions 카테고리 → 글 목록·상세·작성. 탭 진입 시 Discord를 자동으로 열지 않는다. Issue 말풍선은 소통 본체가 아니다.
- Discord 연동은 `account_link`에 user id·표시 이름만 두고, Discord 액세스 토큰은 보관하지 않는다. 앱 로그아웃 시 연동도 지운다.
- `Info.plist`: `DiscordClientID`(OAuth 공용). 서버·채널 ID는 repo `.crewrp/settings.json`(운영진이 앱에서 등록 가능).
- 홈·크루 시작 화면 상단에 **로그아웃**이 있다. 토큰·대기 OAuth·세션을 지우고 로그인 화면으로 돌아간다.
- 로그인은 외부 Safari(`UIApplication.open`) + `crewrp://` 콜백이다. PKCE pending은 UserDefaults. 액세스 토큰은 Keychain 우선, entitlement 없으면 UserDefaults 폴백(폴백이 있으면 Keychain보다 우선). HTTP는 ephemeral URLSession.
- `CacheStore`(SQLite)는 락 + FULLMUTEX로 직렬화하고, 손상 시 파일을 지우고 다시 연다. ETag 캐시 쓰기는 best-effort라 캐시 실패로 자료실 로드가 깨지지 않는다.
- `refreshHomeData`는 네트워크·JSON 디코드를 `Task.detached`에서 돌리고 섹션을 `async let`으로 병렬화한다. GraphQL 목록(`listTasks`/`listNotices`)은 `GraphQLFreshness`(TTL 60s, `graphql_cursor`+`cache_entry`)로 신선하면 네트워크를 생략한다. 당겨서 새로고침·쓰기 후 갱신은 `forceNetwork: true`.
- 모든 쓰기는 async로 하고, 실패 시 “저장하지 못했습니다”류(스코프 부족이면 재로그인 안내)만 보여 준다.
