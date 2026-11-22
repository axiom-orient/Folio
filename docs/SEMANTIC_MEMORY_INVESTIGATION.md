# 의미 검색 메모리 원인 분석과 측정 기준

2026-11-08. [검색 정본](SEMANTIC_SEARCH_IMPLEMENTATION.md)의 자원 예산 후속 기록이다. **128 MiB는 이전 계획의 내부 비교 목표이며 Apple의 강제 한도가 아니다. 이 숫자를 제품 전체의 절대 제한으로 삼을 근거는 확인되지 않았다. 기존 RSS·footprint의 실패를 통과로 변경하지 않는다.** 원문 writer, 별도 승인, intent/receipt 복구, 모델 weight와 검색 점수 기준을 변경하지 않았다.

최종 raw 결과·실패·재실행·binary/source SHA-256은 [검증 manifest](Verification/semantic-memory-20261108/results.json), 지표 판정은 [memory gates](Verification/semantic-memory-20261108/memory-gates.json)를 따른다.

## 1. 계획과 실행

| 단계 | 실행 | 완료 조건 |
| --- | --- | --- |
| P0 | 변경 전 174개 파일 해시·source 복사본·이전 평가 보존. 단계별 RSS/physical footprint와 Allocations 수집 | tokenizer/compile/load/predict/pool/release 구분. 계측 trace와 비계측 평가 분리 |
| P1 | JSON 파서·Rust tokenizer·SentencePiece 대안 반증. 원본 어휘를 읽기 전용 표로 컴파일 | 어휘·점수·정규화·특수 토큰 보존. 독립 HF 기준 검사 |
| P2 | 공유 scalar trie·scoped tensor 접근·실제 async 해제·원문 전환 전 해제 | 동일 수치·stride·패딩·손상 표 거부·해제 후 재로딩 검증 |
| P3 | 같은 82질의 반복, 기존 정책 고정 추가 16질의, 긴 입력 3회 load/release | 후보와 양쪽 점수 불변. 새 지표와 이전 지표 별도 판정 |
| P4 | 서명 Mac·물리 iPhone 15에서 검색·기각·원문·취소·승인·재실행 receipt | simulator로 대체하지 않음. iPhone의 작은 예산 여유를 확인한 뒤 추가 반복 |
| P5 | 전체 282 회귀·SEMI 3·SDK 호스트·자산 재생성·문서·해시 검토 | 최종 실행 결과와 한계가 일치 |

## 2. 623 MiB의 원인

이전 M2 Debug CLI 82질의 실행은 **652,869,632 bytes = 622.625 MiB peak RSS**였다. 그 실행에는 physical footprint 기록이 없으므로 이를 사후에 추정하지 않는다.

별도의 동일 모델·긴 입력 진단에서는 다음을 관찰했다. 아래 값은 한 프로세스에서 얻은 bytes를 MiB로 환산한 것이다. 누적 peak와 해당 시점의 사용량은 다른 값이다. [원본](Verification/semantic-memory-20261108/baseline-joint-memory.jsonl).

| 지점 | 현재 physical footprint | 누적 physical peak | 누적 RSS peak |
| --- | ---: | ---: | ---: |
| E5 JSON decode 뒤 | 104.720 | 104.720 | 113.906 |
| E5 tokenizer 구성 뒤 | 196.329 | 196.329 | 199.719 |
| E5 `MLModel(contentsOf:)` 뒤 | 127.595 | 196.329 | 460.188 |
| 관련성 tokenizer 구성 뒤 | 261.079 | 261.079 | 460.188 |
| 관련성 `MLModel(contentsOf:)` 뒤 | 199.579 | 261.079 | 524.859 |
| 두 자원 해제 뒤 | 115.235 | 261.079 | 524.859 |

확인한 원인은 두 가지다.

1. **25만 어휘를 큰 Swift 객체 그래프로 만드는 비용.** `JSONDecoder → Config`가 어휘·점수의 중간 배열을 만들고, `UnigramTokenizer`가 vocab 배열·token→ID dictionary·scalar별 class/dictionary trie를 추가했다. 두 모델의 어휘와 charsmap은 실제 bytes/값이 같지만 각각 구성했다. 단, 정규화·공백 처리·`<mask>` 처리까지 같지는 않으므로 tokenizer 전체를 하나로 바꾸면 안 된다.
2. **Core ML load 중 일시적인 resident 증가.** compile 직후와 `MLModel(contentsOf:)` 직후 사이에 누적 RSS가 크게 올랐다. 같은 구간의 physical peak는 훨씬 작았다. 모든 RSS를 heap 누수나 추론 tensor로 해석할 수 없다. clean file mapping은 OS가 회수할 수 있다. Apple은 앱의 부담을 dirty/compressed footprint로 설명한다. [Apple 메모리 설명](https://developer.apple.com/videos/play/wwdc2018/416/).

Allocations 25초 trace에서는 누적 allocation 약 1.66 GB와 2,329만 event를 관찰했다. **이는 살아 있는 메모리나 peak 1.66 GB라는 뜻이 아니다.** 캡처 시점에 `ContiguousArrayStorage<Int>` 약 35.75 MB, `Config` 배열 약 22.42 MB, UTF-16 배열 약 8.71 MB가 남았다. 계측이 느려 tokenizer 구성 중 제한 시간에 종료됐고, 전체 모델 실행을 포괄하지 않았다. 큰 Int 배열의 정확한 소유자를 이 통계만으로 단정하지 않는다. [Statistics export](Verification/semantic-memory-20261108/baseline-allocations-statistics.xml). 1.2 GB Instruments 원본 경로·해시는 manifest에 있다.

기존 E5 pooling은 약 `L×384`개 원소를 NSNumber subscript로 읽고 tensor 입력도 원소별 boxing을 했다. 이 비용은 제거했지만, 이전 단계 측정에서 pooling 직후 peak 증가가 없었으므로 **623 MiB의 주원인**이라고 부르지 않는다.

## 3. 채택·기각한 변경

| 후보 | 실제 검증 | 결정 |
| --- | --- | --- |
| Foundation decoder를 기존 yyjson 경로로 교체 | 초기화는 빨랐으나 같은 구조의 객체·trie가 남고 joint physical peak 약 276.7 MiB | 메모리 해결로 채택하지 않음 |
| `DePasqualeOrg/swift-tokenizers` 0.7.4 / Rust backend | 111+84 토큰 일치. 두 tokenizer만으로 physical peak 약 618.7 MiB | 기각. 의존성 추가하지 않음 |
| SentencePiece 기본 정규화 | 기존 입력에서 E5 2개·pair 1개 불일치. 분해 한글·특수 토큰 주변 공백 포함 | 기각. 근사 tokenizer로 대체하지 않음 |
| 원 어휘·점수에서 만든 고정 scalar trie | 기존 195건 및 추가 Unicode 768건 기준 일치, 전체 검색 수치 일치 | 채택 |
| scoped Core ML buffer | 기존 Double 연산 순서와 일치. 실제 양의 비연속 stride·잘못된 shape/NaN·mask 검사 | 채택 |
| release의 명시적 async 구현 | concrete actor와 protocol existential 모두 실제 모델·tokenizer 해제, 재로딩 수치 일치 | 채택 |
| 결과→원문 전환 전 해제 완료 대기 | 기존에는 원문을 연 다음 sheet 종료에서 해제. 현재는 해제 후 generation/취소 확인, 현재 원문 read | 채택. 개별 실행 차이를 모두 이 변경의 효과라고 단정하지 않음 |

기각한 실험 코드는 제품·패키지 그래프에 넣지 않았다. 새 quantization이나 모델·cutoff 변경은 필요하지 않았다.

## 4. 구현의 정확한 범위

- [컴파일러](../Tools/SemanticAssets/compile_tokenizer.py)는 두 고정 JSON SHA-256, 어휘·Float32 점수의 동일성, 전처리·추가 토큰 계약을 검사한다. 표를 **학습하거나 어휘를 줄이지 않는다.**
- 250,002개 어휘를 505,199개 scalar trie 노드로 만든다. 표는 **12,124,800 bytes**, charsmap은 **237,539 bytes**다. [TOKENIZER_SOURCE](../Sources/FolioSemanticModels/Resources/TOKENIZER_SOURCE.json)에 입력/출력 해시를 고정했다.
- [CompactUnigramTokenizer](../Sources/FolioSemanticModels/CompactUnigramTokenizer.swift)는 local bundle 표를 `.mappedIfSafe`로 읽는다. 런타임에 원 JSON, 어휘 String 배열, token dictionary, class trie를 만들지 않는다. read-only 표를 일반 heap 상주 객체로 복제하지 않는다.
- normalizer는 기존 HF의 grapheme/scalar 변환을 보존한다. [알고리즘 원본 revision](https://github.com/huggingface/swift-transformers/blob/402a8a1105f52038b0949d9596981fc9e32bed17/Sources/Tokenizers/UnigramTokenizer.swift)을 고정했다. E5의 반복 ASCII 공백 축약과 관련성의 WhitespaceSplit·mask lstrip을 별도로 유지한다. malformed charsmap에 근사 NFKC fallback을 쓰지 않는다.
- Viterbi는 기존 Float32 덧셈 순서, 동점의 첫 predecessor 선택, pre-tokenized word별 unknown fusion을 보존한다. raw scalar 경계를 사용한다. 첫 구현의 Foundation 문자열 분할이 결합 문자 뒤 내용을 누락한 **8건 실패를 보존**하고 scalar 분할로 수정했다. fixture나 gold를 바꾸어 통과시키지 않았다.
- [SemanticTensor](../Sources/FolioSemanticModels/SemanticTensor.swift)는 buffer scope 안에서 strides를 따른다. 토큰 ID 범위·512 상한·pad 1·mask 0/1·float32 shape·유한 norm을 검사한다. Double 누적과 L2 순서를 바꾸지 않았다.
- actor 초기화는 계속 동기 격리되어 있다. async tokenizer factory나 actor 재진입을 새로 만들지 않았다. `releaseResources() async`를 명시해 기본 async no-op과 concrete sync 메서드의 overload 선택을 제거했다. compiled URL은 재사용하며 actor 종료 때 정리한다.
- source 전환 전에 사용하던 service에서 해제 완료를 기다린다. 이후에도 workspace generation·취소·기존 reference read를 검사한다. source 경로나 승인 권한을 모델에 주지 않는다.
- 어휘·전처리·모델 출력이 같으므로 model ID·proposal 정책은 유지한다. 파생 cache·원문·초안·intent·receipt를 삭제하지 않는다.

`swift-transformers`의 런타임 의존성과 사용하지 않는 전이 의존성 **8개 pin**을 제거했다. root `Package.resolved`는 12→4다. HF에서 차용한 알고리즘의 Apache-2.0 라이선스·출처는 번들에 보존했다. 큰 원본 tokenizer JSON은 컴파일 입력·재현 근거로 남겼다. 기존 빌드 캐시나 사용자 자료를 정리 대상으로 삭제하지 않았다.

## 5. 측정 지표 변경과 수치 목표에 대한 정정

**v1: `ru_maxrss ≤134,217,728 bytes`는 여전히 FAIL이다.** 새 모델의 RSS peak가 128 MiB 아래가 됐다고 주장하지 않는다.

**이전 v2 기록은 `TASK_VM_INFO.ledger_phys_footprint_peak ≤134,217,728 bytes`를 사용했다. 이는 v1과 다른 측정 조건이다.** RSS는 함께 기록하는 진단 지표로 유지한다. clean 매핑과 dirty/compressed 부담을 구별하기 위한 변경이며, 관찰한 peak에 맞춰 한도를 올린 결정이 아니다.

- Apple의 [memory footprint 설명](https://developer.apple.com/videos/play/wwdc2018/416/)과 [task_vm_info API](https://developer.apple.com/documentation/kernel/task_vm_info_data_t?language=occ), [XNU lifetime max 구현](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/kern/bsd_kern.c)을 근거로 삼았다.
- CLI뿐 아니라 **UI를 포함한 앱 프로세스의 launch 이후 누적 peak**를 사용한다. 앱 baseline을 빼지 않고, 모델 load·화면 전환·취소·해제도 제외하지 않는다.
- 앱 프로세스 회계 기준이다. 별도 Core ML compiler 프로세스나 기기 전체 사용량의 합계를 측정한 값은 아니다. 이 경계는 이전 RSS 측정에도 같았다.
- kernel의 lifetime high-water mark를 읽는다. 샘플 사이의 순간 peak를 1초 RSS polling으로 놓쳐 통과시키지 않는다. peak를 초기화하지 않는다.
- RSS와 physical footprint는 단순 포함 관계가 아니다. 압축 메모리가 있어 둘을 빼서 clean bytes를 계산하지 않는다.
- native Mac의 loaded-state `vmmap`은 mapped file 29.2 MiB resident·0 dirty를 보였다. **818.6 MiB virtual size를 실제 사용량이라고 부르지 않는다.** 이것만으로 load 순간 모든 resident 페이지의 종류를 입증하지 않는다. [VM 원본](Verification/semantic-memory-20261108/mac-loaded-vmmap.txt).
- 태스크 정보가 없거나 두 모델의 load/release가 빠진 trace는 [판정 도구](../Tools/SemanticAssets/verify_memory.py)가 거부한다. 이전 RSS 판정을 덮어쓰지 않는다.

RSS와 footprint를 함께 기록하는 것은 타당하지만 **같은 128이라는 숫자가 기준의 동등성이나 제품 적합성을 입증하지 않는다.** 앞선 계획은 128 MiB 수치 자체의 제품 근거를 제시하지 못했다. 이를 Apple 제한으로 설명하거나 초과를 숨겨 통과시키면 안 된다.

후속 부하 검사에서 실제로 512개 구간·4개 service의 전체 프로세스 physical peak가 Mac **155.143 MiB**, iPhone **138.660 MiB**로 목표를 초과했다. 한 service의 소규모 PASS를 일반 도입 근거로 확대할 수 없다. 모델 공유와 예측별 임시 객체 해제만 적용한 중간 iPhone 실행은 **98.580 MiB**였으며, 이는 최종 전체 UI·모든 부하의 인증이 아니다. [원자료와 현재 범위](Verification/resource-reading-20261108/README.md).

사용자의 후속 지시에 따라 불필요한 장시간·반복 검증은 중단하고, 실제 안정성·응답·검색 정확도와 핵심 UI를 우선한다. 128을 맞추기 위해 검색을 강제 중단하는 제품 제한을 넣지 않았다. 새 숫자로 기준을 올리거나 기존 실패를 PASS로 덮지도 않았다. **의미 검색의 명시 실행과 자동 활성화 보류는 유지**한다.

## 6. 실제 측정과 품질

현재 수치는 [memory gates](Verification/semantic-memory-20261108/memory-gates.json)와 [timing/quality 요약](Verification/semantic-memory-20261108/measurement-summary.json)에 모든 run을 남긴다. 같은 긴 입력의 진단에서 이전 physical peak는 261.079 MiB, 읽기 전용 표·3회 load/release는 약 34 MiB였다. 별도로 두 모델 모두 정확히 **512-token**인 입력도 3회 검사해 **33.235 MiB**를 관찰했다. 513-token은 E5 오류·관련성 nil로 거부하며 잘라내지 않는다. RSS는 Core ML load에 따라 여전히 수백 MiB가 될 수 있다.

최종 실행 파일 SHA-256을 고정한 M2 Debug 82질의 3회에서 physical peak는 **27.782–36.579 MiB**, RSS peak는 **529.688–546.062 MiB**였다. 해제 뒤 RSS는 **21.953–26.641 MiB**였다. p50은 **201.69–218.10 ms**, p95는 **295.48–362.47 ms**, 최대는 초기화·compile을 포함해 **3,103.43 ms**였다. 각 실행의 첫 요청을 통계에서 빼지 않았다. process-cold지만 OS/Core ML compiler cache까지 비운 실험은 아니다. 이전 622.625 MiB와 새 RSS 차이는 단일 baseline과 관찰 범위의 비교다. RSS 감소나 첫 실행 속도 개선율을 모든 실행에서 보장하지 않는다. Release 수치와 Debug 수치를 섞어 개선율을 계산하지 않는다.

| 최종 실기기 실행 | 전체 프로세스 peak physical footprint | v2 128 MiB | v1 RSS 128 MiB |
| --- | ---: | --- | --- |
| M2 Mac 원문 전환 검증 | 84.939 MiB | PASS | FAIL |
| iPhone 15 1회 | 123.955 MiB | PASS | FAIL |
| iPhone 15 2회 | 122.565 MiB | PASS | FAIL |
| iPhone 15 3회 | 120.315 MiB | PASS | FAIL |

이전 UI 순서의 127.221 MiB도 삭제하지 않았다. 최신 3회의 여유는 약 4.0–7.7 MiB로 작다. 한도 통과를 여유 있는 모든 기기 인증으로 표현하지 않는다.

같은 82질의·기존 추가 16질의에서 **반환 ID·코사인·관련성 점수가 이전 JSON과 모두 일치**했다. 963개 독립 토큰 기준도 통과했다. 한국어에 예외 질의 사전이나 cutoff 완화를 넣지 않았다. 기존 전체 품질 표의 hit/recall/precision·놓친 하천 질의는 그대로다.

실제 Mac에서는 한·영 검색, 배관 후보, 양자 질의 기각, 원문 이동, 기존 receipt, 새 sleep 관계의 취소·승인·재실행을 확인했다. 검색·취소 시 source hash는 같았고, 승인 뒤에는 표시한 `notes/sleep-ko.md`의 related 한 개만 바뀌었다. operation **E1E81A5B-AA62-407F-9DCC-7B1DBD676081**을 재실행 후 확인했다.

실제 iPhone에서는 bank 검색·현재 원문·이전 receipt, 핵융합/양자 기각·배관 후보를 확인했다. 별도의 새 coffee 관계에서 취소·정확한 승인·재실행 receipt **C715E7CB-A743-4157-9FE5-FB2E3D66B071**을 확인했다. QA의 기존 coffee-en 본문을 일반 편집기로 한국어 대조 문서로 준비했다. 개인 자료나 cloud admission 보호를 우회하지 않았다.

이후 변경은 검색 결과에서 원문을 여는 경로에 한정했다. 변경 후 Mac의 해당 전환과 iPhone 검색·기존 receipt 흐름을 다시 검사했다. 관계 prepare/apply/reject/history 코드는 변경 전과 byte 단위로 같고, 최종 SEMI의 정확한 승인·복구 회귀도 통과했다. [범위별 대조](Verification/semantic-memory-20261108/contract-review.json)를 따른다.

첫 iPhone 승인 시도는 목록 행을 탭한 뒤 detail로 전환되지 않아 `document-edit` assertion에서 실패했다. 원문 편집 전이었다. 기본 검색으로 대상 행을 고정한 재실행은 통과했다. 그 실패 `.xcresult`와 로그를 유지하며 첫 suite 전체를 PASS라고 부르지 않는다.

추가 iPhone 실행에서 한도에 가까운 **127.221 MiB**를 관찰했다. 이를 감추거나 그보다 큰 한도를 만들지 않았다. source 전환 전에 해제를 완료하도록 바꾼 뒤, 최종 동일 시나리오를 실제 기기에서 3회 반복했다. 해제 전후 trace는 남은 UI peak가 이미 모델을 해제한 뒤 전환 구간에서도 발생함을 보여 준다. UI framework 안의 정확한 할당 소유자는 이 trace만으로 단정하지 않는다. 최종 세 값과 과거 값은 모두 manifest에 보존한다.

## 7. 회귀·재현·남은 도입 조건

Root 전체 **282 PASS**(UI 164·Knowledge 36·Core 10·Agents 38·VaultImport 20·Development 14), 실제 SEMI **3 PASS**, 독립 SDK 호스트 build와 Core ML 직접 링크 없음 검사를 수행했다. 모델 누락·오류·취소·손상 cache·변경/삭제 source·source epoch·정책 migration·정확한 승인·불확실한 intent/committed receipt의 기존 회귀를 유지했다.

```sh
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
git lfs pull
python3 Tools/SemanticAssets/compile_tokenizer.py --check
swift test --scratch-path /tmp/folio-memory-build --no-parallel
swift build --scratch-path /tmp/folio-memory-build --product FolioSearchEvaluation
FOLIO_SEMANTIC_BIN="$(swift build --scratch-path /tmp/folio-memory-build --show-bin-path)"
FOLIO_SEMANTIC_MEMORY_TRACE=1 "$FOLIO_SEMANTIC_BIN/FolioSearchEvaluation" --semantic > evaluation.json 2> memory.jsonl
# 긴 입력·해제/재로딩: FolioSearchEvaluation --semantic-memory-probe --scenario joint --long --cycles 3
python3 Tools/SemanticAssets/verify_memory.py memory.jsonl
```

진단 env가 없으면 phase 출력·파일 쓰기를 하지 않는다. 켠 경우 `Library/Caches/FolioSemanticMemoryTrace.jsonl`에는 phase·monotonic time·프로세스 메모리 수치만 쓴다. 첫 기록에서 이전 실행 파일을 덮어쓴다. 원문·질의·문서 ID·source 경로는 기록하지 않는다. iPhone trace는 실제 앱 container에서 `devicectl device copy from`으로 회수했다.

추가 토큰 기준의 재생성은 `tokenizers==0.22.2`가 설치된 별도 Python 환경에서 `Tools/SemanticAssets/generate_conformance.py`로 수행한다. 제품 런타임은 Python·Hub·네트워크를 요구하지 않는다.

다음 일반 도입 조건은 새 동의 자료의 품질 평가, 512 section·긴 pair·큰 Markdown·다중 service, 기기별 반복 physical peak, 메모리 압박·배터리·열·background 전환 검증이다. 한 iPhone의 여유가 작다는 사실과 이 범위를 남긴다. 관계의 자동 쓰기나 미확정 작업의 재실행은 허용하지 않는다.

## 8. 후속 리팩터링 · 2026-11-08

- 여러 provider 인스턴스가 프로세스 안에서 모델별 단일 runtime을 공유한다. 각 provider의 사용권을 따로 관리하므로 한 창을 닫아도 다른 사용자의 모델을 임의로 해제하지 않는다. 두 모델의 무거운 동작은 공통 executor에서 직렬 실행한다.
- Core ML 예측·pooling을 `autoreleasepool`로 감싸 예측의 임시 객체를 그 범위에서 해제한다. 원본 weight·토큰·정규화·점수·cutoff는 그대로다. OS의 실제 memory-pressure 신호에는 자원을 비우고, 정상 신호 뒤 다시 사용할 수 있다. 테스트에 주입한 신호와 실제 OS 압박을 구별한다.
- refresh는 원문 scan과 해시 검증을 계속한다. 문서·stale 문서·규칙·진단·coverage까지 동일할 때 projection 재작성만 생략한다. 새 adapter, 외부 projection 변경, 강제 재색인과 scan 순서를 보존한다.
- vector 저장마다 전체 index item을 만들던 작업을 제거했다. 선택된 최대 512개 구간의 vector JSON만 읽고, 오래된 cache 삭제에는 큰 JSON 대신 식별자만 읽는다.
- 목록 발췌는 표시 전 길이를 제한하고, 변경 없는 Markdown은 다시 해석하지 않으며 reader 구간을 지연 구성한다. 전체 원문은 읽기·편집·승인 상세에서 유지한다.
- 큰 자료함·긴 실행의 보편적인 메모리·배터리·열 인증은 하지 않았다. 취소된 검증 범위를 완료라고 기록하지 않는다.
