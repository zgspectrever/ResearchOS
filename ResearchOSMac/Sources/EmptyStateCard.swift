import SwiftUI

struct EmptyStateCard<Actions: View>: View {
    let title: String
    let message: String
    let symbol: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack {
            VStack(spacing: 16) {
                Image(systemName: symbol).font(.system(size: 34, weight: .medium)).foregroundStyle(.blue)
                Text(title).font(.title3.weight(.semibold))
                Text(message).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 360)
                HStack(spacing: 10) { actions() }
            }
            .padding(.horizontal, 36).padding(.vertical, 32)
            // Keep the empty state light and content-led; the surrounding workspace
            // already provides enough hierarchy without another framed container.
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
    }
}
