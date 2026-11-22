# 근거 기반 지식 플랫폼 구현 계획

계획일: **2026-11-18, Asia/Seoul**. 리서치 기준일: **2026-11-17**.

이 문서는 [리서치](Research/folio-knowledge-platform-20261117.md)와 [재검토](Research/folio-knowledge-platform-review-20261117.md)를 실행 범위로 좁힌 계획이다. 모델·프로젝트 비교의 상세 출처는 두 문서와 [출처 기록](Research/folio-knowledge-platform-sources-20261117.json)에 보존한다. P0–P2의 최초 구현은 자동 테스트 29개와 iOS 앱 컴파일을 통과했다. 이후 실제 모델 입력, 원문 인용, 저장 직전 변경, 가져오기 재시도를 다시 검토하여 기능별 결함을 수정했다. 현재 판정과 이번 확인은 [세부 구현 재검토](KNOWLEDGE_PLATFORM_REVIEW.md)에 기록한다.

## 1. 제품의 우선순위

Folio의 본체는 책·문제집·논문 등 저장한 자료에서 필요한 정보를 찾고 그 근거를 확인하는 플랫폼이다. 우선 완성할 사용자 동작은 세 가지다.

1. **자료 수집:** 원본을 보존하고 자료함에 추가한다.
2. **근거 검색:** 질문과 관련된 실제 원문 인용을 찾는다.
3. **원문 확인:** 인용한 자료·페이지·구간을 바로 연다.

교육·문제 생성·문제풀이·학습 기록은 이 공통 기반을 사용하는 후속 기능이다. 모델 설정, 내부 ID, 처리 단계, 점수를 메인 화면의 중심에 두지 않는다. 자료 이름·내용·출처를 먼저 보여 주고, 기술 정보와 진단은 정보 화면에 둔다.

이번 core의 결과는 **찾은 근거**다. 인용문이 현재 자료와 일치한다는 검사와, 인용문이 객관적으로 참이거나 질문의 답이라는 판단은 별개다. 생성 모델이 없는 경로를 생성형 답변으로 표현하지 않는다.

## 2. 현재 구현 범위

| 범위 | 현재 코드에서 확인한 내용 | 상태·근거 |
| --- | --- | --- |
| 자료와 근거 타입 | 자료 범위·원본 경로·소유 문서·revision, Markdown UTF-8 범위, PDF page index·label·page text hash·영역을 구별한다. | 코드 추가: [WikiKnowledgeTypes](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeTypes.swift) |
| 자료 admission | 현재 읽을 수 있는 Markdown과 그 문서가 직접 연결한 `attachments/` PDF만 자료 목록에 넣는다. 다른 경로의 복제본·링크 제거·소유 문서 변경을 기존 근거로 우회할 수 없게 검사한다. | 코드 추가: [WikiKnowledgeSources](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeSources.swift) |
| PDF 추출 | admitted Data의 PDF 텍스트 layer를 페이지별로 읽고 원문 문자열과 cropBox 정규화 영역을 보존한다. 색인은 한 페이지씩 소비하여 모든 페이지의 줄 영역을 동시에 유지하지 않는다. 읽을 텍스트가 없는 페이지는 명시적으로 남긴다. | 구현·추출 fixture PASS: [WikiPDFExtraction](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiPDFExtraction.swift) |
| 지속 색인 | 자료별 블록·FTS·모델 식별자가 있는 벡터 필드를 SQLite 파생 상태에 저장한다. 자료 교체는 트랜잭션으로 수행하고 이전 벡터를 버린다. 전역 row cursor로 256개씩 읽을 수 있다. | 코드 추가: [WikiKnowledgeProjection](../Vendor/KnowledgeKit/Sources/KnowledgeKit/WikiKnowledgeProjection.swift) |
| 원문 재확인 | 근거를 읽거나 PDF를 열 때 현재 원본과 소유 문서의 연결을 다시 확인한다. 같은 자료의 인용을 묶어서 선택 페이지를 재추출한다. 원문 UTF-8, 범위·해시·영역을 검증한 인용만 표시한다. | `readKnowledgeEvidence(_:)`, `previewKnowledgePDF(_:)` |
| 앱·SDK 질의 진입점 | `prepareKnowledgeIndex()`·`knowledgeAnswer`·근거 읽기·PDF snapshot API가 연결되어 있다. 앱 기본 경로는 모델을 자동 로드하지 않으며, 뜻 검색은 명시적으로 선택한다. SDK의 기본 질의는 모델 없는 경로다. | 구현·컴파일·핵심 회귀 PASS: [WikiKnowledgeQuery](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeQuery.swift), [WikiSearchService](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiSearchService.swift), [FolioSession](../Sources/FolioCore/FolioSession.swift) |
| 사용자 화면 | 검색 결과, 자료함 More, 문서 More에서 질문 화면을 연다. 인용·출처·부분 누락을 표시하고 Markdown 구간 또는 PDF 페이지·영역을 연다. PDF viewer는 검증된 Data만 받는다. | 코드 연결: [FolioKnowledgeQueryView](../Sources/FolioUI/FolioKnowledgeQueryView.swift). 실제 화면 실행은 미검증 |
| PDF 직접 수집·근거 노트 저장 | 기존 첨부 import와 writer의 결과 관찰 경로를 재사용하여 자료 하나당 첨부 노트 하나를 만들고, 사용자가 선택한 근거 묶음을 별도 노트로 저장한다. | 구현·2개 앱 모델 회귀 PASS: [WikiAppModel+Imports](../Sources/FolioUI/WikiAppModel+Imports.swift), [WikiAppModel+Knowledge](../Sources/FolioUI/WikiAppModel+Knowledge.swift) |
| 핵심 회귀 fixture | PDF 원문·위조 인용·원본 변경·연결 제거·다른 자료함·닫힘, 512개 이후 블록·원자적 교체·범위 필터를 검사한다. 이전 시험은 29개였다. | 후속 변경의 20개 확인은 [세부 재검토](KNOWLEDGE_PLATFORM_REVIEW.md#이번-확인)에 기록 |

호출 경로는 `질문 화면 → WikiSearchService → 자료 질의 조정기 → 파생 색인 → 현재 WikiWorkspace 원문 재확인 → 인용 결과`다. 외부 SDK는 `FolioSession`이 admission과 작업 수명을 소유한다. 앱 화면은 요청 Task와 결과 표시를 소유하며, 원문 파일의 읽기·쓰기 권한을 직접 갖지 않는다.

전체 블록을 저장하고 페이지로 순회하는 것과, 모든 질문에 필요한 근거를 반드시 찾아내는 것은 다르다. 기존 Markdown 검색을 새 경로로 대체하거나 기존 의미 검색의 첫 512개 구간 계약을 몰래 바꾸지 않는다. 새 경로의 자료 범위·처리 batch·최종 결과 개수는 각각 구분한다.

## 3. P0–P2: 이번 core의 완료 순서

### P0. 자료·권한·인용 계약 고정

- 원본, 추출물, 색인, 인용, 사용자가 저장한 노트를 다른 상태로 다룬다.
- 자료 정체성에 자료함 scope, 소유 문서와 연결, 원본 revision을 포함한다. page label과 실제 0부터 시작하는 page index를 분리한다.
- Markdown 인용은 원본 UTF-8 범위를, PDF 인용은 페이지 문자열의 범위를 유지한다. 원문 정규화·번역·요약으로 인용을 바꾸지 않는다.
- 추출 producer와 모델 identity를 파생 상태에 포함한다. 자료 변경 시 이전 블록·벡터를 무효화한다.

**완료 기준:** 현재 원문에서 그대로 얻지 못한 인용, 다른 scope의 cache, 제거된 PDF 연결, 닫힌 자료함의 읽기를 거부한다. 원문 무결성을 사실성 배지로 사용하지 않는다.

### P1. 수집 → 전체 자료 색인 → 질문 → 원문 확인 연결

1. PDF 파일 선택을 기존 첨부 import로 보낸다. 원본 PDF를 유지하고 목록에는 첨부 노트 한 개를 표시한다. 페이지·블록을 개별 사용자 문서로 만들지 않는다.
2. 허용된 자료의 추출 가능한 블록을 지속 색인한다. 중단·실패·텍스트 없는 페이지를 coverage에 반영하며, 일부 cache를 전체 자료처럼 반환하지 않는다.
3. 기본 질문은 모델 없이 키워드·FTS 경로를 사용한다. 자료 한 개를 지정한 질의는 그 문서와 연결된 자료로 제한하고, 잘못된 범위를 전체 자료함 검색으로 확대하지 않는다.
4. 뜻 검색은 사용자 선택으로 실행한다. 전체 벡터를 한 번에 최대 256개씩 순회하고 중단 후 유효한 cache를 재사용한다. 키워드와 벡터 순위를 결합한 뒤 MiniLM에 최대 20개의 후보를 보낸다. 이 한도는 색인 대상의 개수와 별개다.
5. 최종 인용은 현재 원문에서 확인한 후 반환한다. 근거가 없으면 없다고 표시하고, 검색 누락을 모델의 사전 지식으로 채우지 않는다.
6. 출처를 누르면 Markdown 구간 또는 PDF의 실제 페이지를 연다. 정확한 영역을 얻지 못했으면 페이지 수준으로 열며 임의의 강조 영역을 만들지 않는다.

**완료 기준:** 가져온 텍스트 PDF에서 질문 → 원문 인용 → 해당 페이지 열기가 연결된다. 512개 뒤에 있는 고유 근거도 검색할 수 있다. 원본 변경·손상된 cache·누락 페이지·닫힘이 정상 결과와 구별된다.

### P2. 명시적 저장과 SDK 제공

- 사용자의 **노트로 저장**을 새 노트 작성 의도로 받는다. 저장 직전 같은 근거를 다시 읽고, 기존 prepare/execute/결과 관찰 경로로 저장한다.
- 저장한 노트에는 질문, 실제 인용, 출처와 위치를 남긴다. 원본 책·논문은 수정하지 않는다.
- 원문 revision·자료 scope·구간·PDF producer·검사 시점·`atomicSnapshot: false`는 frontmatter에 보존한다. `folio_knowledge_note: true`인 저장 노트는 목록·읽기·기존 Markdown 검색을 유지하되 새 기본 근거 corpus에서는 제외한다. 복제된 인용이 독립된 1차 출처로 다시 사용되는 중복을 막는다.
- 결과가 불확실하면 유지한 작업의 결과를 확인한다. 새 operation으로 같은 노트를 자동 생성하거나 PDF를 다시 복사하지 않는다.
- SDK에도 준비·질의·근거 읽기·PDF snapshot을 제공한다. 호스트는 권한 수명과 결과 표시를 소유한다. 공개 API의 상세 사용법은 [SwiftPM SDK](SWIFTPM_SDK.md)를 따른다.
- 메인 화면에는 핵심 세 동작을 유지한다. 모델 설정·진단·내부 식별자는 정보 경로에 둔다.

**완료 기준:** 단일 저장 요청이 기존 writer를 통과하며, 실패·미확정 결과에서도 원문과 복구 상태를 보존한다. 자료함을 전환하거나 닫은 뒤 늦게 도착한 검색·열기·저장 결과가 새 자료함에 게시되지 않는다.

## 4. 유지하는 원문·승인·복구 계약

| 경계 | 유지할 동작 |
| --- | --- |
| 원문 | PDF 원본과 Markdown 원본을 권위로 둔다. 추출·벡터·요약·질의 결과는 재생성 가능한 파생 상태다. 원문 digest와 cache 자체 digest를 같은 검증으로 취급하지 않는다. |
| 읽기 권한 | 기존 workspace admission, 경로 검사, 계정·파일 접근 상태를 따른다. 캐시된 reference가 새로운 원문 읽기 권한을 부여하지 않는다. PDF 화면에 root URL을 넘기지 않는다. |
| 승인 | 검색·원문 열기에 쓰기 승인을 추가하지 않는다. 실제 원문 변경·노트 생성은 사용자의 명시적 동작과 기존 writer 계획을 따른다. 모델·검색 조정기가 writer를 직접 우회하지 않는다. |
| 버전 | 준비된 계획의 경로·revision·내용을 실행 직전에 확인한다. 변경된 원문에 과거 계획을 자동으로 다시 적용하지 않는다. |
| 복구 | 기존 operation·intent·receipt를 유지한다. 미확정 결과는 같은 요청의 결과를 관찰하며, 새 요청의 성공으로 덮거나 자동 재실행하지 않는다. |
| 비동기 수명 | 닫기·자료함 변경·접근 상실 후 결과를 폐기한다. 모델 대기 뒤와 원문 효과·결과 게시 경계에서 admission·세션·generation·root·취소를 확인한다. 공유 질의 조정기는 실행 중 자원 해제를 보류하고, 해제 중 새 질의를 차단한다. |
| snapshot 의미 | 여러 자료를 순서대로 재확인한 결과는 전역 원자적 snapshot이 아니다. 자료별 revision 확인을 모든 파일이 같은 순간에 읽혔다는 보장으로 확대하지 않는다. |

## 5. 지원 범위와 한계

- **포맷:** 현재 원문 경로는 Markdown과 연결된 텍스트 PDF다. 책·논문·문제집은 자료 분류이며 별도의 해석 엔진을 뜻하지 않는다. EPUB·DOCX·웹 수집은 이번 완료 범위에 포함하지 않는다.
- **크기:** 이번 색인의 읽기 경계는 Markdown 개별 256 KiB, PDF 개별 50 MiB다. 일반 문서 writer의 기존 한도는 변경하지 않았다. 새 근거 노트에만 frontmatter 64 KiB·전체 256 KiB를 적용한다. 큰 책 지원은 한도 숫자만 늘리는 변경으로 처리하지 않고 streaming·페이지 처리·취소 가능한 작업으로 별도 구현한다. 자료 하나당 최대 100,000블록과 질의·payload 한도도 존재한다.
- **PDF:** PDFKit 텍스트 layer는 화면의 읽기 순서, 다단 문서, 표·수식·각주 구조를 완전히 복원하지 않는다. 이미지·빈 페이지는 읽을 수 없는 페이지로 남으며 OCR은 수행하지 않는다. 암호화 PDF는 현재 추출 대상에서 거부한다.
- **원문 위치:** 영역은 cropBox 기준 정규화 좌표다. 줄 영역을 찾을 수 없으면 페이지 인용만 제공한다. 눈에 보이는 인쇄 쪽수와 PDF page index가 다를 수 있어 둘을 구별한다.
- **정확성:** 현재 결과는 원문 인용이며, 인용의 답변 적합성·논문의 신뢰성·수식의 타당성·최신성·상충 여부를 일반적으로 인증하지 않는다.
- **검색 품질:** 한국어·영어 뜻 검색은 기존 E5·관련성 provider를 사용한다. 새 PDF corpus의 한국어 실측이나 새 모델 우위를 확인했다고 선언하지 않는다. 무관한 질의에는 근거 없음으로 끝낼 수 있어야 한다.
- **규모:** 전체 블록 색인과 batch 순회는 무제한 자료 크기·일정한 메모리·지연을 보장하지 않는다. 현재 PDF 추출은 원본 Data와 추출 문자열을 사용한다. 장시간·대용량 성능 수치는 이번 실행 증거가 없으면 보고하지 않는다.

## 6. 후속 계획과 도입 조건

P0–P2의 현재 흐름을 먼저 유지한다. 아래 단계는 독립적으로 도입할 수 있게 입력, 변경할 경계, 확인할 실패를 정한다. 앱의 기본 동작은 자료 수집, 근거 찾기, 원문 확인이다.

| 단계 | 도입 조건 | 개발 산출물 | 완료 기준 |
| --- | --- | --- | --- |
| P2.1b: 저장 작업의 재실행 후 확인 | 종료 직전 실패로 어떤 근거 노트가 저장됐는지 사용자가 기존 목록과 관리 화면에서 판단하기 어렵다. | 계정별 기존 복구 범위에 제출 ID와 사용자 요청을 연결한다. 재실행 시 writer의 intent·receipt를 읽거나 현재 원문을 관측한다. | 원문 게시 직전·직후에 종료한 각 사례를 한 번 확인한다. 결과가 불확실하면 기존 작업을 관측하고, 새 노트 작성은 사용자가 의도적으로 요청해야 한다. |
| P2.2: 큰 자료함 증분 갱신 | 같은 자료에서 준비와 게시의 전체 인벤토리 비교가 실제 지연의 주요 원인으로 나타난다. | 같은 파일 revision을 재사용할 수 있는 변경 감지, 자료별 작업 중단·재개, 선택 페이지 추출과 벡터 기록을 분리한다. 지원 크기 안의 대표 PDF를 섞은 시작/재검색 사례를 측정한다. | 변경·삭제·충돌 뒤 stale 인용을 반환하지 않는다. 한 자료를 바꾼 후 여전히 관련 없는 모든 PDF의 추출과 벡터화가 일어나는지 확인한다. 기존 512개 이후 근거는 계속 찾을 수 있다. 필요할 때만 변경 전후 지연·메모리를 한 번씩 비교한다. |
| P3: OCR·문서 구조 | 사용자 자료의 이미지 페이지 또는 읽기 순서 누락이 실제 근거 검색을 막는다. | `ExtractionProducer` 역할, 버전이 고정된 producer identity, 페이지 원본 hash, 텍스트·영역·추출 상태, 취소·재개 작업, 원본 이미지와 대조하는 검토 경로. native OCR과 외부 parser는 별도 adapter로 둔다. | 이미지 원본을 그대로 보존하고 OCR 산출물을 `ocrUnreviewed`로 표시한다. 교정 전후와 source anchor를 추적한다. 읽지 못한 표·수식을 임의 텍스트로 확정하지 않는다. |
| P4a: 검색 provider capability | 기존 한국어·영어 기준선에서 실패한 질문을 확보하고 실패가 추출·범위·필터 문제가 아닌 표현 검색 문제임을 확인한다. | 텍스트/이미지, 단일/다중 벡터, 길이·dtype·pooling·정규화·query/document 지시를 명시하는 capability와 cache identity. 재현 가능한 artifact manifest와 작은 비교 corpus. | 미지원 입력을 명시적으로 거부한다. 차원·비유한 값·토큰 처리·모델 revision이 검증되고 기존 벡터를 새 모델 벡터로 오인하지 않는다. |
| P4b: EmbeddingGemma 2 등 새 단일 벡터·다중 모달 후보 | P4a가 준비되고, 해결할 질의 유형과 배포 runtime·artifact·이용 조건이 확정된다. 이미지 입력은 페이지 이미지 producer·원본 좌표 대응도 필요하다. | 기존 E5와 독립된 adapter, tokenizer/processor, query/document 입력 계약, dtype 경로, 모델별 변환·캐시 무효화, 취소·자원 해제. | 공식 카드의 fp16 activation 위험을 피한 수치 경로에서 finite 출력과 참조 출력 대응을 확인한다. 같은 한국어·영어 corpus에서 기존 필수 근거 누락·무관 결과가 늘지 않고 목표 실패 사례를 개선한다. Folio 실행 결과를 발표 수치와 구별한다. |
| P4c: KURE-v2·late interaction·다중 벡터 | 단일 벡터+관련성 검사로 남는 한국어 세밀 대응의 실패를 확보한다. 저장량·질의 지연·배포 지원을 포함한 이득이 확인된다. | token 벡터와 mask를 다루는 별도 provider, MaxSim 등 해당 모델 점수 계약, source별 vector 저장·압축·순회, 모델별 index revision. | 단일 `[Float]` 반환으로 가장하지 않는다. 모델 참조 구현과 점수를 대조하고 긴 입력·token 수·빈 입력을 처리한다. 전체 index의 벡터 원소·보조 index·작업 메모리와 지연을 함께 측정한다. |
| P5: 생성형 설명·주장별 근거 | P0–P2의 실제 근거 묶음과 source 재확인이 완성된다. 선택한 생성 backend의 데이터 전송·이용 조건과 취소 수명이 정해진다. | 생성 provider, 구조화 `claim → evidence IDs` 응답, 원문/종합/계산/해석 구별, 인용 허용 목록 검사, 미지원·상충 상태, 저장 전 writer 연결. | 실제 읽은 근거만 공급한다. 존재하지 않는 citation·쪽수·DOI를 거부한다. 출처가 있어도 주장을 뒷받침하지 않으면 유보한다. 수치·단위·부정·적용 조건·판본을 바꾼 회귀를 잡는다. 자기검토 반복을 독립 검증으로 표시하지 않는다. |
| P6: 자료 간 비교·지식 상태 | 여러 판본·연구를 하나의 결론으로 합치는 사용 사례가 있고, P5의 주장별 근거가 존재한다. | 판본·대상·방법·시점·정정·철회 메타데이터, 지지/제한/상충 근거 관계, 갱신 시 관련 산출물 무효화. | 최신 날짜·높은 유사도만으로 참을 선택하지 않는다. 서로 다른 전제와 원저자/재인용을 구분하고 상충·미확인을 그대로 전달한다. |
| P7: 교육·문제풀이 소비 기능 | 자료 검색·인용·설명이 해당 분야에서 유용하고 근거 범위를 정의할 수 있다. | 설명·문항·풀이 adapter, 과목별 계산·형식 검증기, 사용자가 선택하는 학습 흐름. | 모든 설명·정답의 원문 근거와 생성물 구분을 유지한다. 공통 자료 수집·검색·원문 확인 화면을 학습 관리 화면으로 바꾸지 않는다. |

P2.1a의 PDF 링크는 저장 노트 revision, 출처 기록, 현재 PDF와 해당 페이지를 확인한 뒤 미리보기로 연결한다. 같은 페이지를 가리키는 여러 인용은 페이지 수준으로 연다. iOS 앱이 관리하는 로컬 자료함에서 새로 만드는 인용은 설치 범위와 자료함 ID를 사용해 같은 앱의 저장 경로가 이동한 뒤에도 정확한 원본과 위치를 확인한다. 기존 경로 기반 인용은 기록한 경로를 확인할 수 있을 때 호환되며, 검증에 실패하면 재검색을 안내한다. [현재 화면과 진입점](FOLIO_REDESIGN.md) · [시뮬레이터 기록](Design/EvidenceFlow-20261122/SIMULATOR_REVIEW.md).

확인된 대표 PDF가 텍스트 추출에 실패하면 P3, 원문은 읽히지만 질문의 표현 때문에 놓치면 P4a부터 진행한다. 테스트 자료에는 원본 판본, 질문, 기대 페이지·행, 반례를 함께 기록한다. 같은 질문에서 P4b는 단일 벡터·멀티모달 적합성, P4c는 토큰별 비교의 개선 폭을 각각 본다. 충분한 근거 검색 품질이 확인되면 P5를 시작할 수 있다.

모델 채택 전에는 같은 자료·질문·정답 anchor에서 근거 검색 recall@k·순위, 무관 질의 오반환, 한국어/영어 실패 사례와 처리 비용을 비교한다. 대상 하드웨어·artifact·질의 길이·자료량·메모리 지표·지연 허용 범위를 실행 전에 고정한다. 통과시키기 위해 실행 후 지표 정의나 한도를 바꾸지 않는다. 현재 작업에서 실기기를 사용하거나 장시간 반복 평가를 추가하지 않는다.

모델·라이선스의 세부 수치는 2026-11-17 리서치의 스냅샷이다. 실제 adapter 도입 시 고정할 artifact·config·모델 카드·이용 조건을 다시 확인한다. 예를 들어 [EmbeddingGemma 2](https://ai.google.dev/gemma/docs/embeddinggemma/model_card_2)의 수치 경로와 [KURE-v2](https://huggingface.co/nlpai-lab/KURE-v2)의 multi-vector 계약을 현재 E5 adapter와 같다고 가정하지 않는다. Jina 후보도 이용 조건을 확인하기 전 기본 배포 모델로 채택하지 않는다.

## 7. 최초 구현 검증 기록

이번 구현은 실기기·앱·시뮬레이터 실행 없이 검증한다. 반복 대규모 평가나 화면 캡처를 완료 조건에 추가하지 않는다. 코드 변경이 직접 건드린 핵심 실패에 한정한다.

| 검사 | 필요한 증거 | 2026-11-18 최종 기록 |
| --- | --- | --- |
| 빌드 연결 | 앱 UI와 SDK가 새 타입·질의·저장 API를 실제로 참조하여 컴파일되는지 확인 | macOS SwiftPM의 앱 UI·SDK·테스트 컴파일 PASS. iOS generic destination 앱 빌드 **BUILD SUCCEEDED**, 서명·설치·실행 없음 |
| 원문 인용 | PDF page hash·UTF-8 범위·인용 문자열 대조, 위조 cache·원본 변경·연결 제거 거부 | [KnowledgePlatformEvidenceTests](../Tests/FolioKnowledgeTests/KnowledgePlatformEvidenceTests.swift) 4개 PASS. CRLF·한국어·PDF 실제 질의·무관 키워드·파생 노트 제외 포함 |
| 전체 블록·색인 복구 | 600블록의 전역 cursor, 512개 이후 고유 근거, 자료 교체 rollback·기존 vector 제거·범위 필터 | [KnowledgeProjectionTests](../Tests/FolioKnowledgeTests/KnowledgeProjectionTests.swift) 3개, [KnowledgeQueryTests](../Tests/FolioKnowledgeTests/KnowledgeQueryTests.swift) 3개 PASS. fake provider로 600개 이상 구간 방문·벡터 재사용·nil/token-budget 배제·동시 실행·해제 보류·원문 변경 검사 |
| PDF 추출 | 원문 문자열·쪽수·정규화 좌표·추출 불가 페이지·암호화/손상 입력 | [PDFExtractionTests](../Tests/FolioKnowledgeTests/PDFExtractionTests.swift) 3개 PASS |
| 세션 권한 | SDK 자료함 닫힘·다른 scope·접근 상실의 결과 차단 | [FolioKnowledgeSessionTests](../Tests/FolioCoreTests/FolioKnowledgeSessionTests.swift) 1개 PASS. 다른 자료함은 위 원문 인용 fixture에서도 거부 |
| 수집·저장 계약 | PDF import와 근거 노트가 기존 writer를 사용하며, 미확정 결과는 같은 operation을 관찰 | [KnowledgeNoteTests](../Tests/FolioUITests/KnowledgeNoteTests.swift) 2개 PASS. 특수문자 PDF, 표시 실패 후 원본 선택 파일 없이 완료 receipt 재관측, 저장 metadata·stale 거부·중복 방지 포함 |
| 기존 계약 회귀 | 검색 후보 수명·현재 근거·승인 계획·원문 CAS·초안·불확실한 저장 복구 유지 | 기존 [KnowledgeEvidenceTests](../Tests/FolioKnowledgeTests/KnowledgeEvidenceTests.swift) 8개, FolioSessionProtectionTests 4개, reviewedUncertainSave 1개 PASS |
| 화면 수명 | 준비 전 질의 차단, 닫기 취소, 저장 중 닫기 방지, generation/root 변경 시 인용·PDF 숨김 | 정적 검토. 실제 화면 실행·시각 판정은 미실시 |

선택한 **29개 모두 PASS**: 원문·검색 모듈 21개, SDK/복구 6개, 앱 모델 수집·저장 2개. Swift Testing 실행은 약 3.8초였으며 컴파일 시간은 별도다. 전체 suite·실모델 대규모 평가를 반복 실행하지 않았다. 통합 중 테스트 경로 충돌은 기존 테스트 원본을 정확히 복원하고 새 PDF 테스트를 별도 파일로 분리하여 해결했다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcrun swift test \
  --scratch-path /Users/ax/Library/Developer/FolioBuilds/Tests/Folio --jobs 2 --no-parallel \
  --filter 'KnowledgePlatformEvidenceTests|KnowledgeEvidenceTests|KnowledgeProjectionTests|KnowledgeQueryTests|PDFExtractionTests|FolioKnowledgeSessionTests|KnowledgeNoteTests|FolioSessionProtectionTests|reviewedUncertainSave'

DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild \
  -project Folio.xcodeproj -scheme FolioIOS -configuration Debug \
  -destination 'generic/platform=iOS' \
  -derivedDataPath /Users/ax/Library/Developer/FolioBuilds/KnowledgeIOS-20261118 \
  -jobs 2 CODE_SIGNING_ALLOWED=NO build
```

빌드의 기존 ZIPFoundation watchOS 선언·기존 테스트 캡처 경고, iOS 방향 설정·App Intents metadata 경고는 이번 기능의 실패가 아니다. 대용량·장시간·실기기 성능, 새 모델의 한국어 우위, 생성형 사실성은 이번 검사로 확인한 것처럼 기록하지 않는다. 현재 결과는 텍스트 자료의 근거 검색이며, 화면 실행·스캔 OCR·표/수식 해석·생성형 설명은 검증 완료 범위에 포함하지 않는다.
