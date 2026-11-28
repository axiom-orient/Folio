# Folio v0.2.0 소스 릴리스

이번 릴리스의 범위는 **자료 관리·검색·원문 확인·개념과 주장 저장·복구**다. PDF·Markdown에서 필요한 근거를 찾고, 실제 원문 페이지·영역·행을 확인한 뒤 명시적으로 저장한다. 관계 탐색의 확장(O4), 생성형 설명(O5), 기본 자동 추출 모델은 포함하지 않는다. [현재 구현과 후속 범위](ONTOLOGY_IMPLEMENTATION_PLAN.md)

## 배포 파일

[GitHub Releases · v0.2.0](https://github.com/axiom-orient/Folio/releases/tag/v0.2.0)에서 다음 첨부 파일을 받는다.

- **Folio-0.2.0-source.tar.gz**: 태그의 공개 소스와 실제 모델·토크나이저 파일이 들어 있는 아카이브.
- **Folio-0.2.0-SHA256SUMS.txt**: 첨부 소스 아카이브의 SHA-256 체크섬.

두 파일을 같은 폴더에 받은 뒤 확인한다.

```sh
shasum -a 256 -c Folio-0.2.0-SHA256SUMS.txt
tar -xzf Folio-0.2.0-source.tar.gz
```

GitHub가 자동 생성하는 `Source code` 파일과 위 첨부 아카이브를 구별한다. Git으로 받는 경우 `v0.2.0` 태그를 선택하고 `git lfs pull`로 모델을 내려받는다. 이번 배포는 소스 배포이며 설치용 `.app`·DMG·IPA와 Apple 배포 서명·공증을 제공하지 않는다. [Git LFS 소스 아카이브 안내](https://docs.github.com/en/repositories/managing-your-repositorys-settings-and-features/managing-repository-settings/managing-git-lfs-objects-in-archives-of-your-repository)

## 핵심 기능과 이번 정리

- 한국어·영어 키워드와 뜻 검색을 사용하고, 텍스트·스캔·혼합 PDF의 근거를 실제 원문 위치로 연다. 이미지 표·수식의 OCR 범위와 읽지 못한 페이지를 구별한다. [PDF·OCR 계약](PDF_EVIDENCE.md)
- 개념명·다른 이름과 주장·조건·값·단위·판본을 원문 근거에 연결한다. 100개 뒤의 동일 주장도 정확한 내용으로 찾아 재사용하며, 읽지 못한 기록이 있으면 부재를 추정해 새 파일을 만들지 않는다.
- 연결 개념이 바뀐 주장은 현재 내용을 명시 검토하고 같은 파일에서 다시 연결한다. 검토 뒤 다시 바뀐 개념과 변경된 원문을 보지 않은 상태로 승인하지 않는다.
- 저장한 노트로 이동할 때 검색창이 남던 문제를 수정했다. 중복 검색창 표시 코드를 통합하고, 파생 노트의 동작하지 않는 질문 진입점과 기본 화면의 부가 진단을 정리했다.
- 원문 writer, 명시 승인, 버전 검사, 초안, 작업 영수증과 불확실한 결과 관측은 기존 계약을 유지한다. 공개 SDK와 기존 호환 제품을 폐기하지 않는다. [SDK·승인·복구](SWIFTPM_SDK.md) · [인용 검증](EVIDENCE_VERIFICATION.md)

이 소스 배포 자체는 사용자 자료함을 변경하거나 자동 마이그레이션하지 않는다. 원문 ZIP은 기기 내 초안·작업 기록 전체의 백업이 아니다. 이전 소스로 돌아갈 때도 원문 자료와 기기 내 복구 상태를 구별해 보존하며, 불확실한 작업을 새 작업으로 재실행하지 않는다. 별도의 복구 절차를 추가하지 않았다. [자료함·상태·복구 계약](SWIFTPM_SDK.md) · [문서 관리](DOCUMENT_MANAGEMENT.md)

## 빌드

Xcode 27 이상, macOS 27 및 iOS·iPadOS 27 이상을 대상으로 한다. 압축을 푼 소스의 루트에서 실행한다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
./script/build_and_run.sh --build-only
./script/build_ios.sh --local-simulator
```

Mac 명령은 로컬 자료함 개발 앱을 만든다. iOS 명령은 개발팀 계정 없이 임시 서명한 Simulator 앱을 빌드하며 프로비저닝·실기기 설치를 요청하지 않는다. iCloud·App Group·Spotlight를 포함한 애플리케이션은 `Folio.xcodeproj`에서 각 Apple 개발팀의 서명과 권한을 설정한다. [Mac 개발 구성](../MacApp/README.md) · [iOS 설정](IOS_IMPLEMENTATION.md)

## 검증 범위

릴리스 준비 직전 핵심 소스의 **고유 26개 테스트**를 확인했다. 핵심 회귀 20개, 실제 SEMI 통합 5개, native UI 1개이며 마지막 UI 관련 4개 재실행은 중복 합산하지 않았다. 이번 문서·버전 정리에서는 제품 Swift 코드를 바꾸지 않고 이 결과를 재사용했다.

Mac 로컬 앱에서 실제 논문 PDF 추가, 한국어 별칭·뜻 검색, 무관 질의의 근거 없음, 근거 저장·원문 재열기, 정상 종료 후 초안 복구와 주장 재연결을 확인했다. 원문 PDF 해시는 전후에 같았다. iOS Simulator는 빌드·설치·실행과 검색→저장→검색창 닫힘→저장 인용의 원문·판본 재열기를 확인했다. 마지막 native UI 테스트는 1개, 실패·skip 0개, 종료 코드 0이었다.

이번 릴리스 준비에서 실기기, 실제 iCloud 계정 전환·동기화, 전체 테스트 suite와 장시간·대규모 부하는 실행하지 않았다. 과거 기기·성능 결과를 이번 소스의 새 인증으로 합산하지 않는다. 원문 일치·현재성 검사를 객관적 진실이나 표·수식의 완전한 의미 이해로 표시하지 않는다. 로컬 원시 로그·소스 해시·화면 기록은 공개 아카이브에서 제외한다.

라이선스와 제3자 고지는 [LICENSE](../LICENSE)와 [Vendor 고지](../Vendor/README.md)를 따른다.
