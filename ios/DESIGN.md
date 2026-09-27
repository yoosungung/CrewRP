# ios

iOS 클라이언트. `CrewRPCore` 패키지 + `CrewRPApp` 셸. 로그인 후 admin private repo를 골라 크루를 등록한다. 테스트용 샘플 저장소는 [SIMULATION.md](../SIMULATION.md).

## Commands

```bash
cd ios
swift test
# 앱: CrewRPApp.xcodeproj 를 Xcode에서 열어 시뮬레이터 실행
```

## 셸

화면 계산은 `CrewRPCore`의 `ShellPresentation`이다. SwiftUI 셸은 `CrewRPApp.swift`.

- 포인트 색은 틸이고, 배경은 시스템 grouped 색을 따른다.
- 할 일은 칸반(접수·진행 중·완료)과 마감일 목록을 전환한다. 홈은 오늘 할 일, 고정 공지, 다가오는 할 일이다.
- 불러오기 실패는 다시 시도를 보여 준다. Discord 식별자가 비어 있으면 바로 대화 버튼을 숨긴다.
- 공지·할 일·자료실·소통은 앱에서 CRUD한다. 탭의 `+`로 작성, 항목으로 상세·수정·삭제. 운영진은 전 항목, 멤버는 본인 작성분만 수정·삭제.
- 모든 쓰기는 async로 하고, 실패 시 “저장하지 못했습니다”류 문구만 보여 준다.
