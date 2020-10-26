import SwiftUI

let formatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "y-MM-dd HH:mm:ss.SSS"
    return formatter
}()

struct ItemView: View {
    var item: Item
    var colorMap: [UUID : Color]
    var insertAfter: Action
    var delete: Action

    var text: String {
        formatter.string(from: item.date)
    }

    var body: some View {
        let color = colorMap[item.author] ?? Color.red
        Text(text)
            .font(Font.body.monospacedDigit())
            .padding()
            .frame(maxWidth: .infinity)
            .background(RoundedRectangle(cornerRadius: 4).fill(color))
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
    @EnvironmentObject var listModel: ListModel

    var colorMap: [UUID : Color] {
        var uniqueAuthors = Set(listModel.items.map(\.author))
        var map = [UUID : Color]()
        if let identity = UIDevice.current.identifierForVendor {
            uniqueAuthors.remove(identity)
            map[identity] = .pink
        }

        let authors = uniqueAuthors.sorted { $0.uuidString < $1.uuidString }
        let colors: [Color] = [.blue, .gray, .green, .orange, .yellow, .purple]

        for (author, color) in zip(authors, colors) {
            map[author] = color
        }
        return map
    }

    var body: some View {
        NavigationView {
            ScrollView {
                LazyVStack {
                    Button("Insert At Beginning") {
                        listModel.makeInsertAfter(.init(timestamp: 0, index: 0, author: .zero))()
                    }

                    let map = colorMap
                    ForEach(listModel.items) { item in
                        ItemView(item: item,
                                 colorMap: map,
                                 insertAfter: listModel.makeInsertAfter(item.id),
                                 delete: listModel.makeDelete(item.id))
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
