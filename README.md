# Folio

Mac·iPhone·iPad에서 Markdown과 PDF를 보관하고, 다시 찾아 정확한 원문 위치를 확인합니다.

## 사용

1. **자료 추가**에서 PDF·Markdown을 가져오거나 새 노트를 만듭니다.
2. **노트 검색**으로 노트를 찾습니다. 본문 근거가 필요할 때는 검색 화면의 **PDF·노트 근거 찾기**를 엽니다. **키워드**는 입력한 단어를 찾고, **뜻**은 기기 내 한국어·영어 검색 모델을 사용합니다. 노트에 적용한 폴더·태그 범위 안에서 뜻으로 찾으려면 검색 옵션을 사용합니다.
3. 자료명과 페이지·행이 표시된 인용을 눌러 원문을 엽니다. 검색 결과로 돌아온 뒤 **노트로 저장**을 누르면 질문과 출처를 별도 노트에 보관합니다. 저장 노트의 인용도 검증한 원문으로 연결됩니다.

근거 검색은 Markdown, 텍스트·스캔 PDF, 본문에 이미지 표나 수식이 삽입된 PDF를 지원합니다. **스캔 인식** 결과를 누르면 원본 페이지의 해당 영역을 확인할 수 있습니다. 읽지 못한 페이지는 검색 범위에 표시합니다. [스캔·표·수식 지원 범위](docs/PDF_EVIDENCE.md) · [화면과 진입점](docs/FOLIO_REDESIGN.md) · [개발 계획](docs/KNOWLEDGE_PLATFORM_IMPLEMENTATION.md)

## 원문과 복구

- `_workspace.md`, 선택형 `_ontology.md`, `notes/`, `attachments/`가 원문 자료함입니다. 검색 색인은 다시 만들 수 있으며 자료함 ZIP은 저장한 원문을 담습니다.
- 편집 내용을 저장할 때 원문 버전을 검사합니다. 읽기 화면으로 돌아가도 초안이 남고, 자료함을 바꾸거나 Mac 앱을 정상 종료할 때 기기 내 복구본을 보존합니다. 불확실한 저장은 해당 작업의 결과를 확인합니다.
- 관계 제안은 **문서 옵션 → 연결된 문서**에서 살펴보고 명시적으로 승인합니다. 파일 이동·휴지통·복원은 **문서 관리**, 전송과 미확정 수신 내역은 **받은 파일**에서 확인합니다. [문서 관리](docs/DOCUMENT_MANAGEMENT.md) · [iCloud와 계정별 복구](docs/SWIFTPM_SDK.md#icloud와-권한) · [기기 전송](docs/NEARBY_TRANSFER.md)

## 빌드

Xcode 27 이상이 필요합니다. 배포 대상은 macOS 27 및 iOS/iPadOS 27 이상입니다.

[GitHub Releases](https://github.com/axiom-orient/Folio/releases)의 소스 아카이브에는 빌드에 필요한 모델 파일이 포함됩니다. Git으로 받을 때는 Git LFS를 설치하고 아래 명령으로 모델을 내려받습니다. [배포 범위와 빌드](docs/RELEASE.md)

```sh
git clone https://github.com/axiom-orient/Folio.git
cd Folio
git lfs pull
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./script/build_and_run.sh
./script/build_ios.sh --local-simulator
```

공통 SwiftPM 제품은 `Package.swift`에, 앱·확장·서명은 `Folio.xcodeproj`에 선언합니다. 개발 빌드는 기본적으로 작업 트리 밖 `~/Library/Developer/FolioBuilds/Development/`에 보관합니다. 위치를 바꾸려면 `FOLIO_BUILD_ROOT`에 외부 절대 경로를 지정합니다. 정식 서명·iCloud·App Group은 Xcode에서 개발 팀과 capability를 설정합니다. [Mac 개발 빌드](MacApp/README.md) · [iOS 설정](docs/IOS_IMPLEMENTATION.md)

## 통합과 관리 도구

- SwiftPM으로 통합할 때는 **`FolioCore`**와 선택형 **`FolioSDKUI`**를 사용합니다. 호스트가 원문·상태 위치와 파일 접근 수명을 지정합니다. `FolioUI`는 기존 Folio 앱 셸의 호환 제품입니다. [SDK 계약](docs/SWIFTPM_SDK.md) · [통합 예제](Examples/FolioSDKHost/README.md)
- `FolioDeveloper`는 빌드와 앱 아이콘 생성을 담당합니다. 기존 Vault를 가져오는 명령과 옵션은 `xcrun swift run FolioVaultImport --help`에서 확인할 수 있습니다. `FolioSearchEvaluation`은 합성 자료로 검색을 평가합니다. [인용과 검색 검증](docs/EVIDENCE_VERIFICATION.md)
- Mac의 선택형 SEMI 연결은 조회 검토와 쓰기 승인을 거칩니다. 별도 스킬·플러그인 관리 도구는 Mac 설정과 `FolioAgentsCLI`에서 사용할 수 있습니다. [SEMI와 플랫폼 경계](docs/PLATFORM_DECISIONS.md) · [스킬·플러그인 관리](docs/AGENT_MANAGEMENT.md)

## 라이선스

Folio는 [MIT 라이선스](LICENSE)를 따릅니다. 포함된 타사 소스 및 모델의 라이선스와 출처는 [Vendor 고지](Vendor/README.md)와 [의미 검색 문서](docs/SEMANTIC_SEARCH_IMPLEMENTATION.md)에 있습니다. 공개 저장소에서 제외한 개인 자료와 로컬 검증 기록은 해당 작업 환경에서 확인할 수 있습니다.
