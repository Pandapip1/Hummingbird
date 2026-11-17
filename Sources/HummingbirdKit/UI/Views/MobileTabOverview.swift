import Foundation
import SwiftOpenUI

/// The tab controls for the selected tab: history, the section menu and the
/// tab overview. The tab container shows them in its own bar, outside the
/// pages (see `browserTabControls`).
@MainActor
struct MobileBrowserToolbar: View {
    @Environment(AppModel.self) private var app
    @Binding var showingTabOverview: Bool

    var body: some View {
        HStack {
            BrowserBackButton(tab: app.activeTab)
                .frame(width: 44, height: 44)
            BrowserForwardButton(tab: app.activeTab)
                .frame(width: 44, height: 44)
            Spacer()
            AppSectionMenu()
                .frame(width: 44, height: 44)
            BrowserTabOverviewButton { showingTabOverview = true }
                .frame(width: 44, height: 44)
        }
        .font(.headline)
        .buttonStyle(.plain)
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        // The tab container draws the bar itself (the system's glass).
    }
}
