# Auto Ontology 비교 재검토 및 Folio 구현 기록

2026-11-08 · [개정 비교·계획](AUTO_ONTOLOGY_COMPARISON_AND_ROADMAP.md) · [공개 인용 검증 계약](EVIDENCE_VERIFICATION.md)

## 1. 검토 결론과 수정한 주장

서로 다른 제품에 대한 최초 문서의 큰 방향은 코드와 부합한다. Folio는 원문 Markdown과 Apple 앱의 수명을 소유하고, Auto Ontology는 기업 데이터의 의미 계층과 SQL 질의 파이프라인을 제공한다. 두 제품을 대체 관계로 보거나 NVIDIA의 서버 전체를 이식할 근거는 확인되지 않았다.

다만 최초 계획은 다음 부분을 수정했다. 세 번의 검토는 다수결이 아니라 서로 다른 증거를 이용했다.

| 검토 | 증거 | 판정과 변경 |
| --- | --- | --- |
| 1차: 주장·소유권 대조 | Folio의 package/실제 호출자, 고정 NVIDIA revision의 pipeline·MCP·검증 routing | local page와 bounded agent search의 차이는 사실. 도식의 SEMI → 검색 서비스 호출 방향을 수정. 기존 관계 화면에 incoming/outgoing·진단·이동·선언 원문 열기가 이미 있음을 확인해 새 화면 계획을 축소. |
| 1차: 의미적 타당성 | 검색 후보·원문 해시·coverageComplete의 실제 의미 | 검색 성공으로 질문 답변 가능성이나 진실을 판정할 수 없다. P3의 자동 `supported/ambiguous` 판정은 철회하고 참조의 current/changed/invalid/unavailable 검증으로 구체화. 기존 장기 proposal 모델은 미구현 참고로 표시. |
| 2차: 실패·경계 실행 | 취소를 무시하는 provider, 늦은 결과, 여러 요청, 실제 parser/SQLite/source CAS, SDK 전체 테스트 | task-group의 800ms 경쟁이 비협조 provider를 기다린다는 결함을 수정. provider 실행 슬롯을 유지해 반복 요청의 누적 방지. SDK의 정상 상태 경로 admission 오류도 재현·수정. |
| 3차: 수정 후 회귀·빌드 | 전체 root 테스트, 별도 SEMI 통합, Mac/iOS 빌드, 합성 검색 JSON, 전후 파일 해시 | 아래 실제 결과와 남은 범위를 기록. 테스트 오류·디스크 부족 실패를 삭제하거나 성공으로 바꾸지 않음. |

NVIDIA `c447003f72a822301e927196a4ecb5b597c308d5`를 다시 읽었다. SQL 검증은 모든 검사에 대한 무조건적 인증이 아니다. `text_to_sql_graph._make_soft_check_router`는 재구성 횟수가 한도를 넘으면 일부 soft check를 건너뛰는 경로를 갖는다. 따라서 “검증 파이프라인 존재”를 “항상 정확한 답변”으로 해석하지 않는다. [고정 소스](https://github.com/NVIDIA/auto-ontology/blob/c447003f72a822301e927196a4ecb5b597c308d5/auto_ontology/retrieval/text_to_sql/text_to_sql_graph.py#L131)

## 2. P0 — 기준 보존과 정리 판정

변경 전 저장소 555개 파일의 SHA-256 manifest 및 gzip archive, Git staged/untracked 상태를 작업 트리 밖 `/Users/ax/Library/Developer/FolioBuilds/Verification/ontology-20261108/`에 보존했다. Git commit이나 index를 변경하지 않았다. `.git`, `.build`, `build`, `.swiftpm`, `.DS_Store`는 archive에서 제외했다. 원래 비교 문서의 310개 집합과는 조사 범위가 다르다.

공개 제품은 `Package.swift`, 앱 consumer는 Xcode 프로젝트·`MacApp`, SEMI consumer는 `MacIntegration`, 독립 SDK consumer는 `Examples/FolioSDKHost`에서 확인했다. 외부 소비자가 없다는 증거는 없으므로 공개 API를 제거하지 않았다. KnowledgeKit 권리 확인은 저장소 고지 이상으로 확정할 수 없어 외부 배포 판단은 미확정이다. 로컬 구현·테스트와는 별도로 기록한다.

| 정리 후보 | 검증과 실행 결과 |
| --- | --- |
| R1 과거 hash/History | 11개 manifest의 바이트와 `files` inventory 해시가 모두 다름. History의 본문 참조도 존재. 삭제 대신 [보존 인덱스](Verification/ontology-20261108/historical-snapshot-inventory.json)를 생성. |
| R2 제한형/페이지 검색 | 실제 소비자와 33-term 경계 fixture로 서로 다른 계약 확인. 공통 ranking/FTS는 이미 공유. 제거 대상은 결함 있는 task-group timeout 경쟁으로 좁혀 교체. local 페이지의 전체 결과 계약과 기존 32-term 제한형 호환은 유지. |
| R3 Core/UI CloudIdentity | 계정 ID 저장과 UI opening 세대의 다른 책임을 확인. 통합·삭제하지 않음. |
| R4 앱/SDK UI | 실제 각 consumer가 존재. 중복 화면 대신 기존 관계 근거 sheet에 설명 추가. |
| R5 legacy 복구/스킬 경로 | 사용자 수정·초안 보존 계약이 있어 유지. 데이터를 버리는 cleanup을 실행하지 않음. |
| R6 derived-value 공개 API | 저장소 내부 직접 사용 부재는 외부 미사용 증거가 아님. 호환 API 유지. |
| R7 agent/import/developer | 실제 CLI·앱 연결과 독립 테스트가 존재. 기능 제거 근거 없음. |
| R8 Vendor | 원본 `files` 체크섬을 보존하고 `adaptations.modifiedFiles`에 수정/추가 소스 해시 갱신. 배포 권리 미확정을 해소했다고 주장하지 않음. |

사용자 원문·초안·operation receipt·iCloud·기존 캐시는 삭제하지 않았다. 디스크 부족 복구 때 이번 작업에서 생성한 Mac 빌드 중간물과 별도 provider 빌드 중간물만 정리했다. 작업 도중 `WikiSourceRepairView.swift`의 confirmationDialog → alert 변경과 별도 iOS 빌드가 관찰됐다. 이 변경은 이번 구현이 아니며 보존했다.

## 3. P1 — 검색의 취소·수명·평가

`WikiCandidateSearch`가 선택형 검색 작업의 수명을 소유한다. 기다림은 기본 약 800ms에 끝나며 비협조 provider가 계속 실행되면 완료할 때까지 슬롯 하나를 점유한다. 이 기간 다른 요청은 `systemSearchBusy` 상태의 로컬 결과를 받는다. 늦은 결과는 끝난 요청에 게시되지 않는다. provider 종료 뒤 슬롯을 해제한다. 취소된 호출자는 늦은 결과를 받지 않는다.

`WikiSearchService`는 provider가 반환하는 후보 ID를 1,000개까지 사용하며, provider 오류의 출처를 보존한다. await 후 workspace admission을 다시 검사하므로 자료함을 닫은 뒤 비어 있는 검색 성공을 반환하지 않는다. 전체 source scan/FTS/검증을 포함한 응답 시간은 800ms 보장이 아니다.

실행 검사는 실제 suspension gate로 provider를 멈춘 뒤 timeout·20회 중복 요청·취소·늦은 완료·다시 검색을 확인한다. 실제 서비스가 provider를 기다리는 동안 workspace를 닫는 fixture도 포함한다. sleep 완료를 성공으로 간주하지 않는다.

`FolioSearchEvaluation`은 임시 자료함의 문서 5개, 질의 8개, 경로 2개, 반복 5회로 80회 실행했다. 평가 경로는 앱/SDK와 같은 `localPage` 및 SEMI 검색의 `includeSystemSearch=false` 로컬 fallback이다. **실제 Spotlight·원격/온디바이스 의미 모델 및 SEMI 앱 UI 평가는 아니다.**

| 경로 | 관련 문서가 있는 질의의 평균 Recall@10 | 평균 MRR@10 | p50 / p95 |
| --- | --- | --- | --- |
| localPage | 0.8571 | 0.8571 | 29.75ms / 50.71ms |
| boundedLocalFallback | 0.8571 | 0.8571 | 18.33ms / 28.00ms |

[원시 결과](Verification/ontology-20261108/search-evaluation.json). 관련 질의는 7개×5회/경로이며 빈 결과 질의 1개는 recall/MRR 분모에서 제외했다. `AbsentNeedle`은 두 경로 모두 결과가 없었다. 의도적으로 동의어를 선언하지 않은 `저축기관`은 두 경로 모두 예금 문서를 찾지 못했다. 캐시는 처음 실행 후 warm 상태를 포함하며 동시에 빌드가 진행된 개발 기기 측정이므로 일반 성능이나 전후 개선율로 해석할 수 없다. 같은 질의 반복은 독립 표본이 아니므로 신뢰구간을 제시하지 않는다.

## 4. P2 — 관계 검토와 쓰기 안전성

기존 `WikiRelationsView`의 근거 sheet에 관찰한 관계 상태와 설명을 추가했다. 명시 typed relation이 규칙에 맞는 경우, Markdown 링크/ontology 부재로 별도 유형 검증이 없는 경우, 제약 위반, 대상 없음/중복, ontology 읽기 실패를 구별한다. 표시한 상태는 선택한 연결의 관찰값이며 원문 변경 시 다시 확인하도록 안내한다.

기존 writer를 그대로 사용한다. target 변경 또는 ontology 변경 뒤 기존 관계 편집 계획의 execute가 거부되고 source가 보존되는지 검증했다. 새 계획으로 반영한 뒤 receipt를 확인하고 같은 operation의 재확인이 관계 중복 추가로 이어지지 않는지 검사했다. 별도 새 관계 생성 UI나 자동 제안 저장소는 만들지 않았다. 기존 SEMI 미리보기·승인·실행 통합도 실제 SDK로 테스트했다.

## 5. P3 — 인용 근거 검증

`WikiWorkspace.verifyEvidence`와 읽기 전용 `wiki.verify_evidence`를 추가했다. 요청 순서와 중복을 유지하며 각 참조의 현재성·변경·잘못된 digest/범위·파일 접근 불가를 보고한다. 빈 참조는 `allCurrent=false`다. workspace 접근 admission 및 취소는 오류로 전달한다. 기존 `read`의 원문 검증을 공유하며 stale 본문이나 자동 답변을 만들지 않는다.

실제 provider에 정상 참조, 변경 후 참조, 초과 입력과 잘못된 최상위 키를 보내고 원문 무변경을 확인했다. API는 추가형이며 기존 8개 capability의 식별자와 쓰기 의미는 유지한다. 여러 파일의 `atomicSnapshot=false`를 명시한다.

## 6. P4 — P0~P3 완료 당시 판정과 후속 구현

**당시 판정: 게이트 평가 완료, 모델/자동 관계 생성 도입 보류.** 합성 코퍼스에서 lexical 누락은 관찰했지만 실제 사용자의 반복 질의·기기 예산·의미 모델 성능·데이터 전송 선호는 확보하지 못했다. 최초 계획 자체의 조건이 충족되지 않아 외부 모델 호출, 임베딩 서버, 자동 관계 반영을 실행하지 않았다. 이를 P4 기능 구현 완료로 표시하지 않는다. P1 평가 도구와 P2/P3 검증 경계가 다음 실험의 기반이다.

후속 구현에서 발견한 부정 후보 문제를 분석하고 한국어·영어 후보 검색과 공동 관련성 검사로 교체했다. 기존 기록의 테스트 수는 P0~P3 시점이며, 최신 범위·실기기 검증·도입 기준은 [의미 검색 구현 기록](SEMANTIC_SEARCH_IMPLEMENTATION.md)을 따른다.

## 7. 검증 결과

P0~P3 당시의 최종 결과를 아래 표에 기록한다. 환경: Apple Silicon macOS, Xcode의 Swift 6.4, Swift 6 언어 모드, macOS/iOS 배포 대상 27.0. 사용자의 전역 developer directory는 바꾸지 않고 명령별 `DEVELOPER_DIR`를 사용했다.

| 검사 | 결과 | 실제 범위 / 로그 |
| --- | --- | --- |
| Root Swift Testing | **PASS · 252 tests** | UI 162, Knowledge 8, Core 10, Agents 38, VaultImport 20, Development 14. `Logs/folio-ontology-complete-tests.log`, exit 0. parameterized cases는 test 수에 중복 합산하지 않음. |
| 취소·timeout 반복 | **PASS · 2 tests × 각 5회** | 비협조 provider 수명·20회 중복 admission·caller 취소. `Logs/folio-ontology-cancellation-repeated.log`, exit 0. |
| 실제 SEMI SDK/provider 통합 | **PASS · 2 tests** | 승인·쓰기·receipt 및 새 인용 검증 요청/오류/무변경. `Logs/folio-ontology-provider-final.log`, exit 0. |
| Mac 앱 Xcode | **PASS** | scheme `FolioMac`, macOS, 서명 비활성. `Logs/folio-ontology-mac-final.log`, exit 0. |
| iOS 앱 Xcode | **PASS** | scheme `FolioIOS`, generic iOS Simulator, arm64/x86_64, 서명 비활성. `Logs/folio-ontology-ios-final.log`, exit 0. |
| 독립 SDK 예제 | **PASS** | `Examples/FolioSDKHost`의 실제 SwiftPM 빌드. `Logs/folio-ontology-sdkhost.log`, exit 0. |
| 합성 검색 | **실행 완료 · 알려진 누락 1/8 질의** | 80 samples, 동의어 미선언 `저축기관` 누락. 품질 한계를 성공으로 바꾸지 않음. |
| Vendor 수정 체크섬 / 문서 링크 | **PASS** | 원본 checksum 유지, 수정/추가 소스 현재 checksum 일치, 새 문서의 로컬 링크 검사. |
| UI 조작·VoiceOver·실기기·NVIDIA 서비스 | **NOT_RUN** | 빌드 및 fixture 통과로 승계하지 않음. |

이 표는 P0~P3 실행 당시의 기록이다. 후속 실제 Mac·iPhone 의미 검색 UI·승인·복구 검증은 [현재 P4 기록](SEMANTIC_SEARCH_IMPLEMENTATION.md)을 따른다. VoiceOver와 NVIDIA 서비스 실행을 새로 통과했다고 주장하지 않는다.

실패 이력:

- 최초 예비 빌드는 소스 파일 추가와 빌드 입력 발견이 겹쳐 helper를 찾지 못했다. 이 실행은 baseline 통과로 집계하지 않는다.
- 전체 실행에서 SDK 5개가 `recoveryDamaged`로 실패했다. 실제 원인은 `FolioStatePaths.validate`가 시스템 별칭 `/var`까지 `lstat` 디렉터리 조건으로 거부한 것이다. Foundation이 `/private/var`를 `/var`로 표시하는 것을 별도 실행으로 확인했다. 지정 base와 하위는 `lstat`로 계속 거부하고, base 위의 canonical ancestor만 디렉터리 별칭을 허용한다. base·scope·ancestor를 source로 repoint하는 회귀 테스트를 유지/추가했다.
- 중첩된 빌드 부하에서 기존 refresh 테스트의 2초 대기가 한 차례 실패했다. 제품 코드나 기대값을 완화하지 않고 병렬 실행을 끈 전체 테스트로 재확인했다. 빌드 부하가 원인이라는 인과관계까지 증명한 것은 아니다. 실패 로그를 보존한다.
- iOS 최초 링크는 `errno=28`, 디스크 부족으로 실패했다. 이번 작업의 생성 중간물만 정리한 뒤 다시 빌드했다.

GUI의 실제 새 sheet 조작, VoiceOver·큰 글자·iCloud 계정 전환·실기기, NVIDIA 서버/DB/모델 실행, 외부 SDK 소비자 전수·배포 권리는 이번 결과에 포함되지 않는다. 코드와 테스트 통과를 이 범위의 인증으로 승계하지 않는다.

## 8. 변경 추적과 재실행

변경 전 archive/manifest와 전체 빌드·테스트 로그는 `/Users/ax/Library/Developer/FolioBuilds/Verification/ontology-20261108/`에 보존한다. 저장소의 [변경 목록](Verification/ontology-20261108/changes.json)과 원시 검색 평가, 과거 snapshot 인덱스를 함께 사용한다. 모든 원문·기존 index·사용자 전역 설정은 이번 feature 작업의 삭제 대상이 아니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --scratch-path /tmp/folio-tests --jobs 2 --enable-swift-testing --disable-xctest --no-parallel
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift test --package-path MacIntegration --scratch-path /tmp/folio-provider-tests --jobs 2 --enable-swift-testing --disable-xctest
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run --scratch-path /tmp/folio-search-build FolioSearchEvaluation
```

MacIntegration은 기존 계약에 따라 실제 SEMI SDK 경로를 요구한다. 필요하면 `FOLIO_SEMI_SDK_PATH`로 지정한다. 별도 checkout을 가짜 SDK로 대체하지 않는다.
