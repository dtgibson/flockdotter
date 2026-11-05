import SwiftUI

/// Legal and privacy reading stays available without a connection or detector startup.
struct BundledHelpDocument: View {
    let title: String
    let resource: String
    let `extension`: String?
    private var content: String {
        guard let url = Bundle.main.url(forResource: resource, withExtension: `extension`),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return "This document is missing from this build. Please consult the source repository."
        }
        return text
    }
    var body: some View {
        ScrollView {
            Text(content).font(Design.font(14)).lineSpacing(5)
                .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 590, alignment: .leading).padding(24)
        }.background(Design.surface).foregroundStyle(Design.ink).navigationTitle(title)
    }
}
