import Foundation
import Combine

typealias Action = () -> Void

class ListModel: ObservableObject {
    weak var storageLayer: StorageLayer?

    @Published var items: [Item] = []

    init(storageLayer: StorageLayer) {
        self.storageLayer = storageLayer

        storageLayer.weave
            .receive(on: RunLoop.main)
            .map(\.items)
            .assign(to: &$items)
    }

    private func makeMutation(for target: RecordID, isDeletion: Bool) -> Action {
        return { [weak self] in
            guard let storageLayer = self?.storageLayer else { return }
            let author = storageLayer.identity
            let weave = storageLayer.weave.value
            let nextID = RecordID(timestamp: weave.maxTimestamp + 1,
                                  index: weave.nextIndex(for: author),
                                  author: author)
            let record = Record(id: nextID, cause: target, date: isDeletion ? nil : Date())
            storageLayer.weave.value.insert(record)
        }
    }

    func makeInsertAfter(_ target: RecordID) -> Action {
        makeMutation(for: target, isDeletion: false)
    }

    func makeDelete(_ target: RecordID) -> Action {
        makeMutation(for: target, isDeletion: true)
    }
}
