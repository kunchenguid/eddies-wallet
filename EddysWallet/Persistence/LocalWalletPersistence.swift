import CoreData
import Foundation

protocol LocalWalletPersisting {
    func load() throws -> Data?
    func save(_ payload: Data) throws
    func erase() throws
}

/// Versioned protected Core Data container for the one-child local aggregate.
/// The aggregate is encoded as one transactionally-updated record so metadata,
/// materialized balance, immutable events, loan, repayment state, allowance,
/// and the bounded outbox never commit independently.
final class LocalWalletPersistence: LocalWalletPersisting {
    static let modelName = "WalletModel"
    private let container: NSPersistentContainer
    private let recordEntity = "WalletRecord"

    init(directory: URL? = nil, inMemory: Bool = false) throws {
        let model = Self.managedObjectModel()
        container = NSPersistentContainer(name: Self.modelName, managedObjectModel: model)
        let description = NSPersistentStoreDescription()
        if inMemory {
            description.type = NSInMemoryStoreType
        } else {
            let root = try directory ?? Self.defaultDirectory()
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            description.url = root.appendingPathComponent("Wallet.sqlite")
            description.setOption(FileProtectionType.completeUntilFirstUserAuthentication as NSObject, forKey: NSPersistentStoreFileProtectionKey)
            description.setOption(true as NSNumber, forKey: NSPersistentHistoryTrackingKey)
        }
        container.persistentStoreDescriptions = [description]
        var loadError: Error?
        container.loadPersistentStores { _, error in loadError = error }
        if let loadError { throw loadError }
        container.viewContext.mergePolicy = NSMergeByPropertyStoreTrumpMergePolicy
        container.viewContext.undoManager = nil
        if !inMemory, let storeURL = description.url {
            try Self.applyProtectionAndBackupExclusion(to: storeURL)
        }
    }

    func load() throws -> Data? {
        let request = NSFetchRequest<NSManagedObject>(entityName: recordEntity)
        request.fetchLimit = 1
        return try container.viewContext.fetch(request).first?.value(forKey: "payload") as? Data
    }

    func save(_ payload: Data) throws {
        let context = container.viewContext
        try context.performAndWait {
            let request = NSFetchRequest<NSManagedObject>(entityName: recordEntity)
            request.fetchLimit = 1
            let object = try context.fetch(request).first ?? NSEntityDescription.insertNewObject(forEntityName: recordEntity, into: context)
            object.setValue("current", forKey: "id")
            object.setValue(payload, forKey: "payload")
            object.setValue(Date(), forKey: "updatedAt")
            try context.save()
        }
    }

    func erase() throws {
        let context = container.viewContext
        try context.performAndWait {
            let request = NSFetchRequest<NSFetchRequestResult>(entityName: recordEntity)
            try context.execute(NSBatchDeleteRequest(fetchRequest: request))
            try context.save()
        }
    }

    private static func defaultDirectory() throws -> URL {
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
        return base.appendingPathComponent("Wallet", isDirectory: true)
    }

    private static func applyProtectionAndBackupExclusion(to storeURL: URL) throws {
        let manager = FileManager.default
        for candidate in [storeURL, URL(fileURLWithPath: storeURL.path + "-wal"), URL(fileURLWithPath: storeURL.path + "-shm")] where manager.fileExists(atPath: candidate.path) {
            var url = candidate
            var values = URLResourceValues()
            values.isExcludedFromBackup = true
            try url.setResourceValues(values)
            try manager.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
        }
    }

    private static func managedObjectModel() -> NSManagedObjectModel {
        let model = NSManagedObjectModel()
        let entity = NSEntityDescription()
        entity.name = "WalletRecord"
        entity.managedObjectClassName = "NSManagedObject"
        let id = NSAttributeDescription()
        id.name = "id"; id.attributeType = .stringAttributeType; id.isOptional = false
        let payload = NSAttributeDescription()
        payload.name = "payload"; payload.attributeType = .binaryDataAttributeType; payload.allowsExternalBinaryDataStorage = false; payload.isOptional = false
        let updatedAt = NSAttributeDescription()
        updatedAt.name = "updatedAt"; updatedAt.attributeType = .dateAttributeType; updatedAt.isOptional = false
        entity.properties = [id, payload, updatedAt]
        model.entities = [entity]
        return model
    }
}
