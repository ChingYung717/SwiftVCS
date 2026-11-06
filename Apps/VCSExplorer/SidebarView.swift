import SwiftUI

struct SidebarView: View {
    @EnvironmentObject private var model: AppModel

    private func badgeText(for tab: SidebarTab) -> String? {
        switch tab {
        case .history:
            guard !model.logs.isEmpty else { return nil }
            return model.hasMoreLogs ? "\(model.logs.count)+" : "\(model.logs.count)"
        case .changes:
            let count = model.pendingChangesCount
            return count > 0 ? "\(count)" : nil
        case .browse:
            guard !model.entries.isEmpty else { return nil }
            return "\(model.entries.count)"
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // 顶部 GitHub Desktop 风格三页签切换栏
            HStack(spacing: 4) {
                ForEach(SidebarTab.allCases) { tab in
                    let isSelected = model.sidebarTab == tab
                    Button {
                        model.selectSidebarTab(tab)
                    } label: {
                        HStack(spacing: 5) {
                            Image(systemName: tab.icon)
                                .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                            Text(verbatim: tab.rawValue)
                                .font(.system(size: 13, weight: isSelected ? .semibold : .medium))
                            if let badge = badgeText(for: tab) {
                                Text(verbatim: badge)
                                    .font(.system(size: 10.5, weight: .bold, design: .rounded))
                                    .padding(.horizontal, 5.5)
                                    .padding(.vertical, 1.5)
                                    .background(
                                        Capsule()
                                            .fill(isSelected ? Theme.brandBlue : Color.secondary.opacity(0.16))
                                    )
                                    .foregroundStyle(isSelected ? .white : .secondary)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 7)
                        .background(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .fill(isSelected ? Theme.brandBlue.opacity(0.16) : Color.clear)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 7, style: .continuous)
                                .strokeBorder(isSelected ? Theme.brandBlue.opacity(0.4) : Color.clear, lineWidth: 0.5)
                        )
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(isSelected ? Theme.brandBlue : .secondary)
                }
            }
            .padding(6)
            .background(Color.primary.opacity(0.04))

            Divider()

            // 下方列表区域
            Group {
                switch model.sidebarTab {
                case .history:
                    HistoryListView()
                case .changes:
                    ChangesListView()
                case .browse:
                    BrowseView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }
}
