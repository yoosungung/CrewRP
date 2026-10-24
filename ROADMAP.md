# ROADMAP.md

수행 순서. 불변 규칙은 [ARCHITECTURE.md](ARCHITECTURE.md). 코드와 `DESIGN.md`는 해당 Phase에 첫 코드가 들어올 때 만든다.

클라이언트는 iOS(Swift)와 Android(Kotlin), 로컬 캐시는 SQLite다. 두 앱은 같은 Phase를 따른다.

## Phase 1 — 인증과 캐시

- [x] PKCE·SQLite·TeamRole 코어, `auth-bridge` 교환 Worker
- [x] 토큰 보관(Keychain / EncryptedSharedPreferences)
- [x] auth-bridge 코드 교환 클라이언트
- [x] Organization 목록·`admins`/`members` Team 식별 클라이언트
- [x] 시스템 브라우저 로그인 UI(앱 셸: iOS/Android 외부 브라우저 + `crewrp://` 콜백)
- 완료 기준: GitHub OAuth App·Worker URL을 넣고 로그인·조직 선택 수동 확인

## Phase 2 — 할 일, 자료, 공지, 서식

- [x] Projects v2 칸반/마감일 정렬 클라이언트(iOS GraphQL, Android 정렬·코어)
- [x] `/docs` 마크다운 ETag REST 클라이언트
- [x] Discussions 공지 목록·작성·투표 참여 클라이언트
- [x] Issue Forms YAML 파서·Issue 생성 클라이언트
- [x] Releases 첨부 릴리스 확보 클라이언트
- [x] 4탭 UI 셸(홈·할 일·자료실·소통) — 목록 API 화면 바인딩은 설정값 투입 후 확장
- [x] 앱 셸 CRUD: 공지·할 일·자료실·스레드 톡 작성·수정·삭제 (GitHub 용어 비노출)

## Phase 3 — 스레드 톡과 푸시

- [x] 스레드 톡·Reactions 클라이언트, Discord 딥링크
- [x] `push-bridge` Webhook→FCM(+KV 기기 토큰) Worker·테스트
- [x] 앱에서 Discord 딥링크·기기 등록 API 호출 훅(실제 FCM/APNs 토큰은 배포 설정 후)
- [x] 스레드 톡 앱 CRUD(댓글 전송·수정·삭제·반응) 화면 바인딩
- 지출 한도 $0 유지(설계 반영)
- [x] 코어 CRUD E2E 하네스(`scripts/e2e-crud.sh`, `CREWRP_E2E_TOKEN`+`CREWRP_E2E_REPO`; 할 일은 `project` 토큰 또는 에뮬 앱 세션 `DeviceCrudSmokeTest`)
- 완료 기준: OAuth·Worker·Discord·FCM 실키 투입 후 UI 수동 E2E + `./scripts/e2e-crud.sh` 통과(할 일: host `project` 또는 로그인된 에뮬)

## Phase 4 — 소통 = Discord 계정 연동

- [x] `auth-bridge` Discord 코드 교환 + `@me` (`POST /oauth/discord/token`)
- [x] 기기 `account_link`(discord) 저장·해제, 로그아웃 시 삭제
- [x] 소통 탭: Discord 연결 / 바로 대화(딥링크) / 연결 해제 (Issue 말풍선 본체 제거)
- [x] Discord OAuth App·서버/채널 ID 실키 투입 후 수동 E2E (`DISCORD_CLIENT_*` Worker 시크릿 + 앱 `DiscordClientID`/`DISCORD_CLIENT_ID`)
- 완료 기준: GitHub 로그인 후 Discord 연동 → 소통에서 딥링크 진입, 해제·로그아웃 시 연동 기록 없음

## Phase 5 — 소통 허브 + 홈 README

- [x] 홈: repo `README.md` Contents 렌더, 고정 공지 섹션·홈 공지 작성 제거
- [x] 소통: Discord 상단 + Discussions 카테고리 → 글 CRUD (탭 자동 딥링크 제거)
- [x] `listCategories` / 카테고리별 `listDiscussions` 코어·테스트
- [x] 홈 README·소통 카테고리 글 수동 E2E
- 완료 기준: 홈에서 README, 소통에서 바로 대화·카테고리 글 작성·열람 수동 확인

## Phase 6 — 할 일·게시판 댓글

- [x] 할 일 상세에서 Issue comments 목록·작성·수정·삭제 (`ThreadTalkClient`)
- [x] 게시판 글 상세에서 Discussion comments 목록·작성·수정·삭제 (`DiscussionsClient`)
- [x] 작성·수정 팝업 제목을 할 일·글·문서 제목(경로 basename)으로 표시
- [ ] 수동 E2E: 할 일·게시판 글에서 댓글 1회 작성·수정·삭제
- 완료 기준: issueNumber 있는 할 일·Discussion 글에서 댓글 CRUD 확인

## Phase 7 — 공부 (Study, 구 UniTutor)

경험은 [docs/study/PRODUCT.md](docs/study/PRODUCT.md), 스키마·계약은 [ARCHITECTURE.md](ARCHITECTURE.md) §7. **구현은 이 저장소(CrewRP)만.** [UniTutorAI](https://github.com/yoosungung/UniTutorAI)는 동결.

티켓 상태: `todo` | `doing` | `done`. TDD: 실패 테스트 → 구현 → 통과. 두 클라이언트(iOS/Android) 동일 순서.

### S7-01 · 공개 강의 1개 정적 자산

- **내용**: 자막(VTT)·슬라이드 라벨을 배치 1회로 `CourseRef` + `SourceSpan[]` JSON. 크루 repo에서 로드(UI). 런타임 인덱싱 $0.
- **완료 조건**: 한 강의의 `id`/`playbackUrl`/`SourceSpan`이 로드된다.
- **상태**: `done` — 테스트 픽스처 `cs-algo-intro-01`(MIT 6.006 L1). 첫 과목 **CS**.

### S7-02 · 적응형 2분할 공부 캔버스 (네이티브)

- **내용**: 세로 상하 / 가로 좌우. 분할 핸들 스냅 `7:3` · `5:5` · `3:7`. 튜터 UI는 영상 영역을 가리지 않는다.
- **완료 조건**: 뷰포트 전환·핸들 스냅이 테스트/수동으로 확인되고 PRODUCT §4.3을 만족한다.
- **상태**: `done` — 코어 비율 테스트 + iOS/Android 캔버스 UI.

### S7-03 · 영상 WebView (YouTube embed, 무저장)

- **내용**: `playbackUrl`을 WebView **최상위**로 로드. `CitationSelected` 시 `startSec`로 seek/재로드. 앱이 영상을 저장하지 않는다.
- **의존**: S7-02
- **완료 조건**: 재생·인용 점프가 동작한다.
- **상태**: `done` — `embedPlaybackURL` + WebView 재로드(`?start=`).

### S7-04 · 네이티브 `TutorTurn` + 저가 추론

- **내용**: 네이티브가 Worker 또는 BYOK로 1질문 튜터 호출. 스키마·`out_of_scope` 준수. 시크릿은 바이너리에 없음.
- **의존**: S7-01
- **완료 조건**: `question` 하나·`citations`·`escalationStep`을 받고 정답/풀이 전문이 실리지 않는다(계약 테스트).
- **상태**: `done` — 1단계는 `BundledTutorClient`(정적 프롬프트, 시크릿 없음). Worker/BYOK는 후속.

### S7-05 · 튜터 대화 UI + 시각 점프

- **내용**: 대화 슬롯(네이티브). 인용 탭 → `CitationSelected`. 속생각 접힌 한 줄.
- **의존**: S7-03, S7-04
- **완료 조건**: 질문 → 인용 → 영상 점프가 한 캔버스에서 끝난다.
- **상태**: `done`

### S7-06 · 홈에서 공부 진입 E2E

- **내용**: 홈 CTA → 고정 강의 1개 캔버스. 장면 보기 + 질문 1개.
- **의존**: S7-02~S7-05
- **완료 조건**: 크루 홈에서 공부로 들어가 강의를 보며 질문을 받는다.
- **상태**: `done` — 홈 「이어서 할 공부」 CTA. 수동 기기 확인은 로그인 후.

### S7-07 · 경로·온보딩·detour (2단계)

- **내용**: 정적 지식 DAG, Advisor 온보딩으로 `skipped`, 막힘 시 `DetourInserted`.
- **의존**: S7-06
- **완료 조건**: 온보딩으로 아는 개념이 `skipped`되고, 막힘 시 선수 장면이 `detour`로 끼워진 뒤 `returnToSpanId`로 돌아온다(코어 테스트 + 캔버스 UI).
- **상태**: `done` — `StudyPath` + 번들 `knowledgeEdges`, iOS/Android 온보딩·경로 줄·막혀요/우회 끝.

### S7-08 · 세션 종료 + 로컬 `ReviewCard`

- **내용**: `SessionClosed` → SQLite `review_card` 1장. `fadesAt`(1단계는 고정 간격 가능).
- **의존**: S7-06
- **상태**: `todo`

### S7-09 · 카드 알림·문답 한도·BYOK (3단계)

- **내용**: `CardFaded` 알림, 하루 문답 한도, BYOK/광고 중 하나.
- **의존**: S7-08, §미결정
- **상태**: `todo`

### S7-10 · 학습 탭 셸 (5탭)

- **내용**: 하단 탭을 홈·할 일·**학습**·자료실·소통으로 바꾼다. 학습 탭 골격(최근 / 과목·수업 / 운영진 과목 관리 진입점). 홈 CTA는 학습·최근으로 연결. `SHELL_*_TAB_INDEX` 갱신.
- **의존**: S7-06
- **완료 조건**: 양 클라이언트에서 5탭·학습 빈 상태가 보인다. 운영진에게만 과목 관리 진입이 보인다.
- **상태**: `done`

### S7-11 · 과목·수업 카탈로그 로드

- **내용**: `.crewrp/study/subjects.json`·`courses.json`·`course.json` 읽기. 과목→수업 목록 UI. repo 비면 빈 상태(번들 UI 폴백 없음; `loadBundled`는 테스트 픽스처만).
- **의존**: S7-10
- **완료 조건**: 픽스처/실 repo에서 과목·수업이 목록에 나오고 탭하면 기존 캔버스가 열린다. 카탈로그 비면 빈 UI.
- **상태**: `done`

### S7-12 · 최근 수업 (로컬)

- **내용**: 수업 오픈 시 로컬에 `(subjectId, courseId, openedAt)` 기록. 학습 탭 상단 「최근 수업」. 홈 「이어서 할 공부」와 동일 소스.
- **의존**: S7-11
- **완료 조건**: 수업을 연 뒤 최근·홈 CTA에 반영된다(코어 테스트 + UI).
- **상태**: `done`

### S7-13 · 네이티브 과정 배치 (자막→JSON)

- **내용**: UniTutor `content/`와 동일 규칙으로 `parseSubtitles`·`buildSourceSpans`·`validateSpans`를 crewrp-core / CrewRPCore에 이식. 선형 `knowledgeEdges`. CLI/Worker 없음.
- **의존**: S7-01 스키마
- **완료 조건**: 픽스처 VTT+마커 → `SourceSpan[]` 단위 테스트 통과(양 플랫폼).
- **상태**: `done`

### S7-14 · 운영진 과목·수업 저장 (기기→repo)

- **내용**: 과목 CRUD, 수업 만들기 폼(재생 URL·자막 파일·개념 마커 편집) → S7-13 배치 → Contents로 `.crewrp/study/...` 커밋. GitHub 용어 비노출. `admins`만.
- **의존**: S7-11, S7-13
- **완료 조건**: 운영진이 앱에서 과목·수업을 저장하면 다른 기기/멤버 목록에 보인다. 멤버는 관리 UI가 없다.
- **상태**: `done` — 자막·마커는 텍스트 입력(파일 피커는 후속). S7-15에서 URL→초안 검수로 교체.

### S7-15 · 수업 초안 (URL→자막·챕터→검수)

- **내용**: 재생 URL만으로 자막·YouTube 챕터를 읽어 `draftConceptMarkers` 초안 → 목록에서 이름·합치기·삭제 → S7-13 배치·저장. VTT 붙여넣기는 가져오기 실패 폴백. LLM 없음.
- **의존**: S7-13, S7-14
- **완료 조건**: 챕터 있는 URL·챕터 없는 VTT 픽스처에서 초안이 나오고, 검수 후 저장되면 멤버 목록에 수업이 보인다.
- **상태**: `done`

### 재생목록으로 강의 등록 (S7-16~S7-20)

과목 아래 수업은 지금 영상 하나마다 재생 URL을 붙여 초안을 검수한 뒤 저장한다. 바꿀 등록은 공개 YouTube 재생목록 하나를 과목의 수업 목록으로 한 번에 넣는 것이다. 뺀 영상·사이에 끼운 영상은 그 다음 편집에서만 다룬다. 학습 캔버스의 수업 하나는 지금처럼 영상 하나(`CourseRef` + `course.json`)다. 과목과 수업 사이에 이름 있는 과정 계층은 두지 않는다.

착수할 때 [ARCHITECTURE.md](ARCHITECTURE.md) §7과 [docs/study/PRODUCT.md](docs/study/PRODUCT.md) §4.6을 이 절에 맞게 고친 다음 코드를 넣는다. 스키마 초안은 여기 두고, 구현 전 §7을 먼저 바꾸지 않는다.

#### 흐름

| | 지금 (S7-14·S7-15) | 개선 (S7-16~) |
|--|-------------------|---------------|
| 등록 단위 | 수업 1개 = 재생 URL 1개. id·제목을 손으로 넣는다 | 과목에 재생목록 URL 1개. 영상마다 id는 `yt-<videoId>`, 제목은 재생목록 항목 |
| 손질 시점 | 저장 전에 그 영상의 개념 마커를 검수해야 한다 | 등록은 자막·챕터 초안을 자동 저장하고 끝낸다. 마커 검수·영상 빼기·끼워 넣기는 등록 후 목록 편집 |
| 순서 | `courses.json` 배열 순. 끼워 넣기 UI 없음 | 같은 배열이 수업 순서. 편집에서 삭제·한 칸 이동·그 자리에 영상 URL 하나 삽입 |
| 재생목록과 목록의 관계 | 없음 | 가져오기는 그 시점의 스냅샷. 유튜브에서 재생목록이 바뀌어도 크루 목록은 그대로다 |
| 누가 | `admins`만 생성·수정. `members`는 목록·재생 | 같다. 재생목록에서 온 수업도 운영진이면 빼거나 다른 영상을 끼울 수 있다. 역할은 늘리지 않는다 |

한 과목에 재생목록을 두 번 가져오면 기존 목록 뒤에 이어 붙인다. 같은 `youtubeVideoId`는 건너뛴다. 자막을 못 읽은 영상은 `courses.json`에 넣지 않고, 가져오기 결과에만 실패로 남긴다. 그 영상은 편집의 끼워 넣기(기존 URL→초안, VTT 붙여넣기 폴백)로 나중에 넣는다.

다시 가져오기(유튜브와 맞추기)와 과목 안을 여러 재생목록 묶음으로 나누는 중간 계층은 이 범위에 넣지 않는다.

#### 데이터

수업 재생·튜터 계약(`CourseRef`, `SourceSpan`, `course.json`)은 그대로다. 출처는 카탈로그인 `courses.json` 항목에만 둔다. 배열 순서가 화면 순서다. 별도 `position`은 두지 않는다.

기존 `[{ "id", "title" }]`는 그대로 읽는다. `origin`이 없으면 예전 수동 등록이다.

재생목록에서 온 항목:

```json
{
  "id": "yt-HtSuA80QTyo",
  "title": "Lecture 1",
  "origin": "playlist",
  "playlistId": "PLxxxx",
  "youtubeVideoId": "HtSuA80QTyo",
  "playlistIndex": 0
}
```

편집에서 끼운 항목은 `origin`이 `manual`이고 `playlistId`·`playlistIndex`가 없다. `playlistIndex`는 가져올 때의 재생목록 순번이다. 빼거나 끼운 뒤에는 정렬에 쓰지 않는다.

`subjects.json`은 `{ "id", "title" }` 그대로다. 재생목록 id는 수업 항목에만 둔다.

권한은 §7.0과 같다. `origin`은 권한을 나누지 않는다. 운영진만 일괄 등록·빼기·끼워 넣기·순서 변경·마커 재검수를 한다. 멤버에게 편집 UI를 보이지 않는다.

가져오기 구현은 S7-15와 같이 네이티브 HTTP다. 공개 재생목록 페이지의 `ytInitialData`에서 `playlistVideoRenderer`(`videoId`, 제목)를 읽고, 100개 넘으면 `continuation`으로 `youtubei/v1/browse`를 이어 받는다. Data API 키와 Worker는 만들지 않는다. 비공개 재생목록·믹스(`RD`)·재생 불가는 건너뛰고 결과에 사유를 남긴다.

#### 티켓

우선순위는 위가 먼저다. 코어 파서·스키마가 되기 전에 UI를 붙이지 않는다. TDD, iOS·Android 같은 순서.

1. **S7-16 · 재생목록 파서** (먼저) — `playlist?list=` / `watch?v=&list=`에서 `playlistId`. 픽스처 HTML·continuation JSON → 순서 있는 `{videoId, title, index}`. 재생 불가·id 없음은 제외.
   - **의존**: 없음(S7-15의 시청 페이지 파서와 같은 코어).
   - **완료 조건**: 양 플랫폼 단위 테스트. 네트워크 없는 픽스처로 첫 페이지와 continuation 한 번이 이어져 같은 순서가 나온다.
   - **상태**: `todo`

2. **S7-17 · 수업 목록 출처 필드** (먼저, S7-16과 병렬 가능) — `courses.json` 읽기/쓰기가 위 필드를 왕복하고, 필드 없는 기존 파일을 깨지 않는다. 수업 id 기본값은 `yt-<videoId>`.
   - **의존**: 없음.
   - **완료 조건**: 기존 카탈로그 픽스처가 그대로 파싱되고, 출처 필드가 직렬화 테스트로 유지된다.
   - **상태**: `todo`

3. **S7-18 · 일괄 초안** — 재생목록 항목마다 기존 `draftFromPlaybackUrl`로 `course.json`·`concepts.json`을 만든다. 순서는 재생목록 순(실패한 항목은 빈칸 없이 빠진다). 같은 과목의 `youtubeVideoId`는 건너뛴다. 한 편 실패가 나머지를 롤백하지 않는다.
   - **의존**: S7-13, S7-15, S7-16, S7-17
   - **완료 조건**: 픽스처 전송으로 N건 중 성공만 자산이 생기고, 중복·자막 실패는 결과 목록에 사유가 남는다.
   - **상태**: `todo`

4. **S7-19 · 운영진 가져오기 화면** — 과목 관리에 재생목록 URL, 가져오기 전 제목 목록, 진행(`3/N`), 저장. 저장은 성공분만 Contents에 올리고 `courses.json` 끝에 이어 붙인다. 화면에는 GitHub 용어를 쓰지 않는다. 지금 수업 만들기 폼은 등록 기본 경로에서 빼되, 끼워 넣기(S7-20)가 그 폼을 쓴다.
   - **의존**: S7-14, S7-18
   - **완료 조건**: 운영진이 재생목록 하나로 여러 수업이 멤버 목록에 재생목록 순서대로 보인다. 멤버에게는 가져오기 UI가 없다.
   - **상태**: `todo`

5. **S7-20 · 수업 목록 편집** — 운영진 목록에서 한 편 빼기(목록 항목과 `course.json`·`concepts.json`·선택 `source.vtt` 삭제), 위·아래 한 칸, 고른 자리에 재생 URL 하나 끼워 넣기(S7-15 검수 후 그 인덱스에 삽입).
   - **의존**: S7-17, S7-19
   - **완료 조건**: 빼기·이동·끼워 넣기 뒤 `courses.json` 순서가 바뀌고, 멤버가 연 목록과 같다. 멤버에게는 편집 UI가 없다.
   - **상태**: `todo`

**권장 순서:** S7-10 → S7-13(병렬 가능) → S7-11 → S7-12 → S7-14 → S7-15 → (S7-16 ∥ S7-17) → S7-18 → S7-19 → S7-20. S7-08·S7-09는 학습 탭과 독립이라 끼워 넣거나 뒤에 둬도 된다.

---

## 미결정

- **투표 생성.** `createDiscussion`에 poll 필드가 없다. 앱에서 투표를 만들 API가 생기기 전에는 만들지 않는다.
- **본문 이미지 직접 업로드.** `uploads.github.com`은 비공식이다. 공식 REST가 생기기 전에는 Releases Assets URL만 본문에 넣는다.
- ~~**공부 첫 과목.**~~ → **CS** (`cs-algo-intro-01`, S7-01)
- **무료 문답 하루 기본 횟수**, 광고 1회당 충전, BYOK 노출 시점 → **S7-09**
- **다시 보기 알림 하루 상한** → **S7-09**
- **학습 탭 최근 수업 최대 개수** → 기본 10(변경 시 S7-12와 함께)
- **자막 `source.vtt`를 repo에 항상 올릴지** → 기본은 `course.json`(+`concepts.json`)만; VTT는 선택(S7-14)
