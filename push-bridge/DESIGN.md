# push-bridge

GitHub Webhook → FCM. 기기 토큰은 Workers KV. 사용자 GitHub 토큰은 저장하지 않는다.

## 배포

- URL: https://crewrp-push-bridge.candydate.workers.dev
- KV: `crewrp-device-tokens` → binding `DEVICE_TOKENS`
- 시크릿: `WEBHOOK_SECRET`, `FCM_SERVER_KEY`
- GitHub repo Webhook URL: `https://crewrp-push-bridge.candydate.workers.dev/webhook` (secret은 Worker와 동일)

## Commands

```bash
cd push-bridge
npm install
npm test
npm run deploy
printf '%s' '...' | npx wrangler secret put WEBHOOK_SECRET
printf '%s' '...' | npx wrangler secret put FCM_SERVER_KEY
```
