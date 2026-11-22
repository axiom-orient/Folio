import SwiftUI

enum FolioTheme {
  static func paper(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0x232528 : 0xFAFAF7) }
  static func accent(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xB7C8AC : 0x4F6B50) }
  static func muted(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xA8ACAE : 0x626B66) }
  static func text(_ scheme: ColorScheme) -> Color { color(scheme == .dark ? 0xF0F1ED : 0x272C2A) }
  static func typeName(_ type: String?) -> String {
    switch type {
    case "project": "프로젝트"
    case "technology": "기술"
    case "project_hub": "프로젝트 모음"
    case "resource": "참고 자료"
    case "area": "분야"
    case "personal": "개인 자료"
    case "moc": "목차"
    case "project-draft": "기획 초안"
    case "research": "리서치"
    case "collection": "자료 모음"
    case "document", nil: "문서"
    case .some(let value): value
    }
  }
  private static func color(_ value: UInt32) -> Color {
    Color(red: Double((value >> 16) & 255) / 255, green: Double((value >> 8) & 255) / 255, blue: Double(value & 255) / 255)
  }
}

/// An open book for reading and writing, with a bookmark for keeping useful documents.
/// The app icon renderer uses this same two-page silhouette at every size.
struct FolioBrandMark: View {
  var body: some View {
    FolioBookShape().fill(style: FillStyle(eoFill: true))
      .aspectRatio(1.6, contentMode: .fit).accessibilityHidden(true)
  }
}
struct FolioBookShape: Shape {
  func path(in rect: CGRect) -> Path {
    var path = Path()
    path.move(to: CGPoint(x: 4, y: 6))
    path.addCurve(to: CGPoint(x: 29.5, y: 9), control1: CGPoint(x: 14, y: 2), control2: CGPoint(x: 21, y: 4))
    path.addLine(to: CGPoint(x: 29.5, y: 37))
    path.addCurve(to: CGPoint(x: 4, y: 34), control1: CGPoint(x: 20, y: 32), control2: CGPoint(x: 13, y: 30))
    path.closeSubpath()

    path.move(to: CGPoint(x: 34.5, y: 9))
    path.addCurve(to: CGPoint(x: 60, y: 6), control1: CGPoint(x: 43, y: 4), control2: CGPoint(x: 51, y: 2))
    path.addLine(to: CGPoint(x: 60, y: 34))
    path.addCurve(to: CGPoint(x: 34.5, y: 37), control1: CGPoint(x: 51, y: 30), control2: CGPoint(x: 44, y: 32))
    path.closeSubpath()

    // Negative space keeps the bookmark legible in the icon and monochrome UI mark.
    path.move(to: CGPoint(x: 45, y: 8))
    path.addLine(to: CGPoint(x: 52, y: 8))
    path.addLine(to: CGPoint(x: 52, y: 22))
    path.addLine(to: CGPoint(x: 48.5, y: 18.5))
    path.addLine(to: CGPoint(x: 45, y: 22))
    path.closeSubpath()

    return path.applying(CGAffineTransform(scaleX: rect.width / 64, y: rect.height / 40))
      .applying(CGAffineTransform(translationX: rect.minX, y: rect.minY))
  }
}
