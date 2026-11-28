# 인용 근거와 검색 검증

새 자료 질문 경로의 `readKnowledgeEvidence(_:)`·`previewKnowledgePDF(_:)`는 Markdown 하위 구간과 PDF 페이지 인용을 검사한다. PDF는 현재 원본의 선택 페이지를 다시 추출해 대조하며 자체 cache hash만으로 인증하지 않는다. 기존 아래 Markdown 검증 API와 같은 권한·원문 우선 원칙을 유지한다. [구현과 제한](KNOWLEDGE_PLATFORM_IMPLEMENTATION.md).

2026-11-28의 Concept·Assertion 조회·저장도 같은 typed evidence 검사를 사용한다. 모델 없이 한·영 명칭과 원문에 인용된 주장·조건·값·단위·판본을 연결한다. 지식 기록 자체의 복제 인용은 독립 primary source로 재집계하지 않는다. 검색 중 Concept revision·채택 상태가 바뀌면 결과를 게시하지 않는다. 원문 현재성과 사용자 채택은 의미적 진실의 인증이 아니다. [온톨로지 구현](ONTOLOGY_IMPLEMENTATION_PLAN.md)

Mac SEMI의 새 경로는 다음과 같다. 호스트의 기존 읽기 접근 승인을 유지하며 실제 저장은 별도의 기존 mutation 승인을 사용한다.

| capability | 결과 |
| --- | --- |
| `wiki.knowledge_search` | 선택 자료의 PDF·Markdown 근거와 optional 개념 선택 정보 |
| `wiki.read_knowledge_evidence` | 반환된 typed evidence의 현재 원문 재검사와 문자열 |
| `wiki.concept` | 이미 아는 Concept ID의 직접 조회와 현재 근거 |
| `wiki.save_concept` | 정확한 Concept 생성·CAS 갱신 plan의 승인 후 실행 |
| `wiki.concept_operation` | 기존 저장 작업의 결과와 원문 현재성 관측 |
| `wiki.assertion` | 이미 아는 Assertion ID의 직접 조회, 연결된 항목과 현재 원문 근거 |
| `wiki.assertion_review` | 연결 Concept이 바뀐 주장을 현재 지식과 구분해 검토하며 원문 인용은 계속 재검사 |
| `wiki.assertions` | 선택적 개념·자료·단위·판본·본문 필터로 채택된 현재 주장 목록 조회 |
| `wiki.save_assertion` | 정확한 Assertion 생성·CAS 갱신 plan의 승인 후 실행 |
| `wiki.assertion_operation` | 저장 영수증·실제 파일 관측과 현재 근거 상태를 분리해 조회 |

`wiki.knowledge_search`는 생성 답변을 만들지 않는다. `wiki.concept` 역시 원문에 연결된 용어 기록의 조회다. 등록된 의미는 직접 읽고 필요한 자료를 모를 때 검색한다. 새 형식의 저장 인용은 기존 PDF·Markdown resolver의 version/role 분기를 사용하며 알 수 없는 형식은 일반 첨부 미리보기로 우회하지 않는다.

### Assertion 조회·저장 계약

| capability | 입력 JSON |
| --- | --- |
| `wiki.assertion` | `{ "assertion_id": "기존 주장 ID" }` |
| `wiki.assertion_review` | `{ "assertion_id": "검토할 주장 ID" }` |
| `wiki.assertions` | `{}` 또는 `concept_id`, `document_id`, `unit`, `edition`, `query`, `limit` 중 필요한 필드 |
| `wiki.save_assertion` | `{ "assertion": <Assertion>, "path": <선택 경로>, "expected_revision": <갱신 시 현재 revision>, "expected_concept_revisions": <검토 시 관측한 개념 revision map> }` |
| `wiki.assertion_operation` | `{ "operation_id": "저장 작업 UUID" }` |

`wiki.assertion`은 검색 없이 한 번의 호출로 `assertion`, `relativePath`, `revision`, `currentness`, `atomicSnapshot`을 반환한다. `wiki.assertions`는 기본 20개, 최대 100개를 반환한다. `unit`은 NFC 정규화 후 대소문자까지 일치해야 한다(`mW`와 `MW`는 다르다). `edition`은 대소문자를 구분하지 않는 판본 표기 일치, `query`는 대소문자를 구분하지 않는 저장 항목의 부분 문자열 조회다. 임베딩이나 답변 생성은 수행하지 않는다.

연결 Concept이 바뀌면 현재 조회는 그 주장을 거부한다. 이때 `wiki.assertion_review`로 같은 파일을 명시적으로 검토할 수 있다. 응답에는 `purpose: "review"`, `assertion`, `relativePath`, `revision`, `originalEvidenceCurrent`, `requiresConceptReview`, `conceptChanges`, `currentConceptRevisions`, `atomicSnapshot`이 있으며 현재 지식 조회의 `currentness` 필드는 제공하지 않는다. `conceptChanges`는 바뀌거나 사용할 수 없는 개념의 `conceptID`, `name`, `state`를 반환한다. 현재 채택된 개념을 검증할 수 있으면 `currentConcept`에 명칭·분야·별칭·근거를 함께 반환해 구체적으로 검토할 수 있게 한다. 사용할 수 없는 개념에는 이 값을 제공하지 않는다. 검토는 읽기 전용이며 연결 재설정이나 승인을 수행하지 않는다. 원문 인용 또는 주장 본문이 바뀐 경우에는 이 경로도 거부한다.

검토한 개념을 재연결할 때는 반환된 `currentConceptRevisions`를 선택형 `expected_concept_revisions`에 그대로 넣고 기존 경로·revision으로 `wiki.save_assertion` 계획을 준비한다. 검토 이후 Concept이 다시 바뀌면 계획 준비부터 거부하므로 아직 보지 않은 개념에 연결되지 않는다. 현재 내용을 다시 검토하고 새 계획을 별도로 승인해야 저장된다. 이 map은 기존 수동 저장 호출과의 호환성을 위해 선택형이지만, 검토에서 저장으로 이어지는 호출에서는 전달한다.

목록 응답의 `assertions`는 개별 조회와 같은 완전한 레코드다. `document_id`를 선택하면 모든 근거가 그 자료에 속한 주장만 반환하므로 다른 자료의 인용이 함께 노출되지 않는다. `complete`, `diagnostics`, `diagnosticsTruncated`로 조회 범위의 누락을 알린다. 레코드 수·읽기 실패·변경된 원문·응답 크기 제한으로 일부를 반환하지 못하면 `complete`는 거짓이다. 응답은 최대 128 KiB이며 원문 문자열이나 필드를 잘라 맞추지 않고 레코드 전체를 생략한다. 이 값은 응답 크기 제한이며 앱 메모리 기준이 아니다. `fingerprint`는 관측한 자료함 상태를 나타내고, 여러 파일의 같은 시점 스냅샷을 보장하지 않으므로 `atomicSnapshot`은 거짓이다.

저장할 `Assertion`의 wire ID는 `recordID`다. 필수 필드는 `recordID`, `statement`, `polarity`, `conceptIDs`, `conditions`, `evidence`, `state`이고 `value`, `unit`, `edition`은 선택 항목이다. 문장·조건·값·단위·판본은 `{ "text": "원문 표현", "citations": [{ "evidenceID": "반환된 근거 ID", "quote": "정확한 인용 문구" }], "origin": "quoted" }` 형식이다. 해석은 `origin: "interpretation"`으로 구분하되 값·단위·판본은 직접 인용만 허용한다. `evidence`의 각 항목은 `{ "evidence": <조회에서 반환된 완전한 typed evidence>, "role": "support" }` 형식이며 역할은 `support`, `context`, `refute` 중 하나다. 원문 경로나 범위를 임의로 재구성하지 않는다. 전체 필드·enum·제한의 정본은 `WikiKnowledgeAssertion.inputSchemaJSON`이며 `wiki.save_assertion` descriptor가 같은 schema를 사용한다. 알려지지 않은 저장 입력 필드는 무시하지 않고 거부한다.

생성은 `expected_revision` 없이, 갱신은 현재 `revision`을 넣어 한 번 준비한다. 사용자가 정확한 plan을 승인한 뒤 같은 plan을 실행한다. 저장 직전에 원문과 연결된 채택 Concept의 revision을 재검사한다. 원문·Concept이 달라지면 새 승인이 필요한 계획을 다시 준비한다. 응답을 잃었으면 같은 쓰기를 재생하지 않고 `wiki.assertion_operation`으로 `operation`, `sourceObserved`, `currentness`를 조회한다. 과거 `committed` 영수증은 나중에 원문이 바뀌어도 보존되며 현재 근거의 `changed`와 함께 표시될 수 있다.

자동 추출 provider는 호스트가 명시적으로 주입하는 선택 기능이다. 기본 모델·서버가 없으며 SEMI에 추출·생성 capability를 광고하지 않는다. 인용이 유효하고 같은 원문에 연결됐다는 검사는 의미적 함의나 사실의 참을 자동 인증하지 않는다.

### 기존 참조 검증

`FolioKnowledgeApple`의 `WikiWorkspace.verifyEvidence(_:)`는 최대 100개의 `WikiEvidenceReference`를 현재 원문에서 검사합니다. Mac의 SEMI adapter는 같은 기능을 읽기 전용 `wiki.verify_evidence`로 노출합니다.

입력은 `{ "references": [...] }`이며 참조는 기존 `wiki.search` 또는 `wiki.read`의 결과를 사용합니다. 결과의 `items`는 입력 순서와 중복을 유지합니다.

| 상태 | 의미 |
| --- | --- |
| `current` | 검사 시점에 workspace·문서·section·revision·범위·본문 해시가 일치함 |
| `changed` | 원문 revision 또는 참조 identity가 달라짐 |
| `invalid` | 잘못된 경로·범위·본문 digest 등 참조 검증 실패 |
| `unavailable` | 파일 삭제·접근 불가·미해결 충돌 등으로 해당 참조를 읽지 못함 |

`allCurrent`는 하나 이상의 참조가 있고 모두 `current`인 경우에만 참입니다. 빈 목록은 거짓입니다. stale 본문을 반환하지 않습니다. 호출 시작의 접근 admission 실패, 닫힌 workspace, 취소, 100개 초과 입력은 오류입니다. 여러 파일은 같은 시점의 원자적 스냅샷이 아니며 `atomicSnapshot`은 거짓입니다. 결과는 진실 여부나 질문 답변 가능성을 인증하지 않습니다.

검색의 `coverageComplete`는 스캔/현재 근거의 완전성입니다. 외부 후보의 품질이나 검색 recall을 뜻하지 않습니다. 앱/SDK의 전체 로컬 페이지 검색과 SEMI의 제한형 검색은 별도 계약입니다.

외부 후보 조회는 약 800ms 후 기다림을 끝내고 로컬 결과로 돌아갑니다. 스캔·FTS·원문 읽기를 포함한 전체 검색의 800ms 보장은 아닙니다. 취소에 응답하지 않는 provider는 종료할 때까지 서비스의 실행 슬롯 하나를 점유합니다. 그동안 다음 검색은 `systemSearchBusy`와 로컬 결과를 반환합니다. 이 정책은 강제 종료가 아니라 작업 수 제한입니다. provider가 종료하면 다시 검색할 수 있습니다.

합성 한·영 코퍼스 평가는 다음 명령으로 실행합니다. 임시 자료함을 만들고 지우며 개인 자료함·Spotlight·모델 서버는 사용하지 않습니다. 출력 JSON에는 경로별 후보, Recall@10, reciprocal rank, 지연과 범위를 기록합니다. 의미가 다른 표현의 누락을 포함하므로 모든 질의가 통과한다고 가정하지 않습니다.

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer \
  xcrun swift run --scratch-path /tmp/folio-search-build FolioSearchEvaluation
```

현재 실행의 결과와 한계는 재검토·구현 기록(로컬 보관: `docs/History/ReleaseCleanup-20261128/AUTO_ONTOLOGY_IMPLEMENTATION_REVIEW.md`)을 따릅니다.

별도의 한국어·영어 의미 검색·자동 관계 후보 검토는 [현재 구현 문서](SEMANTIC_SEARCH_IMPLEMENTATION.md)의 명시적 실험 기능으로 제공합니다. `wiki.verify_evidence`는 해당 후보의 참조도 검사할 수 있으며, 그 결과가 의미적 관계의 참임을 인증하지는 않습니다.
