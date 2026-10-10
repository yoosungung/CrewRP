# ARCHITECTURE.md

CrewRP(Crew Resource Planning)의 불변 계약과 컴포넌트 *간* 인터페이스. 일정은 [ROADMAP.md](ROADMAP.md).

클라이언트는 iOS(Swift)와 Android(Kotlin) 두 개다. 둘은 이 문서의 계약을 각자 구현하고, 원본 데이터는 GitHub에만 둔다.

## 1. 계약사항

- 크루는 앱에 **등록된** private repository 하나(`owner/repo`)다. 앱 코드에 특정 저장소 이름(예: 테스트용 `ai-edu`)을 넣지 않는다.
- **소유(크루 시작)는 계정당 최대 1개.** 로그인한 사용자가 admin인 private 저장소를 골라 등록하면 그 사람이 해당 크루 운영진(owner)이 된다. 이미 owner인 크루가 있으면 새 등록을 막고, 기존 소유를 넘기거나 해제한 뒤에만 다시 등록한다.
- **가입(멤버)은 여러 개.** 이메일 초대로 들어온 크루는 제한 없이 가질 수 있고, 앱에서 활성 크루를 바꿔 가며 본다.
- 멤버 구성: 운영진이 **이메일**로 Organization 초대를 보낸다. 따라서 크루 보관소는 GitHub Free Organization 소속 private repository여야 한다. Team slug는 `admins`(운영진) / `members`(멤버).
- 화면 문구에 Git, Commit, PR, Issue, Discussion을 노출하지 않는다. 사용자 용어는 자료실, 할 일, 공지, 서식, 소통, 크루 시작, 초대다.
- 앱 바이너리에 OAuth client secret과 GitHub App / Discord client secret을 넣지 않는다. 로그인은 시스템 브라우저와 Authorization Code + PKCE(S256)다. GitHub 액세스 토큰은 iOS Keychain, Android EncryptedSharedPreferences에만 둔다.
- GitHub·Discord 토큰 엔드포인트는 `client_secret`을 요구한다. 시크릿은 `auth-bridge` Cloudflare Worker에만 두고, 앱은 코드·verifier를 Worker에 넘겨 교환한다. 사용자 토큰은 Worker에 저장하지 않는다.
- **계정:** CrewRP 신원은 GitHub 로그인으로 만든다. Discord는 **선택 연동**(identify). GitHub 토큰으로 Discord API에 로그인하지 않는다. 연동 결과는 기기에 `discord_user_id`·표시 이름만 둔다(Discord 액세스 토큰은 연동 직후 폐기).
- GitHub, Cloudflare, Firebase의 결제 한도는 $0이며, 포함 한도를 넘기면 사용을 멈춘다. 포함 한도는 §5와 같다.
- 의결, 회계, 문서의 감사 추적은 GitHub에 남긴다. 로컬 SQLite는 캐시이며 원본이 아니다.
- 실시간 채팅 엔진을 두지 않는다. **소통(잡담·음성)은 Discord 딥링크**다. Issue 댓글 말풍선은 소통 탭의 본체가 아니다(할 일별 업무 대화는 별도).
- 본문에 넣는 파일은 Releases Assets로만 업로드한다. 비공식 업로드 엔드포인트는 계약이 아니다.

## 2. 크루 리소스

| 개념 | GitHub 리소스 | 식별 |
|------|----------------|------|
| 크루 보관소 | Organization의 private repository | `owner/repo` (앱이 등록) |
| 운영진 / 멤버 | Organization Team | slug `admins` / `members` |
| 초대 | Organization invitation | 이메일만 |

멤버십이 없는 사용자는 크루 데이터를 읽지 못한다. `admins` Team(또는 저장소 등록자)만 편집·삭제·초대를 수행한다. `members`는 읽기와 본인 작성만 한다.

## 3. 화면과 API

하단 탭은 홈, 할 일, 자료실, 소통이다. 로그인 직후는 **내 크루** 목록(소유·가입)이다. 소유 크루가 없으면 **크루 시작**(admin private repo 선택)을 할 수 있다.

| 화면 | 사용자 용어 | GitHub 리소스 | 연동 |
|------|-------------|---------------|------|
| 로그인 / 권한 | 계정, 운영진, 멤버 | Organization, Team, Repositories | OAuth 2.0 PKCE. 등록 저장소·Team으로 편집·삭제 버튼 노출 |
| 내 크루 | 크루 전환 | memberships | 소유 0–1 + 가입 N. 하나를 골라 활성 세션으로 둔다 |
| 크루 시작 | 크루 등록 | Repositories (admin) | admin private repo 중 하나 등록. 이미 owner면 불가 |
| 초대 | 초대 | Organization invitation | 이메일만 |
| 공지 / 자유게시판 | 공지 | Discussions | GraphQL. 카테고리별 목록·본문 조회와 작성 |
| 투표 참여 | 투표 | Discussion poll | 기존 poll 조회와 `addDiscussionPollVote`. 앱에서 poll 생성은 하지 않는다 |
| 할 일 | 할 일 | Projects (v2), Issues | GraphQL. 상태 필드 값으로 접수 → 진행 중 → 완료 |
| 행정 서식 | 서식 | Issue Forms YAML, Issues | 앱이 `.github/ISSUE_TEMPLATE` YAML을 읽어 네이티브 폼을 그린 뒤 Issue를 생성 |
| 정관 / 규정 / 자료 | 자료실 | Repository contents `/docs` + Releases Assets | **문서**는 `docs/**/*.md`(필요 시 `.txt`) — Contents 목록·본문, Trees 검색, 인앱 마크다운 렌더/편집. **첨부**(이미지·PDF·기타)는 `crewrp-attachments` Release Assets — 업로드·목록·다운로드. 탭 시 미리보기 가능하면 View(QuickLook/Intent), 아니면 Share/Download. 본문에 넣을 때도 asset URL만. 범용 바이너리를 Contents에 올리지 않는다 |
| 정기 과업 | 자동 업무 | Actions | `workflow_dispatch` 또는 cron. private repository 포함 분(分) 안에서만 |
| 소통 | 소통 / 바로 대화 | `.crewrp/settings.json` + Discord | 탭 선택 시 크루 설정의 서버·채널로 딥링크(미연동이면 OAuth). Issue 댓글 UI 아님 |
| 알림 | 알림 | Webhook | Phase 3. Webhook → Cloudflare Worker → FCM |

할 일 화면은 칸반과 마감일 리스트를 같은 Project 데이터로 전환한다. 홈은 마일스톤, 오늘 할 일, 고정 공지, 최근 활동의 조합이며 별도 저장소가 아니다. 공지·할 일·자료실의 목록·작성·수정·삭제는 앱 네이티브 UI에서 하며, 원본은 GitHub에만 둔다. 소통은 Discord다. Discord **OAuth 앱**은 CrewRP 공용이고, **서버·채널 ID는 크루 repo**의 `.crewrp/settings.json`에 둔다(앱 바이너리에 하드코딩하지 않음).

```json
{ "discord": { "serverId": "…", "channelId": "…" } }
```

운영진이 앱에서 등록하거나 파일을 직접 커밋한다.


### 계정 UX (가입·사용·로그인·로그아웃)

| 단계 | 동작 |
|------|------|
| 가입 | GitHub OAuth로 CrewRP 세션 생성 → 크루 시작/초대 수락. Discord는 선택 |
| 사용 | 공지·할 일·자료실 = GitHub. 소통 = Discord 연동 후 **활성 크루** `.crewrp/settings.json`의 서버·채널 딥링크 |
| 로그인 | 저장된 GitHub 세션 복귀. Discord는 연동 기록만 보고, Discord 앱 로그인 상태는 OS/Discord가 관리 |
| 로그아웃 | GitHub 토큰·크루 세션·Discord 연동 기록을 지움. Discord 앱 로그아웃과 동기화하지 않음 |
| Discord만 해제 | 연동 기록만 삭제. GitHub·크루는 유지 |

## 4. 인증과 권한

1. 앱이 `code_verifier`를 만들고 `code_challenge`(S256)를 붙인 authorize URL을 시스템 브라우저로 연다. GitHub scope는 `read:org repo project`(Org·저장소·Projects v2 쓰기).
2. 리다이렉트 URI로 돌아온 `code`와 `code_verifier`를 `auth-bridge` `POST /oauth/token`에 넘긴다. Worker가 GitHub `client_secret`으로 교환하고, 토큰은 응답으로 기기에만 전달한다.
3. 토큰으로 **가입된** 크루(Org `members`/`admins` Team 또는 초대 수락 저장소)와, 아직 owner가 없을 때만 **등록 후보**(admin private repo)를 보여 준다.
4. 사용자가 크루를 고르면 그 `owner/repo`를 **활성 세션**으로 둔다. owner 등록은 계정당 1회(기존 owner가 없을 때)만 허용한다.
5. 활성 크루 Organization에서 `admins`(또는 등록 owner)면 편집·삭제·초대, `members`면 읽기와 본인 작성. Org Team이 없고 저장소 admin이면 운영진으로 본다.
6. Discord 연동: 별도 PKCE authorize(`scope=identify`, redirect `discord-{clientId}:/authorize/callback`). `auth-bridge` `POST /oauth/discord/token`이 코드를 교환한 뒤 Discord `@me`를 조회해 `id`·표시 이름만 앱에 돌려준다. 앱은 `account_link`에 저장하고 Discord 액세스 토큰은 보관하지 않는다.

초대는 관리자가 이메일을 입력하면 Organization invitation API로 메일을 보낸다. 초대 수락자는 가입 목록에만 추가된다(소유 슬롯을 쓰지 않는다).

## 5. 캐시, 한도, 푸시

로컬 스키마(두 클라이언트가 같은 컬럼을 유지한다):

| 테이블 | 키 | 용도 |
|--------|----|------|
| `cache_entry` | `url` | REST 응답 본문, `etag`, `fetched_at` |
| `graphql_cursor` | `query_name` | GraphQL `cursor`, `updated_at` |
| `crew_membership` | `repo` (`owner/name`) | 내가 소유·가입한 크루. `relation` = `owner` \| `member`, `team_role`. owner 행은 기기당 최대 1개 |
| `session` | 기기당 1행 | 활성 크루: org, repo(`owner/name`), team role. 토큰은 이 테이블에 넣지 않는다 |
| `account_link` | `provider` (`discord`) | Discord 연동: `user_id`, `username`, `linked_at`. 액세스 토큰 없음 |

- REST GET은 저장된 `etag`를 `If-None-Match`로 보낸다. `304`는 일차 한도를 소모하지 않으므로 캐시를 유지한다.
- GraphQL(Discussions, Projects v2)은 ETag가 없다. `graphql_cursor.updated_at`이 신선하면 네트워크를 치지 않는다.
- 자료실 Trees 검색 인덱스는 `graphql_cursor`(`docsTree:owner/repo`)에 tree SHA·TTL(60s)을 둔다. TTL이 신선하면 네트워크 생략. 만료 시 얕은 tree로 SHA만 비교해 같으면 캐시를 쓰고, 다르거나 강제 새로고침·쓰기 후면 `recursive=1`을 다시 받는다.
- 한도는 사용자 토큰 기준 REST 시간당 5,000회, GraphQL 시간당 5,000포인트로 서로 따로 센다.
- GitHub Free for organizations: private repository Actions 월 2,000분, Actions/Packages 저장 500MB. 초과 과금이 나지 않도록 지출 한도를 $0으로 둔다.
- Cloudflare Workers 무료: 일 100,000 요청, 호출당 CPU 10ms. KV 쓰기는 일 1,000회. 푸시 브리지는 이 안에 둔다.
- FCM 발송 요금은 없다. 기기 토큰은 Workers KV에만 둔다. Worker는 GitHub Webhook(공지, 댓글, 담당자 배정)을 검증한 뒤 FCM으로 전달한다.

## 6. 이벤트

Worker가 구독하는 Webhook과 앱에 보이는 알림 이름:

| GitHub event | 알림 |
|--------------|------|
| `discussion` created | 새 공지 |
| `discussion_comment` created | 공지 댓글 |
| `issues` assigned | 할 일 배정 |

이 외 이벤트는 푸시하지 않는다.
