import Foundation
import CloudKit
import Combine

extension CKServerChangeToken {
    var insecuredData: Data? {
        try? NSKeyedArchiver.archivedData(withRootObject: self, requiringSecureCoding: false)
    }

    static func from(data: Data) -> CKServerChangeToken? {
        (try? NSKeyedUnarchiver.unarchiveTopLevelObjectWithData(data)) as? CKServerChangeToken
    }
}

struct AppData: Equatable, Codable {
    var createdCustomZone = false
    var subscribedToPrivateChanges = false
    var data: [Item] = [Item()]

    var serverChangeToken: Data?
    var recordSystemFields: Data?

    static var modelURL: URL {
        let documentsURL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        return documentsURL.appendingPathComponent("model.json")
    }

    static var latest: AppData {
        guard let file = try? Data(contentsOf: modelURL) else { return .init() }
        let decoder = JSONDecoder()
        guard let decoded = try? decoder.decode(AppData.self, from: file) else { return .init() }
        return decoded
    }

    func save() throws {
        let encoder = JSONEncoder()
        let encoded = try encoder.encode(self)
        try encoded.write(to: Self.modelURL)
    }
}

class AppModel: ObservableObject {
    @Published var data: AppData

    var userDidChange = PassthroughSubject<Void, Never>()

    var subscriptions = Set<AnyCancellable>()
    let container: CKContainer
    let privateDB: CKDatabase

    init() {
        container = CKContainer(identifier: "iCloud.LMSLearnCloudKit")
        privateDB = container.privateCloudDatabase

        data = AppData.latest
        objectWillChange
            .throttle(for: 1, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                try? self?.data.save()
            }
            .store(in: &subscriptions)

        userDidChange
            .throttle(for: 1, scheduler: RunLoop.main, latest: true)
            .sink { [weak self] in
                self?.saveToiCloud()
            }
            .store(in: &subscriptions)
    }

    func makeInsertAfter(id: UUID) -> Action {
        return { [weak self] in
            guard
                let self = self,
                let index = self.data.data.firstIndex(where: { $0.id == id })
            else { return }
            self.data.data.insert(.init(), at: index + 1)
            self.userDidChange.send()
        }
    }

    func makeDelete(id: UUID) -> Action {
        return { [weak self] in
            guard
                let self = self,
                let index = self.data.data.firstIndex(where: { $0.id == id })
            else { return }
            self.data.data.remove(at: index)
            self.userDidChange.send()
        }
    }
}

extension AppModel {
    static let zoneNameString = "AtomicList"
    static let zoneID = CKRecordZone.ID(zoneName: zoneNameString, ownerName: CKCurrentUserDefaultName)
    static let privateSubscriptionID = "AtomicList-private-changes"


    func setUpCloudKit() {
        let createZoneGroup = DispatchGroup()
        if !data.createdCustomZone {
            createZoneGroup.enter()

            let customZone = CKRecordZone(zoneID: Self.zoneID)
            let createZoneOperation = CKModifyRecordZonesOperation(recordZonesToSave: [customZone], recordZoneIDsToDelete: [] )

            createZoneOperation.modifyRecordZonesCompletionBlock = { [weak self] (saved, deleted, error) in
                guard error == nil else { fatalError() }
                DispatchQueue.main.async {
                    self?.data.createdCustomZone = true
                    createZoneGroup.leave()
                }
            }
            createZoneOperation.qualityOfService = .userInitiated

            privateDB.add(createZoneOperation)
        }

        if !data.subscribedToPrivateChanges {
            let subscription = CKRecordZoneSubscription(zoneID: Self.zoneID, subscriptionID: Self.privateSubscriptionID)

            let notificationInfo = CKSubscription.NotificationInfo()
            // send a silent notification
            notificationInfo.shouldSendContentAvailable = true
            subscription.notificationInfo = notificationInfo

            let createSubscriptionOperation = CKModifySubscriptionsOperation(subscriptionsToSave: [subscription], subscriptionIDsToDelete: [])
            createSubscriptionOperation.qualityOfService = .utility

            createSubscriptionOperation.modifySubscriptionsCompletionBlock = { [weak self] (saved, deleted, error) in
                guard error == nil else { fatalError() }
                DispatchQueue.main.async {
                    self?.data.subscribedToPrivateChanges = true
                }
            }

            privateDB.add(createSubscriptionOperation)
        }

        createZoneGroup.notify(queue: .global()) { [weak self] in
            guard let self = self else { return }
            if self.data.createdCustomZone {
                self.fetchChanges()
                self.userDidChange.send()
            }
        }
    }

    func fetchChanges(onCompletion: @escaping () -> Void = {}) {
        let options = CKFetchRecordZoneChangesOperation.ZoneConfiguration()
        options.previousServerChangeToken = data.serverChangeToken.flatMap { CKServerChangeToken.from(data: $0) }
        let operation = CKFetchRecordZoneChangesOperation(recordZoneIDs: [Self.zoneID], configurationsByRecordZoneID: [Self.zoneID: options])

        var temporaryData = data.data
        var temporarySystemFields: Data? = data.recordSystemFields

        operation.recordChangedBlock = { (record) in
            guard record.recordID.recordName == "main",
                  let json = record["json"] as? String
            else { return }

            let decoder = JSONDecoder()
            let coder = NSKeyedArchiver(requiringSecureCoding: false)
            guard let data = json.data(using: .utf8),
                  let decoded = try? decoder.decode([Item].self, from: data)
            else { return }
            temporaryData = decoded
            record.encodeSystemFields(with: coder)
            temporarySystemFields = coder.encodedData
        }

        operation.recordWithIDWasDeletedBlock = { (recordID, type) in
            if recordID.recordName == "main" {
                temporaryData = [Item()]
            }
        }

        operation.recordZoneChangeTokensUpdatedBlock = { [weak self] (_, token, _) in
            DispatchQueue.main.async {
                if let codedToken = token?.insecuredData {
                    self?.data.serverChangeToken = codedToken
                }
                if let codedSystemFields = temporarySystemFields {
                    self?.data.recordSystemFields = codedSystemFields
                }
            }
        }

        operation.recordZoneFetchCompletionBlock = { [weak self] (zoneID, changeToken, _, _, error) in
            guard error == nil else { fatalError() }
            DispatchQueue.main.async {
                self?.data.data = temporaryData
            }
            onCompletion()
        }

        privateDB.add(operation)
    }

    func saveToiCloud() {
        let record: CKRecord
        if let codedSystemFields = data.recordSystemFields,
           let decodedRecord = try? NSKeyedUnarchiver.unarchivedObject(ofClass: CKRecord.self, from: codedSystemFields) {
            record = decodedRecord
        } else {
            let recordID = CKRecord.ID(recordName: "main", zoneID: Self.zoneID)
            record = CKRecord(recordType: "onlyType", recordID: recordID)
        }

        let encoder = JSONEncoder()
        let json = try! String(data: encoder.encode(data.data), encoding: .utf8)
        record["json"] = json

        let operation = CKModifyRecordsOperation(recordsToSave: [record], recordIDsToDelete: nil)
        operation.savePolicy = .changedKeys

        operation.modifyRecordsCompletionBlock = { (saved, deleted, error) in
            guard error == nil else { fatalError() }
            print("record saved!", saved)
        }

        privateDB.add(operation)
    }
}
