import CoreML
import Foundation
import FolioKnowledge

package enum SemanticTensor {
  package static func input(tokens: [Int], length: Int) throws -> MLDictionaryFeatureProvider {
    guard (1...512).contains(length), tokens.count <= length, tokens.allSatisfy({ (0...250001).contains($0) }) else {
      throw WikiError.invalidSource("Token tensor budget exceeded or token ID invalid.")
    }
    let ids = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    let mask = try MLMultiArray(shape: [1, NSNumber(value: length)], dataType: .int32)
    ids.withUnsafeMutableBufferPointer(ofType: Int32.self) { values, strides in
      for i in 0..<length { values[i * strides[1]] = i < tokens.count ? Int32(tokens[i]) : 1 }
    }
    mask.withUnsafeMutableBufferPointer(ofType: Int32.self) { values, strides in
      for i in 0..<length { values[i * strides[1]] = i < tokens.count ? 1 : 0 }
    }
    return try MLDictionaryFeatureProvider(dictionary: ["input_ids": ids, "attention_mask": mask])
  }

  /// Read Core ML storage only inside its scoped buffer, honoring strides.
  /// Keep the original Double accumulation order and L2 normalization.
  package static func pooled(_ hidden: MLMultiArray, tokens: Int, dimensions: Int) throws -> [Double] {
    guard hidden.dataType == .float32, hidden.shape == [1, NSNumber(value: tokens), NSNumber(value: dimensions)], tokens > 0, dimensions > 0 else {
      throw WikiError.invalidSource("Unexpected multilingual model output.")
    }
    let strides = hidden.strides.map(\.intValue)
    var vector = [Double](repeating: 0, count: dimensions)
    try hidden.withUnsafeBufferPointer(ofType: Float.self) { values in
      guard strides.count == 3, strides.allSatisfy({ $0 > 0 }),
        (tokens - 1) * strides[1] + (dimensions - 1) * strides[2] < values.count else {
        throw WikiError.invalidSource("Unexpected multilingual model strides.")
      }
      for t in 0..<tokens {
        for d in 0..<dimensions { vector[d] += Double(values[t * strides[1] + d * strides[2]]) }
      }
    }
    let norm = sqrt(vector.reduce(0) { $0 + $1 * $1 })
    guard norm.isFinite, norm > 0 else { throw WikiError.invalidSource("Invalid multilingual model vector.") }
    return vector.map { $0 / norm }
  }
}
