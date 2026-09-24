# ARCHITECTURE.md

CrewRP(Crew Resource Planning)의 불변 계약과 컴포넌트 *간* 인터페이스. 일정은 [ROADMAP.md](ROADMAP.md).

클라이언트는 iOS(Swift)와 Android(Kotlin) 두 개다. 둘은 이 문서의 계약을 각자 구현하고, 원본 데이터는 GitHub에만 둔다.

## 1. 계약사항

- 한 크루는 GitHub Free Organization 하나와 private repository 하나다. 편집·삭제 권한은 Organization Team(운영진 / 멤버)으로만 나눈다. 초대는 이메일로만 보낸다.
- 화면 문구에 Git, Commit, PR, Issue, Discussion을 노출하지 않는다. 사용자 용어는 자료실, 할 일, 공지, 서식, 스레드 톡이다.
- 앱 바이너리에 OAuth client secret과 GitHub App private key를 넣지 않는다. 로그인은 시스템 브라우저와 Authorization Code + PKCE(S256)다. 액세스 토큰은 iOS Keychain, Android EncryptedSharedPreferences에만 둔다.
- GitHub 토큰 엔드포인트는 `client_secret`을 요구한다. 시크릿은 `auth-bridge` Cloudflare Worker에만 두고, 앱은 코드·verifier를 Worker에 넘겨 교환한다. 사용자 토큰은 Worker에 저장하지 않는다.
- GitHub, Cloudflare, Firebase의 결제 한도는 $0이며, 포함 한도를 넘기면 사용을 멈춘다. 포함 한도는 §5와 같다.
- 의결, 회계, 문서의 감사 추적은 GitHub에 남긴다. 로컬 SQLite는 캐시이며 원본이 아니다.
- 실시간 채팅 엔진을 두지 않는다. 스레드 톡은 댓글과 Reaction의 말풍선 뷰다. 음성과 잡담은 Discord 딥링크만 사용한다.
- 본문에 넣는 파일은 Releases Assets로만 업로드한다. 비공식 업로드 엔드포인트는 계약이 아니다.

## 2. 크루 리소스

| 개념 | GitHub 리소스 | 식별 |
|------|----------------|------|
| 크루 | Organization | `org login` |
| 보관소 | 그 Organization의 private repository 하나 | `owner/repo` |
| 운영진 / 멤버 | Organization Team | slug `admins` / `members` |
| 초대 | Organization invitation | 이메일 |

멤버십이 없는 사용자는 크루 데이터를 읽지 못한다. `admins` Team에 속한 계정만 편집·삭제·초대를 수행한다. `members`는 읽기와 본인 작성만 한다.

## 3. 화면과 API

하단 탭은 홈, 할 일, 자료실, 소통이다.

| 화면 | 사용자 용어 | GitHub 리소스 | 연동 |
|------|-------------|---------------|------|
| 로그인 / 권한 | 계정, 운영진, 멤버 | Organization, Team | OAuth 2.0 PKCE. Team 소속으로 편집·삭제 버튼 노출 |
| 공지 / 자유게시판 | 공지 | Discussions | GraphQL. 카테고리별 목록·본문 조회와 작성 |
| 투표 참여 | 투표 | Discussion poll | 기존 poll 조회와 `addDiscussionPollVote`. 앱에서 poll 생성은 하지 않는다 |
| 할 일 | 할 일 | Projects (v2), Issues | GraphQL. 상태 필드 값으로 접수 → 진행 중 → 완료 |
| 행정 서식 | 서식 | Issue Forms YAML, Issues | 앱이 `.github/ISSUE_TEMPLATE` YAML을 읽어 네이티브 폼을 그린 뒤 Issue를 생성. GitHub는 폼을 렌더하는 API를 제공하지 않는다 |
| 정관 / 규정 / 자료 | 자료실 | Repository contents `/docs` | REST Contents API. 마크다운은 앱이 렌더 |
| 첨부 파일 | 첨부 | Releases Assets | REST. 파일당 100MB 이상 2GB 이하. 본문에는 asset URL만 삽입 |
| 정기 과업 | 자동 업무 | Actions | `workflow_dispatch` 또는 cron. private repository 포함 분(分) 안에서만 |
| 스레드 톡 | 스레드 톡 | Issue / Discussion comments, Reactions | 댓글 목록을 말풍선으로 표시. Reaction은 Reactions API |
| 음성 / 잡담 | 바로 대화 | 없음 | Discord 딥링크 |
| 알림 | 알림 | Webhook | Phase 3. Webhook → Cloudflare Worker → FCM |

할 일 화면은 칸반과 마감일 리스트를 같은 Project 데이터로 전환한다. 홈은 마일스톤, 오늘 할 일, 고정 공지, 최근 활동의 조합이며 별도 저장소가 아니다.

## 4. 인증과 권한

1. 앱이 `code_verifier`를 만들고 `code_challenge`(S256)를 붙인 authorize URL을 시스템 브라우저로 연다.
2. 리다이렉트 URI로 돌아온 `code`와 `code_verifier`를 `auth-bridge`에 넘긴다. Worker가 `client_secret`으로 GitHub와 교환하고, 토큰은 응답으로 기기에만 전달한다.
3. 토큰으로 사용자가 속한 Organization과 Team을 조회한다.
4. `admins`면 편집·삭제·초대를 노출한다. `members`면 읽기와 본인 작성만 노출한다.

초대는 관리자가 이메일을 입력하면 Organization invitation API로 메일을 보낸다.

## 5. 캐시, 한도, 푸시

로컬 스키마(두 클라이언트가 같은 컬럼을 유지한다):

| 테이블 | 키 | 용도 |
|--------|----|------|
| `cache_entry` | `url` | REST 응답 본문, `etag`, `fetched_at` |
| `graphql_cursor` | `query_name` | GraphQL `cursor`, `updated_at` |
| `session` | 기기당 1행 | org, repo, team role. 토큰은 이 테이블에 넣지 않는다 |

- REST GET은 저장된 `etag`를 `If-None-Match`로 보낸다. `304`는 일차 한도를 소모하지 않으므로 캐시를 유지한다.
- GraphQL(Discussions, Projects v2)은 ETag가 없다. `graphql_cursor.updated_at`이 신선하면 네트워크를 치지 않는다.
- 한도는 사용자 토큰 기준 REST 시간당 5,000회, GraphQL 시간당 5,000포인트로 서로 따로 센다.
- GitHub Free for organizations: private repository Actions 월 2,000분, Actions/Packages 저장 500MB. 초과 과금이 나지 않도록 지출 한도를 $0으로 둔다.
- Cloudflare Workers 무료: 일 100,000 요청, 호출당 CPU 10ms. KV 쓰기는 일 1,000회. 푸시 브리지는 이 안에 둔다.
- FCM 발송 요금은 없다. 기기 토큰은 Workers KV에만 둔다. Worker는 GitHub Webhook(공지, 댓글, 담당자 배정)을 검증한 뒤 FCM으로 전달한다.

## 6. 이벤트

Worker가 구독하는 Webhook과 앱에 보이는 알림 이름:

| GitHub event | 알림 |
|--------------|------|
| `discussion` created | 새 공지 |
| `issue_comment` / `discussion_comment` created | 스레드 톡 |
| `issues` assigned | 할 일 배정 |

이 외 이벤트는 푸시하지 않는다.
