# 인용 근거와 검색 검증

새 자료 질문 경로의 `readKnowledgeEvidence(_:)`·`previewKnowledgePDF(_:)`는 Markdown 하위 구간과 PDF 페이지 인용을 검사한다. PDF는 현재 원본의 선택 페이지를 다시 추출해 대조하며 자체 cache hash만으로 인증하지 않는다. 기존 아래 Markdown 검증 API와 같은 권한·원문 우선 원칙을 유지한다. [구현과 제한](KNOWLEDGE_PLATFORM_IMPLEMENTATION.md).

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

현재 실행의 결과와 한계는 [재검토·구현 기록](AUTO_ONTOLOGY_IMPLEMENTATION_REVIEW.md)을 따릅니다.

별도의 한국어·영어 의미 검색·자동 관계 후보 검토는 [현재 구현 문서](SEMANTIC_SEARCH_IMPLEMENTATION.md)의 명시적 실험 기능으로 제공합니다. `wiki.verify_evidence`는 해당 후보의 참조도 검사할 수 있으며, 그 결과가 의미적 관계의 참임을 인증하지는 않습니다.
