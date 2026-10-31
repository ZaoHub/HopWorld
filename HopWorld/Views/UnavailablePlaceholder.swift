import SwiftUI

/// macOS 13 可用的空态占位，替代 ContentUnavailableView。
struct UnavailablePlaceholder<Description: View, Actions: View>: View {
    var title: String
    var systemImage: String
    @ViewBuilder var description: () -> Description
    @ViewBuilder var actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.title3.weight(.semibold))
            description()
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            actions()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

extension UnavailablePlaceholder where Description == EmptyView, Actions == EmptyView {
    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
        self.description = { EmptyView() }
        self.actions = { EmptyView() }
    }
}

extension UnavailablePlaceholder where Actions == EmptyView {
    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder description: @escaping () -> Description
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = { EmptyView() }
    }
}

extension UnavailablePlaceholder {
    init(
        _ title: String,
        systemImage: String,
        @ViewBuilder description: @escaping () -> Description,
        @ViewBuilder actions: @escaping () -> Actions
    ) {
        self.title = title
        self.systemImage = systemImage
        self.description = description
        self.actions = actions
    }
}
