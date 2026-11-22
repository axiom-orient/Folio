---
id: folio-research-evidence
tags: [research, writing]
---

# 근거를 남기는 연구 노트

연구 노트의 목적은 나중에 결론을 다시 검토할 수 있도록 관찰, 해석, 다음 행동을 연결하는 것이다. 좋은 문서는 결론만 모으지 않고 어떤 자료에서 무엇을 확인했는지도 남긴다.

## 관찰과 해석을 구분하기

원문에서 직접 읽은 내용에는 출처와 위치를 적는다. 그 내용에서 도출한 해석에는 전제와 아직 확인하지 못한 조건을 함께 적는다. 해석이 달라져도 원문과 이전 판단을 지우지 않으면 다른 사람이 변화의 이유를 이해할 수 있다.

예를 들어 Swift 패키지는 다른 앱에 코드를 제공할 수 있지만, 패키지를 가져오는 것만으로 호스트 앱에 iCloud 권한이 생기지는 않는다. 전자는 패키지 구조에 관한 사실이고 후자는 앱의 서명과 권한 설정에 관한 사실이다. 두 경계를 구분해야 통합 계획을 정확히 세울 수 있다.

## 문서에서 행동으로 연결하기

자료를 수집한 다음에는 질문을 한 문장으로 좁힌다. 무엇을 관찰하면 현재 가설을 버릴 것인지 정하고, 조사 결과에는 확인한 범위와 남은 불확실성을 함께 기록한다. 검증을 통과하지 않은 목표를 이미 구현된 기능처럼 표현하지 않는다.

SDK의 책임 분담은 [Swift SDK 통합 원칙](swift-sdk-boundaries.md), 변경 검토와 복구 절차는 [팀 문서 운영 절차](document-review.md)에서 이어서 읽을 수 있다.

## 참고 자료

- [Swift Package Manager의 의존성 정의](https://docs.swift.org/swiftpm/documentation/packagemanagerdocs/addingdependencies/)
- [Apple의 iCloud 설정 안내](https://developer.apple.com/documentation/xcode/configuring-icloud-services/)
