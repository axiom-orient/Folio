import Foundation

/// All SDK state belongs to this host. Construction performs no I/O or migration.
public struct FolioConfiguration: Sendable {
  public let stateDirectory: URL
  public let namespace: String
  public let sourceAccess: FolioSourceAccess

  public init(stateDirectory: URL, namespace: String, sourceAccess: FolioSourceAccess = FolioSourceAccess()) throws {
    guard stateDirectory.isFileURL, stateDirectory.path.hasPrefix("/"),
      !namespace.isEmpty, namespace.utf8.count <= 200,
      namespace.utf8.allSatisfy({ (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45, 46, 95].contains($0) }) else {
      throw FolioError.invalidConfiguration
    }
    self.stateDirectory = try FolioStatePaths.canonicalDirectoryLocation(stateDirectory)
    self.namespace = namespace
    self.sourceAccess = sourceAccess
  }
}

/// Cloud access is opt-in. The SDK binds the live iCloud Documents token; the host
/// cannot substitute an account name or treat a workspace UUID as account identity.
public enum FolioSourceLocation: Sendable, Equatable {
  case local
  case iCloud(containerIdentifier: String)
}

public struct FolioDocument: Identifiable, Sendable, Equatable {
  public let id: String
  public let title: String
  public let relativePath: String
  public let revision: String
}

public struct FolioWorkspaceSnapshot: Sendable {
  public let id: UUID
  public let name: String
  public let documents: [FolioDocument]
  public let diagnostics: [String]
  public let coverageComplete: Bool
}

public struct FolioSearchResult: Identifiable, Sendable {
  public var id: String { documentID + ":" + sectionID }
  public let documentID: String
  public let sectionID: String
  public let title: String
  public let excerpt: String
}

public struct FolioSaveReceipt: Sendable {
  public let operationID: UUID
  public let sourceRevision: String
  public let diagnostic: String?
}

public enum FolioSaveOutcome: Sendable {
  case committed(FolioSaveReceipt)
  case notObserved
  case uncertain
}

public enum FolioError: Error, LocalizedError, Equatable {
  case invalidConfiguration, sourceStateOverlap, busy, noWorkspace, noDocument
  case changedSource, accountUnavailable, recoveryDamaged, stateInUse, noChanges
  case pendingSave(UUID)
  case documentIdentityChanged

  public var errorDescription: String? {
    switch self {
    case .invalidConfiguration: "호스트의 상태 폴더와 고유 namespace를 지정해 주세요."
    case .sourceStateOverlap: "원문과 SDK 상태 폴더는 서로 포함하지 않는 별도 위치여야 합니다."
    case .busy: "진행 중인 작업이 끝난 뒤 다시 시도해 주세요."
    case .noWorkspace: "자료함을 먼저 열어 주세요."
    case .noDocument: "문서를 먼저 선택해 주세요."
    case .changedSource: "원문이나 자료함이 변경됐습니다. 초안을 보존했으니 원문을 다시 확인해 주세요."
    case .accountUnavailable: "iCloud 계정을 안전하게 확인할 수 없습니다. 원문과 초안을 보존했습니다."
    case .recoveryDamaged: "복구 정보를 읽거나 보관할 수 없습니다. 기존 복구 파일은 보존했습니다."
    case .stateInUse: "다른 세션이 같은 SDK 복구 상태를 사용하고 있습니다."
    case .documentIdentityChanged: "일반 저장에서는 문서 ID를 바꿀 수 없습니다. 편집 내용은 초안으로 보존했습니다."
    case .noChanges: "저장할 변경이 없습니다."
    case .pendingSave(let id): "저장 결과를 먼저 확인해 주세요 (\(id)). 초안은 보존됐습니다."
    }
  }
}

/// Immutable evidence for an explicit conflict review. Only its originating
/// session/context may adopt it, and adoption checks the source again.
public struct FolioSourceReview: Sendable {
  public let documentID: String
  public let relativePath: String
  public let revision: String
  public let text: String
  let contextID: UUID
  let selectionID: UUID
}

/// Capture this when presenting an editor. Native input and asynchronous UI
/// commands must keep this target instead of following a later selection.
public struct FolioEditingTarget: Sendable, Hashable {
  public let documentID: String
  let contextID: UUID
  let selectionID: UUID
}
