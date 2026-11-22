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

`prepareKnowledgeIndex()`와 `knowledgeAnswer(_:documentID:)`는 Markdown과 문서에 연결된 텍스트 PDF를 전체 블록 색인에서 검색합니다. `documentID`를 주면 해당 문서와 연결된 PDF만 조회하며 존재하지 않는 범위를 전체 자료함으로 확대하지 않습니다. SDK 세션의 이 경로는 모델이나 네트워크를 활성화하지 않습니다. 기존 Folio 앱의 선택형 뜻 검색은 별도 `WikiSearchService` 모델 주입을 사용합니다.

반환되는 `WikiKnowledgeAnswer.evidence`는 생성형 답변이 아닌 현재 원문 인용입니다. `coverage`의 추출 누락·검색 범위를 함께 표시해야 합니다. `readKnowledgeEvidence(_:)`와 `previewKnowledgePDF(_:)`는 원문 권한과 revision을 다시 검사합니다. PDF 미리보기는 검증된 Data snapshot과 페이지·영역 좌표이며 원본 URL 쓰기 권한을 제공하지 않습니다. 원문 폴더 변경·계정 접근 상실·세션 닫힘 뒤 기존 인용으로 새 원문 읽기를 수행할 수 없습니다. 여러 자료의 검사는 전역 원자적 snapshot이 아닙니다.

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
