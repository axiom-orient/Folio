import CoreSpotlight
import Foundation
import FolioKnowledge
import UniformTypeIdentifiers

public actor WikiSpotlight {
  private let projection: WikiProjection
  private let workspaceID: UUID
  private let indexName: String
  private let registeredIndex: CSSearchableIndex
  private let indexDelegate: WikiSpotlightDelegate
  private var applying = false
  public private(set) var state = "notIndexed"

  public init(projection: WikiProjection, workspaceID: UUID) {
    self.projection = projection; self.workspaceID = workspaceID
    indexName = "Folio.\(workspaceID.uuidString.lowercased())"
    let delegate = WikiSpotlightDelegate(projection: projection)
    let index = Self.makeIndex(name: "Folio.\(workspaceID.uuidString.lowercased())")
    index.indexDelegate = delegate
    registeredIndex = index; indexDelegate = delegate
  }

  static func makeIndex(name: String) -> CSSearchableIndex {
    #if os(iOS)
    return CSSearchableIndex(name: name, protectionClass: WikiLocalStorage.protection)
    #else
    return CSSearchableIndex(name: name)
    #endif
  }

  /// One worker per adapter instance, including across actor suspension points.
  public func applyPendingJobs(maximumBatches: Int = 10) async throws {
    guard !applying else { return }
    guard CSSearchableIndex.isIndexingAvailable() else {
      state = "unavailable"; throw WikiError.unavailable("Core Spotlight is unavailable.")
    }
    applying = true; state = "indexing"; defer { applying = false }
    do {
      let index = Self.makeIndex(name: indexName)
      let storeID = Data((try await projection.storeID() + "/spotlight-v2").utf8)
      let previousState = try await index.fetchLastClientState()
      if previousState != storeID {
        // A replaced/deleted projection has a new identity: discard orphaned system items.
        try await index.deleteSearchableItems(withDomainIdentifiers: [workspaceID.uuidString.lowercased()])
        try await projection.requestReindex(adapter: "spotlight")
      }
      for _ in 0..<max(1, maximumBatches) {
        try Task.checkCancellation()
        let jobs = try await projection.pendingJobs(adapter: "spotlight")
        guard !jobs.isEmpty else { break }
        for job in jobs {
          try Task.checkCancellation()
          guard try await projection.isCurrent(job) else { continue }
          do {
            if let item = job.item, job.operation == .upsert {
              try await index.indexSearchableItems([Self.searchableItem(item)])
            } else { try await index.deleteSearchableItems(withIdentifiers: [job.subjectID]) }
            if try await projection.isCurrent(job) { try await projection.acknowledge(job) }
            else {
              // Another process may have applied a newer job while this OS call
              // was outstanding. Requeue its latest desired state to repair a late donation.
              try await projection.requestReindex(adapter: "spotlight", subjects: [job.subjectID])
            }
          } catch {
            try await projection.acknowledge(job, error: error.localizedDescription)
            throw error
          }
        }
      }
      guard Data((try await projection.storeID() + "/spotlight-v2").utf8) == storeID else { throw WikiError.changedSource }
      // Client state identifies the projection, not a promise that the entire backlog is empty.
      index.beginBatch()
      try await index.endIndexBatch(expectedClientState: previousState == storeID ? previousState : nil, newClientState: storeID)
      state = try await projection.pendingJobs(adapter: "spotlight", limit: 1).isEmpty ? "ready" : "indexing"
    } catch { state = "degraded: \(error.localizedDescription)"; throw error }
  }

  public func search(_ text: String, limit: Int = 100) async throws -> [String] {
    guard !text.isEmpty, text.utf8.count <= 512, (1...500).contains(limit) else {
      throw WikiError.invalidSource("Invalid Spotlight query/limit.")
    }
    guard CSSearchableIndex.isIndexingAvailable() else { throw WikiError.unavailable("Core Spotlight is unavailable.") }
    let context = CSUserQueryContext()
    context.enableRankedResults = true; context.maxResultCount = limit; context.maxRankedResultCount = limit
    context.filterQueries = ["com_axient_folio_workspace == \"\(workspaceID.uuidString.lowercased())\""]
    let query = CSUserQuery(userQueryString: text, userQueryContext: context)
    #if os(iOS)
    query.protectionClasses = [WikiLocalStorage.protection]
    #endif
    let cancellation = SpotlightQueryCancellation(query)
    defer { cancellation.cancel() }
    let prefix = workspaceID.uuidString.lowercased() + "/"
    return try await withTaskCancellationHandler {
      var ids: [String] = []
      for try await response in query.responses {
        try Task.checkCancellation()
        if case .item(let item) = response, item.item.uniqueIdentifier.hasPrefix(prefix) {
          ids.append(String(item.item.uniqueIdentifier.dropFirst(prefix.count)))
        }
        if ids.count >= limit { break }
      }
      return ids
    } onCancel: { cancellation.cancel() }
  }

  public static func searchableItem(_ item: WikiIndexItem) -> CSSearchableItem {
    let attributes = CSSearchableItemAttributeSet(contentType: .text)
    if let key = CSCustomAttributeKey(keyName: "com_axient_folio_workspace", searchable: true,
      searchableByDefault: false, unique: true, multiValued: false) {
      attributes.setValue(item.workspaceID.uuidString.lowercased() as NSString, forCustomKey: key)
    }
    attributes.title = item.title
    attributes.textContent = item.searchText
    attributes.contentDescription = String(item.searchText.prefix(512))
    var link = URLComponents(); link.scheme = "folio"; link.host = "open"
    link.queryItems = [URLQueryItem(name: "workspace", value: item.workspaceID.uuidString),
      URLQueryItem(name: "document", value: item.documentID), URLQueryItem(name: "section", value: item.sectionID),
      URLQueryItem(name: "revision", value: item.sourceRevision)]
    attributes.contentURL = link.url
    return CSSearchableItem(uniqueIdentifier: item.id,
      domainIdentifier: item.workspaceID.uuidString.lowercased(), attributeSet: attributes)
  }
}

/// Core Spotlight permits cancelling an in-flight query. The immutable bridge
/// limits cross-executor access to that documented cancellation operation.
private final class SpotlightQueryCancellation: @unchecked Sendable {
  private let query: CSUserQuery
  init(_ query: CSUserQuery) { self.query = query }
  func cancel() { query.cancel() }
}
