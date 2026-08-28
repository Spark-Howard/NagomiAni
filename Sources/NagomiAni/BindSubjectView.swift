import SwiftUI
import NagomiAniCore

/// 搜索并关联 Bangumi 条目的弹窗
struct BindSubjectView: View {
    @ObservedObject var model: PlayerModel
    @State private var keyword = ""
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 12) {
            Text("关联 Bangumi 条目")
                .font(.headline)

            HStack {
                TextField("输入动画名称搜索（如：命运石之门）", text: $keyword)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { search() }
                Button("搜索") { search() }
                    .disabled(keyword.trimmingCharacters(in: .whitespaces).isEmpty || model.isSearching)
            }

            if model.isSearching {
                ProgressView()
                    .controlSize(.small)
            } else if model.searchResults.isEmpty {
                Text("搜索结果会显示在这里，选择后自动记住当前文件的关联")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 24)
            } else {
                List(model.searchResults) { subject in
                    Button {
                        model.bind(subject: subject)
                        dismiss()
                    } label: {
                        HStack {
                            VStack(alignment: .leading) {
                                Text(subject.nameCN ?? "—")
                                    .font(.body)
                                Text(subject.name ?? "")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Text("共 \(subject.totalEpisodes ?? 0) 集")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(16)
        .frame(width: 440, height: 440)
    }

    private func search() {
        Task { await model.search(keyword: keyword) }
    }
}
