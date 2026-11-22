import FolioKnowledge

/// Explains the observed relation without treating an unconstrained link as certification.
struct FolioRelationDetail {
  let status: String
  let explanation: String

  init(relation: WikiRelation) {
    switch relation.status {
    case .valid:
      status = "대상 문서 확인됨"
      explanation = relation.origin == .frontmatter && relation.ontologyRevision != nil
        ? "선택한 연결은 자료함의 유형 규칙에 맞습니다. 내용의 사실 여부를 인증한 것은 아닙니다."
        : "대상 문서를 찾았습니다. 이 연결에는 별도 유형 규칙 검증이 적용되지 않았습니다."
    case .invalid:
      status = "관계 규칙 확인 필요"
      explanation = "원문에 선언한 관계의 이름 또는 두 문서의 유형이 자료함의 관계 규칙에 맞지 않습니다."
    case .unresolved:
      status = "연결 확인 필요"
      explanation = relation.diagnostic == "ontology_unavailable"
        ? "자료함의 관계 규칙을 읽을 수 없어 연결을 검증하지 못했습니다."
        : "대상 문서가 없거나 같은 식별자를 사용하는 문서가 있어 대상을 정할 수 없습니다."
    }
  }
}
