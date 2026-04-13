import Darwin
import Foundation
import os

// MARK: - Slot pool

/// Manages a fixed pool of pre-allocated I/O buffers and bounds concurrent
/// `getattrlistbulk` calls to `capacity` simultaneous readers.
///
/// Each `acquire()` returns a `Slot` that holds a raw pointer to a 256 KB
/// buffer and an index.  The caller uses the buffer for one `bulkScan` call,
/// then releases the slot.  Because the semaphore and buffer pool are unified,
/// there is no separate allocation per call — the same buffers are reused for
/// the entire lifetime of the scan.
final class SlotPool: Sendable {

    struct Slot {
        let index:  Int
        let buffer: UnsafeMutableRawPointer
        let pool:   SlotPool      // back-pointer so callers can call slot.release()

        func release() { pool.release(index) }
    }

    static let bufSize = 256 * 1024   // 256 KB per slot

    private let semaphore: DispatchSemaphore
    private let buffers:   [UnsafeMutableRawPointer]   // one per slot, never freed
    private let capacity:  Int

    // Free-list: indices of slots not currently in use.
    // Protected by `listLock` (os_unfair_lock via OSAllocatedUnfairLock).
    private let listLock = OSAllocatedUnfairLock(initialState: [Int]())

    init(capacity: Int) {
        self.capacity  = capacity
        self.semaphore = DispatchSemaphore(value: capacity)
        self.buffers   = (0..<capacity).map { _ in
            UnsafeMutableRawPointer.allocate(byteCount: SlotPool.bufSize, alignment: 8)
        }
        // All slots start free.
        self.listLock.withLock { $0 = Array(0..<capacity) }
    }

    deinit {
        for buf in buffers { buf.deallocate() }
    }

    /// Suspends until a slot is free, then returns it.
    /// The wait is dispatched onto a GCD thread so the Swift cooperative
    /// thread pool is never parked on the semaphore.
    func acquire() async -> Slot {
        await withCheckedContinuation { (cont: CheckedContinuation<Slot, Never>) in
            DispatchQueue.global(qos: .userInitiated).async {
                self.semaphore.wait()
                let idx = self.listLock.withLock { list -> Int in
                    let i = list.removeLast()
                    return i
                }
                cont.resume(returning: Slot(index: idx, buffer: self.buffers[idx], pool: self))
            }
        }
    }

    fileprivate func release(_ index: Int) {
        listLock.withLock { $0.append(index) }
        semaphore.signal()
    }
}

// MARK: - Shared attrlist

/// Single `attrlist` struct used by all `scanDirectoryEntries` calls.
/// Safe to share because `getattrlistbulk` treats it as read-only after setup.
private let sharedAttrList: attrlist = {
    var al = attrlist()
    al.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
    al.commonattr  = ATTR_CMN_RETURNED_ATTRS
                   | UInt32(bitPattern: ATTR_CMN_NAME)
                   | UInt32(bitPattern: ATTR_CMN_ERROR)
                   | UInt32(bitPattern: ATTR_CMN_DEVID)
                   | UInt32(bitPattern: ATTR_CMN_OBJTYPE)
                   | UInt32(bitPattern: ATTR_CMN_MODTIME)
    al.fileattr    = UInt32(bitPattern: ATTR_FILE_ALLOCSIZE)
    return al
}()

// MARK: - Inline bulk scan

/// Reads all entries from `path` using `getattrlistbulk(2)`, calling `body`
/// once per entry.  No intermediate array is allocated — entries are parsed
/// directly from the pre-allocated `slot.buffer` and handed to the closure.
///
/// ### Why inline instead of returning [BulkEntry]
/// The previous design returned `[BulkEntry]`, which:
/// - Allocated a `[BulkEntry]` array that grew as entries were appended
/// - Allocated a `String` per entry name (copied from the kernel buffer)
/// - Then iterated the array a second time to build `FileNode` objects
///
/// Here, `body` is called once per entry while the entry is still in the
/// kernel buffer.  The name `String` is still allocated (it must outlive the
/// buffer), but the intermediate `BulkEntry` structs and the results array
/// are eliminated entirely.
///
/// - Parameters:
///   - path:  Absolute POSIX path of the directory to read.
///   - slot:  A `SlotPool.Slot` whose buffer is used for the kernel call.
///   - body:  Called for each entry.  Return `true` to continue, `false` to stop.
///            Parameters: (name, devid, isDirectory, isSymlink, allocatedSize, modifiedDate)
@inline(__always)
func scanDirectoryEntries(
    path: String,
    slot: SlotPool.Slot,
    body: (
        _ name:          String,
        _ devid:         dev_t,
        _ isDirectory:   Bool,
        _ isSymlink:     Bool,
        _ allocatedSize: Int64,
        _ modifiedDate:  Date?
    ) -> Void
) {
    let fd = Darwin.open(path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard fd >= 0 else { return }
    defer { Darwin.close(fd) }

    var al = sharedAttrList    // copy — getattrlistbulk takes inout but only reads it
    let buf    = slot.buffer
    let bufSize = SlotPool.bufSize

    while true {
        let n = getattrlistbulk(fd, &al, buf, bufSize, 0)
        guard n > 0 else { break }

        var entryPtr = buf
        for _ in 0..<n {
            let entryBase = entryPtr
            let entryLen  = entryPtr.load(as: UInt32.self)

            let returned  = entryPtr.advanced(by: 4).load(as: attribute_set_t.self)
            var field = entryPtr.advanced(by: 4 + MemoryLayout<attribute_set_t>.size)

            var entryError: UInt32 = 0
            if (returned.commonattr & UInt32(ATTR_CMN_ERROR)) != 0 {
                entryError = field.load(as: UInt32.self)
                field = field.advanced(by: 4)
            }

            var name = ""
            if (returned.commonattr & UInt32(ATTR_CMN_NAME)) != 0 {
                let nameFieldPtr  = field
                let nameDataOff   = field.load(as: Int32.self)
                let nameByteCount = field.advanced(by: 4).load(as: UInt32.self)
                field = field.advanced(by: MemoryLayout<attrreference_t>.size)

                let nameStart = nameFieldPtr.advanced(by: Int(nameDataOff))
                let nameBytes = nameByteCount > 0 ? Int(nameByteCount) - 1 : 0
                if nameBytes > 0 {
                    name = String(
                        bytes: UnsafeRawBufferPointer(start: nameStart, count: nameBytes),
                        encoding: .utf8
                    ) ?? ""
                }
            }

            var devid: dev_t = 0
            if (returned.commonattr & UInt32(ATTR_CMN_DEVID)) != 0 {
                devid = field.load(as: dev_t.self)
                field = field.advanced(by: MemoryLayout<dev_t>.size)
            }

            var objType: fsobj_type_t = 0
            if (returned.commonattr & UInt32(ATTR_CMN_OBJTYPE)) != 0 {
                objType = field.load(as: fsobj_type_t.self)
                field = field.advanced(by: MemoryLayout<fsobj_type_t>.size)
            }

            var tvSec: Int64 = 0
            if (returned.commonattr & UInt32(ATTR_CMN_MODTIME)) != 0 {
                tvSec = field.load(as: Int64.self)
                field = field.advanced(by: MemoryLayout<timespec>.size)
            }

            var allocSize: Int64 = 0
            if (returned.fileattr & UInt32(ATTR_FILE_ALLOCSIZE)) != 0 {
                allocSize = field.load(as: Int64.self)
            }

            if entryError == 0, !name.isEmpty, name != ".", name != ".." {
                let isDir  = objType == VDIR.rawValue
                let isLink = objType == VLNK.rawValue
                let mdate: Date? = (objType == VREG.rawValue && tvSec > 0)
                    ? Date(timeIntervalSince1970: TimeInterval(tvSec))
                    : nil
                body(name, devid, isDir, isLink, allocSize, mdate)
            }

            entryPtr = entryBase.advanced(by: Int(entryLen))
        }
    }
}
