import Darwin
import Foundation
import FolioVaultImport

@main enum FolioVaultImportCLI {
  static func main() {
    do {
      let arguments = Array(CommandLine.arguments.dropFirst())
      if arguments == ["--help"] || arguments == ["help"] || arguments.isEmpty { print(help); return }
      let result = try VaultImporter.run(parse(arguments))
      let output: [String: Any] = ["workspace": result.workspace.path,
        "workspaceID": result.workspaceID.uuidString.lowercased(), "manifest": result.manifest.path,
        "markdown": result.markdown, "files": result.files, "convertedWikiLinks": result.convertedWikiLinks,
        "parentRelations": result.parentRelations, "unresolved": result.unresolved]
      let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys, .withoutEscapingSlashes])
      try FileHandle.standardOutput.write(contentsOf: data + Data([0x0A]))
    } catch {
      let message = (error as? VaultImportError)?.localizedDescription ?? "가져오기를 완료하지 못했습니다. 입력 파일과 출력 폴더 접근 권한을 확인하세요."
      try? FileHandle.standardError.write(contentsOf: Data("FolioVaultImport: \(message)\n".utf8))
      exit(1)
    }
  }

  private static func parse(_ arguments: [String]) throws -> VaultImportRequest {
    var paths: [String] = []; var options: [String: String] = [:]; var index = 0
    while index < arguments.count {
      let value = arguments[index]
      guard !value.isEmpty, !value.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
        throw VaultImportError.invalid("비어 있거나 제어 문자가 있는 인수는 사용할 수 없습니다.")
      }
      if value.hasPrefix("-") {
        guard ["--evidence", "--name"].contains(value), options[value] == nil,
          index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-"), !arguments[index + 1].isEmpty,
          !arguments[index + 1].unicodeScalars.contains(where: CharacterSet.controlCharacters.contains) else {
          throw VaultImportError.invalid("알 수 없거나 중복된 옵션입니다. 각 옵션 뒤에 값 하나를 지정하세요. --help를 확인하세요.")
        }
        options[value] = arguments[index + 1]; index += 2
      } else { paths.append(value); index += 1 }
    }
    guard paths.count == 2, let evidence = options["--evidence"] else {
      throw VaultImportError.invalid("SOURCE DEST와 --evidence EVIDENCE가 필요합니다. --help를 확인하세요.")
    }
    return VaultImportRequest(source: url(paths[0]), destination: url(paths[1]), evidence: url(evidence),
      name: options["--name"] ?? "ProjectVault")
  }

  private static func url(_ path: String) -> URL {
    URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true).standardizedFileURL
  }

  private static let help = """
  FolioVaultImport — Markdown 자료함을 원본 보존과 증거 사본을 포함해 가져오기

  사용: FolioVaultImport SOURCE DEST --evidence EVIDENCE [--name ProjectVault]

  SOURCE는 Markdown 원본 폴더이며 DEST와 EVIDENCE는 서로 겹치지 않는 새 폴더여야 합니다.
  Markdown은 notes/projectvault/, 다른 파일은 attachments/projectvault/에 배치합니다.
  EVIDENCE의 originals/에 원본 바이트를 보존하고 import-manifest.json에 해시·변환·미해결 링크를 기록합니다.
  숨김 항목은 제외하고 심볼릭 링크는 거부합니다. 기존 id·relations는 자동으로 덮어쓰지 않습니다.
  제한: 파일 10,000개, 전체 256 MiB, Markdown 문서당 256 KiB·UTF-8.
  결과는 JSON, 실패는 표준 오류로 출력합니다. 원본 파일은 변경하지 않습니다.
  """
}
