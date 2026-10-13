# CrewRP

서버 비용 없이 소규모 조직(스터디, 동호회, 프로젝트 팀)을 관리하는 iOS·Android 앱입니다. 가칭은 Crew Resource Planning이고, 규모는 약 5–30명입니다.

데이터는 GitHub의 무료 플랜에 두고, 앱은 그 위를 그룹웨어 화면으로 보여 줍니다. 로그인, 권한, 캐시, 비용 한도의 계약은 [ARCHITECTURE.md](ARCHITECTURE.md), 개발 순서는 [ROADMAP.md](ROADMAP.md)를 봅니다.

**공부(Study):** 공개 강의를 보며 튜터 질문을 받는 짧은 수업. UI는 네이티브, 영상만 WebView. 경험은 [docs/study/PRODUCT.md](docs/study/PRODUCT.md), 스키마는 ARCHITECTURE §7, 티켓은 ROADMAP Phase 7. (구 UniTutorAI 저장소는 동결.)

로컬 명령은 컴포넌트별 `DESIGN.md`에 있습니다: [ios/DESIGN.md](ios/DESIGN.md), [android/DESIGN.md](android/DESIGN.md), [auth-bridge/DESIGN.md](auth-bridge/DESIGN.md), [push-bridge/DESIGN.md](push-bridge/DESIGN.md).

크루는 사용자가 앱에서 자기 private repo를 등록해 시작한다. 테스트용 샘플은 [SIMULATION.md](SIMULATION.md).
