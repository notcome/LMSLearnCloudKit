import Foundation
import UIKit
import Combine
import CloudKit

struct PendingRecords: Codable {
    var map: [UUID : [Record]] = [:]

    var recordCount: Int {
        map.values.map(\.count).reduce(0, +)
    }

    mutating func applyPendingRecords(to weave: inout Weave) {
        var totalRemoved: Int
        repeat {
            totalRemoved = 0

            for author in map.keys {
                var committed = 0
                let pendingRecords = map[author]!
                for record in pendingRecords {
                    guard !weave.contains(record.id) else {
                        committed += 1
                        continue
                    }
                    guard weave.canCommit(record) else { break }
                    weave.insert(record)
                    committed += 1
                }
                if committed == pendingRecords.count {
                    map.removeValue(forKey: author)
                } else {
                    map[author] = Array(pendingRecords.dropFirst(committed))
                }
                totalRemoved += committed
            }
        } while totalRemoved > 0
    }

    func contains(_ id: RecordID) -> Bool {
        nil != map[id.author]?.first { $0.id.index == id.index }
    }

    mutating func insert(records: [Record]) {
        var touched = Set<UUID>()
        for record in records {
            map[record.id.author, default: []].append(record)
            touched.insert(record.id.author)
        }
        for author in touched {
            map[author]!.sort { $0.id.index < $1.id.index }
        }
    }
}

extension RecordID {
    init?(ckRecord: CKRecord, prefix: String) {
        guard let timestamp = ckRecord["\(prefix)Timestamp"] as? Int,
              let index = ckRecord["\(prefix)Index"] as? Int,
              let authorString = ckRecord["\(prefix)Author"] as? String,
              let author = UUID(uuidString: authorString)
        else { return nil }
        self.timestamp = timestamp
        self.index = index
        self.author = author
    }

    func write(toCKRecord ckRecord: CKRecord, prefix: String) {
        ckRecord["\(prefix)Timestamp"] = timestamp
        ckRecord["\(prefix)Index"] = index
        ckRecord["\(prefix)Author"] = author.uuidString
    }

    var ckRecordName: String {
        "\(author.uuidString)-\(timestamp)"
    }
}

extension Record {
    static let ckRecordType: CKRecord.RecordType = "crdt_list_record"

    init?(ckRecord: CKRecord) {
        guard ckRecord.recordType == Self.ckRecordType,
              let id = RecordID(ckRecord: ckRecord, prefix: "id"),
              let cause = RecordID(ckRecord: ckRecord, prefix: "cause")
        else { return nil }

        self.id = id
        self.cause = cause
        if let insertionDate = ckRecord["date"] as? Date {
            date = insertionDate
        } else {
            date = nil
        }
    }

    func ckRecord(of ckRecordID: CKRecord.ID) -> CKRecord {
        let ckRecord = CKRecord(recordType: Self.ckRecordType, recordID: ckRecordID)

        id.write(toCKRecord: ckRecord, prefix: "id")
        cause.write(toCKRecord: ckRecord, prefix: "cause")
        if let date = date {
            ckRecord["date"] = date
        }

        return ckRecord
    }
}

struct StorageLayerData: Codable {
    var zoneCreatedAndSubscribed: Bool = false
    var serverChangeToken: Data? = nil
    var lastIndex: Int = 0
    var pendingRecords = PendingRecords()
    var weave: Weave = Weave()

    static var modelURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("model.json")
    }

    static var latest: Self {
        guard let file = try? Data(contentsOf: modelURL) else { return .init() }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(Self.self, from: file) else { return .init() }
        return decoded
    }

    func save() throws {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(self)
        try encoded.write(to: Self.modelURL)
    }
}

class StorageLayer {
    var zoneCreatedAndSubscribed: Bool {
        didSet { shouldSave.send() }
    }
    var serverChangeToken: Data? {
        didSet { shouldSave.send() }
    }
    var lastIndex: Int {
        didSet { shouldSave.send() }
    }
    var pendingRecords: PendingRecords {
        didSet { shouldSave.send() }
    }
    var weave: CurrentValueSubject<Weave, Never>

    let container: CKContainer
    let privateDB: CKDatabase
    static let zoneNameString = "CRDTList"
    static let zoneID = CKRecordZone.ID(zoneName: zoneNameString, ownerName: CKCurrentUserDefaultName)
    static let privateSubscriptionID = "CRDTList-private-changes"

    let identity = UIDevice.current.identifierForVendor ?? UUID()
    var shouldSave = PassthroughSubject<Void, Never>()
    var subscriptions = Set<AnyCancellable>()

    init() {
        container = CKContainer(identifier: "iCloud.LMSLearnCloudKit")
        privateDB = container.privateCloudDatabase

        let data = StorageLayerData.latest
        zoneCreatedAndSubscribed = data.zoneCreatedAndSubscribed
        serverChangeToken = data.serverChangeToken
        lastIndex = data.lastIndex
        pendingRecords = data.pendingRecords
        weave = .init(data.weave)

        weave.sink { [weak self] _ in
            self?.shouldSave.send()
        }.store(in: &subscriptions)

        weave
            .throttle(for: 1, scheduler: RunLoop.current, latest: true)
            .sink { [weak self] _ in
                self?.uploadLocalRecords()
            }
            .store(in: &subscriptions)

        shouldSave
            .throttle(for: 1, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                guard let self = self else { return }
                let data = StorageLayerData(zoneCreatedAndSubscribed: self.zoneCreatedAndSubscribed,
                                            serverChangeToken: self.serverChangeToken,
                                            lastIndex: self.lastIndex,
                                            pendingRecords: self.pendingRecords,
                                            weave: self.weave.value)
                try? data.save()
            }
            .store(in: &subscriptions)
    }
}

extension StorageLayer {
    func setUpCloudIfNeeded() {
        let group = DispatchGroup()

        if !zoneCreatedAndSubscribed {
            createZoneThenSubscribe(in: group)
        }

        group.notify(queue: .global()) { [weak self] in
            guard let self = self else { return }
            if self.zoneCreatedAndSubscribed {
                self.fetchChanges()
            }
        }
    }

    func createZoneThenSubscribe(in group: DispatchGroup) {
        group.enter()

        let customZone = CKRecordZone(zoneID: Self.zoneID)
        let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [customZone], recordZoneIDsToDelete: [] )
        createZoneOperation.modifyRecordZonesCompletionBlock = { (_, _, error) in
            guard error == nil else { fatalError() }
            group.leave()
        }
        privateDB.add(createZoneOperation)

        group.notify(queue: .global()) { [weak self] in
            self?.subscribeZoneChanges()
            self?.uploadLocalRecords()
            self?.fetchChanges()
        }
    }

    func subscribeZoneChanges() {
        let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.privateSubscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        // send a silent notification
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo

        let createSubscriptionOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
        createSubscriptionOperation.qualityOfService = .utility
        createSubscriptionOperation.modifySubscriptionsCompletionBlock = { [weak self] (_, _, error) in
            guard error == nil else { fatalError() }
            self?.zoneCreatedAndSubscribed = true
        }
        privateDB.add(createSubscriptionOperation)
    }

    func fetchChanges(onCompletion: @escaping Action = {}) {
        let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        options.previousServerChangeToken = serverChangeToken.flatMap {
            try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKServerChangeToken.self, from: $0)
        }
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [Self.zoneID], configurationsByRecordZoneID: [Self.zoneID: options])

        var pendingRecords = self.pendingRecords
        var toInsert = [Record]()
        var serverChangeToken: Data? = nil

        operation.recordChangedBlock = { ckRecord in
            guard let record = Record(ckRecord: ckRecord) else { return }
            if !pendingRecords.contains(record.id) {
                toInsert.append(record)
            }
        }

        operation.recordWithIDWasDeletedBlock = { (id, type) in
            print("Record \(id) of type \(type) deleted.")
        }

        operation.recordZoneChangeTokensUpdatedBlock = { (_, token, _) in
            guard let token = token else { return }
            serverChangeToken = try! NSKeyedArchiver.archivedData(withRootObject: token, requiringSecureCoding: true)
        }

        operation.recordZoneFetchCompletionBlock = { [weak self] (_, _, _, _, error) in
            guard error == nil else { fatalError() }
            pendingRecords.insert(records: toInsert)
            self?.pendingRecords = pendingRecords
            if let newToken = serverChangeToken {
                self?.serverChangeToken = newToken
            }
            onCompletion()
            self?.handlePendingRecords()
        }

        privateDB.add(operation)
    }

    func handlePendingRecords() {
        pendingRecords.applyPendingRecords(to: &weave.value)
    }

    func uploadLocalRecords() {
        guard zoneCreatedAndSubscribed, let localYarn = weave.value.map[identity] else { return }
        let localRecords = localYarn.dropFirst(lastIndex)
        guard !localRecords.isEmpty else { return }
        let ckRecords = localRecords.map { node -> CKRecord in
            let record = node.record
            let recordName = record.id.ckRecordName
            let recordID = CKRecord.ID(recordName: recordName, zoneID: Self.zoneID)
            return record.ckRecord(of: recordID)
        }
        let operation = CKModifyRecordsOperation(recordsToSave: ckRecords, recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys
        operation.modifyRecordsCompletionBlock = { [weak self] (saved, deleted, error) in
            guard error == nil else { fatalError() }
            self?.lastIndex = localYarn.count
        }
        privateDB.add(operation)
    }
}
