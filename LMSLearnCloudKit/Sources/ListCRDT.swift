import Foundation
import Combine

struct RecordID: Equatable, Hashable, Codable {
    var timestamp: Int
    var index: Int
    var author: UUID

    var isInitial: Bool {
        timestamp == 0
    }
}

struct Record: Identifiable, Codable {
    var id: RecordID
    var cause: RecordID
    /// `nil` represents deletion.
    var date: Date?

    static var initial: Record {
        let id = RecordID(timestamp: 0, index: 0, author: .zero)
        return Record(id: id, cause: id, date: nil)
    }
}

struct Item: Equatable, Identifiable, Codable {
    var id: RecordID
    var date: Date
    var author: UUID {
        id.author
    }
}

struct Pointer: Equatable, Hashable, Codable {
    var index: Int
    var author: UUID

    init(_ id: RecordID) {
        index = id.index
        author = id.author
    }
}

struct Node: Codable {
    var record: Record
    var child: Pointer? = nil
    var sibling: Pointer? = nil
}

extension UUID {
    static var zero: UUID {
        .init(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0))
    }
}

typealias VersionVector = [UUID : Int]

struct Weave: Codable {
    var maxTimestamp: Int = 0
    var map: [UUID : [Node]] = [.zero : [Node(record: .initial)]]

    func contains(_ id: RecordID) -> Bool {
        if let yarn = map[id.author], yarn.count > id.index {
            return true
        }
        return false
    }

    func existsCause(for record: Record) -> Bool {
        contains(record.cause)
    }

    func noPreviousRecordFromSameAuthorMissing(for record: Record) -> Bool {
        let id = record.id
        guard let yarn = map[id.author] else {
            return id.index == 0
        }
        return yarn.count == id.index
    }

    func canCommit(_ record: Record) -> Bool {
        !contains(record.id) && noPreviousRecordFromSameAuthorMissing(for: record) && existsCause(for: record)
    }

    func nextIndex(for author: UUID) -> Int {
        map[author]?.count ?? 0
    }

    subscript(_ id: RecordID) -> Node {
        get { self[Pointer(id)] }
        set { self[Pointer(id)] = newValue }
    }

    subscript(_ pointer: Pointer) -> Node {
        get { map[pointer.author]![pointer.index] }
        set { map[pointer.author]![pointer.index] = newValue }
    }

    static func record(_ lhs: Record, shouldComeBefore rhs: Record) -> Bool {
        assert(lhs.id != rhs.id)

        if lhs.id.isInitial {
            return true
        }
        if rhs.id.isInitial {
            return false
        }

        if lhs.id.author == rhs.id.author {
            return lhs.id.index > rhs.id.index
        }

        if lhs.date == nil {
            return true
        }
        if rhs.date == nil {
            return false
        }

        guard lhs.id.timestamp != rhs.id.timestamp else {
            return lhs.id.author.uuidString < rhs.id.author.uuidString
        }
        return lhs.id.timestamp > rhs.id.timestamp
    }

    mutating func insert(_ record: Record) {
        assert(canCommit(record))
        maxTimestamp = max(maxTimestamp, record.id.timestamp)

        var node = Node(record: record)
        defer {
            map[record.id.author, default: []].append(node)
        }

        let cause = self[record.cause]
        guard let firstChildPointer = cause.child else {
            self[record.cause].child = .init(record.id)
            return
        }

        let firstChild = self[firstChildPointer]
        guard !Self.record(record, shouldComeBefore: firstChild.record) else {
            node.sibling = firstChildPointer
            self[record.cause].child = .init(record.id)
            return
        }

        var currentPointer = firstChildPointer
        var current = firstChild
        while true {
            guard let nextPointer = current.sibling else {
                self[currentPointer].sibling = .init(record.id)
                return
            }
            let next = self[nextPointer]
            guard !Self.record(record, shouldComeBefore: next.record) else {
                node.sibling = nextPointer
                self[currentPointer].sibling = .init(record.id)
                return
            }
            currentPointer = nextPointer
            current = next
        }
    }

    func readChildren(of pointer: Pointer, into array: inout [Item]) {
        var parentDeleted = false
        var childAppended = false
        let parent = self[pointer]

        var maybeNextPointer = parent.child
        while let nextPointer = maybeNextPointer {
            let next = self[nextPointer]
            defer {
                maybeNextPointer = next.sibling
            }

            if let date = next.record.date {
                let item = Item(id: next.record.id, date: date)
                array.append(item)
                childAppended = true
                readChildren(of: nextPointer, into: &array)
            } else {
                if parentDeleted {
                    continue
                }
                assert(!childAppended && array.count > 0)
                array.removeLast()
                parentDeleted = true
            }
        }
    }

    var items: [Item] {
        var array = [Item]()
        readChildren(of: Pointer(.init(timestamp: 0, index: 0, author: .zero)), into: &array)
        return array
    }
}
