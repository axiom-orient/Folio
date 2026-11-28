# Folio SwiftPM SDK

Folio SDK는 Apple 앱이 자신에게 허용된 Markdown 원문을 열고, 검색하고, revision을 확인하며 저장하고, 전용 상태 폴더에서 초안을 복구할 수 있도록 제공합니다. Swift tools 6.3, Swift 6 언어 모드, iOS·macOS 27 이상을 사용합니다.

## 제품과 의존 방향

| 제품 | 책임 |
| --- | --- |
| `FolioCore` | 명시적인 호스트 설정, 자료함 세션, 검색·읽기, 원문 버전을 확인하는 저장, 초안·미확정 저장 결과 복구 |
| `FolioSDKUI` | 호스트가 만든 세션을 표시하는 선택형 SwiftUI 문서 목록·검색·편집 화면 |
| `FolioUI` | 기존 Folio 앱 셸의 호환 제품. 기존 앱의 자료함 카탈로그·이관·전송·연동 흐름을 포함 |
| `FolioKnowledge`·`FolioKnowledgeApple` | 기존 앱과 어댑터가 사용하는 이름이 분리된 원문 처리 기반 모듈. SDK의 원문 writer도 이 구현을 사용 |

`FolioCore`는 `FolioUI`, 근거리 전송, SEMI, 예제 앱에 의존하지 않습니다. `FolioSDKUI`는 `FolioCore`에만 의존하며 저장소를 생성하거나 앱 전역 모델을 만들지 않습니다. 루트 manifest는 sibling checkout·환경변수 기반 패키지 경로를 사용하지 않습니다. 필요한 기반 소스는 같은 패키지의 `Vendor/` 타깃이고, 원격 의존성은 swift-markdown 0.9.0, Yams 6.2.2, ZIPFoundation 0.9.20으로 고정했습니다.

원본 모듈과 다른 호스트의 의존성이 충돌하지 않도록 모듈 이름을 `FolioKnowledge`, `FolioKnowledgeApple`, `FolioKnowledgeSQLite`, `FolioNearbyTransport`로 바꿨습니다. 원본 폴더 이름·고지·체크섬과 조정 내역은 [Vendor](../Vendor/README.md)에 있습니다. 기존 sibling KnowledgeKit·Acornry 저장소는 수정하지 않습니다.

Mac의 SEMI 연결은 `MacIntegration` 어댑터에 남습니다. `MacApp` 개발 패키지와 `Folio.xcodeproj`가 이를 앱에 조합합니다. SDK 소비 앱은 `FOLIO_SEMI_SDK_PATH`나 SEMI checkout이 필요하지 않습니다.

## 소비 방법

Xcode의 Add Package Dependencies에서 배포된 Folio 저장소 URL과 버전 요구사항을 지정하고 `FolioCore`, 필요한 경우 `FolioSDKUI`를 앱 타깃에 추가합니다. 이 로컬 작업은 외부 저장소 게시·버전 태그·새 라이선스를 만들지 않습니다. 배포 전에는 실제 저장소의 라이선스와 semantic version tag를 확정해야 합니다.

개발 중에는 한 Folio checkout만 local package로 추가해도 됩니다. [독립 예제](../Examples/FolioSDKHost/README.md)의 `.package(path: "../..")`는 이 개발 소비를 보여 주며 루트 SDK가 예제에 의존하는 것은 아닙니다. 버전 기반 소비를 위해 루트 SDK 그래프에는 filesystem package dependency가 없습니다.

## 호스트가 정하는 저장소

```swift
import FolioCore

@MainActor
func openLibrary(sourceURL: URL, hostStateURL: URL) async throws -> FolioSession {
  let configuration = try FolioConfiguration(
    stateDirectory: hostStateURL,
    namespace: "com.example.Research.documents"
  )
  let session = FolioSession(configuration: configuration)
  try await session.openWorkspace(at: sourceURL)
  return session
}
```

`sourceURL`은 `_workspace.md`와 `notes/`를 포함한, 호스트가 접근을 허용받은 원문 폴더입니다. `hostStateURL`은 그 호스트의 SDK 전용 로컬 상태 폴더입니다. 두 경로는 서로 포함할 수 없습니다. 원문을 SDK 상태 폴더 안에 두거나 SDK 상태를 원문 아래에 두면 열기를 거부합니다.

설정과 세션 생성은 기존 폴더를 이관하거나 파일을 생성하지 않습니다. `openWorkspace`가 전달받은 원문을 열고 지정 상태 폴더에 색인·복구 상태를 준비합니다. `createWorkspace(at:name:)`는 호스트가 명시 호출할 때 새 원문 디렉터리를 만듭니다. 이미 존재하는 디렉터리를 병합하거나 덮어쓰지 않으며 실패 후 생긴 부분 자료도 자동 삭제하지 않습니다.

상태 범위는 호스트 namespace, 정규화된 원문 위치, 로컬/iCloud 위치 구분, iCloud 계정, 작업공간 ID를 사용합니다. 동일 UUID의 다른 위치·계정 자료함에 초안을 자동 귀속하지 않습니다. 상태 루트와 파생 경로의 심볼릭 링크·비정상 파일 유형은 디렉터리나 잠금 파일 생성 전에 거부합니다. 설정 뒤 경로가 원문 안으로 바뀐 경우도 그대로 거부합니다. 동일 범위의 복구 파일은 한 세션이 소유하며 중복 세션은 상태 사용 중 오류를 받습니다. namespace나 원문 폴더 위치를 바꾸면 별도 범위가 됩니다. 기존 범위의 초안을 지우거나 새 범위로 임의 이관하지 않으므로 호스트가 이전 설정과 파일을 보존해야 합니다.

SDK는 기존 Folio 앱의 Application Support·UserDefaults·Keychain을 탐색하지 않고 `SourceWiki` 폴더나 이전 초안을 이관하지 않습니다. 기존 앱의 이관 흐름은 앱 셸에 남아 있습니다. 기존 `WikiAppModel(migrateLegacyStorage: false)` 옵션도 iOS 준비 경로까지 전달해 이관 호출을 건너뜁니다. 이는 앱 셸의 호환 동작이며 새 SDK가 그 저장소를 가져온다는 뜻은 아닙니다. 호스트가 자기 앱의 기존 데이터를 이관하려면 별도 명시 작업으로 계획하고 원문·초안·영수증을 보존해야 합니다.

## 검색

`search(query)`는 처음 50개 결과를 반환하는 편의 API입니다. 전체 결과는 `searchPage(query, continuation:)`의 `nextContinuation`이 없어질 때까지 이어서 조회합니다. 각 페이지는 전체 개수, 검색 범위의 완전성, 진단을 반환합니다. continuation은 세션·검색어·원문 버전·정렬에 묶이며 원문이 바뀌면 재검색을 요구합니다. SDK UI는 더 보기와 불완전 검색 안내를 표시합니다.

`prepareKnowledgeIndex()`와 `knowledgeAnswer(_:documentID:)`는 Markdown과 문서에 연결된 PDF를 블록 색인에서 검색합니다. 기기 내 Apple Vision으로 스캔 페이지와 본문이 있는 페이지의 이미지 영역을 읽습니다. `documentID`를 지정하면 해당 문서와 연결된 PDF로 범위를 제한합니다. 기본 검색은 네트워크 없이 동작합니다. Folio 앱의 선택형 뜻 검색은 별도 `WikiSearchService` 모델 주입을 사용합니다.

`WikiKnowledgeAnswer.evidence`는 원문 기반의 검색 결과입니다. `pdfRegion?.kind == .ocrUnreviewed`인 항목에는 스캔 인식 표시를 붙이고 `coverage`의 추출 누락·검색 범위를 함께 표시합니다. `readKnowledgeEvidence(_:)`와 `previewKnowledgePDF(_:)`는 원문 권한과 revision을 다시 검사합니다. PDF 미리보기는 검증된 Data snapshot과 페이지·영역 좌표를 제공합니다. 원문 폴더 변경·계정 접근 상실·세션 닫힘 뒤 기존 인용으로 새 원문 읽기를 수행할 수 없습니다. 여러 자료는 순서대로 검사합니다. [PDF 추출과 원문 확인](PDF_EVIDENCE.md)

### 원문에 연결된 개념 · 2026-11-28

`knowledgeAnswer(_:documentID:conceptID:)`는 선택 자료를 추출 전에 확정하고 선택 밖의 정상 캐시·벡터를 보존합니다. 현재 전체 inventory의 scan/hash 재확인은 유지하므로 선택 밖의 파일 I/O 전체를 생략한다는 뜻은 아닙니다. 빈 범위와 없는 문서를 전체 검색으로 확대하지 않습니다.

채택한 Concept의 한·영 이름·별칭은 모델 없는 검색에도 사용합니다. 일반 문서 aliases는 기존 문서 이름의 의미를 유지합니다. optional `answer.concepts`는 가능한 의미·선택·확장 완료 여부를 반환합니다. 동명 개념이 있으면 그중 선택한 ID를 같은 질문의 `conceptID`로 전달합니다. 이미 ID를 아는 경우 `readKnowledgeConcept(id:)`가 개념과 현재 검증한 원문 근거를 직접 반환하므로 재검색이 필요 없습니다.

```swift
import Foundation
import FolioKnowledge
import FolioKnowledgeApple

let found = try await session.knowledgeAnswer("thermal conductivity")
if let evidence = found.evidence.first {
  let concept = WikiKnowledgeConcept(id: UUID().uuidString.lowercased(), domain: "재료",
    labels: [WikiConceptLabel(language: "ko", preferred: "열전도율", aliases: ["thermal conductivity"])],
    mentions: [WikiKnowledgeConceptMention(evidence: evidence)])
  let operation = UUID()
  let plan = try await session.prepareKnowledgeConcept(concept, operationID: operation)
  // 호스트가 정확한 내용의 저장 의도를 확인한 뒤 같은 plan을 실행합니다.
  let receipt = try await session.executeKnowledgeConcept(plan)
  let current = try await session.readKnowledgeConcept(id: concept.id)
}
```

기존 개념에 별칭·근거를 추가할 때는 그 record의 `relativePath`와 `revision`을 prepare의 `relativePath`·`expectedRevision`으로 넘깁니다. ID·다른 Mention·unknown JSON을 보존하는 CAS 갱신이며 이름만으로 자동 병합하지 않습니다. draft와 accepted를 구별하고 원문 근거 없는 draft는 검색 확장에 사용하지 않습니다.

저장 결과가 불확실하면 같은 `operationID`의 `knowledgeConceptOperationStatus`를 관측합니다. `operation`은 기존 writer의 역사적 결과, `sourceObserved`는 요청한 파일 바이트의 현재 관측, `currentness`는 인용한 원문 근거의 상태입니다. 세 값을 합쳐 사실성 배지로 사용하지 않습니다. 미확정 상태에서 새 작업을 자동 생성하거나 execute를 재실행하지 않습니다. 원문이 바뀌어도 과거 commit의 관측은 유지합니다. [구현 범위와 보존 계약](ONTOLOGY_IMPLEMENTATION_PLAN.md)

### 주장·조건·값·단위·판본 · O3

`WikiKnowledgeAssertion`은 한 주장과 `conceptIDs`, 조건, 선택적인 값·단위·판본, 원문 근거를 묶습니다. 각 항목의 `WikiKnowledgeAssertionText`에는 표현, `quoted` 또는 `interpretation` 구분, 실제 근거 ID와 원문 문구가 들어갑니다. 근거 역할은 `support`, `context`, `refute`입니다. 문맥이나 반박만으로 주장을 지지한 것으로 처리하지 않습니다. `polarity`의 기본값은 `unspecified`이며, 다른 값도 호출자의 분류입니다.

직접 인용은 원문의 연속된 UTF-8 표현을 유지합니다. 숫자의 부호·소수점·지수를 잘라 다른 값으로 만들거나 단어의 일부를 단위로 사용하는 입력은 거부합니다. 값·단위·판본은 직접 인용만 허용합니다. 직접 인용한 값은 주장 표현 자체에도 있어야 합니다. 이 항목들과 직접 인용한 조건은 주장의 지지 근거와 같은 실제 원본의 자료함 범위·경로·해시에 연결돼야 합니다. 표의 값, 헤더의 단위, 표지의 판본은 같은 PDF 안의 서로 다른 근거로 지정할 수 있습니다. 이 검사는 추적 가능성과 표현의 보존을 확인하며, 표의 의미·문장의 논리적 함의·객관적 참임을 인증하지 않습니다. 해석은 명시적으로 구분해 표시해야 합니다.

ID를 알면 `readKnowledgeAssertion(id:)`로 바로 읽습니다. 목록은 `knowledgeAssertions(conceptID:documentID:unit:edition:query:limit:)`로 조회하며 검색 모델이 필요 없습니다. 단위는 대소문자를 보존해 일치시키고, 판본과 `query`는 Unicode 정규화 후 대소문자를 구분하지 않습니다. `query`는 주장·조건·값·단위·판본의 부분 문자열 검색입니다. `documentID`를 지정하면 전체 근거 묶음이 그 문서에 속한 주장만 반환합니다. 채택된 주장만 목록에 포함되며, 원문이나 연결 개념이 바뀐 레코드는 진단과 함께 제외됩니다. `complete`와 `diagnostics`도 확인합니다.

```swift
let saved = try await session.knowledgeAssertions(unit: "W/(m K)", limit: 20)
if let record = saved.records.first, let field = record.assertion.unit {
  // 첫 번째 근거 전체가 아니라 이 단위를 실제로 포함한 근거를 선택합니다.
  if let original = try record.assertion.sourceEvidence(for: field).first {
    let text = try await session.readKnowledgeEvidence(original)
    if original.source.kind == .pdf {
      let preview = try await session.previewKnowledgePDF(original)
      // 호스트 viewer에 검증된 preview의 Data·페이지·영역을 전달합니다.
    }
  }
}
```

주장 저장도 `prepareKnowledgeAssertion(_:relativePath:expectedRevision:operationID:)` 후 승인된 같은 계획을 `executeKnowledgeAssertion(_:)`으로 실행합니다. 기존 레코드 수정에는 반환된 경로와 revision을 전달합니다. 공통 Concept/Assertion writer가 원문과 연결 개념의 현재 revision, 계획의 경로·내용을 다시 확인합니다. 저장 결과가 불확실하면 같은 작업의 `knowledgeAssertionOperationStatus(operationID:)`만 조회합니다. 그 결과의 `operation`, `sourceObserved`, `currentness`는 앞의 개념 저장과 같은 서로 다른 의미를 유지합니다. 원문 책·논문은 수정하지 않으며, 저장한 주장을 독립적인 1차 출처로 다시 색인하지 않습니다.

연결 개념의 경로·revision은 writer 소유 `conceptBindings`에 기록합니다. prepare·execute·직접 조회에서 현재 채택된 개념과 원문 근거를 다시 확인합니다. 개념이 바뀌면 기존 주장을 자동으로 새 의미에 연결하지 않습니다. 검토한 호출자가 기존 주장 경로·revision을 사용해 명시적으로 CAS 갱신하면 현재 개념에 다시 연결할 수 있습니다. 주장 노트의 생성된 Markdown 구간도 typed 메타데이터와 일치해야 합니다. 일반 원문 편집으로 둘이 달라진 파일은 보존하지만 typed 읽기·저장은 거부하므로 내용을 검토해 복구해야 합니다. 새 assertion 경로를 추가하면서 기존 `ConceptOperations` v1의 작업 필드·근거 digest는 유지합니다.

필요한 문맥은 `knowledgeEvidenceContext(_:limit:)`로 더 읽습니다. 기본 8개, 최대 16개이며 Markdown은 해당 구획과 이웃 구획, PDF는 선택한 페이지를 대상으로 합니다. OCR 이미지가 지정된 근거는 그 이미지의 인식 범위를 유지합니다. 반환된 `complete`는 이 제한된 주변 범위의 누락 여부이며, 책 전체나 표의 의미 구조를 완전히 읽었다는 뜻이 아닙니다. [PDF 위치와 해석 범위](PDF_EVIDENCE.md)

개념만 바뀐 주장은 `reviewKnowledgeAssertion(id:)`로 별도 검토합니다. 유효한 원문과 기존 주장, 변경된 개념의 현재 내용, `currentConceptRevisions`를 반환하며 현재 지식 조회와 구별합니다. 원문까지 바뀌면 검토 조회도 거부하며 인용을 자동 갱신하지 않습니다. 화면에서 확인한 개념 버전을 아래처럼 저장 준비에 전달하면, 검토 뒤 개념이 다시 바뀐 경우 거부합니다. 사용할 수 없는 개념은 명시적으로 연결을 해제한 뒤 저장합니다.

```swift
let review = try await session.reviewKnowledgeAssertion(id: assertionID)
// 호스트가 주장과 현재 개념 내용을 표시하고 사용자의 저장 의도를 받은 뒤:
let plan = try await session.prepareKnowledgeAssertion(review.record.assertion,
  relativePath: review.record.relativePath, expectedRevision: review.record.revision,
  expectedConceptRevisions: review.currentConceptRevisions, operationID: UUID())
// 승인된 plan만 executeKnowledgeAssertion에 전달합니다.
```

앱의 반복 저장 검사는 `matchingKnowledgeAssertion(_:)`로 정확한 typed 내용을 원문 레코드 전체에서 대조합니다. 목록의 첫 100개를 읽고 나머지가 없다고 추정하지 않습니다. `contentDigest()`는 배정된 `recordID`만 제외하며 근거 버전·역할·해석 구분·조건은 유지합니다. 같은 내용은 현재 원문과 개념을 다시 검증해 재사용합니다. 읽지 못한 기록이 있어 부재를 확인할 수 없으면 새 파일을 만들지 않습니다.

### 선택형 주장 후보 추출

기본 추출 backend는 없습니다. 호스트가 `WikiKnowledgeAssertionExtractionProvider`를 구현해 `proposeKnowledgeAssertions(_:evidence:conceptIDs:provider:)`에 명시 전달할 때만 후보를 만듭니다. provider가 없으면 설정되지 않았다는 오류를 반환하며 직접 저장 경로는 유지됩니다. 호스트는 선택한 모델과 외부 전송 여부·이용 조건을 결정합니다.

provider에는 현재 읽은 원문 텍스트·근거 ID·표시 위치와 허용한 개념 목록, 응답 schema만 전달합니다. 자료함 URL·파일 도구·writer·승인 도구는 전달하지 않습니다. 입력은 schema를 포함해 64 KiB, 근거는 최대 64개, 출력은 64 KiB 안의 최대 8개 후보로 제한합니다. 출력은 `WikiKnowledgeAssertionProposer.responseSchemaJSON()`을 따르며 허용한 근거·개념 ID만 참조할 수 있습니다. 알 수 없는 필드, 임의 레코드 ID나 채택 상태, 원문과 다른 직접 인용은 거부합니다. 대기 전후에 원문과 개념 revision을 검사하고, 취소된 provider가 실제로 끝나기 전에는 같은 proposer의 실행 자리를 비우지 않습니다.

반환하는 `WikiKnowledgeAssertionProposal`은 host가 만든 읽기 전용 후보이며 상태는 `draft`입니다. 제안 자체는 파일을 쓰지 않습니다. 사용자가 후보를 검토해 저장할 때 proposal을 받는 `prepareKnowledgeAssertion` overload를 호출하고 같은 계획을 실행합니다. 이 경로는 원문·개념을 다시 검사하고 명시 저장으로 채택하며 provider ID, schema·policy 버전, 입력 digest와 proposal ID를 writer 소유 메타데이터에 보존합니다. 새 수동 입력의 `WikiKnowledgeAssertion.decodeInput(_:)`은 이 메타데이터를 위조할 수 없습니다. 이후 명시 수정도 최초 추출 출처를 보존합니다. 후보가 schema 검사를 통과한 것을 생성 모델의 정확도나 사실성 검증 통과로 표시하지 않습니다.

## 편집·저장·복구

```swift
let document = session.documents[0] // 호스트가 빈 목록을 처리한 뒤 선택
try await session.openDocument(id: document.id)
let editedSource = session.draftText + "\n검토한 근거를 원문에 남깁니다.\n"
try session.updateDraft(editedSource)
let receipt = try await session.save()
// receipt.operationID와 sourceRevision은 원문 저장 결과입니다.
try await session.close()
```

UI는 문서를 열 때 `session.editingTarget`을 캡처하고 `updateDraft(_:target:)`, `save(target:)`, `readCurrentSource(target:)`, `resolvePendingSave(target:)`에 그 값을 사용합니다. 이 값은 세션의 자료함과 문서 선택에 묶입니다. 같은 UUID를 가진 다른 자료함이나 이전 편집기의 늦은 입력 콜백은 현재 초안에 반영되지 않습니다. 인자가 없는 편의 API는 현재 선택에 즉시 명령하는 프로그램 호출용입니다. 선택형 UI도 이 고정 대상과 `editingContextID`를 사용하며 검색 결과가 다른 문맥으로 넘어가지 않게 확인합니다.

일반 SDK 저장은 문서 ID 변경을 거부하고 초안을 유지합니다. 제목 변경은 허용하며 저장된 선택 문서의 제목에도 반영합니다. ID 변경이나 손상된 메타데이터 복구는 별도 호스트 도구의 명시적 작업으로 다룹니다.

초안은 front matter를 포함한 Markdown 원문 전체입니다. `updateDraft`는 원문을 쓰지 않고 전용 복구 파일을 먼저 원자적으로 교체합니다. 이는 갑작스러운 전원 손실까지 보장하는 fsync 기반 내구성 계약은 아닙니다. 체크포인트가 실패하면 오류를 전달하므로 호스트 편집기는 자체 입력을 유지하고 사용자에게 복사·공유 경로를 제공해야 합니다. 실패를 무시하고 이전 SDK 값으로 네이티브 편집기를 되돌리지 않습니다. `FolioLibraryView(session:onUncheckpointedEdit:)`의 콜백이 `true`를 알리면 호스트도 해당 화면과 세션을 유지하고, 입력을 별도로 확보하거나 체크포인트 재시도를 마친 뒤 화면을 제거해야 합니다.

`save`는 편집 기준 revision을 사용하며 원문이 달라졌으면 자동 덮어쓰지 않습니다. 원문 writer는 기존 coordinated I/O와 revision CAS를 사용합니다. SDK의 계정·접근 확인은 파일 조정이 끝난 뒤 실제 CAS·게시 직전에도 실행됩니다. 원문을 쓸 수 없더라도 기존 초안을 다른 자료함으로 옮기거나 삭제하지 않습니다.

저장에는 작업 ID와 예상 결과 해시가 연결됩니다. 저장 결과가 불확실하면 초안과 pending 작업을 보존하고, 호스트는 `resolvePendingSave()`로 그 작업의 상태만 확인합니다. 이 API는 원문 저장을 재실행하지 않습니다. `committed`는 영수증을 확인한 결과, `notObserved`는 관측되지 않은 작업, `uncertain`은 판단 보류입니다. 미확정 결과에서 자동 retry나 초안 삭제를 하지 않습니다. `.uncertain`에서 계속 편집하려면 현재 원문과 초안을 검토하고 `adoptReviewedSource(review, mergedText: ..., resolvingPendingSave: operationID)`를 명시 호출합니다. SDK는 원문·작업 ID를 다시 확인하고, 이전 pending 초안의 전체 내용을 같은 상태 범위의 `ReviewedSaves/<operationID>.json`에 덮어쓰기 없이 보존한 뒤 새 초안을 준비합니다. 이전 writer의 intent는 그대로 두며 원문을 재실행하지 않습니다. 이미 committed인 작업은 이 경로로 버릴 수 없고 먼저 영수증을 확인해야 합니다. 이후 저장도 별도 `save`입니다. 원문 충돌은 호스트가 `readCurrentSource()`로 원문을 읽어 초안과 함께 표시하고 사용자의 검토 결과를 명시적으로 적용합니다.

```swift
let review = try await session.readCurrentSource()
// 호스트가 review.text와 session.draftText를 보여 주고 사용자 선택을 받습니다.
try await session.adoptReviewedSource(review, mergedText: userReviewedMarkdown)
let receipt = try await session.save()
```

`readCurrentSource`는 초안과 기준 revision을 바꾸지 않습니다. `adoptReviewedSource`는 그 세션·문서에서 받은 검토 자료인지 확인하고 현재 원문이 검토한 해시와 같은지 다시 읽어 확인한 뒤 초안 기준을 바꿉니다. 원문 저장은 별도 `save()` 호출이며 그 사이 원문이 또 바뀌면 CAS가 거부합니다. 검토 자료를 다른 자료함·세션에 재사용할 수 없습니다. 자동 병합이나 자동 저장을 실행하는 API가 아닙니다.

`close()`는 초안을 체크포인트하고 원문 접근 세션을 닫습니다. 실행 중인 저장·조회와 겹치면 busy 오류를 받으므로 호스트는 진행 작업 완료를 기다리고 닫기가 끝난 다음 security-scoped URL을 해제합니다. 세션·앱 종료가 저장된 초안을 삭제하는 의미는 아닙니다. 원문이 삭제되거나 색인에서 제외돼도 `recoverableDrafts`로 보존 초안을 열 수 있고 선택형 UI의 복구 목록에서 공유할 수 있습니다.

## iCloud와 권한

로컬 자료함과 기본 예제에는 iCloud·App Group·Photos·근거리 네트워크 권한이 필요 없습니다. iOS 파생 저장소의 기본 파일 보호는 `complete`입니다. 기존 기반 계층의 호스트 Info.plist 키 `KnowledgeDataProtection`에 `after-first-unlock`을 명시한 앱은 첫 잠금 해제 이후 보호를 사용합니다. 이 설정은 호스트 전체 정책이며 세션별 설정은 아닙니다. SDK가 이를 자동 추가하거나 변경하지 않습니다. 외부 폴더를 지원하는 호스트는 문서 선택기, sandbox entitlement와 security-scoped bookmark/URL의 접근 수명을 소유합니다. SDK가 권한을 확대하거나 폴더 선택기를 자동 표시하지 않습니다.

iCloud Documents를 사용하려는 호스트는 자신의 App ID에 iCloud capability와 사용할 컨테이너를 설정하고 서명해야 합니다. 허용된 컨테이너 아래에서 실제 선택한 원문 경로를 전달합니다.

```swift
try await session.openWorkspace(
  at: authorizedCloudSourceURL,
  location: .iCloud(containerIdentifier: "iCloud.com.example.Research")
)
```

SDK는 컨테이너와 경로, 실제 `ubiquityIdentityToken`을 확인합니다. 임의의 계정 문자열이나 UUID를 Apple 계정으로 신뢰하지 않습니다. 토큰은 secure archive로 복원하고 객체 동등성으로 비교하며, 안전한 복원·계정 확인이 실패하면 iCloud 원문 접근을 거부하고 기존 복구 자료를 보존합니다. 이 토큰은 iCloud Documents용이며 CloudKit 계정 인증 API를 대신하지 않습니다.

SDK는 기존 scope 해시와 `drafts-v1.json` 형식을 유지하며, scope 옆의 `scope-v1.json`에 로컬·iCloud 구분과 불투명 계정 UUID를 기록합니다. 계정 레지스트리가 사라지거나 기록된 iCloud 계정이 레지스트리에서 누락되면 새 복구 범위를 만들지 않고 오류를 반환합니다. 레지스트리를 복원하면 기존 scope의 초안을 다시 읽습니다. 로컬로 분류된 초안은 최초 iCloud 계정 등록을 막지 않습니다. 분류 정보가 없는 과거 복구본은 등록된 기존 계정으로 다시 열 수 있지만, 새 계정 UUID를 만들기 전에는 복구본을 먼저 확인해야 합니다. 계정 정보까지 유실된 경우에는 계정을 추정하지 않고 복구본을 보존합니다. 이 경우 레지스트리를 복원하거나, 로컬 자료함이었다면 해당 자료함을 먼저 다시 열어 분류해야 합니다.

호스트는 `FolioSourceAccess`를 설정에 전달해 보호 데이터·security-scoped URL·계정 변경 시 원문 접근을 즉시 철회할 수 있습니다. 생성 자체에는 I/O가 없습니다.

```swift
let access = FolioSourceAccess()
let configuration = try FolioConfiguration(
  stateDirectory: hostStateURL,
  namespace: "com.example.Research.documents",
  sourceAccess: access
)
let session = FolioSession(configuration: configuration)
// 원문 접근을 철회하거나 호스트 권한을 해제하기 전에 동기적으로 호출합니다.
access.revoke()
// 진행 요청의 완료를 기다린 뒤:
try await session.close()
// 이후에만 host-owned security-scoped URL 등의 접근을 해제합니다.
```

`revoke()`는 공유 가능한 gate를 영구 철회합니다. 재개하려면 새 gate와 설정으로 새 세션을 만듭니다. gate를 철회해도 이미 게시된 원문 변경을 되돌릴 수는 없습니다. 원문 변경이 먼저 커밋됐다면 저장 영수증이 그 결과를 나타내고, 별도 사용자 변경으로 취소해야 합니다. 호스트는 계정 변경을 감지하거나 보호 데이터·파일 접근 전환을 시작할 때 gate를 철회하고, 비동기 `close()` 완료를 기다린 뒤 접근 권한을 해제합니다. 이미 진행 중인 요청에는 최종 coordinated writer의 gate 확인이 적용됩니다.

호스트는 scene lifetime과 UI에서 진행 중인 요청도 소유합니다. 기본 SDK는 App Group, Spotlight 색인, Keychain 항목, Bonjour·Photos 설정을 자동 등록하지 않습니다. SDK에 iCloud 기능을 가져오는 것만으로 호스트 앱의 entitlement가 생기지는 않습니다.

## 의미 있는 예제와 확인 범위

[연구 자료함 예제 앱](../Examples/FolioSDKHost/README.md)은 한국어 연구 기록·SDK 책임 분담·문서 검토 지침을 Markdown 리소스로 포함합니다. 사용자가 자료함 만들기를 선택하면 새 UUID 폴더로 복사하고, 원문과 SDK 상태를 서로 다른 디렉터리에 둡니다. 기존 Folio 앱 자료함과 초안을 읽거나 초기화하지 않습니다. Mac 실행 파일과 iPhone·iPad 앱은 같은 화면·리소스를 사용합니다. Mac 예제는 보관 실패 콜백을 정상 창 닫기·앱 종료에 연결해 메모리에만 남은 입력이 있으면 종료를 취소합니다. 이 AppKit 연결은 SDK 밖의 예제 타깃에만 있으며 OS 강제 종료 보호를 보장하지 않습니다.

최소 확인은 독립 소비 앱의 빌드, 원문 변경 시 저장 거부와 초안 복구, 같은 UUID의 다른 호스트·위치 구분, 중복 세션 거부처럼 이 분리가 바꾼 경계에 한정합니다. 기존 실기기 결과나 mock 계정 결과는 SDK의 실제 Apple 계정 전환 통과로 대체하지 않습니다.

## 설계 근거

- [SwiftPM dependency 문서](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/): 원격 의존성은 URL과 버전 요구사항으로 재현하며 local dependency와 구분합니다.
- [Apple Swift package 리소스 문서](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package): 예제 리소스는 `Bundle.module`로 접근합니다.
- [Apple iCloud capability 설정](https://developer.apple.com/documentation/xcode/configuring-icloud-services/): 호스트 타깃이 iCloud entitlement·컨테이너·서명을 설정합니다.
- [Apple ubiquityIdentityToken 문서](https://developer.apple.com/documentation/foundation/filemanager/ubiquityidentitytoken): 토큰은 opaque 객체이고 archive byte 해시 대신 객체 동등성으로 계정 변화를 확인합니다.

## 2026-10-29 구현 검증

- `swift test --scratch-path /tmp/folio-sdk-build --jobs 4 --filter FolioSessionProtectionTests`: 핵심 4개 통과. 검토 후 원문 변경·재확인 후 재변경 거부와 최종 저장 해시, 초안 재실행 복원, 같은 UUID의 위치·호스트 및 늦은 편집 대상 격리, 이관 무변경, 파일 조정 도중 접근 철회를 포함합니다. 테스트는 임시 폴더의 의미 있는 한국어 문서만 사용합니다.
- 루트 SDK를 별도 임시 Git 저장소에 캡처해 임시 버전 태그의 URL 의존성으로 `FolioCore`와 `FolioSDKUI`를 가져오는 외부 소비 앱 빌드가 통과했습니다. 이 결과는 당시 캡처한 코어·선택형 UI·기반 소스에 한정됩니다. 이후 구조 정리와 아래 후속 개선의 검증을 대신하지 않습니다. 이 태그는 검증용 임시 저장소에만 있으며 Folio 저장소의 릴리스가 아닙니다.
- macOS 예제와 iOS Simulator 예제 앱 빌드 통과. 정상 Mac `.app`에서 자료함 만들기 → 한국어 문서 3개 목록 → 연구 노트 전체 본문·네이티브 편집 포커스를 실제 확인했습니다. 빌드·번들은 [예제 실행 helper](../Examples/FolioSDKHost/script/run_macos.sh)가 저장소 밖에 만듭니다.
- 기존 `MacApp`의 FolioMac 빌드와 기존 FolioIOS Simulator 앱 빌드도 통과했습니다.
- iOS 예제 런타임은 격리 시뮬레이터의 초기 OS 서비스가 `(ipc/mig) server died`로 종료돼 미확인입니다. 해당 시뮬레이터만 종료·삭제했고 기존 기기·시뮬레이터는 변경하지 않았습니다. 이번 SDK 변경으로 Apple 계정 전환 실기기 검증을 새로 통과한 것은 아닙니다.

소비 방식은 [SwiftPM 의존성 정의](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/)와 [Apple 패키지 통합](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app), 리소스는 [Bundle.module 규약](https://developer.apple.com/documentation/xcode/bundling-resources-with-a-swift-package)을 따릅니다. 호스트의 서명·iCloud 권한은 [Apple iCloud 설정](https://developer.apple.com/documentation/xcode/configuring-icloud-services/)에 따라 앱 타깃에서 관리합니다.
