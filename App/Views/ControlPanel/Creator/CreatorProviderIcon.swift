import SwiftUI

struct CreatorProviderIcon: View {
    let name: String?
    var body: some View {
        Group {
            if name == "minicpm" { Text(verbatim: "M").font(.system(size: 16, weight: .semibold, design: .rounded)) }
            else if let name { Image("Provider-" + name).resizable().scaledToFit() }
            else { Image(systemName: "cpu").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
