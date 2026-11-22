import Foundation
import Yams

public struct WikiOntology: Codable, Hashable, Sendable {
  public struct Constraint: Codable, Hashable, Sendable {
    public let from: Set<String>
    public let to: Set<String>
  }
  public let revision: String
  public let types: Set<String>
  public let relations: [String: Constraint]

  public init(bytes: Data) throws {
    let fields = try Frontmatter.read(SourceText(bytes)).fields
    guard let kind = fields["kind"], try Frontmatter.string(kind) == "ontology" else {
      throw WikiError.invalidSource("Expected kind: ontology.")
    }
    let typeFields = try fields["types"].map(Frontmatter.mapping) ?? [:]
    types = Set(typeFields.keys)
    for node in typeFields.values { _ = try Frontmatter.mapping(node) }
    var constraints: [String: Constraint] = [:]
    for (predicate, node) in try fields["relations"].map(Frontmatter.mapping) ?? [:] {
      let declaration = try Frontmatter.mapping(node)
      guard let source = declaration["from"], let target = declaration["to"] else {
        throw WikiError.invalidSource("Relation \(predicate) needs from/to arrays.")
      }
      let from = Set(try Frontmatter.strings(source)); let to = Set(try Frontmatter.strings(target))
      guard !from.isEmpty, !to.isEmpty, from.isSubset(of: types), to.isSubset(of: types) else {
        throw WikiError.invalidSource("Relation \(predicate) refers to missing/empty types.")
      }
      constraints[predicate] = Constraint(from: from, to: to)
    }
    relations = constraints; revision = SourceDigest.sha256(bytes)
  }
}
