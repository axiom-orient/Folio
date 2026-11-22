#if os(macOS)
import Foundation

enum SkillSourceResolver {
  struct Resolved: Sendable {
    let directory: URL
    let revision: String?
    let temporary: URL?
    func cleanup() { if let temporary { try? FileManager.default.removeItem(at: temporary) } }
  }

  static func resolve(_ source: SkillSource) async throws -> Resolved {
    switch source {
    case .local(let directory):
      guard directory.isFileURL else { throw SkillError.invalid("로컬 원본 폴더를 선택해 주세요.") }
      return Resolved(directory: directory.standardizedFileURL, revision: nil, temporary: nil)
    case .git(let repository, let reference, let subdirectory):
      try validate(repository: repository, reference: reference, subdirectory: subdirectory)
      let temporary = FileManager.default.temporaryDirectory.appendingPathComponent("FolioSkill-" + UUID().uuidString, isDirectory: true)
      try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
      do {
        let checkout = temporary.appendingPathComponent("repository", isDirectory: true)
        let environment = ["GIT_TERMINAL_PROMPT": "0", "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false",
          "GIT_SSH_COMMAND": "/usr/bin/ssh -oBatchMode=yes -oStrictHostKeyChecking=yes"]
        func git(_ arguments: [String], at directory: URL? = nil) async throws -> String {
          let result = try await AgentCommand.run(executable: URL(fileURLWithPath: "/usr/bin/git"),
            arguments: ["-c", "core.hooksPath=/dev/null", "-c", "protocol.ext.allow=never"] + arguments,
            directory: directory, environment: environment)
          guard result.status == 0 else {
            // Git errors may echo credential-bearing helper output. Keep it out of UI/receipts.
            throw SkillError.invalid("Git 원본을 가져오지 못했습니다. 저장소·ref와 기존 Git/SSH 인증을 확인해 주세요. 인증 창은 열지 않습니다.")
          }
          return result.output.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        _ = try await git(["clone", "--no-checkout", "--filter=blob:none", "--", repository, checkout.path])
        let ref = reference.isEmpty ? "HEAD" : reference
        // Resolve the requested branch, tag, or commit into one immutable commit.
        let revision: String
        do { revision = try await git(["rev-parse", "--verify", "--end-of-options", ref + "^{commit}"], at: checkout) }
        catch is CancellationError { throw CancellationError() }
        catch { revision = try await git(["rev-parse", "--verify", "--end-of-options", "refs/remotes/origin/" + ref + "^{commit}"], at: checkout) }
        guard revision.count == 40 || revision.count == 64, revision.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else {
          throw SkillError.invalid("Git commit을 확인하지 못했습니다.")
        }
        _ = try await git(["-c", "advice.detachedHead=false", "checkout", "--detach", revision, "--"], at: checkout)
        let directory = subdirectory.isEmpty || subdirectory == "." ? checkout : checkout.appendingPathComponent(subdirectory, isDirectory: true)
        // Each component, including parents of a selected subdirectory, must stay inside the checkout.
        let prefix = checkout.standardizedFileURL.path + "/"
        guard directory.resolvingSymlinksInPath().path == checkout.path || directory.resolvingSymlinksInPath().path.hasPrefix(prefix) else {
          throw SkillError.invalid("스킬 경로가 저장소 밖을 가리킵니다.")
        }
        var path = checkout
        for component in subdirectory.split(separator: "/") where component != "." {
          path.appendPathComponent(String(component))
          guard try path.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw SkillError.invalid("Git 스킬 경로에 심볼릭 링크가 있습니다.") }
        }
        // Repository roots need their own name; SkillFiles validates the manifest's folder name.
        if directory == checkout {
          let data = try SkillIO.read(checkout.appendingPathComponent("SKILL.md"), limit: SkillManifest.byteLimit)
          let name = try SkillManifest.sourceName(data)
          let renamed = temporary.appendingPathComponent(name, isDirectory: true)
          if checkout != renamed { try FileManager.default.moveItem(at: checkout, to: renamed) }
          return Resolved(directory: renamed, revision: revision, temporary: temporary)
        }
        return Resolved(directory: directory, revision: revision, temporary: temporary)
      } catch {
        try? FileManager.default.removeItem(at: temporary)
        throw error
      }
    }
  }

  private static func validate(repository: String, reference: String, subdirectory: String) throws {
    guard !repository.isEmpty, !repository.hasPrefix("-"), !repository.contains(where: { $0.isWhitespace }),
      !reference.hasPrefix("-"), !reference.contains(where: { $0.isNewline || $0 == "\0" }),
      !subdirectory.hasPrefix("/"), !subdirectory.contains("\\"), !subdirectory.split(separator: "/").contains("..") else {
      throw SkillError.invalid("저장소 URL·ref·저장소 내부 상대 경로를 확인해 주세요.")
    }
    if let url = URLComponents(string: repository), let scheme = url.scheme, repository.contains("://") {
      guard ["https", "ssh", "file"].contains(scheme), url.password == nil, url.query == nil, url.fragment == nil,
        (scheme != "https" || url.user == nil), (scheme == "file" || !(url.host ?? "").isEmpty) else {
        throw SkillError.invalid("인증정보가 없는 HTTPS/SSH Git URL을 사용해 주세요. 인증은 기존 Git 설정으로 처리합니다.")
      }
    } else {
      guard repository.hasPrefix("git@"), repository.contains(":"), !repository.contains("//") else {
        throw SkillError.invalid("HTTPS URL 또는 git@host:owner/repository.git 형식을 사용해 주세요.")
      }
    }
  }
}
#endif
