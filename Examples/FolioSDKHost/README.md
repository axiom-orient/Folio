# 독립 호스트 예제: 연구 자료함

이 예제는 앱 전용 `FolioUI`나 SEMI 연동을 가져오지 않고 `FolioCore`와 선택형 `FolioSDKUI`만 사용합니다. Mac 실행 파일과 iPhone·iPad 앱이 같은 `FolioResearchExample` 화면과 문서 리소스를 사용합니다.

문서는 연구 노트 작성, Swift SDK의 책임 분담, 팀 문서 검토를 다룹니다. 서로 이어지는 Markdown 링크와 한국어 본문을 포함합니다. `Bundle.module`의 리소스는 읽기 전용이며 사용자가 **연구 자료함 만들기**를 선택할 때만 새 UUID 디렉터리에 복사합니다. 기존 자료함에 복사하거나 덮어쓰지 않습니다.

## 실행

Mac에서는 실행 도우미로 정상 앱 번들을 만들어 엽니다. 빌드 산출물과 앱 번들은 저장소 밖에 두고 매 실행마다 새 앱을 만들며, 기존 앱을 교체하지 않습니다.

```sh
Examples/FolioSDKHost/script/run_macos.sh
```

도우미는 Xcode의 Swift로 예제를 빌드하고 SwiftPM이 생성한 리소스 번들을 앱의 `Contents/Resources`에 그대로 포함합니다. 코드에서는 계속 `Bundle.module`을 사용합니다. 별도 서명, entitlements, 권한 추가는 하지 않습니다. `--prepare-only`를 지정하면 앱을 실행하지 않고 생성된 `.app`의 절대 경로를 출력합니다. `FOLIO_EXAMPLE_BUILD_DIR`로 저장소 밖의 빌드 캐시를 지정할 수 있습니다.

iPhone·iPad에서는 `FolioSDKHost.xcodeproj`를 열어 **FolioResearchIOS** scheme을 선택합니다. 시뮬레이터에는 별도 계정이나 권한 설정이 필요 없습니다. 실기기에 설치하려면 예제 앱 타깃에 자신의 개발 Team과 고유한 Bundle Identifier를 지정합니다. 예제는 iCloud, App Group, Photos, 근거리 통신 권한을 사용하지 않습니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Examples/FolioSDKHost/FolioSDKHost.xcodeproj \
  -scheme FolioResearchIOS -destination 'generic/platform=iOS Simulator' \
  -derivedDataPath /tmp/FolioResearchIOS-build build
```

## 사용 흐름

1. **연구 자료함 만들기**를 눌러 문서 세 개가 들어 있는 새 자료함을 만듭니다.
2. 문서를 선택하고 Markdown 원문을 읽거나 편집합니다. `iCloud`, `근거`, `복구` 같은 주제로 검색할 수 있습니다.
3. 편집 내용은 SDK의 전용 초안 저장소에 기록됩니다. **저장**은 기준 원문 버전을 확인한 뒤 원문에 반영합니다.
4. **자료함 닫기** 뒤 **이전 자료함 열기**를 선택하면 같은 예제 자료함과 초안을 다시 엽니다. 앱을 다시 실행해도 이전 자료함은 사용자가 열기를 선택할 때만 엽니다.
5. 저장 결과가 불확실하면 **저장 결과 확인**으로 기존 작업의 결과를 확인합니다. UI는 결과가 확인되지 않은 저장을 자동 재실행하지 않으며 **편집 복사본 공유**를 제공합니다.
6. 외부에서 원문이 변경됐다면 **현재 원문과 비교**에서 양쪽 내용을 검토합니다. 필요한 변경을 초안에 반영하고 **확인한 원문을 기준으로 초안 준비**를 누릅니다. 이 사이 원문이 다시 바뀌면 준비가 거부되고 초안은 유지됩니다. **원문 다시 확인** 뒤 재검토할 수 있으며 실제 원문 반영은 별도 **저장** 동작입니다.

## 저장소와 수명 경계

호스트는 Application Support의 `FolioSDKHost/Libraries/<새 UUID>/`에 원문을 만들고, `FolioSDKHost/State/`를 SDK의 상태 디렉터리로 지정합니다. 두 디렉터리는 서로 포함하지 않습니다. 기본 설정은 `com.example.FolioSDKHost` suite에 마지막으로 만든 예제 디렉터리의 UUID만 기록합니다. SDK는 이 설정을 읽지 않습니다.

자료함 생성, 마지막 예제 기억, 다시 열기는 `ResearchHost`의 책임입니다. `FolioSession`은 명시적으로 전달받은 원문과 상태 디렉터리만 사용합니다. 예제는 기존 Folio 앱의 자료함, 초안, `SourceWiki` 이관 경로, Keychain, iCloud 계정을 사용하지 않습니다. 생성한 자료와 초안을 자동 삭제하는 기능도 없습니다.

`FolioLibraryView`는 호스트가 전달한 세션을 표시하는 선택형 화면입니다. 자체 저장소나 앱 전역 모델을 만들지 않으며, 세션을 닫거나 보안 범위 접근을 해제할 시점은 호스트가 소유합니다. 외부 폴더를 지원하는 실제 호스트는 폴더 접근 권한과 security-scoped bookmark의 수명을 별도로 관리해야 합니다.

초안 파일 보관이 실패하면 화면의 네이티브 입력을 유지하고 공유와 보관 재시도를 제공합니다. `onUncheckpointedEdit`가 `true`인 동안 예제 호스트는 자료함 닫기를 막습니다. 이를 임베드하는 호스트도 해당 입력을 별도로 확보하거나 보관이 성공할 때까지 화면과 세션을 유지해야 합니다.

이 예제의 `.package(path: "../..")`는 같은 checkout의 SDK를 소비하기 위한 개발 설정입니다. 실제 앱에서는 배포된 Folio 저장소의 URL과 버전을 지정하고 `FolioCore`, 필요한 경우 `FolioSDKUI` 제품을 선택합니다. 루트 SDK는 예제 패키지에 의존하지 않습니다.
