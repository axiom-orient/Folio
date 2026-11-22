# Folio

> 공개 저장소에는 개인 자료의 원문, 화면 캡처 및 로컬 검증 기록을 포함하지 않습니다. 관련 개발 문서의 일부 과거 기록 링크는 로컬 작업 환경에서만 사용할 수 있습니다.

Mac·iPhone·iPad에서 Markdown과 PDF 자료를 보관하고, 읽고, 원문 근거를 찾습니다.

**자료 추가**에서 PDF·Markdown을 가져옵니다. 돋보기로 노트 목록을 검색하거나 **PDF·노트 근거 찾기**를 열어 저장한 자료의 본문을 검색합니다. 찾은 인용에서 PDF 페이지나 Markdown 원문을 확인하고, 같은 결과로 돌아와 근거 노트를 저장할 수 있습니다. 키워드 검색은 모델 없이 실행하며 **뜻**을 선택하면 한국어·영어 모델로 검색합니다. [단계별 고도화 계획과 구현 범위](docs/KNOWLEDGE_PLATFORM_IMPLEMENTATION.md).

**자료함 선택 → 문서 선택 → 읽기 또는 편집.** 새 문서는 제목을 입력하면 본문 끝에서 바로 쓰기 시작합니다. 검색 결과는 해당 원문 위치를 엽니다. 편집·저장·공유는 도구 막대에 있으며, 연결된 문서는 본문 끝에서 펼칩니다.

- **저장**은 원문 반영, **읽기**는 표시 전환입니다. 읽기로 돌아가도 초안은 남습니다. Mac은 Cmd-S로 저장합니다. 자료함 전환 전에도 이 기기의 복구본을 보존합니다.
- Mac 종료는 모든 창의 입력 조합을 마친 뒤 초안 복구본 보관에 성공해야 진행합니다. 보관에 실패하면 편집과 자료함을 유지하고 종료를 취소합니다. 성공한 뒤에는 새 입력·자료함 전환을 닫고 기존 작업과 파일 접근의 종료를 기다립니다.
- 같은 작업공간 ID를 공유하는 로컬·iCloud 자료함의 새 초안은 위치와 iCloud 계정별로 보관합니다. 저장 위치나 계정 정보가 없는 이전 초안은 자동으로 귀속하지 않고, **이전 편집 복사본**에서 내용을 확인·공유할 수 있습니다. 계정 정보를 안전하게 확인할 수 없으면 기존 복구본을 유지하고 iCloud 자료함 편집을 중단합니다.
- **자료함**에서는 자료를 선택·생성·가져옵니다. **관리**에서는 문서 추가·첨부·공유·연결을 실행합니다. 새 자료함은 이름과 저장 위치만 입력합니다.
- 문서의 **공유**는 저장한 Markdown, **자료함 → 관리 → 자료함 ZIP 공유**는 원문 묶음을 사용합니다. **받은 파일**에서 파일과 대상 자료함을 확인하고 문서·첨부를 추가하거나 ZIP을 가져옵니다.
- 수신 원본이 남았지만 저장이 끝나지 않은 파일은 **받은 파일 → 저장을 마칠 수신 파일**에서 확인합니다. 명시적으로 다시 시도할 때 같은 전송의 원본과 파일 해시를 재확인하며 자동 재실행·덮어쓰기는 하지 않습니다.
- Markdown은 열린 자료함에, Folio ZIP·원문 폴더는 이 기기의 자료함으로 가져옵니다. 기존 원문·같은 ID의 자료·전송 기록을 덮어쓰지 않습니다.
- 받은 문서·첨부를 추가할 때는 표시한 자료함의 저장 위치도 확인합니다. 처리 중 자료함이 바뀌면 받은 원본과 전송 기록을 보존합니다.
- **문서 관리**에서 폴더 생성·이동·파일 이름 변경·휴지통·복원을 사용합니다. 문서 삭제는 첨부를 유지하고, 이동은 문서 ID와 상대 링크를 보존합니다. [문서 관리 계약](docs/DOCUMENT_MANAGEMENT.md).
- **제목·태그 편집**은 원문에 저장합니다. 폴더·태그·유형 필터로 목록과 검색을 좁히고, 검색 결과는 50개씩 끝까지 더 볼 수 있습니다.

원문 폴더는 `_workspace.md`, 선택형 `_ontology.md`, `notes/`, `attachments/`로 구성합니다. 원문이 정본이며 검색 DB는 다시 만들 수 있습니다. 외부 변경은 해시로 확인하고 오래된 초안의 덮어쓰기를 거부합니다. 원문 ZIP에는 DB·초안·영수증이 포함되지 않습니다.

[현재 화면과 구조](docs/FOLIO_REDESIGN.md) · [기기 전송](docs/NEARBY_TRANSFER.md)

다른 앱에는 **`FolioCore`와 선택형 `FolioSDKUI`**를 SwiftPM 제품으로 가져옵니다. 호스트가 원문 폴더와 SDK 상태 폴더, 고유 namespace, 파일 접근 수명을 직접 지정합니다. 세션 생성만으로 기존 Folio 자료함을 열거나 저장소 이관·Keychain·통신을 시작하지 않습니다. [SDK API·저장 경계·호스트 설정](docs/SWIFTPM_SDK.md)과 [연구 자료함 예제 앱](Examples/FolioSDKHost/README.md)에 통합 방법을 설명합니다.

루트 SDK의 의존성은 버전이 고정된 원격 패키지와 이 저장소에 포함된 원문 처리 모듈입니다. KnowledgeKit·Acornry의 필요한 소스는 `FolioKnowledge`·`FolioKnowledgeApple`·`FolioKnowledgeSQLite`·`FolioNearbyTransport` 모듈로 분리했습니다. 외부 앱의 같은 이름 모듈과 충돌하지 않도록 의도적으로 namespace를 변경했으며, 원본 체크섬·수정 내역·고지는 [Vendor](Vendor/README.md)에 보존합니다. `FolioUI`는 기존 Folio 앱 셸의 호환 제품이며, 새 호스트는 그 앱 전용 저장소·이관·SEMI 설정을 가져올 필요가 없습니다.

## 빌드

Xcode 27 이상(Swift 6.3 이상)과 Git LFS가 필요합니다. 배포 대상은 macOS 27 및 iOS/iPadOS 27 이상입니다. 처음 복제할 때 모델 파일을 함께 받습니다.

```sh
git clone https://github.com/axiom-orient/Folio.git
cd Folio
git lfs pull
```

기본 Mac·iOS 빌드는 별도 SEMI SDK 없이 동작합니다. Mac의 SEMI 연결은 선택 기능이며 SDK를 포함하지 않은 빌드에서는 연결 메뉴가 나타나지 않습니다. 개발 실행에는 Xcode의 Swift를 사용합니다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./script/build_and_run.sh
./script/build_ios.sh --local-simulator
xcrun swift run --scratch-path "$HOME/Library/Developer/FolioBuilds/Bootstrap" FolioDeveloper --dry-run cloud --install-iphone DEVICE_ID
xcrun swift test --scratch-path "$HOME/Library/Developer/FolioBuilds/Tests/Folio" --jobs 4
```

`FolioDeveloper`가 빌드·번들 교체·서명·아이콘 생성을 담당합니다. shell 진입점 네 개는 공통 `script/folio_developer.sh`를 통해 같은 Swift 도구를 실행합니다. `--dry-run`은 명령과 효과를 JSON으로 출력합니다. `mac --build-only`, `ios --local-simulator`, `cloud --mac|--iphone`, `assets`를 지원하며 기기 설치·실행은 `cloud --install-iphone DEVICE_ID`를 지정할 때 수행합니다.

아이콘의 변형·출력 크기·아이콘셋 파일명은 `DevelopmentIconLayout` 한 곳에 정의합니다. 개발 도구의 복사·경로 검사와 렌더러가 이 소스를 함께 사용하며, 기존 asset catalog 이름과 출력 파일명은 유지합니다.

SwiftPM·Xcode 빌드와 개발 앱 번들은 작업 트리 밖의 `~/Library/Developer/FolioBuilds/Development/<저장소 경로 digest>/`에 보관합니다. `DevelopmentPaths`가 캐시 루트를 선택하고 `DevelopmentBuildPaths`가 모드별 앱 제품 경로를 계산해 출력 안내·실행 파일 확인·기기 설치가 같은 경로를 사용합니다. bootstrap도 같은 외부 캐시 영역을 사용해 저장소에 `.build`를 다시 만들지 않습니다. Xcode가 로컬 패키지를 열 때 누적 빌드 파일까지 읽는 일을 줄이기 위한 경계입니다. `FOLIO_BUILD_ROOT`에 외부 절대 경로를 지정하면 그 경로를 사용합니다. 공백이 있는 경로도 인수 하나로 전달하며, 기존 캐시를 자동 삭제·이동하지 않습니다. 아이콘 원본과 asset catalog는 기존 저장소 경로를 유지합니다.

Mac 앱은 정상 종료한 뒤 빌드합니다. 정식 서명·iCloud·App Group은 `Folio.xcodeproj`에서 각자의 Apple 개발 팀과 capability로 설정합니다. 로컬 Mac 개발 앱은 `MacApp/Package.swift`를 사용합니다. 선택형 SEMI 연동을 활성화할 때만 `FOLIO_SEMI_SDK_PATH`를 지정합니다. [Mac 빌드와 선택형 연동](MacApp/README.md).

`Package.swift`는 공통 모듈·도구의 선언형 정본이며 모든 타깃은 Swift 6 모드입니다. 앱·확장·UI 테스트·서명 설정은 체크인된 `Folio.xcodeproj`에서 관리합니다. Vault 가져오기는 `swift run FolioVaultImport`를 사용합니다.

자료함 수명은 `FolioWorkspaceSession`, 새로고침·색인 작업은 `FolioWorkspaceJobs`, 초안은 `FolioDraftStore`, 문서 관리 작업은 `FolioDocumentLibrary`가 소유합니다. 최근 문서·숨긴 자료함 설정은 `FolioLibraryHistory`, 복구 비교 값은 `FolioSourceRepair`, 플러그인 입력·실행·취소 상태는 `AgentPluginsModel`이 담당합니다. 원문 변경 권한은 포함된 `FolioKnowledgeApple`의 기존 writer에 유지합니다.

저장소 준비 상태와 iPhone의 첫 잠금 해제 준비 작업은 `FolioStorageAccess`, iCloud 계정 변경과 자료함 닫기·위치 해제 작업은 `FolioCloudAccount`가 소유합니다. `FolioFileIntake`는 첨부 연결·받은 파일 반영의 진행 상태와 미리보기를, `FolioDocumentReader`는 원문 읽기·revision별 재조회 이력을 관리합니다. 편집 입력의 세대는 초안을 소유한 `FolioDraftStore`에 두며 읽기·저장·복구가 같은 값을 사용합니다. 이들은 같은 세션·초안·전송 모델을 사용하며 별도 상태 복사본이나 원문 writer를 만들지 않습니다.

`WikiAppModel`에는 창 등록, 전역 메시지·복구·충돌·병합 표시, 자료함·문서 명령의 조정을 남겼습니다. 기능별 extension은 이 조정 명령을 묶습니다. `WikiWindowTasks`가 두 플랫폼의 창별 작업을 연결하고, 상태 없는 `FolioAttachmentNotes`가 기존 영수증으로 첨부 노트 반영을 이어갑니다. 비동기 결과의 유효성은 해당 작업을 소유한 객체가 확인하고 앱 모델은 창 선택과 화면 갱신을 연결합니다.

원문 모듈의 YAML 검증·온톨로지·줄 좌표는 `Frontmatter`·`WikiOntology`·`SourceText`가 담당합니다. `WikiWorkspaceScanner`는 기존 workspace actor의 접근 확인 뒤 같은 동기 구간에서 원문을 검사하며, 저장·영수증·복구 권한은 `WikiWorkspace`에 유지합니다. 검색 조정과 Spotlight 색인·delegate는 별도 파일에 두고, 완료 콜백은 단일 구현을 사용합니다. 전송은 `AcornryNearby`가 작업·연결 수명과 관찰 상태를 유지하고 `AcornryOutgoingTransferSession`·`AcornryIncomingTransferSession`이 각 프로토콜과 결과 조회를 수행합니다. `AcornryApprovalExchange`와 `AcornryProgressLedger`는 승인 교환과 진행 값 계산을 담당합니다. 수신·저장 파일의 동일한 무결성 검사는 `AcornryPath.verifyFile`을 함께 사용합니다.

링크된 기존 검증 결과는 각 날짜와 소스의 실행 범위입니다. SDK 추출의 빌드·타깃 검증과 기존 실기기 검증은 별도이며, 과거 결과를 새 SDK의 실기기 통과로 간주하지 않습니다.

선택형 SEMI SDK를 포함해 빌드하고 SEMI를 실행한 뒤 **자료함 → 관리 → SEMI에 연결**을 선택합니다. 조회는 접근 검토, 변경은 정확한 미리보기와 별도 승인을 거칩니다. 결과가 불확실하면 기존 영수증을 조회하며 변경을 자동 재실행하지 않습니다. [플랫폼·기존 자료 이관 계약](docs/PLATFORM_DECISIONS.md), [iOS 구현](docs/IOS_IMPLEMENTATION.md).

Mac capability의 공개 schema와 실행 시 허용하는 최상위 입력 키는 `WikiCapabilityContract`가 함께 정의합니다. Provider는 준비·실행 Task와 승인 계획을 소유하며, 값·원문 버전·CAS 검사는 기존 capability와 `FolioKnowledgeApple`에 유지합니다.

Mac의 **Folio → 설정 → 스킬**에서 Codex·Claude Code 스킬을 글로벌 또는 프로젝트 폴더에 설치합니다. 로컬 폴더와 프라이빗 Git을 지원하며, 기존 파일과 사용자가 수정한 설치는 보존합니다. **플러그인** 탭은 설치된 호스트 CLI로 패키지·마켓플레이스를 관리합니다. 터미널에서는 같은 Swift 엔진의 `swift run FolioAgentsCLI --help`를 사용합니다. [설치 경로·인증·샌드박스 제한](docs/AGENT_MANAGEMENT.md).

검색 후보의 시간 제한·실행 수 제한과 인용 검증 API는 [인용 근거와 검색 검증](docs/EVIDENCE_VERIFICATION.md)에 설명합니다. `FolioSearchEvaluation`은 개인 자료를 사용하지 않는 한·영 합성 검색 평가 도구입니다. [Auto Ontology 비교와 개정 계획](docs/AUTO_ONTOLOGY_COMPARISON_AND_ROADMAP.md), [재검토·구현 결과](docs/AUTO_ONTOLOGY_IMPLEMENTATION_REVIEW.md)에 결정 근거와 실제 검증 범위를 기록합니다.

메인은 **읽기·쓰기·만들기**에 집중합니다. 돋보기로 검색을 열고 **뜻으로 찾기**로 한국어·영어 의미 검색을 실행합니다. 연결은 **문서 옵션 → 연결된 문서 → 연결 제안**에서 두 근거를 검토하고 별도로 승인합니다. 점수·모델 설명·식별자는 정보나 원문 변경 상세에서 확인합니다. 고정된 다국어 검색·관련성 모델을 앱에 포함하며 본문을 외부 모델로 보내지 않습니다. 개발 빌드 전 `git lfs pull`로 모델 weight와 공유 tokenizer 표를 확보하세요. 기본 검색은 유지합니다. [원인 분석·구현·실기기 검증·한계](docs/SEMANTIC_SEARCH_IMPLEMENTATION.md), [메모리 개선과 기준 재검토](docs/SEMANTIC_MEMORY_INVESTIGATION.md)을 확인하세요.

## 라이선스

Folio 코드는 [MIT 라이선스](LICENSE)를 따릅니다. 포함된 타사 코드와 모델에는 각각의 라이선스와 고지가 적용됩니다. [Vendor 고지](Vendor/README.md)와 각 리소스의 라이선스를 확인하세요.
