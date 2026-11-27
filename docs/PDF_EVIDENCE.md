# 스캔 PDF·표·수식의 원문 근거

Folio의 **PDF·노트 근거 찾기**에서 검색한다. 본문은 텍스트이고 표나 수식만 이미지인 PDF도 검색할 수 있다. 이미지에서 찾은 결과는 **스캔 인식**으로 표시한다. 출처를 열면 PDF 원본 페이지에서 해당 줄이나 영역을 강조한다. 숫자, 부호, 단위는 원문과 대조할 수 있다.

## 구현 순서

1. **텍스트와 이미지 분리.** PDFKit으로 현재 원본의 페이지 텍스트를 읽는다. 본문이 있는 페이지는 Quartz가 확인한 실제 이미지 그리기 영역만 잘라 렌더링한다. 텍스트가 없는 스캔 페이지는 전체 페이지를 사용한다. Apple Vision에 제공되는 한국어·영어 설정으로 기기에서 인식한다. [Quartz PDF 분석](https://developer.apple.com/library/archive/documentation/GraphicsImaging/Conceptual/drawingwithquartz2d/dq_pdf_scan/dq_pdf_scan.html)
2. **겹치는 텍스트 정리.** 같은 위치에서 문자열이 일치하는 기존 줄·단어는 기존 텍스트로 한 번만 색인한다. 같은 OCR 줄 안의 고유한 단어는 그 단어의 영역을 유지한다. 대소문자·소수점·부호는 비교에 포함한다. 반복 정렬이 분명한 표의 행, 나란히 배치된 열, 짧은 수식 줄은 각 영역으로 묶는다. [Vision 문자열의 영역](https://developer.apple.com/documentation/vision/vnrecognizedtext/boundingbox(for:))
3. **출처 확인.** 재생성 가능한 색인에 원본 버전과 추출 방식, 페이지, 인식 영역, 범위를 기록한다. 검색 결과를 내보낼 때, 링크를 열 때, 새 근거 노트를 확정할 때 현재 자료함의 원본과 연결 노트를 검사하고 해당 인용의 이미지 영역만 다시 인식한다. 원본·문자열·좌표를 재검증한 뒤 미리보기를 제공한다.
4. **저장.** 사용자의 기존 **노트로 저장**이 별도 근거 노트를 만든다. 새 영역 인용을 구별해 같은 쪽의 여러 행이나 수식도 각자 열 수 있다. 이전 페이지 인용은 기존 위치로 연다. 원문 쓰기 승인과 불확실한 저장 결과 조회는 기존 경로를 사용한다.

## 추출 방식 비교

| 방식 | 확인 가능한 것 | 적용 범위 |
| --- | --- | --- |
| PDFKit 페이지 텍스트 | 원본이 가진 문자열과 페이지 번호. 텍스트 레이어가 없는 이미지 페이지에서는 글자를 얻지 못한다. | 기존 인용에 계속 사용한다. 새 검색에서는 확인할 수 있는 세부 위치가 부족할 때 페이지 텍스트를 보존한다. [PDFKit](https://developer.apple.com/documentation/pdfkit/pdfpage) |
| Vision OCR | 이미지 속 문자의 추정 문자열과 위치. 한국어 모델과 이미지의 해상도·기울기에 따라 결과가 달라질 수 있다. | 이미지 페이지 또는 혼합 페이지의 실제 이미지 영역에서 검색할 문자열을 만든다. 렌더링 변환의 역변환으로 원본 PDF의 cropBox 좌표에 대응시킨다. [Vision 텍스트 인식](https://developer.apple.com/documentation/vision/vnrecognizetextrequest) · [Quartz PDF 좌표 변환](https://developer.apple.com/documentation/coregraphics/cgpdfpage/getdrawingtransform(_:rect:rotate:preserveaspectratio:)) |
| Folio의 위치 기반 묶음 | 반복 정렬이 분명한 표 행, 평행 열, 읽을 수 있는 수식 줄. 같은 페이지의 다른 행과 구별된 좌표. | 원래 문자열과 실제 좌표를 유지하며 병합 셀·헤더·수학적 관계는 가정하지 않는다. 회전된 이미지 페이지는 인식 위치를 되돌려 표시하고 행·열 grouping은 적용하지 않는다. [PDFKit 줄 선택](https://developer.apple.com/documentation/pdfkit/pdfselection/selectionsbyline()) |
| Apple의 문서 구조 API, Docling, LiteParse | Apple 구조 API에는 표·셀 정보가 있다. Docling은 별도 수식 인식 단계를 제공한다. LiteParse의 OCR 모델은 한국어 인식기와 별도 레이아웃 단계를 제공한다. | API와 공개 구현을 조사했다. 이번 비교 실행은 Folio의 이전 PDFKit 경로와 새 OCR·좌표 경로를 대상으로 한다. 복잡한 문서에서 도입하려면 동일한 인용의 자료 버전과 좌표까지 검증해야 한다. [Apple 표 예제](https://developer.apple.com/documentation/vision/recognize-tables-within-a-document) · [Docling 수식 추출](https://docling-project.github.io/docling/usage/enrichments/#formula-understanding) · [LiteParse](https://github.com/run-llama/liteparse) · [OCRia 모델 카드](https://huggingface.co/llamaindex/OCRia-nano-1) |

KoViDoRe는 한국어 표·그림·다단의 페이지 검색을 포함하며 OmniDocBench는 텍스트·표·수식을 별도 지표로 평가한다. Folio에서 검색할 페이지를 찾는지와 그 페이지의 글자를 정확히 읽는지는 각각 확인한다. 외부 공개 점수는 Folio 측정값과 별개다. [KoViDoRe](https://aclanthology.org/2026.magmar-main.11/) · [OmniDocBench](https://github.com/opendatalab/OmniDocBench)

## 적용 범위

- 혼합 페이지는 원문에 그려진 래스터 이미지의 사각 범위를 확인할 수 있을 때 해당 부분을 인식한다. 이미지 형태가 아닌 벡터 윤곽선, 위치를 확정하기 어려운 기울어진 이미지와 비사각형 잘림, 분석 한도를 넘은 페이지에서는 일부 내용이 빠질 수 있다. 확인된 영역과 기존 본문은 검색에 남긴다.
- 표는 찾은 행의 내용과 위치를 제공한다. 수식은 읽을 수 있는 기호·식별자·관련 문장으로 찾는다. 복잡한 표 구조, 수식의 LaTeX 변환·대수적 동치, 손글씨의 전사 품질은 별도 범위다.
- 각 이미지 영역은 한 변 최대 2,200픽셀, 8비트 회색으로 한 번에 하나씩 렌더링한다. 원본 PDF의 50 MiB 읽기 한도를 사용하며 취소는 페이지와 인식 요청 사이에 확인한다. 래스터 외에 PDF 디코딩과 Vision 작업 메모리도 필요하다.
- 파일은 그대로인데 OS의 인식 결과가 달라진 경우에도 과거 영역 인용과 동일하다고 확정할 수 없으면 다시 검색한다. 일시적인 OCR 실패는 같은 PDF의 읽을 수 있는 페이지를 숨기지 않으며 추출 재사용 대상으로 확정하지 않는다.

[앱 화면](../Sources/FolioUI/FolioKnowledgeQueryView.swift) · [페이지 추출](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiPDFExtraction.swift) · [원문 검증](../Vendor/KnowledgeKit/Sources/KnowledgeKitApple/WikiKnowledgeSources.swift)

## 비교 실행과 결과 · 2026-11-27

| 대표 자료 | 기존 경로 | 새 경로에서 확인한 결과 |
| --- | --- | --- |
| 이미지로만 구성된 한글 실험 기록 PDF | PDFKit은 이미지가 있는 2쪽에서 빈 텍스트를 반환했다. | ‘실험’ 검색으로 2쪽의 인식된 줄이 나왔다. 영역은 문자를 그린 위치 안에 있었고 미리보기의 PDF 바이트가 원본과 일치했다. 위조 좌표와 교체된 PDF는 거부했다. [스캔 회귀](../Tests/FolioKnowledgeTests/PDFScannedEvidenceTests.swift) |
| 세 행의 표와 수식이 있는 텍스트 PDF | 페이지 텍스트에는 다른 행도 함께 있었다. | 표 검색 결과는 해당 행의 셀 세 개와 `42 percent`를 포함했고 다른 행의 값은 빠졌다. 수식은 2쪽의 단일 영역을 열었다. [표·수식 회귀](../Tests/FolioKnowledgeTests/PDFLocalizedEvidenceTests.swift) |
| 같은 페이지의 수식 두 개를 담은 저장 노트 | 기존 저장 링크는 쪽수를 기록했다. | 새 노트에서 각 인용이 같은 쪽의 서로 다른 영역을 열었다. 이전 페이지 링크의 열기, 원본 교체 거부, 저장 준비 후 원본이 바뀐 경우도 함께 통과했다. [저장·재열기 회귀](../Tests/FolioUITests/KnowledgeNoteTests.swift) |

선택한 macOS SwiftPM 회귀 **8개**와 iOS 시뮬레이터 대상 앱 빌드가 통과했다. 검증 범위는 위 자동화 사례와 빌드이며 앱과 실기기는 실행하지 않았다.

## 혼합 PDF 확인 · 2026-11-27

원점이 이동된 cropBox에 본문과 라벨·표·수식 이미지 세 개를 배치한 PDF를 사용했다. 기존 PDFKit 경로는 본문과 투명 라벨을 읽었다. 새 경로는 페이지 내부의 이미지 세 영역만 선택했다. 겹친 `CONTROL LABEL`은 본문 근거에 한 번 남았고, 같은 줄의 이미지에만 있는 `COMPANION`은 OCR 결과에 남았다.

표의 `COBALT`와 수식의 `ENERGY`는 각각 다른 이미지 영역으로 검색됐다. 검색 결과와 저장 노트에서 얻은 PDF의 페이지와 좌표가 각 인용마다 일치했고, 좌표는 cropBox 원점을 반영한 기대 위치 안에 있었다. 미리보기에 전달된 바이트와 자료함에 보관된 바이트를 원본과 대조했다. [혼합 PDF 회귀](../Tests/FolioUITests/KnowledgeNoteTests.swift)

혼합 PDF, 이미지 전용 스캔, 텍스트 표·수식, 기존 저장 인용, 저장 직전 원본 교체를 포함한 **핵심 회귀 6개**와 **iOS 시뮬레이터 대상 빌드**가 통과했다. 원문이나 승인·복구 처리에는 지역 OCR이 추가 쓰기를 만들지 않는다. 이번 검증은 자동화와 빌드에서 수행했다.
