import SwiftUI

struct ContentView: View {
    @StateObject private var model = PlayerModel()
    @StateObject private var account = AccountViewModel()
    @State private var showBangumi = false

    var body: some View {
        PlayerView(model: model)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.openPanel()
                    } label: {
                        Label("打开文件", systemImage: "folder")
                    }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        showBangumi = true
                    } label: {
                        Label("Bangumi", systemImage: "person.crop.circle")
                    }
                }
            }
            .navigationTitle(model.fileName ?? "NagomiAni")
            .sheet(isPresented: $showBangumi) {
                AccountView(model: account)
            }
    }
}
