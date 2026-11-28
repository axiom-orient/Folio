import Foundation
import FolioKnowledge

/// A workspace's one source mutation lane. Projection and adapter state remain derived.
public actor WikiWorkspace {
  public nonisolated let root: URL
  public nonisolated let workspaceID: UUID
  public let projection: WikiProjection
  let receiptDirectory: URL
  let knowledgeAccountScope: UUID?
  let managedLocalKnowledgeNamespace: UUID?
  private let scanOwnerID = UUID()
  private var scanGeneration: UInt64 = 0
  private var observedDocuments: [WikiDocument] = []
  private var sourceAccessClosed = false
  let validateSourceAccess: @Sendable () throws -> Void
  var proposalOperations = Set<String>()
  var trashDownloadRequests: [String: WikiTrashDownloadRequest] = [:]

  /// Read-only admission before a host acquires its workspace-scoped state lock.
  /// Creating the workspace later revalidates this identity against current bytes.
  public static func identity(at root: URL,
    validateSourceAccess: @Sendable () throws -> Void = {}
  ) throws -> UUID {
    try validateSourceAccess()
    let canonical = root.standardizedFileURL.resolvingSymlinksInPath()
    return try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: canonical,
      path: "_workspace.md", maximumBytes: 65536)).id
  }

  public init(root: URL, localStateDirectory: URL, knowledgeAccountScope: UUID? = nil,
    validateSourceAccess: @escaping @Sendable () throws -> Void = {}
  ) throws {
    try self.init(root: root, localStateDirectory: localStateDirectory, knowledgeAccountScope: knowledgeAccountScope,
      managedLocalKnowledgeNamespace: nil, validateSourceAccess: validateSourceAccess)
  }

  init(root: URL, localStateDirectory: URL, knowledgeAccountScope: UUID?,
    managedLocalKnowledgeNamespace: UUID?, validateSourceAccess: @escaping @Sendable () throws -> Void
  ) throws {
    self.knowledgeAccountScope = knowledgeAccountScope
    self.managedLocalKnowledgeNamespace = knowledgeAccountScope == nil ? managedLocalKnowledgeNamespace : nil
    self.validateSourceAccess = validateSourceAccess
    self.root = root.standardizedFileURL.resolvingSymlinksInPath()
    workspaceID = try Self.identity(at: self.root, validateSourceAccess: validateSourceAccess)
    let local = localStateDirectory.standardizedFileURL.resolvingSymlinksInPath()
    guard !local.path.hasPrefix(self.root.path + "/"), local != self.root else {
      throw WikiError.invalidPath("Derived state must be outside the source workspace.")
    }
    try WikiLocalStorage.createDirectory(local)
    receiptDirectory = local.appendingPathComponent("OperationReceipts", isDirectory: true)
    try WikiLocalStorage.createDirectory(receiptDirectory)
    projection = try WikiProjection(databaseURL: local.appendingPathComponent("knowledge.sqlite"))
  }

  public static func create(at root: URL, name: String, workspaceID: UUID = UUID()) throws {
    guard !name.contains("\0"), !name.isEmpty, name.utf8.count <= 512 else {
      throw WikiError.invalidSource("Expected a nonempty workspace name.")
    }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    for directory in ["notes", "attachments"] {
      try FileManager.default.createDirectory(at: root.appendingPathComponent(directory), withIntermediateDirectories: true)
    }
    // JSON quoted strings are valid YAML scalars, preserving arbitrary names safely.
    let quoted = String(decoding: try JSONEncoder().encode(name), as: UTF8.self)
    let text = "---\nid: \(workspaceID.uuidString.lowercased())\nkind: workspace\nschema: 1\nname: \(quoted)\n---\n"
    try CoordinatedFiles.write(root: root, path: "_workspace.md", expectedRevision: nil, bytes: Data(text.utf8))
  }

  /// All source I/O is synchronous on this actor. Closing is a barrier for the
  /// current I/O segment; suspended operations recheck admission before further access.
  public func close() { sourceAccessClosed = true }
  func requireOpen() throws {
    guard !sourceAccessClosed else { throw WikiError.unavailable("Workspace source access is closed.") }
    try validateSourceAccess()
    let identity = try WikiMarkdownParser.workspace(bytes: CoordinatedFiles.read(root: root, path: "_workspace.md", maximumBytes: 65536))
    guard identity.id == workspaceID else { throw WikiError.changedSource }
  }

  @discardableResult
  public func refresh() async throws -> WikiSnapshot {
    let previous = try await projection.snapshot()
    scanGeneration += 1
    let sequence = WikiScanSequence(ownerID: scanOwnerID, generation: scanGeneration)
    try requireOpen()
    let scan = try WikiWorkspaceScanner(root: root).scan(previous: (previous?.documents ?? []) + (previous?.staleDocuments ?? []))
    observedDocuments = scan.documents
    return try await projection.apply(scan, sequence: sequence)
  }

  public func read(_ reference: WikiEvidenceReference) throws -> String {
    try read([reference])[0]
  }

  public func source(relativePath: String) throws -> Data {
    try requireOpen()
    guard ["md", "markdown"].contains(URL(fileURLWithPath: relativePath).pathExtension.lowercased()) else {
      throw WikiError.invalidPath("Only Markdown source can be read through this API.")
    }
    return try CoordinatedFiles.read(root: root, path: relativePath)
  }

  public func addAttachment(filename: String, bytes: Data) throws -> String {
    try requireOpen()
    guard filename == URL(fileURLWithPath: filename).lastPathComponent, !filename.hasPrefix("."),
      bytes.count <= 50 * 1024 * 1024, !bytes.isEmpty else {
      throw WikiError.invalidSource("Expected a named attachment of at most 50 MiB.")
    }
    let path = try WikiPath.validate("attachments/\(UUID().uuidString.lowercased())-\(filename)")
    try CoordinatedFiles.write(root: root, path: path, expectedRevision: nil, bytes: bytes)
    return path
  }

  /// Caller retains the selected file's security scope until this method returns.
  public func addAttachment(fromSelectedURL url: URL) throws -> String {
    try requireOpen()
    let bytes = try CoordinatedFiles.readSelectedFile(at: url, maximumBytes: 50 * 1024 * 1024)
    return try addAttachment(filename: url.lastPathComponent, bytes: bytes)
  }

  public func requestSourceDownload(relativePath: String) throws {
    try requireOpen()
    let path = try WikiPath.validate(relativePath)
    guard path == "_ontology.md" || path.hasPrefix("notes/") || path.hasPrefix("attachments/") else {
      throw WikiError.invalidPath("Only workspace source can be downloaded.")
    }
    let url = root.appendingPathComponent(path)
    var componentURL = root
    for component in path.split(separator: "/") {
      componentURL.appendPathComponent(String(component))
      if let attributes = try? FileManager.default.attributesOfItem(atPath: componentURL.path),
        attributes[.type] as? FileAttributeType == .typeSymbolicLink {
        throw WikiError.invalidPath("Cannot download through a symbolic link.")
      }
    }
    try FileManager.default.startDownloadingUbiquitousItem(at: url)
  }

  /// Preview a bounded original-byte copy. Quick Look edits never silently change the source attachment.
  public func previewAttachment(relativePath: String) throws -> URL {
    try requireOpen()
    let path = try WikiPath.validate(relativePath)
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    guard path.hasPrefix("attachments/"),
      ["pdf", "png", "jpg", "jpeg", "gif", "heic", "tiff", "webp", "txt", "md", "csv", "json", "m4a", "mp3", "wav", "mp4", "mov"].contains(ext) else {
      throw WikiError.unavailable("This attachment format has no wiki preview.")
    }
    let bytes = try CoordinatedFiles.read(root: root, path: path, maximumBytes: 50 * 1024 * 1024)
    let digest = SourceDigest.sha256(bytes)
    let directory = receiptDirectory.deletingLastPathComponent()
      .appendingPathComponent("Previews", isDirectory: true).appendingPathComponent(digest, isDirectory: true)
    try WikiLocalStorage.createDirectory(directory)
    let name = Self.attachmentDisplayName(relativePath: path)
    let url = directory.appendingPathComponent(name)
    if !FileManager.default.fileExists(atPath: url.path) {
      try CoordinatedFiles.write(root: directory, path: name, expectedRevision: nil, bytes: bytes)
    } else {
      let cached = try CoordinatedFiles.read(root: directory, path: name, maximumBytes: 50 * 1024 * 1024)
      if SourceDigest.sha256(cached) != digest {
        try CoordinatedFiles.write(root: directory, path: name, expectedRevision: SourceDigest.sha256(cached),
          bytes: bytes, maximumExistingBytes: 50 * 1024 * 1024)
      }
    }
    return url
  }

  public static func attachmentDisplayName(relativePath: String) -> String {
    let name = URL(fileURLWithPath: relativePath).lastPathComponent
    guard UUID(uuidString: String(name.prefix(36))) != nil, name.dropFirst(36).first == "-" else { return name }
    let importedName = String(name.dropFirst(37))
    guard !importedName.isEmpty, importedName != ".", importedName != ".." else { return name }
    return importedName
  }

  public func operationStatus(_ operationID: UUID) throws -> WikiOperationStatus {
    let path = operationID.uuidString + ".json"
    if FileManager.default.fileExists(atPath: receiptDirectory.appendingPathComponent(path).path) {
      let receipt = try JSONDecoder().decode(WikiWriteReceipt.self,
        from: CoordinatedFiles.read(root: receiptDirectory, path: path, maximumBytes: 65536))
      guard receipt.operationID == operationID else { throw WikiError.database("Operation receipt identity mismatch.") }
      return WikiOperationStatus(operationID: operationID, state: .committed, receipt: receipt)
    }
    let hasIntent = FileManager.default.fileExists(atPath: receiptDirectory.appendingPathComponent(operationID.uuidString + ".intent.json").path)
    return WikiOperationStatus(operationID: operationID, state: hasIntent ? .uncertain : .notObserved, receipt: nil)
  }

  public func prepareEdit(relativePath: String, expectedRevision: String?, range: WikiSourceRange?,
    replacement: String, operationID: UUID
  ) async throws -> WikiPreparedEdit {
    let path = try WikiPath.validate(relativePath)
    guard path.hasPrefix("notes/"), ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased()),
      replacement.utf8.count <= 4 * 1024 * 1024 else {
      throw WikiError.invalidPath("Edits must target Markdown inside notes/.")
    }
    let snapshot = try await refresh()
    try requireOpen()
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(path))?.isEmpty != false else {
      throw WikiError.conflict(path)
    }
    guard !snapshot.ontologyUnavailable else { throw WikiError.unavailable("Resolve ontology errors before an approved edit.") }
    let oldBytes: Data
    if let expectedRevision {
      oldBytes = try CoordinatedFiles.read(root: root, path: path)
      guard SourceDigest.sha256(oldBytes) == expectedRevision else { throw WikiError.changedSource }
    } else {
      guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path), range == nil else { throw WikiError.changedSource }
      oldBytes = Data()
    }
    let newBytes: Data
    if let range {
      try WikiMarkdownParser.validate(range: range, bytes: oldBytes)
      newBytes = oldBytes.prefix(range.lowerBound) + Data(replacement.utf8) + oldBytes.suffix(from: range.upperBound)
    } else { newBytes = Data(replacement.utf8) }
    let newDocument = try WikiMarkdownParser.document(relativePath: path, bytes: newBytes)
    if expectedRevision == nil, newDocument.stableID == nil {
      throw WikiError.invalidSource("App-created notes require an explicit id.")
    }
    if expectedRevision != nil {
      let previous = try? WikiMarkdownParser.document(relativePath: path, bytes: oldBytes)
      let repairingDuplicate = snapshot.diagnostics.contains { $0.path == path && $0.reason == "duplicate_document_id" }
      if let stableID = previous?.stableID, newDocument.stableID != stableID, !repairingDuplicate {
        throw WikiError.invalidSource("A normal edit cannot change a stable document ID.")
      }
    }
    let knownPaths = Set(observedDocuments.map(\.relativePath))
    let candidates = observedDocuments + snapshot.documents.filter { !knownPaths.contains($0.relativePath) }
    let candidate = WikiSnapshot(workspace: snapshot.workspace,
      documents: candidates.filter { $0.relativePath != path } + [newDocument], ontology: snapshot.ontology)
    guard !candidate.diagnostics.contains(where: { $0.path == path }),
      candidate.documents.contains(where: { $0.id == newDocument.id && $0.relativePath == path }),
      candidate.relations.filter({ $0.sourceID == newDocument.id && $0.origin == .frontmatter }).allSatisfy({ $0.status == .valid }) else {
      throw WikiError.invalidSource("Edit introduces an invalid ID, type, or relation.")
    }
    return WikiPreparedEdit(operationID: operationID, workspaceID: snapshot.workspace.id,
      workspaceRevision: snapshot.revision, relativePath: path, expectedRevision: expectedRevision,
      resultRevision: newDocument.revision, replacementBytes: newBytes,
      before: String(decoding: oldBytes, as: UTF8.self), after: String(decoding: newBytes, as: UTF8.self))
  }

  /// An explicit human Save preserves even incomplete Markdown. Invalid metadata is
  /// diagnosed by refresh and excluded from certified relations/search, never discarded.
  public func prepareRawSave(relativePath: String, expectedRevision: String?, replacement: String,
    operationID: UUID
  ) async throws -> WikiPreparedEdit {
    let path = try WikiPath.validate(relativePath)
    let ontology = path == "_ontology.md"
    guard ontology || (path.hasPrefix("notes/") && ["md", "markdown"].contains(URL(fileURLWithPath: path).pathExtension.lowercased())),
      replacement.utf8.count <= (ontology ? 65536 : 256 * 1024), !replacement.contains("\0") else {
      throw WikiError.invalidSource("Raw Save requires notes/ Markdown (256 KiB) or _ontology.md (64 KiB).")
    }
    let snapshot = try await refresh()
    try requireOpen()
    guard NSFileVersion.unresolvedConflictVersionsOfItem(at: root.appendingPathComponent(path))?.isEmpty != false else {
      throw WikiError.conflict(path)
    }
    let old: Data
    if let expectedRevision {
      old = try CoordinatedFiles.read(root: root, path: path)
      guard SourceDigest.sha256(old) == expectedRevision else { throw WikiError.changedSource }
    } else {
      guard !FileManager.default.fileExists(atPath: root.appendingPathComponent(path).path) else { throw WikiError.changedSource }
      if !ontology {
        guard try WikiMarkdownParser.document(relativePath: path, bytes: Data(replacement.utf8)).stableID != nil else {
          throw WikiError.invalidSource("New notes require an explicit id.")
        }
      }
      old = Data()
    }
    let bytes = Data(replacement.utf8)
    return WikiPreparedEdit(operationID: operationID, workspaceID: snapshot.workspace.id,
      workspaceRevision: snapshot.revision, relativePath: path, expectedRevision: expectedRevision,
      resultRevision: SourceDigest.sha256(bytes), replacementBytes: bytes,
      before: String(decoding: old, as: UTF8.self), after: replacement)
  }

  public func execute(_ plan: WikiPreparedEdit, idempotencyKey: String? = nil) async throws -> WikiWriteReceipt {
    try await execute(plan, idempotencyKey: idempotencyKey, checkingEvidence: [])
  }

  /// Uses the same writer and receipt. Rechecks the cited originals after the
  /// editor's refresh and before recording intent for a new knowledge note.
  public func executeKnowledgeNote(_ plan: WikiPreparedEdit, evidence: [WikiKnowledgeEvidence]) async throws -> WikiWriteReceipt {
    guard !evidence.isEmpty, plan.expectedRevision == nil,
      try WikiMarkdownParser.isDerivedKnowledgeNote(bytes: plan.replacementBytes) else {
      throw WikiError.invalidSource("Expected a new note with verified knowledge evidence.")
    }
    return try await execute(plan, idempotencyKey: nil, checkingEvidence: evidence)
  }

  func execute(_ plan: WikiPreparedEdit, idempotencyKey: String?,
    checkingEvidence: [WikiKnowledgeEvidence], checkingConcepts: [String: WikiKnowledgeConceptBinding] = [:]
  ) async throws -> WikiWriteReceipt {
    try requireOpen()
    if let idempotencyKey {
      guard !idempotencyKey.isEmpty, idempotencyKey.utf8.count <= 256 else { throw WikiError.invalidSource("Invalid idempotency key.") }
    }
    let keyHash = idempotencyKey.map(SourceDigest.sha256)

    let receiptURL = receiptDirectory.appendingPathComponent(plan.operationID.uuidString + ".json")
    if FileManager.default.fileExists(atPath: receiptURL.path) {
      let receipt = try JSONDecoder().decode(WikiWriteReceipt.self,
        from: CoordinatedFiles.read(root: receiptDirectory, path: receiptURL.lastPathComponent, maximumBytes: 65536))
      guard receipt.operationID == plan.operationID, receipt.relativePath == plan.relativePath, receipt.sourceRevision == plan.resultRevision, receipt.idempotencyKeySHA256 == keyHash else {
        throw WikiError.conflict("Operation ID was already used for a different edit.")
      }
      return receipt
    }
    let current = try await refresh()
    try requireOpen()
    guard current.workspace.id == plan.workspaceID, current.revision == plan.workspaceRevision,
      SourceDigest.sha256(plan.replacementBytes) == plan.resultRevision else { throw WikiError.changedSource }
    try Task.checkCancellation()
    let intentName = plan.operationID.uuidString + ".intent.json"
    let intentURL = receiptDirectory.appendingPathComponent(intentName)
    guard !FileManager.default.fileExists(atPath: intentURL.path) else {
      throw WikiError.unavailable("Operation outcome is uncertain. Inspect source/receipts before a new approved operation.")
    }
    if !checkingEvidence.isEmpty {
      _ = try readKnowledgeEvidence(checkingEvidence)
      try Task.checkCancellation()
    }
    try validateKnowledgeConceptBindings(checkingConcepts)
    struct Intent: Encodable {
      let operationID: UUID; let workspaceID: UUID; let workspaceRevision: String
      let relativePath: String; let expectedRevision: String?; let resultRevision: String
      let idempotencyKeySHA256: String?
    }
    let intent = Intent(operationID: plan.operationID, workspaceID: plan.workspaceID,
      workspaceRevision: plan.workspaceRevision, relativePath: plan.relativePath,
      expectedRevision: plan.expectedRevision, resultRevision: plan.resultRevision, idempotencyKeySHA256: keyHash)
    // A crash after this marker can never cause an automatic replay of the same operation.
    try CoordinatedFiles.write(root: receiptDirectory, path: intentName, expectedRevision: nil,
      bytes: JSONEncoder().encode(intent))
    // From publication onward, cancellation cannot erase the observed durable effect.
    try CoordinatedFiles.write(root: root, path: plan.relativePath,
      expectedRevision: plan.expectedRevision, bytes: plan.replacementBytes,
      validateAccess: validateSourceAccess)
    let receipt = WikiWriteReceipt(operationID: plan.operationID, relativePath: plan.relativePath,
      previousRevision: plan.expectedRevision, sourceRevision: plan.resultRevision, idempotencyKeySHA256: keyHash,
      projectionUpdated: false, diagnostic: "Source committed; projection refresh is pending.")
    let initialReceiptBytes = try JSONEncoder().encode(receipt)
    try CoordinatedFiles.write(root: receiptDirectory, path: receiptURL.lastPathComponent,
      expectedRevision: nil, bytes: initialReceiptBytes)
    do {
      _ = try await refresh()
      let updated = WikiWriteReceipt(operationID: plan.operationID, relativePath: plan.relativePath,
        previousRevision: plan.expectedRevision, sourceRevision: plan.resultRevision, idempotencyKeySHA256: keyHash, projectionUpdated: true, diagnostic: nil)
      try CoordinatedFiles.write(root: receiptDirectory, path: receiptURL.lastPathComponent,
        expectedRevision: SourceDigest.sha256(initialReceiptBytes), bytes: JSONEncoder().encode(updated))
      return updated
    } catch { return receipt }
  }
}
