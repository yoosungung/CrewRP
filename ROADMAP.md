# ROADMAP.md

수행 순서. 불변 규칙은 [ARCHITECTURE.md](ARCHITECTURE.md). 코드와 `DESIGN.md`는 해당 Phase에 첫 코드가 들어올 때 만든다.

클라이언트는 iOS(Swift)와 Android(Kotlin), 로컬 캐시는 SQLite다. 두 앱은 같은 Phase를 따른다.

## Phase 1 — 인증과 캐시

- [x] PKCE·SQLite·TeamRole 코어, `auth-bridge` 교환 Worker
- [x] 토큰 보관(Keychain / EncryptedSharedPreferences)
- [x] auth-bridge 코드 교환 클라이언트
- [x] Organization 목록·`admins`/`members` Team 식별 클라이언트
- [x] 시스템 브라우저 로그인 UI(앱 셸: iOS `ASWebAuthenticationSession`, Android Custom Tabs)
- 완료 기준: GitHub OAuth App·Worker URL을 넣고 로그인·조직 선택 수동 확인

## Phase 2 — 할 일, 자료, 공지, 서식

- [x] Projects v2 칸반/마감일 정렬 클라이언트(iOS GraphQL, Android 정렬·코어)
- [x] `/docs` 마크다운 ETag REST 클라이언트
- [x] Discussions 공지 목록·작성·투표 참여 클라이언트
- [x] Issue Forms YAML 파서·Issue 생성 클라이언트
- [x] Releases 첨부 릴리스 확보 클라이언트
- [x] 4탭 UI 셸(홈·할 일·자료실·소통) — 목록 API 화면 바인딩은 설정값 투입 후 확장

## Phase 3 — 스레드 톡과 푸시

- [x] 스레드 톡·Reactions 클라이언트, Discord 딥링크
- [x] `push-bridge` Webhook→FCM(+KV 기기 토큰) Worker·테스트
- [x] 앱에서 Discord 딥링크·기기 등록 API 호출 훅(실제 FCM/APNs 토큰은 배포 설정 후)
- 지출 한도 $0 유지(설계 반영)
- 완료 기준: OAuth·Worker·Discord·FCM 실키 투입 후 수동 E2E

## 미결정

- **투표 생성.** `createDiscussion`에 poll 필드가 없다. 앱에서 투표를 만들 API가 생기기 전에는 만들지 않는다.
- **본문 이미지 직접 업로드.** `uploads.github.com`은 비공식이다. 공식 REST가 생기기 전에는 Releases Assets URL만 본문에 넣는다.
