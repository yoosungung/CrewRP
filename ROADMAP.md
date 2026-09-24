# ROADMAP.md

수행 순서. 불변 규칙은 [ARCHITECTURE.md](ARCHITECTURE.md). 코드와 `DESIGN.md`는 해당 Phase에 첫 코드가 들어올 때 만든다.

클라이언트는 iOS(Swift)와 Android(Kotlin), 로컬 캐시는 SQLite다. 두 앱은 같은 Phase를 따른다.

## Phase 1 — 인증과 캐시

- 시스템 브라우저 OAuth PKCE(S256) 로그인.
- client secret 없이 토큰 교환이 되는지 확인한다. 필수라면 코드 교환 전용 Cloudflare Worker를 두고, 시크릿은 Worker에만 둔다.
- Organization 선택과 운영진/멤버 Team 식별.
- SQLite `cache_entry`(REST ETag)와 `graphql_cursor`. 토큰은 Keychain / EncryptedSharedPreferences.

## Phase 2 — 할 일, 자료, 공지, 서식

- Projects v2 칸반과 마감일 리스트.
- `/docs` 마크다운 렌더.
- Discussions 공지 목록·작성. 기존 투표 참여(`addDiscussionPollVote`)만 포함한다.
- `.github/ISSUE_TEMPLATE` YAML을 네이티브 서식으로 렌더하고 Issue를 생성한다.
- 첨부는 Releases Assets(파일당 100MB–2GB)만 사용한다.

## Phase 3 — 스레드 톡과 푸시

- Issue/Discussion 댓글의 말풍선 뷰와 Reactions.
- Discord 딥링크.
- GitHub Webhook → Cloudflare Worker → FCM. 기기 토큰은 Workers KV.
- 지출 한도 $0. Actions 월 2,000분, Workers 일 100,000 요청·CPU 10ms, KV 쓰기 일 1,000회를 넘기는 기능은 넣지 않는다.

## 미결정

- **투표 생성.** `createDiscussion`에 poll 필드가 없다. 앱에서 투표를 만들 API가 생기기 전에는 만들지 않는다.
- **본문 이미지 직접 업로드.** `uploads.github.com`은 비공식이다. 공식 REST가 생기기 전에는 Releases Assets URL만 본문에 넣는다.
