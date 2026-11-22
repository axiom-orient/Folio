# 실기기·복구 검증

FolioDeviceUITests는 설치된 앱의 실제 controls를 누르는 XCTest UI target입니다. fixture 성공·앱 hook·가짜 receipt·앱 초기화 없이 native source·저장·전송 결과를 확인합니다. 현재 결과는 [검증 현황](IMPLEMENTATION_STATUS.md)에 있습니다.

목록·자료함·검색·편집의 최신 UI 변경은 [콘텐츠 우선 UI 검증](Design/ContentFirst-20261023/VERIFICATION.md)에 실행별로 기록합니다. 범위 선택은 한 시트에서 직접 고르며, `모든 문서` 행으로 필터를 초기화할 수 있습니다. 기본 상태는 필터 control의 실제 값과 불필요한 범위 표시의 부재로 확인합니다. 편집 화면에서는 문서의 전체 이름도 검사합니다.

동시 편집 시나리오는 저장 전에 대상 문서·기준 revision·상대 기기의 변경·보존된 초안을 확인하고, 독립 변경의 자동 병합 뒤 전체 원문과 본문의 해시를 대조합니다. 전용 iCloud 검증 자료함에서는 같은 줄의 서로 다른 변경을 별도로 만들고, 양쪽 선택 내용을 확인한 뒤 명시적으로 선택·저장합니다. 예상과 다른 충돌이나 revision은 임의로 선택하지 않고 중단합니다. 후속 휴지통·복원 확인은 시나리오별로 지정된 결과 해시를 사용하며, 이전 실행의 해시와 새 기대값을 구분합니다.

문서 정보의 원문 버전을 펼쳐 확인한 revision은 공유 초안에 연결되며, 그 뒤 다른 원문을 받으면 다른 창에서도 저장하지 않고 초안을 보존합니다. 전용 iCloud 검증 자료함의 `testReviewedCloudSourceChangingBeforeSavePreservesSourceAndDraft`는 C 확인 후 C2 수신·저장 거부·C2 전체 해시와 초안 보존·C2 재확인 후 재시도를 확인하도록 작성했습니다. 이 코드와 기대 해시는 실기기 실행 결과가 아닙니다. 전용 iCloud 검증 자료함의 변경·충돌 시나리오는 새 검증 문서를 사용합니다.

전용 자료함의 선택과 확인은 이름 외에 iCloud 컨테이너 `iCloud.com.axient.Folio`와 작업공간 ID `0aad1085-a55f-4571-bf32-d96df65cc2a8`를 함께 사용합니다. 자료함을 다시 만들어 ID가 달라졌다면 실제 대상의 컨테이너와 ID를 확인한 뒤 테스트 설정을 갱신해야 합니다. 찾지 못하거나 식별자가 다르면 이름이 같은 다른 자료함을 대체 선택하지 않습니다. 숨김 자료함을 여는 동작은 숨김 설정을 해제하지 않습니다.

현재 확인 대상은 iCloud의 **AI agent** 자료함에 이미 있는 조사 문서 세 개입니다. 새 검증 문서를 만들지 않습니다. `FolioContentMaintenance/testExistingAIAgentListSearchBodyAndMetadataSave`는 자료함 전환, 폴더 범위, MCP 검색·원문·뒤로 가기, 검색 지우기, 기존 평가 문서의 본문·태그 저장을 확인합니다. 본문에 실행 경계 문서로 이어지는 문단을 추가하고 기존 태그를 보존하며 `ai-agent` 태그를 붙입니다. 이미 같은 내용이 있으면 추가 저장을 했다고 기록하지 않습니다.

FolioIOS scheme의 FolioDeviceChecks plan으로 빌드한 뒤, **해당 case만** 실행합니다. 아래 기기 ID·Team·산출물 경로는 환경에 맞춥니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Folio.xcodeproj -scheme FolioIOS -testPlan FolioDeviceChecks \
  -configuration Debug -destination 'platform=iOS,id=DEVICE_UDID' \
  -derivedDataPath build/FolioDeviceDocumentChecks -parallel-testing-enabled NO \
  DEVELOPMENT_TEAM=TEAM_ID \
  -only-testing:FolioDeviceUITests/FolioContentMaintenance build-for-testing

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -xctestrun build/FolioDeviceDocumentChecks/Build/Products/FolioIOS_FolioDeviceChecks_iphoneos27.1-arm64.xctestrun \
  -destination 'platform=iOS,id=DEVICE_UDID' -parallel-testing-enabled NO \
  -only-testing:FolioDeviceUITests/FolioContentMaintenance/testExistingAIAgentListSearchBodyAndMetadataSave \
  -resultBundlePath build/verification/UNIQUE_NAME.xcresult test-without-building
```

기기를 직접 잠금 해제해야 합니다. iPhone Mirroring은 사용하지 않습니다. signed Mac 앱을 열고 같은 Apple 계정의 전송 키·iCloud 접근을 유지합니다. 테스트는 전역 잠금·계정·네트워크·권한 설정을 바꾸지 않습니다.

Mac에서는 같은 cloud 자료함·평가 문서를 저장 전부터 열어 두고, iPhone이 저장한 새 문단과 태그를 reader·문서 정보에서 확인합니다. iPhone의 저장 성공이나 업로드 표시만으로 상대 기기의 수신 완료를 판정하지 않습니다.

`testCleanupOwnedVerificationDocuments`는 현재 여러 정리 대상의 고유 식별자가 확인되지 않아 앱 실행 전에 건너뜁니다. 나중에 정리를 활성화하려면 모든 자료함의 위치 식별자와 각 문서의 소유·원문을 사전에 확인해야 합니다. 영구 삭제는 실행하지 않습니다.

`testResearchScreensAndArchivedLibraries`와 `testResearchMacToPhoneReceiveAndDuplicateGuard`도 각각 숨김 대상과 수신 대상 자료함의 식별자가 확인될 때까지 건너뜁니다. 이름만 일치하는 다른 자료함의 숨김 상태나 문서를 변경하지 않기 위한 제한입니다.

## 이전 2026-10-13 시나리오

아래는 당시 실행 기록을 해석하기 위한 목록입니다. 현재 UI 검증에는 실행하지 않으며 전체 test plan 실행도 권하지 않습니다. 새 검증용 문서·표식은 만들지 않습니다.

| Case | 당시 준비·확인 |
| --- | --- |
| `testCloudReadAndPhoneCommit` | Mac에서 ‘Folio 실기기 검증 20261013’을 iCloud에 게시하고 ‘양방향 저장 검증’에 `Mac에서 저장한 검증 원문입니다.`를 저장. iPhone에서 읽고 새 문서를 명시 저장한 뒤 Mac reader에서도 `PHONE_COMMIT_20261013` 확인 |
| `testDraftSurvivesBackgroundAndRelaunch` | 같은 cloud 자료함. 초안을 입력한 뒤 background·종료·재실행, 저장한 reader와 초안 구분·이어쓰기·명시 저장 |
| `testPhoneDocumentToMacDelivery` | Mac receiver를 foreground로 유지. 테스트의 `FOLIO_QA_SENT_TO_MAC` 뒤 Mac에서 받기·추가. 실제 송신 완료 문구와 Mac source의 내용·digest 확인 |
| `testReceiveMacDocumentAndAddToLocalLibrary` | `FOLIO_QA_READY_TO_RECEIVE` 뒤 180초 안에 Mac ‘양방향 저장 검증’의 기기로 보내기를 실행. iPhone은 받기·추가·reader·보관된 실제 파일명을 확인. 송신 완료·수신 receipt와 bytes도 별도 확인 |
| `testConcurrentCloudChangeRequiresReviewedDraftRecovery` | `FOLIO_QA_CONCURRENT_DRAFT`의 문서를 Mac에서 열어 `MAC_CONCURRENT_COMMIT_20261013`을 명시 저장. iPhone의 오래된 저장 거부·초안 유지·현재 원문 비교를 확인한 뒤 **초안으로 저장**으로 선택한 초안을 명시 반영. Mac에서도 최종 내용을 확인 |

양기기 전송과 동시 편집은 두 기기의 실제 조작이 필요한 수동 협업 테스트입니다. 대기 창에 송신을 하지 않은 실패를 제품 성공으로 해석하지 않습니다. 일반 `swift test`는 앱을 조작하거나 개인 cloud 자료를 만들지 않습니다.

Mac 원문 fixture에는 `_workspace.md`, `notes/control.md`, `notes/repair.md`와 변경 전 백업을 보존합니다. 초안을 만든 뒤 외부 원문을 깨뜨리거나 다른 위치로 옮겨 진짜 파일 변경을 발생시킵니다. 비교 뒤 추가 변경은 거부해야 하며 재확인·명시 저장 뒤 source bytes와 reader를 확인합니다. 실제 iCloud/NSFileVersion 버전 충돌은 이 CAS 검증과 별도입니다. OS가 제공한 진짜 conflict versions 없이 화면 성공을 만들어 내지 않습니다.

`xcresulttool export attachments`로 실제 기기의 screenshot·AX hierarchy를 보존합니다. SDK build, test list 발견, 설치 성공만으로 runtime PASS를 표시하지 않습니다. 새 실행은 고유한 xcresult 경로를 사용하고 원본 실패 로그를 남깁니다.
