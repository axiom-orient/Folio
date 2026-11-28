# iOS 구현 · 2026-10-13 UX/UI 리뉴얼

FolioIOS는 iPhone·iPad의 native SwiftUI 앱입니다. iOS 27을 대상으로 공통 FolioUI와 KnowledgeKit·KnowledgeKitApple을 사용합니다. SEMI provider는 Mac 전용입니다.

- 자료함은 이 기기·iCloud 선택 목록, 새 자료함은 이름·저장 위치, 관리는 추가·공유·연결로 구성합니다. 폴더·ZIP을 local 자료함으로 복사하며 live 외부 폴더 lease는 Mac 전용입니다.
- iPhone은 목록에서 문서를 열고 링크로 이어 갑니다. 첫 문서는 detail root이므로 목록 복귀에 빈 화면 단계를 추가하지 않습니다. iPad는 split navigation을 사용합니다.
- 새 문서는 제목·대상 자료함을 확인하고 생성합니다. 검색 해제 후 Raw Markdown 본문 끝에서 입력합니다. 실패 시 입력 유지, 알려진 생성 결과는 같은 문서 열기로 이어갑니다. 취소는 기존 선택을 유지합니다.
- UITextView가 입력·IME·선택·undo·검색을 맡습니다. 읽기 전환은 초안 보존, 저장은 명시적 원문 반영입니다. 초안은 앱의 문서별 상태, 탐색·읽기 위치는 창별입니다. 자료함 전환 전 복구본을 보존하며 보존 실패·저장 중에는 전환하지 않습니다.
- 도구 막대의 공유는 저장한 Markdown입니다. **자료함 → 관리 → 자료함 ZIP 공유**는 source-only ZIP입니다. ZIP을 Files에서 미리 풀지 않고 가져올 수 있습니다.
- 파일·사진 첨부는 선택한 대상 자료함을 확인하고 durable copy intent·별도 연결 노트 영수증을 유지합니다. 첨부 노트는 원래 파일명으로 표시합니다. 실패한 연결은 목록에서 이어갑니다.
- **받은 파일** 목록에서 파일·대상을 확인하고 문서/첨부를 추가하거나 ZIP을 가져옵니다. 수신과 자료함 반영은 별개이며 확인된 반영 뒤 보관합니다. 같은 ID·기존 원문은 덮어쓰지 않습니다.
- private 저장은 재부팅 후 첫 잠금 해제까지 보호하는 Class C 정책입니다. background 또는 마지막 scene disconnect에서 admission·observation을 닫고 I/O를 drain하며 foreground에서 다시 엽니다. [전송·자료 보호](NEARBY_TRANSFER.md).

관계 규칙은 **자료함 → 관리 → 고급 → 연결 규칙**에서 읽고 명시적으로 원문 편집합니다. `_ontology.md`, note의 stable ID·type·relations, 원문 링크·역링크는 코어 계약을 따릅니다. 미수신 규칙을 새 템플릿으로 덮어쓰지 않습니다. 충돌 화면은 현재와 선택 버전을 비교하고 원본 복사본을 유지합니다.

개발 빌드:

```sh
./script/build_ios.sh --local-simulator
```

이 명령은 개발팀 계정 없이 로컬 임시 서명을 적용합니다. Keychain을 사용하는 자료 준비도 Simulator에서 실행할 수 있도록 서명하며, 프로비저닝이나 실기기 설치는 요청하지 않습니다. 빌드한 앱의 설치·실행은 Xcode 또는 Simulator에서 별도로 수행합니다.

기본 출력은 작업 트리 밖의 `~/Library/Developer/FolioBuilds/Development/<저장소 경로 digest>/IOSSimulator/Build/Products/Debug-iphonesimulator/FolioIOS.app`입니다. `DevelopmentPaths`가 저장소 경로별 캐시를 선택하며, `FOLIO_BUILD_ROOT`를 지정하면 그 아래의 `IOSSimulator/`를 사용합니다. 실행 도구가 실제 출력 경로를 표시합니다. local plist는 명시적 개발 설정으로 production App Group 실패를 숨기는 fallback이 아닙니다. 정식 iCloud·App Group 서명은 Folio.xcodeproj의 같은 Team/container/group을 사용합니다.

Team 서명 iOS build와 실제 iPhone 15의 cloud 원문 읽기·명시 저장·초안 background/재실행·iPhone→Mac 전송을 확인했습니다. Mac→iPhone 수신·추가·보관과 두 기기의 오래된 편집 거부·명시 복구도 실기기에서 통과했습니다. iPad·IME matrix·VoiceOver·큰 글자·실제 OS cloud 충돌은 NOT_RUN입니다. [검증 범위](RELEASE.md#검증-범위), 실기기 절차(로컬 보관: `docs/History/ReleaseCleanup-20261128/CORE_DEVICE_VERIFICATION.md`), 직전 리뉴얼(로컬 보관: `docs/History/IOS_IMPLEMENTATION-renewal-20261013.md`)을 구분합니다.
