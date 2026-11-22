# 지식 플랫폼 구현 재검토 · 2026-11-18

이전 대화에서 정한 제품 흐름은 **자료 추가 → 근거 찾기 → 원문 확인**이다. 검토 범위는 [이전 구현 계획](KNOWLEDGE_PLATFORM_IMPLEMENTATION.md)의 P0–P2, [리서치 재검토](Research/folio-knowledge-platform-review-20261117.md), 앞선 29개 회귀 기록이다. 그 통과 기록은 당시의 시험 범위다. 특히 대체 모델을 사용한 검색 시험만으로 실제 모델 호출의 입력 계약까지 확인할 수 없다는 점을 이번 코드 대조에서 발견했다.

## P0. 원본과 인용의 경계

| 검토 단위 | 이전 구현에서 확인한 점 | 개선과 판정 |
| --- | --- | --- |
| 자료 식별 | 원문 경로, 자료함 ID, 소유 문서와 원본 revision을 묶었다. 앱의 파생 경로는 자료함 UUID를 기준으로 공유했다. | 앱 iCloud 열기에 기존 복구 계정 ID를 연결했다. 같은 root와 UUID라도 지식 근거의 scope가 달라진다. 기존 복구 파일과 영수증 경로는 유지한다. |
| 원문 권한 | SDK는 읽기 전후 권한을 검사했다. 앱은 화면 세션에서 계정을 검사했으나 원문 actor에는 SDK의 실시간 비교가 없었다. | SDK가 쓰던 보안 코딩 기반의 계정 비교를 앱의 원문 권한 검사에도 연결했다. 계정 토큰은 현재 값과 개체 동등성을 비교하며 아카이브 바이트를 계정 ID로 사용하지 않는다. |
| 유효한 자료 | 검색은 현재 Markdown과 그 문서에서 연결된 PDF만 사용했다. 직접 원문 확인 API는 파생 근거 노트 표시를 확인하지 않았다. | 현재 원문을 다시 해석하는 단계에도 파생 노트 제외를 적용했다. 원본 링크 삭제, 변경, 범위·scope 불일치 시 이전 근거는 거부한다. |
| Markdown 인용 | 원문 revision과 바이트 범위를 검증했지만 인용 문자열의 최종 비교에 Swift의 유니코드 정준 동등성을 사용했다. 개행까지 포함된 인용의 끝 줄도 한 줄 밀렸다. | UTF-8을 직접 비교하고 CR/LF/CRLF와 범위 끝 줄을 구분한다. 원래 인용 ID를 재사용한 정준 동등 문자열도 바이트가 다르면 거부한다. |
| PDF 인용 | 원본 PDF의 해시와 다시 추출한 페이지 텍스트를 검증했다. 줄을 찾을 때 문자 정규화와 부분 겹침에 의존했다. | 줄 텍스트를 페이지의 정확한 바이트 위치에 대응시키고, 인용에 완전히 들어오는 줄만 강조한다. 위치를 확정할 수 없는 경우에는 페이지로 이동한다. |
| 분량과 비용 | 같은 페이지의 digest를 청크마다 계산하고, 최종 인용 여러 개를 개별 검증했다. | 페이지 digest를 재사용한다. 같은 소유 자료는 묶음으로 읽고 선택 페이지를 한 번씩 추출한다. PDF를 새로 색인할 때 자료 하나의 추출 블록은 메모리에 남는다. |
| 검사 시점 | 여러 파일의 검사는 순차적으로 진행한다. | 결과는 각 자료의 revision과 검사 시점을 갖는다. 동시 편집 환경의 전역 원자적 snapshot이나 PDF에 적힌 주장의 사실성을 보장하지 않는다. |

코드 근거는 [자료 인벤토리와 인용 검증](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeSources.swift), [PDF 추출](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiPDFExtraction.swift), [WorkspaceAccess](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WorkspaceAccess.swift), [계정 권한 검사](../Sources/FolioCore/FolioSourceAdmission.swift)다.

## P1. 색인부터 원문 열기까지

| 검토 단위 | 이전 구현에서 확인한 점 | 개선과 판정 |
| --- | --- | --- |
| PDF 추가 | 기존 첨부 가져오기로 원본을 복사하고 연결 노트 하나를 만들었다. | 기존 writer를 사용한다. 원본과 별도의 노트가 목록에 나타나며 추출 페이지는 내부 색인에 둔다. 복사 결과를 확인하는 동안 추가 버튼은 결과 확인으로 표시한다. |
| 색인 교체 | SQLite에서 자료·블록·FTS를 원자적으로 교체하고 이전 벡터를 무효화했다. | 그대로 사용한다. 실제로 제거할 기존 자료가 있을 때만 정리하고, 검색 중 파생 저장소가 재설정되면 해당 결과를 폐기한다. |
| 전체 범위 | 원문 FTS에 512개 블록 한도가 없으며 선택형 벡터 처리도 전체 블록을 256개씩 순회했다. | 유지한다. 256은 한 번에 읽는 양이며 20은 관련성 모델에 보내는 후보 수다. 최초 뜻 검색의 전체 벡터 계산 비용은 남는다. |
| 기본 질의 | 모델 없이 OR 접두어 검색을 실행했다. 짧은 질문 기능어 하나만으로 무관한 자료가 나올 수 있었다. | 복수 단어 질문에서 흔한 질문·기능어를 제외한다. 단일 키워드는 검색 입력으로 유지한다. 결과는 키워드가 겹치는 원문이며 형태소 분석과 의미 판정은 별도 기능이다. |
| 뜻 검색 두 번째 단계 | FTS 최대 60개와 벡터 최대 20개를 합쳐 관련성 모델에 전달했다. 실제 MiniLM은 20개 초과 입력을 거부한다. | 두 후보 순위를 결합하고 동일 원본 위치를 정리한 뒤, 모델 계약에 맞춰 최대 20개의 후보를 한 번 전달한다. 모델과 두 검색 경로가 하나의 제한값을 사용한다. |
| 약한 후보·근거 없음 | 낮은 점수와 미검사 후보를 제외했다. | 기존 관련성 기준과 빈 결과 동작을 유지한다. 후보가 20개를 넘어도 요청은 실패하지 않으며 무검사 후보를 자동 반환하지 않는다. |
| 문서 범위 | 해당 문서와 그 PDF로 결과를 좁혔지만 자료·블록·읽지 못한 페이지 개수는 전체 기준이었다. | 선택 범위 내 색인 자료·구간·읽지 못한 페이지를 센다. 인벤토리 단계에서 소유 자료를 확인하지 못한 전역 진단은 보수적으로 공유한다. |
| 질의 준비 | 질문 창을 열 때 인벤토리를 만들고 첫 질문에서 다시 같은 준비를 실행했다. | 화면에서는 세션만 연결한다. 첫 질문 시 준비하고 인벤토리는 준비 시작과 결과 게시 전 검사한다. 오래 걸리는 모델 호출 뒤에는 접근 권한을 확인한다. |
| 화면 권한 | 자료함 세대가 바뀌면 결과·PDF를 지웠다. Markdown 원문 열기는 내부 읽기 뒤 취소를 다시 확인하지 않고 탐색을 바꿀 수 있었다. | 탐색 명령이 아직 유효하고 권한이 열려 있을 때만 선택한다. 검증한 revision이 화면 목록에 없으면 갱신한 뒤 검증한다. 질문 편집과 재검색 시 이전 결과의 범위 안내를 지운다. |
| 원본 위치 | Markdown은 섹션, PDF는 실제 페이지와 가능한 줄 영역을 열었다. | 질문 결과에서 같은 동작을 유지한다. Markdown 인용의 행 표시는 정확한 바이트 범위이고 읽기 화면의 이동 단위는 섹션이다. |
| 부분 자료 | 빈 페이지·스캔·추출 오류를 진단했다. | 첫 질문에 한 번에 준비하고 현재 결과의 경고만 표시한다. 뜻 검색의 부분 처리 정보는 뜻 검색을 실행했을 때만 표시한다. |

코드 근거는 [질의 조정과 순위 결합](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeQuery.swift), [SQLite 블록 검색](../Vendor/KnowledgeKit/Sources/KnowledgeKit/WikiKnowledgeProjection.swift), [모델 입력 제한](../Sources/FolioSemanticModels/MultilingualMiniLMRelevance.swift), [질문 화면](../Sources/FolioUI/FolioKnowledgeQueryView.swift), [탐색 명령](../Sources/FolioUI/WikiAppModel+Navigation.swift)이다.

## P2. 승인·저장·복구

| 검토 단위 | 이전 구현에서 확인한 점 | 개선과 판정 |
| --- | --- | --- |
| 쓰기 의도 | 원문 읽기는 읽기 작업이고 사용자가 노트 저장을 선택할 때 기존 writer를 호출했다. | 동일하다. 작성 대상은 새 근거 노트이며 원본 PDF와 Markdown은 기록의 출처로 남는다. |
| 준비와 실행 사이 변경 | 앱에서 재검사한 뒤 writer가 다시 자료함을 갱신했다. 그 사이에 PDF만 바뀌면 Markdown snapshot revision이 같을 수 있었다. | 같은 writer에서 갱신이 끝난 뒤 새 intent를 기록하기 직전에 근거를 묶어서 재확인한다. 기존 영수증을 관측하는 경우에는 당시 커밋 결과를 반환한다. |
| 출처 기록 | 질문·실제 인용·자료명·페이지와 원문 revision을 저장했다. | YAML 줄바꿈으로 해석되는 유니코드 문자를 JSON 이스케이프로 보존한다. 본문은 질문·인용·출처를 보여 주고 기술 식별자는 출처 메타데이터에 둔다. |
| PDF 복사 직후 오류 | 첫 복사 요청이 원본 게시 후 오류를 반환하면 호출자가 기록 ID를 얻지 못해 재시도가 새 복사를 만들 수 있었다. | 호출자가 같은 ID를 먼저 가지고 재시도한다. 원본 바이트가 기록과 맞으면 그 복사를 이어서 사용한다. 게시 여부가 불확실한 기록을 새 작업으로 자동 재실행하지 않는다. |
| 연결 저장 확인 | 연결 노트가 이미 저장됐어도 표시 실패가 나면 재시도할 수 있었다. 완료한 기록까지 미완료 건수 제한에 포함했다. | 선택한 첨부 기록의 scope·현재 원본 해시와 관측된 writer 영수증을 확인한다. 2,048건 제한은 미완료 첨부에만 적용한다. 자료함을 열 때 완료 기록을 순회하는 비용은 남는다. |
| 재시도 범위 | 일부 UI 재시도 키는 루트와 UUID만 사용했다. | 기존 복구 파일의 계정별 범위를 키에 포함한다. 자료함과 계정을 바꾼 뒤 이전 UI 작업을 그 범위에서 관측할 수 없다. |
| 프로세스 재실행 | 원본, intent, 영수증, 첨부 기록은 보존된다. 질문 창의 노트 저장 버튼과 operation의 연결은 메모리에 있다. | 신설 복구 저장소 없이 기존 계약을 유지했다. 재실행 뒤에는 이미 만든 노트와 기존 첨부 복구 경로를 사용한다. 질문별 저장 작업 연결을 재실행 후 복원하는 기능은 P2.1이다. |
| 저장 노트에서 출처 열기 | 본문 링크와 페이지 번호가 기록된다. 일반 PDF 첨부 미리보기는 링크의 페이지 조각을 사용하지 않는다. | 질문 화면에서 정확한 페이지를 연다. 저장한 노트에서 동일한 위치로 다시 여는 기능은 P2.1의 별도 인수 기준이다. |
| SDK | 기본 질의·원문 확인·PDF snapshot과 admission을 제공했다. | SDK의 기본 경로는 모델 없이 동작한다. 조회 범위와 최신 원문 검증에는 앱과 같은 조정기를 사용한다. |

코드 근거는 [근거 노트](../Sources/FolioUI/WikiAppModel+Knowledge.swift), [파일 가져오기](../Sources/FolioUI/FolioFileIntake.swift), [첨부 기록](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiAttachmentImport.swift), [기존 원문 writer](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiWorkspace.swift)다.

## 후속 순서

실제 작업을 여는 기준과 해당 단계에서 필요한 최소 확인은 [갱신한 개발 계획](KNOWLEDGE_PLATFORM_IMPLEMENTATION.md#6-후속-계획과-도입-조건)에 있다. 먼저 현재 흐름에서 근거를 다시 쓰는 사람의 출처 복원과 큰 자료함의 갱신 비용을 다룬다. 그 다음 추출이 실패한 대표 자료에 OCR을 추가하거나, 근거는 있는데 질의가 찾지 못하는 경우에 검색 모델을 비교한다. 자료만으로 적절한 답변을 만드는 일은 원문을 다시 확인할 수 있는 검색 결과 위에서 주장별로 도입한다.

## 이번 확인

이번 변경에서 **선택한 자동 테스트 20개와 iOS 앱 컴파일이 통과**했다. 핵심 검색·원문 검증 15개, SDK 권한 1개, 가져오기·저장 4개다. 처음 시험에서 새 자료함에 복사 기록 폴더가 없을 때 PDF 가져오기가 실패했다. 확인된 파일 없음과 접근 오류를 구분한 뒤 영향을 받은 네 건만 다시 실행해 통과했다. macOS는 SwiftPM 테스트 빌드에서 앱 UI와 SDK를 컴파일했고, iOS는 generic destination으로 서명 없이 빌드했다.

| 실행 범위 | 확인한 실패 |
| --- | --- |
| [KnowledgeQueryTests](../Tests/FolioKnowledgeTests/KnowledgeQueryTests.swift), [KnowledgeProjectionTests](../Tests/FolioKnowledgeTests/KnowledgeProjectionTests.swift) | 후보 20개 초과 재현, 선택 문서 범위, 512개 이후 구간, 무관 질문어, 미검사 후보, 색인 교체 및 위조 인용. 모델 계약은 20개 초과를 거부하는 대체 모델로 확인했다. |
| [KnowledgePlatformEvidenceTests](../Tests/FolioKnowledgeTests/KnowledgePlatformEvidenceTests.swift), [PDFExtractionTests](../Tests/FolioKnowledgeTests/PDFExtractionTests.swift), [FolioKnowledgeSessionTests](../Tests/FolioCoreTests/FolioKnowledgeSessionTests.swift) | 정준 동등 인용 변조, CRLF 행 범위, PDF 위치와 텍스트, 원문 변경, 동일 root·UUID의 다른 계정 scope, 닫힘과 접근 철회. |
| [KnowledgeNoteTests](../Tests/FolioUITests/KnowledgeNoteTests.swift), [SourceRecoveryTests](../Tests/FolioUITests/SourceRecoveryTests.swift) | 실제 PDF 수집, 기존 복사와 저장 영수증 재관측, 준비 이후 PDF 변경으로 새 노트 및 intent 거부, Markdown 가져오기 재시도. |

실기기·앱·시뮬레이터는 사용하지 않았다. 실제 PDF corpus에서 한국어 모델 순위가 얼마나 좋아졌는지, 장시간 처리 성능이 어느 정도인지는 별도 측정 대상이다. 기존 producer로 저장해 둔 검색 참조가 새 줄·페이지 표현과 맞지 않으면 원문을 다시 검색해야 한다. 저장한 원본과 노트 파일은 해당 색인 재구성의 대상이 아니다.
