// Copyright (c) 2017 Timofey Solomko
// Licensed under MIT License
//
// See LICENSE for license information

import Foundation

/// Represents either a file or directory entry in ZIP container.
public class ZipEntry: ContainerEntry {

    private let cdEntry: ZipCentralDirectoryEntry
    private var localHeader: ZipLocalHeader?
    private var bitReader: BitReader

    /// Name of the file or directory.
    public var name: String {
        return self.cdEntry.fileName
    }

    /// Comment associated with the entry.
    public var comment: String? {
        return self.cdEntry.fileComment
    }

    /**
     File or directory attributes related to the file system of the container's creator.

     - Note:
     Will be renamed to `externalFileAttributes` in 4.0.
     */
    public var attributes: UInt32 {
        return self.cdEntry.externalFileAttributes
    }

    /// Size of the data associated with the entry.
    public var size: Int {
        return Int(truncatingBitPattern: cdEntry.uncompSize)
    }

    /**
     True, if an entry is a directory.
     For MS-DOS and UNIX-like container creator's OS, the result is based on 'external file attributes'.
     Otherwise, it is true if size of data is 0 AND last character of entry's name is '/'.
     */
    public var isDirectory: Bool {
        let hostSystem = (cdEntry.versionMadeBy & 0xFF00) >> 8
        if hostSystem == 0 || hostSystem == 3 { // MS-DOS or UNIX case.
            // In both of this cases external file attributes indicate if this is a directory.
            // This is indicated by a special bit in the lowest byte of attributes.
            return cdEntry.externalFileAttributes & 0x10 != 0
        } else {
            return size == 0 && name.characters.last == "/"
        }
    }

    /**
     Provides a dictionary with various attributes of the entry.
     `FileAttributeKey` values are used as dictionary keys.

     - Note:
     Will be renamed in 4.0.

     ## Possible attributes:

     - `FileAttributeKey.modificationDate`
     - `FileAttributeKey.size`
     - `FileAttributeKey.type`, only if origin OS was UNIX- or DOS-like.
     - `FileAttributeKey.posixPermissions`, only if origin OS was UNIX-like.
     - `FileAttributeKey.appendOnly`, only if origin OS was DOS-like.
     */
    public let entryAttributes: [FileAttributeKey: Any]

    /**
     Returns data associated with this entry.

     - Throws: `ZipError` or any other error associated with compression type,
     depending on the type of the problem. An error can indicate that container is damaged.
     */
    public func data() throws -> Data {
        // Now, let's move to the location of local header.
        bitReader.index = Int(UInt32(truncatingBitPattern: self.cdEntry.offset))

        if localHeader == nil {
            localHeader = try ZipLocalHeader(bitReader)
            // Check local header for consistency with Central Directory entry.
            guard localHeader!.generalPurposeBitFlags == cdEntry.generalPurposeBitFlags &&
                localHeader!.compressionMethod == cdEntry.compressionMethod &&
                localHeader!.lastModFileTime == cdEntry.lastModFileTime &&
                localHeader!.lastModFileDate == cdEntry.lastModFileDate
                else { throw ZipError.wrongLocalHeader }
        }

        let hasDataDescriptor = localHeader!.generalPurposeBitFlags & 0x08 != 0

        // If file has data descriptor, then some values in local header are absent.
        // So we need to use values from CD entry.
        var uncompSize = hasDataDescriptor ?
            Int(UInt32(truncatingBitPattern: cdEntry.uncompSize)) :
            Int(UInt32(truncatingBitPattern: localHeader!.uncompSize))
        var compSize = hasDataDescriptor ?
            Int(UInt32(truncatingBitPattern: cdEntry.compSize)) :
            Int(UInt32(truncatingBitPattern: localHeader!.compSize))
        var crc32 = hasDataDescriptor ? cdEntry.crc32 : localHeader!.crc32

        let fileBytes: [UInt8]
        let fileDataStart = bitReader.index
        switch localHeader!.compressionMethod {
        case 0:
            fileBytes = bitReader.alignedBytes(count: uncompSize)
        case 8:
            fileBytes = try Deflate.decompress(bitReader)
            // Sometimes bitReader stays in not-aligned state after deflate decompression.
            // Following line ensures that this is not the case.
            bitReader.skipUntilNextByte()
        case 12:
            #if (!SWCOMP_ZIP_POD_BUILD) || (SWCOMP_ZIP_POD_BUILD && SWCOMP_ZIP_POD_BZ2)
                fileBytes = try BZip2.decompress(bitReader)
            #else
                throw ZipError.compressionNotSupported
            #endif
        case 14:
            #if (!SWCOMP_ZIP_POD_BUILD) || (SWCOMP_ZIP_POD_BUILD && SWCOMP_ZIP_POD_LZMA)
                bitReader.index += 4 // Skipping LZMA SDK version and size of properties.
                fileBytes = try LZMA.decompress(bitReader, uncompSize)
            #else
                throw ZipError.compressionNotSupported
            #endif
        default:
            throw ZipError.compressionNotSupported
        }
        let realCompSize = bitReader.index - fileDataStart

        if hasDataDescriptor {
            // Now we need to parse data descriptor itself.
            // First, it might or might not have signature.
            let ddSignature = bitReader.uint32FromAlignedBytes(count: 4)
            if ddSignature != 0x08074b50 {
                bitReader.index -= 4
            }
            // Now, let's update from CD with values from data descriptor.
            crc32 = bitReader.uint32FromAlignedBytes(count: 4)
            let sizeOfSizeField: UInt32 = localHeader!.zip64FieldsArePresent ? 8 : 4
            compSize = Int(bitReader.uint32FromAlignedBytes(count: sizeOfSizeField))
            uncompSize = Int(bitReader.uint32FromAlignedBytes(count: sizeOfSizeField))
        }

        guard compSize == realCompSize && uncompSize == fileBytes.count
            else { throw ZipError.wrongSize }
        guard crc32 == UInt32(CheckSums.crc32(fileBytes))
            else { throw ZipError.wrongCRC32(Data(bytes: fileBytes)) }

        return Data(bytes: fileBytes)
    }

    init(_ cdEntry: ZipCentralDirectoryEntry, _ bitReader: BitReader) {
        self.cdEntry = cdEntry
        self.bitReader = bitReader

        var attributesDict = [FileAttributeKey: Any]()

        // Modification time
        let dosDate = cdEntry.lastModFileDate

        let day = dosDate & 0x1F
        let month = (dosDate & 0x1E0) >> 5
        let year = 1980 + ((dosDate & 0xFE00) >> 9)

        let dosTime = cdEntry.lastModFileTime

        let seconds = 2 * (dosTime & 0x1F)
        let minutes = (dosTime & 0x7E0) >> 5
        let hours = (dosTime & 0xF800) >> 11

        if let mtime = DateComponents(calendar: Calendar(identifier: .iso8601),
                                      timeZone: TimeZone(abbreviation: "UTC"),
                                      year: year, month: month, day: day,
                                      hour: hours, minute: minutes, second: seconds).date {
            attributesDict[FileAttributeKey.modificationDate] = mtime
        }

        // Extended Timestamp
        if let mtimestamp = cdEntry.modificationTimestamp {
            attributesDict[FileAttributeKey.modificationDate] = Date(timeIntervalSince1970: TimeInterval(mtimestamp))
        }

        // Size
        attributesDict[FileAttributeKey.size] = cdEntry.uncompSize

        // External file attributes.

        // For unix-like origin systems we can parse extended attributes.
        let hostSystem = (cdEntry.versionMadeBy & 0xFF00) >> 8
        if hostSystem == 3 {
            // File type.
            let fileType = (cdEntry.externalFileAttributes & 0xF0000000) >> 28
            switch fileType {
            case 0x2:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeCharacterSpecial
            case 0x4:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeDirectory
            case 0x6:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeBlockSpecial
            case 0x8:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeRegular
            case 0xA:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeSymbolicLink
            case 0xC:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeSocket
            default:
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeUnknown
            }

            // Posix permissions.
            let posixPermissions = (cdEntry.externalFileAttributes & 0x0FFF0000) >> 16
            attributesDict[FileAttributeKey.posixPermissions] = posixPermissions
        }

        // For dos and unix-like systems we can parse dos attributes.
        if hostSystem == 0 || hostSystem == 3 {
            let dosAttributes = cdEntry.externalFileAttributes & 0xFF

            if dosAttributes & 0x10 != 0 && hostSystem == 0 {
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeDirectory
            } else if hostSystem == 0 {
                attributesDict[FileAttributeKey.type] = FileAttributeType.typeRegular
            }

            if dosAttributes & 0x1 != 0 {
                attributesDict[FileAttributeKey.appendOnly] = true
            }
        }

        self.entryAttributes = attributesDict
    }

}