# Mac 현재 검토 · 2026-10-13 UX/UI 리뉴얼

자료함부터 연결된 화면들을 native SwiftUI로 개편했습니다. 선택·관리·생성을 구분하고 문서 읽기·저장·공유를 명확한 동작으로 제공합니다. [화면별 계약](Design/UX_RENEWAL.md).

2026-10-13 당시 Team 서명 앱 build와 UI 12 tests가 통과했습니다. 실제 iPhone과 양방향 cloud 원문 전달, iPhone→Mac 수신·명시 추가·receipt/digest를 확인했습니다. Mac에서는 변경 원문과 초안 비교·추가 변경 거부·재확인 저장을 완료했습니다. 같은 workspace ID의 로컬/cloud 행 identity와 폴더 선택을 수정했습니다. Mac→iPhone과 없는 로컬 파일 복구는 실제 저장·읽기까지 확인했습니다. 두 기기의 오래된 저장 거부·명시 복구도 통과했고 진짜 OS 충돌 버전 선택은 아직 검증 전입니다. [정확한 현재 범위](IMPLEMENTATION_STATUS.md), [직전 리뉴얼 검증](History/MACOS_FINAL_REVIEW-renewal-20261013.md).

Mac은 HSplitView의 문서 목록·본문과 native sidebar material·selection·toolbar를 사용합니다. 자료함 목록의 생성·열기 행은 전체 행을 누를 수 있습니다. 관리는 추가·공유·연결을 표시하며 Finder·색인은 고급 관리에 둡니다. sheet의 주 동작은 개별 ToolbarItem으로 제공하고 원문·파일 옵션 Menu는 내용 영역에 둡니다. 관리의 파일 선택기·전송 시트는 자료함 전체의 NavigationStack에 연결합니다.

원문은 KnowledgeKit CAS·durable receipt가 맡고, 현재 초안 상태는 FolioDraftStore, 창별 탐색은 WikiWindowState가 맡습니다. SEMI는 기존 접근 동의·정확한 preview·별도 승인 계약과 같은 Team의 helper를 사용합니다. 마지막 창 종료 후 원문 lease/provider는 명시적 Quit까지 유지하며 Quit은 복구본을 보존하고 I/O를 drain합니다.

이번 변경에서 기존 설치 bundle·사용자 원문·수신 파일·영수증을 삭제하지 않았습니다. 실제 VoiceOver/IME·성능·File Provider·cloud 충돌·SEMI 권한 회수 matrix는 NOT_RUN입니다. [직전 검토](History/MACOS_FINAL_REVIEW-usability-20261013.md)와 [이전 검증](History/IMPLEMENTATION_STATUS-through-20261013.md)을 현재 소스의 실행 증거와 구분합니다.
