import SwiftUI

let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "y-MM-dd H:m:ss.SSS"
    return formatter
}()

typealias Action = () -> Void

struct Item: Equatable, Codable, Identifiable {
    var id: UUID
    var text: String

    init() {
        self.id = UUID()
        self.text = formatter.string(from: Date())
    }
}

struct ItemView: View {
    var text: String
    var insertAfter: Action
    var delete: Action

    var body: some View {
        Text(text)
            .font(Font.body.monospacedDigit())
            .padding()
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.pink))
            .padding(.horizontal)
            .onTapGesture {
                insertAfter()
            }
            .contextMenu {
                Button("Insert After") {
                    insertAfter()
                }
                Button("Delete") {
                    delete()
                }
            }
    }
}

struct ContentView: View {
    @EnvironmentObject var appModel: AppModel

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack {
                    ForEach(appModel.data.data) { item in
                        ItemView(text: item.text,
                             insertAfter: appModel.makeInsertAfter(id: item.id),
                             delete: appModel.makeDelete(id: item.id))
                    }
                }
            }.navigationTitle("List that syncs.")
        }
    }
}

struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
    }
}
