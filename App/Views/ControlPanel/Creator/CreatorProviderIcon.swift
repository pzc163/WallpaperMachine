import SwiftUI

struct CreatorProviderIcon: View {
    let name: String?
    var body: some View {
        Group {
            if let name { Image("Provider-" + name).resizable().scaledToFit() }
            else { Image(systemName: "cpu").resizable().scaledToFit().foregroundStyle(.secondary) }
        }.frame(width: 20, height: 20).accessibilityHidden(true)
    }
}
