# ios

iOS 클라이언트. Phase 1은 Swift Package `CrewRPCore`(PKCE, TeamRole, SQLite 캐시)다. UI 앱은 코어가 안정된 뒤 붙인다.

## 내부 구조

- `PKCE` / `GitHubOAuth`: S256 challenge와 authorize URL.
- `TeamRole`: slug `admins` / `members` → 권한.
- `CacheStore`: ARCHITECTURE §5 테이블(`cache_entry`, `graphql_cursor`, `session`). 토큰은 저장하지 않는다.

## Commands

```bash
cd ios
swift test
```
