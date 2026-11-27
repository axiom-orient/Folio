import Foundation
import FolioKnowledge
import FolioKnowledgeApple

extension WikiAppModel {
  func openMarkdownLink(_ link: String, from document: WikiDocument, in window: WikiWindowState) async {
    guard hasOpenWorkspace, let workspace, let path = WikiPath.resolveLink(link, from: document.relativePath) else { return }
    let navigation = window.beginNavigation()
    let generation = workspaceGeneration
    func citationIsCurrent() -> Bool {
      !Task.isCancelled && hasOpenWorkspace && generation == workspaceGeneration
        && navigation == window.navigationGeneration && window.selectedDocumentID == document.id
    }
    let fragment = link.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).dropFirst().first.map(String.init)
    let pathExtension = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ["md", "markdown"].contains(pathExtension), fragment?.hasPrefix(WikiKnowledgeLocation.markdownCitationPrefix) ?? true {
      do {
        let verified = try await workspace.previewSavedKnowledgeMarkdown(notePath: document.relativePath,
          noteRevision: document.revision, sourcePath: path, fragment: fragment)
        guard citationIsCurrent() else { return }
        if let verified {
          window.savedCitation = .init(documentID: document.id, workspaceGeneration: generation,
            content: .markdown(verified.document, sectionID: verified.sectionID, location: verified.location))
          return
        }
      } catch {
        if citationIsCurrent() { message = "저장한 Markdown 인용 위치를 확인할 수 없습니다. 자료에서 근거를 다시 찾아 주세요." }
        return
      }
    }
    if path.hasPrefix("attachments/") {
      if pathExtension == "pdf", let citation = Self.citedPDFPage(fragment) {
        do {
          let verified = try await workspace.previewSavedKnowledgePDF(notePath: document.relativePath,
            noteRevision: document.revision, attachmentPath: path, pageIndex: citation.index, evidenceID: citation.evidenceID)
          guard citationIsCurrent() else { return }
          if let verified {
            window.savedCitation = .init(documentID: document.id, workspaceGeneration: generation, content: .pdf(verified))
            return
          }
        } catch {
          if citationIsCurrent() { message = "저장한 PDF 인용 위치를 확인할 수 없습니다. 자료에서 근거를 다시 찾아 주세요." }
          return
        }
      } else if pathExtension == "pdf", fragment?.contains("&folio-quote=") == true {
        message = "저장한 PDF 인용 위치를 확인할 수 없습니다. 자료에서 근거를 다시 찾아 주세요."
        return
      }
      await previewAttachment(path: path)
      return
    }
    guard let target = snapshot?.documents.first(where: { $0.relativePath == path }) else {
      message = "연결된 문서를 찾지 못했습니다. 자료함의 원문과 다운로드 상태를 확인해 주세요."; return
    }
    do {
      let bytes = try await workspace.source(relativePath: path)
      guard generation == workspaceGeneration, navigation == window.navigationGeneration else { return }
      guard SourceDigest.sha256(bytes) == target.revision else { throw WikiError.changedSource }
      window.selectMarkdownLink(link, document: target)
      await loadSelection(window)
    } catch { if generation == workspaceGeneration, navigation == window.navigationGeneration { message = error.localizedDescription } }
  }

  public func openLink(_ url: URL, in window: WikiWindowState) async {
    guard ["folio", "sourcewiki"].contains(url.scheme), let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return }
    if workspace == nil { await restore(); guard workspace != nil else { return } }
    let query = Dictionary(components.queryItems?.map { ($0.name, $0.value ?? "") } ?? [], uniquingKeysWith: { first, _ in first })
    guard let workspaceID = query["workspace"].flatMap(UUID.init(uuidString:)), workspaceID == snapshot?.workspace.id,
      let documentID = query["document"], let document = snapshot?.documents.first(where: { $0.id == documentID }),
      document.revision == query["revision"] else { message = "근거가 변경되었거나 다른 작업 공간에 있습니다. 다시 검색해 주세요."; return }
    guard let section = document.sections.first(where: { $0.id == query["section"] }) else {
      message = "근거 section을 다시 검색해 주세요."; return
    }
    await selectEvidence(WikiEvidenceReference(workspaceID: workspaceID, document: document, section: section), in: window)
  }

  public func openHit(_ hit: WikiSearchHit, in window: WikiWindowState) async { _ = await openSearchHit(hit, in: window) }

  func openSearchHit(_ hit: WikiSearchHit, in window: WikiWindowState) async -> Bool {
    await selectEvidence(hit.reference, in: window)
  }

  func openSemanticEvidence(_ reference: WikiEvidenceReference, in window: WikiWindowState) async {
    _ = await selectEvidence(reference, in: window)
  }

  @discardableResult private func selectEvidence(_ reference: WikiEvidenceReference, in window: WikiWindowState) async -> Bool {
    let generation = workspaceGeneration
    do { return try await navigateToEvidence(reference, in: window) }
    catch is CancellationError {}
    catch { if hasOpenWorkspace, generation == workspaceGeneration { message = error.localizedDescription } }
    return false
  }

  private static func citedPDFPage(_ fragment: String?) -> (index: Int, evidenceID: String?)? {
    guard let fragment, fragment.hasPrefix("page=") else { return nil }
    let fields = fragment.components(separatedBy: "&folio-quote=")
    guard fields.count <= 2, let first = fields.first,
      let page = Int(first.dropFirst("page=".count)), page > 0 else { return nil }
    if fields.count == 1 { return (page - 1, nil) }
    let id = fields[1]
    guard id.utf8.count == 64, id.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
      return nil
    }
    return (page - 1, id)
  }

  private func navigateToEvidence(_ reference: WikiEvidenceReference, in window: WikiWindowState) async throws -> Bool {
    guard hasOpenWorkspace, let workspace else { return false }
    let generation = workspaceGeneration
    let navigation = window.beginNavigation()
    func isCurrent() -> Bool {
      !Task.isCancelled && hasOpenWorkspace && generation == workspaceGeneration
        && navigation == window.navigationGeneration
    }
    do {
      _ = try await workspace.read(reference)
    } catch {
      guard isCurrent() else { return false }
      throw error
    }
    guard isCurrent(),
      window.completeNavigation(navigation, documentID: reference.documentID, sectionID: reference.sectionID) else { return false }
    window.readingAnchors[reference.documentID] = reference.sectionID
    window.isEditing = false
    await loadSelection(window)
    return !Task.isCancelled && hasOpenWorkspace && generation == workspaceGeneration
      && window.selectedDocumentID == reference.documentID && window.selectedSectionID == reference.sectionID
  }
}
