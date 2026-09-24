# auth-bridge

앱이 GitHub에 `client_secret`을 넣지 않도록, Authorization Code + PKCE 교환만 수행하는 Cloudflare Worker.

## 계약

- `POST /oauth/token` 본문: `code`, `code_verifier`, `redirect_uri`.
- Worker는 `GITHUB_CLIENT_ID`·`GITHUB_CLIENT_SECRET`으로 GitHub `access_token`을 요청하고, 응답의 토큰을 그대로 돌려준다.
- 사용자 토큰을 KV·로그·디스크에 저장하지 않는다.
- 허용된 `redirect_uri`만 받는다(`ALLOWED_REDIRECT_URIS`, 쉼표 구분).

## Commands

```bash
cd auth-bridge
npm install
npm test
npm run deploy   # wrangler deploy (시크릿은 별도 설정)
```
