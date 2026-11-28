# 플랫폼 결정과 공식 근거 — 2026-10-10

> **2026-10-29 SDK 경계:** 루트 `Folio` 패키지는 독립 소비용 `FolioCore`와 선택형 `FolioSDKUI`, 기존 앱 셸 `FolioUI`를 제공합니다. 원문 처리 기반은 포함된 `FolioKnowledge`·`FolioKnowledgeApple`이며 Mac 어댑터는 `FolioProvider`입니다. Mac 앱 조합은 `MacApp`과 `MacIntegration`에 분리해 SDK 소비가 SEMI나 sibling 경로에 의존하지 않게 합니다. 원문 ID·bytes·CAS·승인·영수증을 보존하며 서명·실제 계정 전환·실기기 동작은 별도 검증입니다. 상세 계약은 [SwiftPM SDK](SWIFTPM_SDK.md)에 있습니다.

목표는 원문을 검색→읽기→연결 따라가기→수정/공유하는 같은 기능을 Mac과 iPhone/iPad에서 제공하는 것이다. 현재 코드, Xcode27 SDK와 Apple의 현재 공식 문서를 대조했다.

| 대안 | 적합성 / 결정 |
|---|---|
| `FolioKnowledge`/`FolioKnowledgeApple`의 기존 원문 writer를 공유하고 앱과 SDK의 입력·탐색을 native로 구성 | 채택. 동일 hash/path/ontology/CAS/receipt를 보존하며 독립 호스트의 저장소·권한 경계를 `FolioCore`와 `FolioSDKUI`로 제공 |
| 플랫폼마다 다른 domain DB / SwiftData sync graph | source-owned Markdown와 파생 FTS/관계의 owner를 둘로 만드는 비용이 있음. 현재 프로젝트의 정확한 원문 편집·공유 과업에는 이득이 확인되지 않음 |
| DocumentGroup을 별도 자동 저장 owner로 추가 | document/browser 중심 새 제품에는 유효. 현 앱의 shared draft와 명시 CAS Save를 유지하려면 단일 write owner에 맞춘 재설계가 필요 |
| iOS에 Mac agent/XPC 전체를 이식 | requested wiki 과업에 불필요한 실행 권한·모델 graph를 더함. MacIntegration만 SEMI provider로 유지 |
| 기본 custom embeddings/LLM enrichment | 선택 package/후속 profile. exact/FTS/Spotlight와 원문 관계가 먼저 유용한 결과를 제공하며 모델 준비를 요구하지 않음 |

NavigationSplitView의 compact collapse와 column 안 NavigationStack을 사용한다. 각 destination은 문서 ID를 캡처한다. [Apple NavigationSplitView](https://developer.apple.com/documentation/swiftui/navigationsplitview).

원문 편집은 UITextView의 native 선택/undo/find/input을 쓰고 provisional marked text를 외부 model update로 덮어쓰지 않는다. [Apple markedTextRange](https://developer.apple.com/documentation/uikit/uitextinput/markedtextrange). 기기 IME 수용을 compile로 대신하지 않는다.

Apple은 iOS background에서 file presenter를 제거하고 foreground에 다시 등록하도록 요구한다. 관찰 중단을 drain보다 먼저 요청하고 foreground open이 새 lease/presenter를 만든다. [Apple NSFilePresenter](https://developer.apple.com/documentation/foundation/nsfilepresenter). 이것이 platform-specific lifecycle 보완의 근거다.

파일 공유는 native FileRepresentation과 ShareLink를 쓴다. 원문을 문자열/임의 HTML로 재생성하지 않는다. [Apple FileRepresentation](https://developer.apple.com/documentation/coretransferable/filerepresentation), [Apple ShareLink](https://developer.apple.com/documentation/swiftui/sharelink). 전송 완료를 app의 Save 성공과 혼동하지 않는다.

directory .forUploading은 accessor 뒤 임시 archive가 사라질 수 있어 accessor 안에서 앱의 임시 URL로 복사한다. [Apple forUploading](https://developer.apple.com/documentation/foundation/nsfilecoordinator/readingoptions/foruploading). private stage는 source layout만 포함하고 사후 제거한다.

iOS named system index는 앱이 선택한 KnowledgeKit 보호 등급을 사용한다. 서명 앱의 `KnowledgeDataProtection=after-first-unlock` 설정은 인덱스에 Class C를 선택한다. 현재 query는 별도로 `.complete` protectionClasses를 지정한다. 이 속성은 query 객체의 것이며 context의 것이 아니다. 이 설정 차이의 실제 검색 영향은 검증하지 않았다. [Apple CSSearchableIndex](https://developer.apple.com/documentation/corespotlight/csssearchableindex), [Apple CSSearchQuery.protectionClasses](https://developer.apple.com/documentation/corespotlight/cssearchquery/protectionclasses).

이 결정은 기능 parity와 owner 계약에 대한 판단이다. signed sync·lock·접근성·relevance·performance의 실측 인증은 [현재 상태](RELEASE.md#검증-범위)의 남은 gate다.

## 기존 자료의 호환 경계

SourceWiki의 같은 로컬 Application Support 자료·초안·영수증·설정은 첫 실행에 Folio로 이동한다. 두 폴더가 모두 있으면 덮어쓰거나 병합하지 않고 중단한다. 새 링크는 folio://이며 저장된 sourcewiki:// 근거도 읽는다. 이름 변경만으로 이전 signed iOS sandbox/iCloud 자료를 자동 이관하지 않는다. 기존 설치는 원문 ZIP → Files → Folio 가져오기를 사용하고 Mac sandbox bookmark는 필요하면 다시 선택한다. 이 경로는 사용자 자료의 호환성을 위해 유지하며 새 제품 화면에 이전 이름을 추가하지 않는다.
