//
//  Copyright (c) 2019 Open Whisper Systems. All rights reserved.
//

import Foundation
import PromiseKit

@objc
public enum MessageStickerError: Int, Error {
    case invalidInput
    case noSticker
    case assertionFailure
}

// MARK: - StickerPackMetadata

@objc
public class StickerPackMetadata: NSObject {
    @objc
    public let packId: Data

    @objc
    public let packKey: Data

    @objc
    public init(packId: Data, packKey: Data) {
        self.packId = packId
        self.packKey = packKey
    }

    // Returns a String that can be used as a key in caches, etc.
    @objc
    public func cacheKey() -> String {
        return packId.hexadecimalString
    }
}

// MARK: - StickerMetadata

@objc
public class StickerMetadata: NSObject {
    @objc
    public let stickerPack: StickerPackMetadata

    @objc
    public var stickerId: UInt32

    @objc
    public init(stickerPack: StickerPackMetadata, stickerId: UInt32) {
        self.stickerPack = stickerPack
        self.stickerId = stickerId
    }

    // Returns a String that can be used as a key in caches, etc.
    @objc
    public func cacheKey() -> String {
        return "\(stickerPack.packId.hexadecimalString).\(stickerId)"
    }
}

// MARK: - MessageStickerDraft

@objc
public class MessageStickerDraft: NSObject {
    @objc
    public let stickerMetadata: StickerMetadata

    @objc
    public var stickerData: Data

    @objc
    public init(stickerMetadata: StickerMetadata, stickerData: Data) {
        self.stickerMetadata = stickerMetadata
        self.stickerData = stickerData
    }
}

// MARK: - MessageSticker

@objc
public class MessageSticker: MTLModel {

    @objc
    public var stickerMetadata: StickerMetadata?

    @objc
    public var attachmentId: String?

    @objc
    public var stickerId: UInt32 {
        guard let stickerMetadata = stickerMetadata else {
            owsFailDebug("Missing stickerMetadata.")
            return 0
        }
        return stickerMetadata.stickerId
    }

    @objc
    public var packId: Data {
        guard let stickerMetadata = stickerMetadata else {
            owsFailDebug("Missing stickerMetadata.")
            return Data()
        }
        return stickerMetadata.stickerPack.packId
    }

    @objc
    public var packKey: Data {
        guard let stickerMetadata = stickerMetadata else {
            owsFailDebug("Missing stickerMetadata.")
            return Data()
        }
        return stickerMetadata.stickerPack.packKey
    }

    @objc
    public init(stickerMetadata: StickerMetadata, attachmentId: String) {
        self.stickerMetadata = stickerMetadata
        self.attachmentId = attachmentId

        super.init()
    }

    @objc
    public override init() {
        super.init()
    }

    @objc
    public required init!(coder: NSCoder) {
        super.init(coder: coder)
    }

    @objc
    public required init(dictionary dictionaryValue: [AnyHashable: Any]!) throws {
        try super.init(dictionary: dictionaryValue)
    }

    @objc
    public class func isNoStickerError(_ error: Error) -> Bool {
        guard let error = error as? MessageStickerError else {
            return false
        }
        return error == .noSticker
    }

    @objc
    public class func buildValidatedMessageSticker(dataMessage: SSKProtoDataMessage,
                                                   transaction: SDSAnyWriteTransaction) throws -> MessageSticker {
        guard FeatureFlags.stickerReceive else {
            throw MessageStickerError.noSticker
        }
        guard let stickerProto: SSKProtoDataMessageSticker = dataMessage.sticker else {
            throw MessageStickerError.noSticker
        }

        let packID: Data = stickerProto.packID
        let packKey: Data = stickerProto.packKey
        let stickerID: UInt32 = stickerProto.stickerID
        let dataProto: SSKProtoAttachmentPointer = stickerProto.data

        guard let attachmentPointer = TSAttachmentPointer(fromProto: dataProto, albumMessage: nil) else {
            throw MessageStickerError.invalidInput
        }
        attachmentPointer.anySave(transaction: transaction)
        guard let attachmentId = attachmentPointer.uniqueId else {
            throw MessageStickerError.assertionFailure
        }

        let stickerPackMetadata = StickerPackMetadata(packId: packID, packKey: packKey)
        let stickerMetadata = StickerMetadata(stickerPack: stickerPackMetadata, stickerId: stickerID)
        let messageSticker = MessageSticker(stickerMetadata: stickerMetadata, attachmentId: attachmentId)
        return messageSticker
    }

    @objc
    public class func buildValidatedMessageSticker(fromDraft draft: MessageStickerDraft,
                                                   transaction: SDSAnyWriteTransaction) throws -> MessageSticker {
        guard FeatureFlags.stickerSend else {
            throw MessageStickerError.assertionFailure
        }
        let attachmentId = try MessageSticker.saveAttachment(stickerData: draft.stickerData,
                                                             transaction: transaction)

        let messageSticker = MessageSticker(stickerMetadata: draft.stickerMetadata, attachmentId: attachmentId)

        return messageSticker
    }

    private class func saveAttachment(stickerData: Data,
                                      transaction: SDSAnyWriteTransaction) throws -> String {
        let fileSize = stickerData.count
        guard fileSize > 0 else {
            owsFailDebug("Invalid file size for data.")
            throw MessageStickerError.assertionFailure
        }
        let fileExtension = "webp"
        let contentType = OWSMimeTypeImageWebp

        let filePath = OWSFileSystem.temporaryFilePath(withFileExtension: fileExtension)
        do {
            try stickerData.write(to: NSURL.fileURL(withPath: filePath))
        } catch let error as NSError {
            owsFailDebug("file write failed: \(filePath), \(error)")
            throw MessageStickerError.assertionFailure
        }

        guard let dataSource = DataSourcePath.dataSource(withFilePath: filePath, shouldDeleteOnDeallocation: true) else {
            owsFailDebug("Could not create data source for path: \(filePath)")
            throw MessageStickerError.assertionFailure
        }
        let attachment = TSAttachmentStream(contentType: contentType, byteCount: UInt32(fileSize), sourceFilename: nil, caption: nil, albumMessageId: nil)
        guard attachment.write(dataSource) else {
            owsFailDebug("Could not write data source for path: \(filePath)")
            throw MessageStickerError.assertionFailure
        }
        attachment.anySave(transaction: transaction)

        guard let attachmentId = attachment.uniqueId else {
            throw MessageStickerError.assertionFailure
        }
        return attachmentId
    }

    @objc
    public func removeAttachment(transaction: YapDatabaseReadWriteTransaction) {
        guard let attachmentId = attachmentId else {
            owsFailDebug("No attachment id.")
            return
        }
        guard let attachment = TSAttachment.fetch(uniqueId: attachmentId, transaction: transaction) else {
            owsFailDebug("Could not load attachment.")
            return
        }
        attachment.remove(with: transaction)
    }
}