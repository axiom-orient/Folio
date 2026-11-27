# 한국어·영어 의미 검색과 관계 제안

2026-11-08. 현재 구현·검증·제한·후속 계획의 정본이다. 이전 영어 전용 P4 문서를 대체한다. **일반 검색은 유지하고, 의미 검색은 사용자가 실행하는 실험 기능으로 제공한다.** 원문 writer·별도 승인·intent/receipt·초안 복구 경계는 유지했다. 자원 최적화와 지표 버전 변경은 [메모리 원인 분석·측정 기준](SEMANTIC_MEMORY_INVESTIGATION.md)을 따른다.

## 1. 계획과 실행 순서

| 단계 | 작업 | 판정 |
| --- | --- | --- |
| P0 | 수정 전 manifest·원문 복사본·이전 평가 보존. 오탐 재현 | 완료 |
| P1 | 고정된 다국어 모델, 실제 토크나이저, 한·영 평가 | 완료 |
| P2 | 추가 질의로 기존 cutoff의 실패 재발견. 공동 관련성 검사 도입 | 구현·회귀 통과 |
| P3 | source epoch·캐시·제안 정책 migration·정확한 승인·receipt 복구 | 회귀 통과 |
| P4 | 실제 Mac·iPhone의 검색·기각·원문 이동·취소·승인·재실행 | 최종 manifest 참조 |
| P5 | 모델 수명·중복 코드·영어 전용 경로·구 문서 정리, 해시·문서 검사 | 최종 manifest 참조 |

## 2. 원인 분석과 반증

기존 `NLEmbedding` 영어 일반 문장 모델은 코사인 0.25 이상을 후보로 반환했다. 관련 자료가 없어도 top-k에는 가장 가까운 문서가 있다. 이전 부정 질의 2개 중 1개에서 후보가 나왔다. 같은 질의의 3회 반복을 독립 표본 6개로 세지 않았다. [이전 원본](Verification/p4-20261108/semantic-evaluation.json).

첫 개선은 다국어 E5-small, 실제 원문 구간, 코사인 0.83와 최고점 차이 0.015였다. 46개 질의는 통과했지만, 새 36개 질의에서 **세면대 수리 → 커피**, **양자 오류 보정 → 작업 취소**가 나왔다. 이 실패를 보존했다. [단일 모델의 추가 audit](Verification/semantic-bilingual-20261108/single-stage-additional-audit.json).

확인한 원인을 분리했다.

- 한국어를 거부하던 영어 전용 경로와 비라틴 스크립트 차단을 제거했다. FTS용 제목·heading 반복 표현 대신 `section.sourceText`를 한 번만 임베딩한다. FTS 자체의 표현·검색 계약은 유지한다.
- E5의 높은 코사인은 관련성 확률이 아니다. 원 모델의 [FAQ](https://huggingface.co/intfloat/multilingual-e5-small#faq)도 높은 점수 분포와 상대 순위의 성격을 설명한다. cutoff 상향만으로 세면대 질의의 잘못된 순위를 고칠 수 없었다.
- 토크나이저 기준 ID를 111개 입력으로 확대해 검사했고 일치했다. 대칭 점수와 corpus 중심 보정도 시험했지만 두 오탐을 안정적으로 해결하지 못했다. 따라서 이를 제품의 추가 판정 규칙으로 넣지 않았다.
- **질문과 문서를 함께 읽는 cross-encoder**가 커피 후보를 -8.008, 수리 문서를 -2.725로 구분했다. 양자 질의의 작업 취소 후보는 -4.762였다. 현재 공동 관련성 기준 -3.0으로 잘못된 후보를 기각하고 수리 문서를 반환한다.

질의별 예외 목록이나 한국어 동의어 사전으로 이 사례만 막지 않았다. 실제 모델·parser·SQLite·파일을 이용해 같은 파이프라인을 검증했다.

## 3. 현재 검색 파이프라인

```mermaid
flowchart LR
  Q[명시적 질의] --> E[E5 후보 검색]
  E --> P[코사인 0.75 이상 상위 20개]
  P --> R[질문과 원문을 함께 읽는 관련성 모델]
  R --> G[logit -3 이상 · 최고점 차이 2 이하]
  G --> V[양쪽 모델 뒤 source epoch 재검증]
  V --> S[정확한 참조로 현재 원문 열기]
```

관련성 점수는 raw logit이며 확률·사실 인증·답변 가능성 인증이 아니다. 반환 순서는 관련성 점수, 동점이면 코사인·section ID다. JSON의 `similarity`는 원래 코사인을 유지하고 선택형 `relevanceScore`를 추가했다. UI에는 **관련성 모델로 선별한 후보**라고 표시한다.

모델 누락·오류·잘못된 점수·취소 때에는 미검사 벡터 후보로 돌아가지 않는다. 지원 언어 값은 `auto/ko/en`이다. 다른 언어 값, 빈 질의, NUL, 512 UTF-8 bytes 초과 질의는 명시적으로 실패한다. 기존 페이지 검색·total/cursor·Spotlight 결과와 자동으로 합치지 않는다.

## 4. 모델·패키지·토큰 계약

| 항목 | 고정된 구현 |
| --- | --- |
| 후보 임베딩 | `intfloat/multilingual-e5-small` @ `614241f622f53c4eeff9890bdc4f31cfecc418b3` |
| E5 Core ML | `tuanda2912/hark-multilingual-e5-small-coreml` @ `0a386d4aea14586b042c6e68a83acb6ff8d87970`, int8, MIT |
| 공동 관련성 | `cross-encoder/mmarco-mMiniLMv2-L12-H384-v1` @ `1427fd652930e4ba29e8149678df786c240d8825` |
| 관련성 Core ML | `isidorus-ai/mmarco-mMiniLMv2-L12-H384-v1` @ `5a9d13a7359c70b5a6b4c90810b65536b2ac470e`, fp16, Apache-2.0 |
| 토크나이저 | 고정 JSON에서 재생성한 읽기 전용 scalar trie. HF 1.4.0 알고리즘·모델별 전처리 유지. 독립 HF 기준 **963건**(기존 195+Unicode 768) 일치 |
| E5 입력·출력 | query/passage prefix, int32 `[1,L]`, 최대 512 tokens, float32 `[1,L,384]`. 유효 token pooling 후 L2 정규화 |
| 관련성 입력·출력 | prefix 없이 `<s> query </s></s> passage </s>`, pad ID 1, mask 0/1, 고정 `[1,512]`, raw scalar |
| 연산 | 두 모델 `.cpuOnly`. E5 후보 실측에서 ANE 경로보다 낮은 peak를 관찰. 관련성 모델의 ANE 비교는 수행하지 않음 |
| 배포 | uncompiled 모델과 토크나이저 약 **382.43 MiB** 원본 리소스 번들. API key·모델 서버·런타임 Hub 다운로드 없음 |

[원 모델 계약](https://huggingface.co/intfloat/multilingual-e5-small/blob/614241f622f53c4eeff9890bdc4f31cfecc418b3/README.md), [E5 변환 출처](https://huggingface.co/tuanda2912/hark-multilingual-e5-small-coreml/blob/0a386d4aea14586b042c6e68a83acb6ff8d87970/README.md), [관련성 원 모델](https://huggingface.co/cross-encoder/mmarco-mMiniLMv2-L12-H384-v1), [관련성 변환](https://huggingface.co/isidorus-ai/mmarco-mMiniLMv2-L12-H384-v1)을 대조했다. 관련성 변환 문서는 출력을 `logits`라고 설명하지만 실제 고정 자산은 **`var_935`**다. 앱은 실제 출력 이름·shape·유효 수치를 검사한다. 배포자의 parity 주장을 자체 한국어 인증으로 사용하지 않았다. 원 fp32 모델과 모든 수치의 동등성은 이번 범위가 아니다.

모델별 [E5 manifest](../Sources/FolioSemanticModels/Resources/MODEL_SOURCE.json), [관련성 manifest](../Sources/FolioSemanticModels/Resources/Relevance/MODEL_SOURCE.json), [tokenizer manifest](../Sources/FolioSemanticModels/Resources/TOKENIZER_SOURCE.json)에 revision·SHA-256·라이선스와 출처를 남겼다. 앱 자산 테스트는 모델·라이선스·컴파일 tokenizer의 해시를 검사한다. 원본 tokenizer JSON과 설정 4개는 `Tools/SemanticAssets/ReferenceTokenizers`에서 재현에 사용하고 배포 번들에서 제외한다. `compile_tokenizer.py --check`는 원본 해시와 컴파일 산출물을 대조한다. 두 weight와 공유 tokenizer 표는 [Git LFS](../.gitattributes)를 사용한다. 개발 빌드 전 `git lfs pull`이 필요하다. 원격 push·배포는 수행하지 않았다.

`FolioSemanticModels`는 선택형 제품이다. `FolioCore`·`FolioSDKUI`는 이 모델을 링크하지 않는다. SwiftPM resolver는 패키지에 선언한 의존성을 해석할 수 있다. 고급 호스트는 `WikiSearchService`에 `localSemanticEmbedding`과 `localSemanticRelevance`를 함께 주입한다. 기본 SDK 세션을 생성하는 것만으로 모델을 읽거나 추론하지 않는다.

실제 iPhone에서 발견한 번들 경로 오류도 수정했다. iOS `Bundle.resourceURL`은 이미 `Resources`일 수 있고 Mac SwiftPM은 `Contents/Resources/Resources`를 사용했다. 현재는 자신의 번들 내부 두 배치만 확인한다. 개발자 checkout으로 우회하지 않는다.

## 5. 모듈·함수·상태 소유권

| 파일·함수 | 책임 |
| --- | --- |
| [WikiSemanticEmbedding/Relevance](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiSemanticEmbedding.swift) | vector·공동 관련성·자원 해제의 선택형 Sendable 계약. 모델에 원문 경로·쓰기 권한을 주지 않음 |
| [MultilingualE5Embedding.vector/loadModel](../Sources/FolioSemanticModels/MultilingualE5Embedding.swift) | actor 격리·로컬 compile·prefix·pooling·L2·토큰 상한 |
| [MultilingualMiniLMRelevance.scores/tokenIDs](../Sources/FolioSemanticModels/MultilingualMiniLMRelevance.swift) | 별도 tokenizer·pair layout·mask·출력 검증·부분 처리. 원문 절단 없음 |
| [CompactUnigramTokenizer](../Sources/FolioSemanticModels/CompactUnigramTokenizer.swift), [SemanticTensor](../Sources/FolioSemanticModels/SemanticTensor.swift) | 고정 표 읽기, 모델별 정규화·Viterbi·패딩·stride·동일 Double pooling |
| [WikiLocalSemanticSearch.search](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiLocalSemanticSearch.swift) | 필터·후보 예산·두 단계 선별·역할별 벡터 캐시·모든 추론 뒤 epoch와 현재 원문 검증 |
| [WikiSearchService](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiSearchService.swift) | 모델 주입·명시적 의미 검색·자원 해제. 일반 검색과 별도 계약 |
| [WikiProjection](../Vendor/KnowledgeKit/Sources/KnowledgeKit/WikiProjection.swift) | 이전 semantic producer만 정리. 다른 producer와 원문·영수증 보존 |
| [suggestRelations/prepare/execute/status](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiRelationProposals.swift) | 타입·대상 자격·제안 JSON·정확한 계획·기존 writer와 receipt |
| [FolioWorkspaceSession](../Sources/FolioUI/FolioWorkspaceSession.swift), [검토 화면](../Sources/FolioUI/FolioSemanticReviewView.swift) | 앱의 지연 모델 주입·명시적 실행·원문 이동·취소·별도 승인·화면 종료 시 자원 해제 |
| [SemanticEvaluation](../Tools/SearchEvaluation/SemanticEvaluation.swift) | 테스트와 하나의 corpus 공유, 집합별 품질·raw score·지연·메모리·선택형 trace |

큰 모델과 tokenizer는 첫 실행 때 로드한다. 검색 결과에서 원문을 열 때는 사용한 service의 모델 해제 완료를 기다린 후 generation·취소·현재 reference를 재검증한다. 검토 화면 종료·자료함 변경 시에도 사용한 service에 해제를 요청한다. 검색 중이면 종료 뒤 해제하며 다른 자료함의 service로 잘못 요청하지 않는다. source·vector DB·proposal·receipt는 지우지 않는다. 임시 compiled model은 같은 service에서 재사용하고 수명 종료 때 정리한다. OS가 임시 파일을 지웠으면 다시 compile한다. 외부 주입 provider의 기본 해제는 no-op이며 호스트가 구현할 수 있다.

## 6. 예산·부분 결과·캐시

- 원문 구간 최대 512개, 제목을 포함한 검색 표현 8 KiB 검사, E5 실제 512 tokens. indexing loop 15초.
- 관련성 후보 최대 20개, query와 전체 구간을 합친 pair 512 tokens, scoring loop 5초. 초과 pair는 nil로 제외한다. **조용한 잘라내기·미검사 fallback은 없다.**
- 모델 초기화·compile·스캔·캐시·최종 원문 검증은 loop 예산 밖이다. 전체 요청의 15초/5초 보장이 아니다. native 추론 중 강제 중단 대신 전후 취소를 확인한다.
- 한 service에서 의미 검색 1개. 중첩 요청은 busy 오류다. 여러 독립 service의 전역 제한은 없다.

`indexComplete`는 벡터 색인, `coverageComplete`는 원문 스캔이다. `relevanceComplete`는 선택된 후보의 공동 관련성 처리 완전성, `relevanceCheckedCandidates`는 검사 수다. 후보 pool 상위 20개 밖의 전체 recall은 보장하지 않는다. 여러 파일의 원자적 스냅샷이 아니므로 `atomicSnapshot=false`다.

producer는 `folio.semantic/<purpose>/<modelID digest>`다. model ID는 고정 weight·토큰 처리·CPU·원문 표현·역할과 retrieval의 공동 검사 버전을 포함한다. section ID·source revision·input hash·차원·수치를 검사한다. 같은 역할의 이전 cache와 옛 한 단계 producer만 정리한다. 손상 JSON 재계산·원문 변경/삭제·재시작·projection reset·다른 cache 보존을 검사했다.

384차원 vector 원소의 상한 **1.5 MiB**는 SQLite JSON·모델·tokenizer·전체 앱 메모리 상한이 아니다. 이전 RSS 128 MiB FAIL과 footprint의 소규모 PASS·동시 실행 FAIL을 모두 보존한다. **128 MiB는 Apple 제한이 아니라 앞선 계획의 근거가 부족한 내부 목표**다. RSS에서 footprint로 측정 조건을 바꿔 같은 제한을 충족했다고 볼 수 없다. 이 숫자로 검색을 강제 차단하지 않으며, 모델 중복·임시 할당·반복 projection 재작성을 줄였다. [기준 재검토](SEMANTIC_MEMORY_INVESTIGATION.md), [현재 UI·검증](Verification/resource-reading-20261108/README.md).

최적화 전 M2 Debug 82질의의 peak RSS **622.625 MiB** 기록을 보존한다. 현재 모델은 같은 weight·토큰·검색 점수를 유지하며 큰 JSON/trie 객체 구성을 제거했다. 앞선 단일 service 검증(이번 모델 공유·UI 변경 이전)의 Mac 전환 peak physical footprint는 **84.939 MiB**, iPhone 최종 3회는 **120.315–123.955 MiB**였다. 첫 실행을 포함한 CLI 지연·RSS·physical peak·해제 후 값은 [전체 측정](Verification/semantic-memory-20261108/measurement-summary.json)을 따른다. process-cold 실행이며 OS/Core ML compiler cache까지 cold로 만든 실험은 아니다. 배터리·열·모든 기기의 인증으로 확대하지 않는다.

## 7. 관계·승인·복구 계약

관계는 E5 query/query 대칭 유사도다. 자신·기존 관계·stable ID 없음·타입 불일치를 **점수 범위 적용 전에** 제외한다. 코사인 0.83와 최고점 차이 0.015를 적용하고 제안은 추가로 0.88 이상이어야 한다. 공동 QA 관련성 모델을 문서 간 관계의 사실 판정에 사용하지 않는다. 첫 source section 앞 120 Unicode scalars로 후보를 찾고 전체 근거는 그대로 검토한다.

검색·생성·거절은 Markdown을 쓰지 않는다. 제안은 선택한 로컬 상태의 `RelationProposals/<digest>.json`에 보관한다. 최대 1,000개·64 KiB/record, symlink 거부, 기존 coordinated I/O·CAS를 사용한다. ID는 정책·source scope·workspace/revision·predicate·양쪽 section/revision·model ID에 묶인다.

`prepareRelationProposal`은 현재 근거·ontology를 검사하고 기존 `prepareEdit`로 정확한 patch를 만든다. operation ID·result revision을 먼저 저장하고, UI/SEMI가 두 근거와 변경 전후를 별도로 승인한다. `executeRelationProposal`은 정확한 plan과 source/workspace/result hash를 대조한 뒤 기존 `execute`를 사용한다. 초안·저장 중 변경, source/target/ontology 변경, 대체 plan, 거절 후 실행을 차단한다.

| 상태 | 의미 |
| --- | --- |
| proposed / prepared | 검토 대기 / 정확한 계획 준비. 반영 확인 없음 |
| rejected | 거절. 원문 무변경 |
| stale | 원문·규칙·정책 변경. 새 검토 필요 |
| uncertain | intent는 있으나 receipt 미확정. 자동 재실행·재준비 금지 |
| accepted | 기존 committed receipt 확인. 다시 적용하지 않음 |

정책 버전은 3이다. 이전 미실행 제안은 stale로 처리하지만 committed/uncertain은 정책보다 기존 receipt/intent를 먼저 조회한다. 새 모델 때문에 과거 반영 결과를 숨기거나 재적용하지 않는다. source writer·초안·iCloud 계정 admission을 우회하지 않았다.

SEMI capability ID/schema는 유지했다. `wiki.semantic_search`, `wiki.suggest_relations`, `wiki.relation_proposal`은 원문 기준 read이고 파생 cache/기록을 만들 수 있다. `wiki.accept_relation_proposal`은 기존 접근 승인과 별도 mutation 승인을 요구한다.

## 8. 평가와 해석

[공유 corpus](../Tests/FolioKnowledgeTests/Fixtures/SemanticCorpus.json)는 6개 주제 한·영 문서 12개, 질의 82개다. 관련 gold는 같은 주제 한·영 문서 2개로 유지했다. 개인 자료와 질의별 예외 코드는 사용하지 않았다.

**첫 holdout과 추가 audit의 실패를 보고 모델·정책을 개선했다. 이 집합은 최종 blind test가 아니다.** 실패는 [보정 전 holdout](Verification/semantic-bilingual-20261108/holdout-before-calibration.json)과 추가 audit 원본으로 보존한다. 이후 정책을 고정해 새 16개 합성 질의를 검사했다. 이 또한 실제 사용자 traffic을 대표하는 통계적 인증은 아니다.

| 집합 | 양성/부정 | Hit@3 | 후보 precision | 부정 후보 반환률 | Recall@3 |
| --- | --- | --- | --- | --- | --- |
| 개발 | 6 / 2 | 1.0000 | 1.0000 | 0 | 0.5833 |
| 검증 | 12 / 10 | 1.0000 | 1.0000 | 0 | 0.6667 |
| 재검사 holdout | 8 / 8 | 1.0000 | 1.0000 | 0 | 0.6250 |
| 추가 audit | 12 / 24 | 0.9167 | 1.0000 | 0 | 0.7083 |
| 정책 고정 후 추가 16질의 | 8 / 8 | 1.0000 | 1.0000 | 0 | 0.6875 |

Hit@3는 관련 문서가 하나라도 나온 비율, Recall@3는 gold 전체의 회수 비율이다. 추가 audit의 하천 질의 하나는 관련 문서가 있어도 기각했다. 이를 gold에서 빼지 않았다. [현재 평가](Verification/semantic-bilingual-20261108/evaluation.json), [고정 후 추가 검사](Verification/semantic-bilingual-20261108/qualification.json)에 질의별 결과·원점수·완전성·지연·RSS를 남긴다. 52개 부정 질의에서 후보가 없었다는 관찰을 모든 질의의 오탐 0으로 일반화하지 않는다.

같은 82질의·같은 gold에서 lexical Recall@3는 **0.4605**, 현재 의미 검색은 **0.6579**, 차이는 **+0.1974**였다. 이전 영어 모델 평가와는 corpus가 다르므로 그 수치와 직접 성능 증감을 비교하지 않는다.

일반 자동 활성화는 보류한다. 다음 순서는 **정책 고정 → 동의받은 새 사용자 자료/질의 → 같은 gold에서 lexical 비교 → 기기별 cold/warm·peak·배터리/열 예산**이다. 품질 기준은 Hit@3 ≥0.8, precision ≥0.8, 부정 후보 반환률 ≤0.1이고, 이전 P4의 lexical 대비 Recall@3 **0.10 이상 개선** 기준도 유지한다. 현 합성 집합 통과와 실제 UI 실행을 장시간 자원·일반 품질 인증으로 확대하지 않는다.

## 9. 실제 검증·정리·재현

이전 두 단계 도입 검증은 [이전 manifest](Verification/semantic-bilingual-20261108/results.json), 현재 자원 최적화·회귀·실기기 실행·binary/source 해시·실패와 재실행은 [현재 manifest](Verification/semantic-memory-20261108/results.json)를 따른다. **Mac은 실제 네이티브 앱과 로컬 QA 원문**, **iPhone은 연결된 iPhone 15와 정확한 iCloud container/workspace admission**으로 검사했다. simulator 결과로 대체하지 않았다. Mac cloud admission 오류의 보호 조건을 해제하지 않고 로컬 폴더를 사용했다.

현재 Mac 검색 후 기존 Markdown 15개 해시가 같았다. QA 대조 문서 1개 추가 후 취소 시 16개 해시가 같았고, 승인 뒤에는 표시한 `sleep-ko`의 related 한 개만 바뀌었다. 재실행 후 같은 operation ID와 accepted 상태를 조회했다. iPhone에서는 새 coffee 관계를 별도로 승인하고 같은 receipt를 재조회했다. [현재 화면·해시 기록](Verification/semantic-memory-20261108/results.json)을 따른다. 이전 단계 통과를 최종 코드 검증으로 대신하지 않는다.

| 최종 검사 | 결과 |
| --- | --- |
| Root 전체 | **282 PASS**: UI 164, Knowledge 36, Core 10, Agents 38, VaultImport 20, Development 14 |
| 실제 SEMI SDK | **3 PASS**, 두 단계 검색 read와 실제 접근·정확한 mutation 승인·거절·receipt |
| 독립 SDK 호스트 | **BUILD SUCCEEDED**, 모델/Core ML 직접 링크 없음 확인 |
| 서명된 Mac | **BUILD SUCCEEDED · 실제 UI PASS**, 한·영·오탐·원문·취소·정확한 승인·재실행 receipt |
| 실제 iPhone 15 | **2 UI cases PASS**, source 전환 최적화 후 검색 case 최종 3회 PASS. 새 승인·재실행 receipt 별도 PASS. 중간 실패 보존 |

이전 두 단계 도입 검증의 중간 실패는 커서 중간에서 문자열을 삭제한 입력 driver와 일부 노출된 목록 행의 탭이었다. 기본 전체 선택 메뉴와 기본 검색으로 입력·대상 행을 확정했다. 이번 자원 검증에서도 별도의 대상 행 탭 뒤 탐색 실패를 보존하고 검색으로 고정한 재실행을 기록했다. 현 앱에서 세면대 질의는 배관 문서를 반환하고 커피를 반환하지 않았고, 양자 질의는 빈 결과였다. 기존 bank·repair와 이번 coffee 승인·복구 기록을 구분해 보존했다.

실기기 QA 자료함은 승인 결과를 보존한다. 새로운 승인 시나리오를 다시 실행하려면 fixture를 명시적으로 새로 준비해야 한다. 기존 bank·repair와 이번 coffee 편집·승인, Mac sleep 검증을 개인 자료와 섞거나 영구 삭제하지 않았다. 초기 실패 중 만든 QA 노트도 보존한다.

정리한 범위는 영어 전용 NaturalLanguage·스크립트 거부, 중복된 inline 평가 corpus, 옛 semantic 벡터, 이전 P4 정본, 도입하지 않은 보정/외부 모델 실험용 코드다. 실제 평가 원본·영수증·복구 파일·다른 producer는 보존한다. 테스트는 `SemanticWorkflowTests`, `BilingualSemanticTests`, `SemanticRelevanceTests`로 책임을 구분했다. 모델 자산은 근거가 있는 두 단계에만 사용한다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
git lfs pull
swift test --scratch-path /tmp/folio-semantic-build --no-parallel
swift run --scratch-path /tmp/folio-semantic-build FolioSearchEvaluation --semantic
```

`--semantic --trace-vectors`는 실제 모델의 retrieval/symmetric/relevance 원점수 진단용이다. 이 모드는 모델을 먼저 준비하므로 cold 성능 측정에 사용하지 않는다. 추가 질문 집합은 canonical `notes`와 질문 JSON을 결합해 `--corpus PATH`로 재현한다. root 전체·실제 SEMI SDK·독립 SDK 예제·서명된 Mac·실제 iPhone 결과를 각각 구분해 기록한다.

## 10. 다음 개선의 우선순위와 통과 조건

1. **P0 자원 후속:** 원본 weight·점수·963 token 기준을 유지하며 모델 공유·예측 임시 객체 해제·projection 재작성과 cache 조회를 개선했다. 128 MiB를 제품의 강제 제한으로 사용하지 않는다. 이전 기준의 실패와 확인하지 않은 범위를 보존한다. 자동 활성화는 계속 보류한다.
2. **P1 품질:** 보정에 쓰지 않은 동의 자료에서 양성·부정 각 100개 이상을 확보한다. 한·영, 동음어, 제목과 본문이 다른 문서, 주제는 비슷하지만 질의와 다른 자료를 포함한다. gold를 먼저 고정하고 기존 검색과 같은 문서·질의로 비교한다. 위 품질·recall 개선 기준과 오류 목록을 함께 판정한다.
3. **P2 큰 자료함:** 512개를 넘는 section, 긴 pair, 변경·삭제·계정/자료함 전환을 포함한 부하 검사를 실행한다. 증분 색인을 도입한다면 기존 `FolioWorkspaceJobs` 수명 안에서 source revision별로 재생성하고 부분 결과 표시·취소·현재 원문 재검증을 유지한다. 읽기 연산 취소 UX와 승인 실행의 결과 미확인 처리는 별도로 검토한다.
4. **P3 자동화 범위:** 위 게이트 후에도 관계 제안은 ontology·stable ID·사용자의 정확한 변경 승인을 요구한다. 모델 점수만으로 원문 수정, 불확실한 작업 재실행, 영수증 삭제를 허용하지 않는다.
