# ios

iOS 클라이언트. `CrewRPCore` 패키지 + `CrewRPApp` 셸.

## 내부 구조

- 인증: `AuthFlow`, Keychain `TokenStore`, `ASWebAuthenticationSession`
- Phase 2: `ETagRESTClient`, `DocsClient`, `ProjectsClient`, `DiscussionsClient`, `IssueFormsClient`, `ReleaseAssetClient`
- Phase 3: `ThreadTalkClient`, `DiscordDeepLink`

## Commands

```bash
cd ios
swift test
# 앱: CrewRPApp.xcodeproj 를 Xcode에서 열어 시뮬레이터 실행
# GitHubClientID, AuthBridgeURL 은 Info.plist 에서 설정
```
