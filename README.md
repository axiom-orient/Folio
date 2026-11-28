# Folio

Mac·iPhone·iPad에서 책·문제집·논문·노트를 보관하고, 필요한 근거를 찾아 정확한 원문 위치를 확인합니다.

## 사용

1. **자료 추가**에서 PDF·Markdown을 가져오거나 노트를 만듭니다.
2. **노트 검색**으로 문서를 찾습니다. 본문 근거가 필요하면 **PDF·노트 근거 찾기**에서 키워드 또는 기기 내 한국어·영어 뜻 검색을 선택합니다.
3. 인용을 눌러 원문 페이지·영역·행을 확인합니다. **노트로 저장**, **용어 연결**, **주장 저장**으로 확인한 내용을 출처와 함께 보관합니다.

텍스트·스캔 PDF와 본문에 이미지 표·수식이 섞인 PDF를 지원합니다. 읽지 못한 페이지와 OCR의 한계도 표시합니다. 개념·주장에는 다른 이름, 조건·값·단위·판본을 연결할 수 있습니다. 원문 일치와 사용자의 채택을 객관적 진실의 인증으로 표시하지 않습니다. [PDF·OCR 지원 범위](docs/PDF_EVIDENCE.md) · [현재 구현과 후속 범위](docs/ONTOLOGY_IMPLEMENTATION_PLAN.md)

## 원문·승인·복구

자료함의 Markdown·PDF가 원문입니다. 검색 색인은 다시 만들 수 있고, 검색 결과나 모델 후보를 원문에 자동 반영하지 않습니다. 저장할 때 원문 버전을 검사하며, 변경된 개념 연결은 현재 내용을 다시 검토합니다. 초안과 불확실한 저장의 작업 기록을 유지하고 같은 작업의 결과를 확인합니다. 자료함 ZIP과 기기 내 초안·작업 기록의 보존 범위는 다릅니다. [저장·복구 계약](docs/SWIFTPM_SDK.md) · [문서 관리](docs/DOCUMENT_MANAGEMENT.md)

## 소스 배포와 빌드

[GitHub Releases · v0.2.0](https://github.com/axiom-orient/Folio/releases/tag/v0.2.0)에서 **Folio-0.2.0-source.tar.gz**와 **Folio-0.2.0-SHA256SUMS.txt**를 받습니다. 첨부한 소스 아카이브에는 검색 모델과 토크나이저가 포함됩니다. 이번 배포에는 설치용 앱·DMG·IPA가 없습니다. [배포 범위·체크섬·검증](docs/RELEASE.md)

Xcode 27 이상과 macOS 27 / iOS·iPadOS 27 이상을 대상으로 합니다. Git으로 받으면 Git LFS를 설치한 뒤 모델을 내려받습니다.

```sh
git clone --branch v0.2.0 https://github.com/axiom-orient/Folio.git
cd Folio
git lfs pull
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./script/build_and_run.sh --build-only
./script/build_ios.sh --local-simulator
```

Mac 명령은 로컬 자료함 개발 앱을 만듭니다. iOS 명령은 개발팀 계정 없이 임시 서명한 Simulator 앱을 빌드하며 설치·실행하지 않습니다. 정식 서명·iCloud·App Group·확장은 `Folio.xcodeproj`에서 각 개발팀의 capability를 설정합니다. [Mac 개발 구성](MacApp/README.md) · [iOS 설정](docs/IOS_IMPLEMENTATION.md)

## SDK와 라이선스

호스트 앱은 `FolioCore`와 선택형 `FolioSDKUI`를 사용합니다. 기존 앱의 호환 제품과 선택형 Mac SEMI 연결도 유지합니다. [SDK 계약](docs/SWIFTPM_SDK.md) · [통합 예제](Examples/FolioSDKHost/README.md) · [플랫폼 경계](docs/PLATFORM_DECISIONS.md)

Folio는 [MIT 라이선스](LICENSE)를 따릅니다. 타사 소스·모델의 출처와 라이선스는 [Vendor 고지](Vendor/README.md)와 [의미 검색 문서](docs/SEMANTIC_SEARCH_IMPLEMENTATION.md)에 있습니다. 개인 자료, 원시 검증 기록과 날짜별 조사 이력은 공개 배포에서 제외합니다.
