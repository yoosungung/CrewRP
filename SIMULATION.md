# 시뮬레이션 (테스트용)

앱 코드에는 특정 저장소 이름을 넣지 않는다. 사용자는 로그인 후 관리 권한이 있는 private repo를 **크루로 등록**하고, 운영진이 이메일로 Organization 초대를 보낸다.

로컬·수동 검증용으로 쓸 수 있는 샘플 저장소: https://github.com/yoosungung/ai-edu  
(`docs/`, Issue Forms, Discussions, Issue `#1` 등이 미리 잡혀 있음.) 앱에서 이 저장소를 admin으로 보면 등록 목록에 나타나고, 골라 등록하면 된다.

## 검증

```bash
cd ios && swift test
# iPhone 17 시뮬레이터 빌드
xcodebuild -project CrewRPApp.xcodeproj -scheme CrewRP \
  -destination 'platform=iOS Simulator,name=iPhone 17,OS=26.5' build

cd android && ./gradlew :crewrp-core:test :app:assembleDebug
```

실기기 OAuth는 GitHub OAuth App `client_id`/`client_secret`을 auth-bridge 시크릿에 넣고, 앱 Info.plist / BuildConfig의 `GitHubClientID`를 채운 뒤 시뮬레이터에서 로그인한다.

배포된 Worker:
- auth: https://crewrp-auth-bridge.candydate.workers.dev ([auth-bridge/DESIGN.md](auth-bridge/DESIGN.md))
- push: https://crewrp-push-bridge.candydate.workers.dev ([push-bridge/DESIGN.md](push-bridge/DESIGN.md))

