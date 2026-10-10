# auth-bridge

앱이 GitHub·Discord에 `client_secret`을 넣지 않도록, Authorization Code + PKCE 교환만 수행하는 Cloudflare Worker.

## 배포

- URL: https://crewrp-auth-bridge.candydate.workers.dev
- 계정: Cloudflare `candydate`
- 시크릿: `GITHUB_CLIENT_ID`, `GITHUB_CLIENT_SECRET`, `DISCORD_CLIENT_ID`, `DISCORD_CLIENT_SECRET`, `ALLOWED_REDIRECT_URIS`=`crewrp://oauth/callback,discord-1558390079926308924:/authorize/callback`
- GitHub OAuth App callback: `crewrp://oauth/callback`
- Discord OAuth App redirect: `discord-1558390079926308924:/authorize/callback` (모바일 공식 형식, `://` 아님)

### Discord OAuth App 설정

- Application: CrewRP (`DISCORD_CLIENT_ID` / 앱 Client ID = `1558390079926308924`)
1. OAuth2 → Redirects에 **정확히** `discord-1558390079926308924:/authorize/callback` 추가.
2. OAuth2 → Client Secret → Worker `DISCORD_CLIENT_SECRET`(퍼블릭 키와 다름).
3. 앱 Client ID·URL scheme `discord-1558390079926308924` 반영됨.
4. 딥링크 서버·채널: `1382521889267908628` / `1382521889267908632`.

`DISCORD_CLIENT_SECRET`이 없으면 `POST /oauth/discord/token`은 `503 discord_not_configured`.

## 계약

- `POST /oauth/token` 본문: `code`, `code_verifier`, `redirect_uri` → GitHub `access_token`을 그대로 반환.
- `POST /oauth/discord/token` 본문: 동일 필드 → Discord 토큰 교환 후 `@me`를 조회해 `{ id, username }`만 반환(액세스 토큰은 응답에 넣지 않음).
- 사용자 토큰을 KV·로그·디스크에 저장하지 않는다.
- 허용된 `redirect_uri`만 받는다(`ALLOWED_REDIRECT_URIS`, 쉼표 구분).

## Commands

```bash
cd auth-bridge
npm install
npm test
npm run deploy
printf '%s' '...' | npx wrangler secret put GITHUB_CLIENT_ID
printf '%s' '...' | npx wrangler secret put GITHUB_CLIENT_SECRET
printf '%s' '...' | npx wrangler secret put DISCORD_CLIENT_ID
printf '%s' '...' | npx wrangler secret put DISCORD_CLIENT_SECRET
printf '%s' 'crewrp://oauth/callback,discord-1558390079926308924:/authorize/callback' | npx wrangler secret put ALLOWED_REDIRECT_URIS
```
