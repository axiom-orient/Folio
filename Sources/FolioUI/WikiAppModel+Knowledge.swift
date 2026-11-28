import Foundation
import FolioKnowledge
import FolioKnowledgeApple

/// Only a pending knowledge-note submission is retained. A retry observes that
/// exact writer operation instead of creating another note.
@MainActor final class FolioKnowledgeSaves {
  struct Key: Hashable {
    let root: URL
    let workspaceID: UUID
    let recoveryScope: URL
    let question: String
    let evidence: [WikiKnowledgeEvidence]
  }
  var submissions: [Key: FolioSubmittedDocument] = [:]
  var working: Set<Key> = []
}

extension WikiAppModel {
  /// Saving is an explicit source write. Search itself never writes a note.
  @discardableResult public func saveKnowledgeAnswer(_ answer: WikiKnowledgeAnswer, in window: WikiWindowState) async -> Bool {
    guard hasOpenWorkspace, let workspace, let recoveryScope = draftStore.recoveryScopeURL else {
      message = "자료함을 다시 열어 주세요."
      return false
    }
    guard !isBusy, !answer.evidence.isEmpty else {
      message = "저장할 근거와 현재 작업 상태를 확인해 주세요."
      return false
    }
    let generation = workspaceGeneration
    let key = FolioKnowledgeSaves.Key(root: workspace.root, workspaceID: workspace.workspaceID,
      recoveryScope: recoveryScope, question: answer.question, evidence: answer.evidence)
    guard knowledgeSaves.working.insert(key).inserted else {
      message = "같은 근거 노트를 저장하고 있습니다."
      return false
    }
    defer { knowledgeSaves.working.remove(key) }
    message = nil

    // An earlier write may already have succeeded even if its source has since
    // changed. Observe that saved historical note before rechecking a new write.
    if let pending = knowledgeSaves.submissions[key] {
      switch await pending.observe(in: workspace) {
      case .committed:
        guard generation == workspaceGeneration, hasOpenWorkspace else { return false }
        let opened = await openCreatedDocument(pending.confirmed(), in: window, editing: false)
        if opened { knowledgeSaves.submissions.removeValue(forKey: key); message = nil }
        return opened
      case .notObserved:
        knowledgeSaves.submissions.removeValue(forKey: key)
        if generation == workspaceGeneration { message = "이전 저장이 반영되지 않았습니다. ‘노트로 저장’을 눌러 다시 저장하세요." }
        return false
      case .uncertain(let diagnostic):
        if generation == workspaceGeneration { message = "저장 결과를 확인하고 있습니다. 같은 노트를 다시 만들지 않았습니다. " + diagnostic }
        return false
      }
    }

    let checkStartedAt = Date()
    do {
      try Task.checkCancellation()
      _ = try await workspace.readKnowledgeEvidence(answer.evidence)
      guard generation == workspaceGeneration, hasOpenWorkspace else { return false }
      let content = try FolioKnowledgeNote.content(answer, sourceCheckStartedAt: checkStartedAt, sourceCheckFinishedAt: Date())
      try Task.checkCancellation()
      guard generation == workspaceGeneration, hasOpenWorkspace else { return false }
      let created = await createDocument(in: window, title: content.title, body: content.body,
        additionalFrontmatter: content.frontmatter, knowledgeEvidence: answer.evidence)
      guard let created else { return false }
      // Keep the submitted identity even if switching workspaces prevented
      // presentation. The creator only returns a confirmed or uncertain write.
      knowledgeSaves.submissions[key] = created
      guard generation == workspaceGeneration, hasOpenWorkspace, created.wasObserved else { return false }
      if window.selectedDocumentID == created.id, drafts[created.id] != nil {
        knowledgeSaves.submissions.removeValue(forKey: key)
        message = nil
        return true
      }
      return false
    } catch {
      guard generation == workspaceGeneration else { return false }
      if (error as? WikiError) == .changedSource {
        message = "원문이 바뀌었습니다. 근거를 다시 찾은 뒤 저장해 주세요."
      } else { message = "근거를 저장하지 못했습니다. " + error.localizedDescription }
      return false
    }
  }
}

/// IDs and byte/page provenance remain in frontmatter. The body contains the
/// question, literal quotations and usable source links, without truth claims.
enum FolioKnowledgeNote {
  struct Content { let title: String; let body: String; let frontmatter: String }
  private struct Provenance: Encodable {
    let version = 1
    let question: String
    let checkedAt: Date
    let sourceCheckStartedAt: Date
    let sourceCheckFinishedAt: Date
    let atomicSnapshot: Bool
    let evidence: [Item]
    struct Item: Encodable {
      let evidence: WikiKnowledgeEvidence
      let producer: String?
    }
  }

  static func content(_ answer: WikiKnowledgeAnswer, sourceCheckStartedAt: Date, sourceCheckFinishedAt: Date) throws -> Content {
    guard !answer.evidence.isEmpty else { throw WikiError.invalidSource("저장할 근거가 없습니다.") }
    let provenance = Provenance(question: answer.question, checkedAt: answer.checkedAt,
      sourceCheckStartedAt: sourceCheckStartedAt, sourceCheckFinishedAt: sourceCheckFinishedAt,
      atomicSnapshot: answer.atomicSnapshot, evidence: answer.evidence.map {
        Provenance.Item(evidence: $0, producer: $0.pdfRegion?.producer ?? ($0.source.kind == .pdf ? WikiPDFExtractor.identifier : nil))
      })
    let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys; encoder.dateEncodingStrategy = .iso8601
    let scalar = try WikiMarkdownEditor.jsonMetadataScalar(encoder.encode(provenance))
    let frontmatter = "folio_knowledge_note: true\nfolio_knowledge_provenance: " + scalar + "\n"
    let placeholderID = "00000000-0000-0000-0000-000000000000"
    guard ("---\nid: " + placeholderID + "\n" + frontmatter + "---\n").utf8.count <= 65_536 else {
      throw WikiError.invalidSource("근거의 출처 정보가 저장 가능한 크기를 넘습니다. 근거 수를 줄여 저장해 주세요.")
    }
    let question = answer.question.components(separatedBy: .newlines).joined(separator: " ")
    var title = "근거 · "
    for character in question {
      if title.utf8.count + String(character).utf8.count > 480 { break }
      title.append(character)
    }
    var parts = ["## 질문\n\n" + WikiMarkdownEditor.literalInline(answer.question)]
    for evidence in answer.evidence {
      parts.append(try evidence.savedCitationMarkdown(from: "notes/saved.md"))
    }
    let body = parts.joined(separator: "\n\n") + "\n"
    guard FolioInput.documentSource(id: placeholderID, title: title, body: body,
      additionalFrontmatter: frontmatter).utf8.count <= 256 * 1024 else {
      throw WikiError.invalidSource("근거 노트가 저장 가능한 크기를 넘습니다. 근거 수를 줄여 저장해 주세요.")
    }
    return Content(title: title, body: body, frontmatter: frontmatter)
  }
}

extension WikiAppModel {
  @discardableResult func saveKnowledgeConcept(name: String, aliases: [String], domain: String,
    evidence: WikiKnowledgeEvidence, existing: WikiKnowledgeConceptRecord? = nil) async -> Bool {
    let identity: String
    do { identity = "concept:" + SourceDigest.sha256(try JSONEncoder().encode([name, domain, existing?.concept.id ?? ""] + aliases)) }
    catch { message = error.localizedDescription; return false }
    let label: WikiConceptLabel
    if let current = existing?.concept.labels.first {
      label = .init(language: current.language, preferred: current.preferred,
        aliases: Array(Set([name] + aliases)).filter { $0 != current.preferred }.sorted())
    } else { label = .init(language: "und", preferred: name, aliases: aliases) }
    let concept = WikiKnowledgeConcept(id: existing?.concept.id ?? UUID().uuidString.lowercased(), domain: domain,
      labels: [label], mentions: [.init(evidence: evidence)])
    return await saveKnowledgeRecord(identity: identity, evidence: [evidence], prepare: { workspace in
      if existing == nil {
        let inventory = try await workspace.knowledgeConceptInventory()
        let names = Set([name] + aliases)
        if let identical = inventory.records.first(where: { record in
          record.concept.state == .accepted && record.concept.domain == domain
            && record.concept.labels.contains { Set([$0.preferred] + $0.aliases).isSuperset(of: names) }
            && record.concept.mentions.contains { $0.evidence == evidence }
        }) {
          _ = try await workspace.readKnowledgeConcept(id: identical.concept.id)
          return .existing
        }
      }
      let plan = try await workspace.prepareKnowledgeConcept(concept, relativePath: existing?.relativePath,
        expectedRevision: existing?.revision, operationID: UUID())
      return .edit(id: concept.id, plan: plan)
    }, execute: { workspace, plan in try await workspace.executeKnowledgeConcept(plan) })
  }

  @discardableResult func saveKnowledgeAssertion(_ assertion: WikiKnowledgeAssertion,
    existing: WikiKnowledgeAssertionRecord? = nil, expectedConceptRevisions: [String: String]? = nil) async -> Bool {
    do {
      let digest = try assertion.contentDigest()
      let identity = "assertion:" + (existing?.assertion.id ?? "new") + ":" + digest
      return await saveKnowledgeRecord(identity: identity, evidence: assertion.allEvidence, prepare: { workspace in
        if existing == nil {
          if try await workspace.matchingKnowledgeAssertion(assertion) != nil { return .existing }
        }
        let plan = try await workspace.prepareKnowledgeAssertion(assertion, relativePath: existing?.relativePath,
          expectedRevision: existing?.revision, expectedConceptRevisions: expectedConceptRevisions,
          operationID: UUID())
        return .edit(id: assertion.id, plan: plan)
      }, execute: { workspace, plan in try await workspace.executeKnowledgeAssertion(plan) })
    } catch { message = error.localizedDescription; return false }
  }

  private enum KnowledgePreparation {
    case existing
    case edit(id: String, plan: WikiPreparedEdit)
  }

  /// One UI submission owner for sourced records. Retrying observes the same operation before fresh reads.
  private func saveKnowledgeRecord(identity: String, evidence: [WikiKnowledgeEvidence],
    prepare: (WikiWorkspace) async throws -> KnowledgePreparation,
    execute: (WikiWorkspace, WikiPreparedEdit) async throws -> WikiWriteReceipt
  ) async -> Bool {
    guard hasOpenWorkspace, let workspace, let recoveryScope = draftStore.recoveryScopeURL, !isBusy else { return false }
    let key = FolioKnowledgeSaves.Key(root: workspace.root, workspaceID: workspace.workspaceID,
      recoveryScope: recoveryScope, question: identity, evidence: evidence)
    guard knowledgeSaves.working.insert(key).inserted else { return false }
    let generation = workspaceGeneration
    isBusy = true; message = nil
    defer {
      knowledgeSaves.working.remove(key)
      if generation == workspaceGeneration { isBusy = false }
    }
    if let pending = knowledgeSaves.submissions[key] {
      switch await pending.observe(in: workspace) {
      case .committed:
        knowledgeSaves.submissions.removeValue(forKey: key)
        if generation == workspaceGeneration { await refresh() }
        return generation == workspaceGeneration && hasOpenWorkspace
      case .notObserved:
        knowledgeSaves.submissions.removeValue(forKey: key)
        if generation == workspaceGeneration { message = "이전 저장은 반영되지 않았습니다. 저장을 눌러 다시 시도해 주세요." }
      case .uncertain(let diagnostic):
        if generation == workspaceGeneration { message = "저장 결과를 확인하고 있습니다. " + diagnostic }
      }
      return false
    }
    do {
      let prepared = try await prepare(workspace)
      guard generation == workspaceGeneration, hasOpenWorkspace else { return false }
      try Task.checkCancellation()
      switch prepared {
      case .existing: return true
      case .edit(let id, let plan):
        let submission = FolioSubmittedDocument(id: id, plan: plan, sourceRoot: workspace.root)
        knowledgeSaves.submissions[key] = submission
        do { _ = try await execute(workspace, plan) }
        catch {
          switch await submission.observe(in: workspace) {
          case .committed: break
          case .notObserved:
            knowledgeSaves.submissions.removeValue(forKey: key)
            throw error
          case .uncertain(let diagnostic):
            if generation == workspaceGeneration { message = "저장 결과를 확인하고 있습니다. " + diagnostic }
            return false
          }
        }
        knowledgeSaves.submissions[key] = nil
        guard generation == workspaceGeneration, hasOpenWorkspace else { return false }
        await refresh()
        return generation == workspaceGeneration && hasOpenWorkspace
      }
    } catch {
      if generation == workspaceGeneration {
        message = (error as? WikiError) == .changedSource
          ? "원문이나 연결한 개념이 바뀌었습니다. 근거를 다시 확인한 뒤 저장해 주세요." : error.localizedDescription
      }
      return false
    }
  }
}
