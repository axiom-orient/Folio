import Foundation

/// Only bytes cross the actor boundary. Tokens are restored with secure coding
/// and compared as objects; their serialized bytes are never used as identity.
package struct FolioSourceAdmission: Sendable {
  let accountID: UUID?
  private let tokenArchive: Data?
  private let hostAccess: FolioSourceAccess

  @MainActor init(location: FolioSourceLocation, root: URL, stateDirectory: URL, hostAccess: FolioSourceAccess) throws {
    self.hostAccess = hostAccess
    try hostAccess.validate()
    switch location {
    case .local:
      guard try root.resourceValues(forKeys: [.isUbiquitousItemKey]).isUbiquitousItem != true else {
        throw FolioError.accountUnavailable
      }
      accountID = nil; tokenArchive = nil
    case .iCloud(let container):
      guard !container.isEmpty, let cloud = FileManager.default.url(forUbiquityContainerIdentifier: container),
        root.path.hasPrefix(cloud.standardizedFileURL.resolvingSymlinksInPath().path + "/"),
        let token = FileManager.default.ubiquityIdentityToken, token is any NSSecureCoding else {
        throw FolioError.accountUnavailable
      }
      accountID = try FolioCloudIdentity.accountID(for: token, directory: stateDirectory.appendingPathComponent("Accounts"),
        sdkRecovery: { try FolioRecoveryScope.cloudAccounts(in: stateDirectory, registryMissing: $0) })
      tokenArchive = try Self.archiveCloudToken(token)
      try validate()
    }
  }

  func validate() throws {
    try hostAccess.validate()
    guard let tokenArchive else { return }
    try Self.validateCloudToken(tokenArchive)
  }

  package static func cloudValidator(for token: (any NSObjectProtocol)?) throws -> @Sendable () throws -> Void {
    guard let token else { throw FolioError.accountUnavailable }
    let archive = try archiveCloudToken(token)
    try validateCloudToken(archive)
    return { try validateCloudToken(archive) }
  }

  private static func archiveCloudToken(_ token: any NSObjectProtocol) throws -> Data {
    guard token is any NSSecureCoding else { throw FolioError.accountUnavailable }
    return try NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
  }

  private static func validateCloudToken(_ tokenArchive: Data) throws {
    guard let current = FileManager.default.ubiquityIdentityToken, current is any NSSecureCoding else {
      throw FolioError.accountUnavailable
    }
    let classes: [AnyClass] = [type(of: current as AnyObject), NSData.self, NSString.self,
      NSNumber.self, NSDate.self, NSUUID.self, NSArray.self, NSDictionary.self]
    let restored = try NSKeyedUnarchiver.unarchivedObject(ofClasses: classes, from: tokenArchive)
    guard let restored = restored as? any NSObjectProtocol,
      current.isEqual(restored), restored.isEqual(current) else { throw FolioError.accountUnavailable }
  }
}
