import Foundation

/// JSONL 分块游标读取：从 offset 起每次读 1 MB，只把完整行（不含换行）交给 body，
/// 半行留给下次。返回最后一个完整行之后的偏移。会话日志动辄几十 MB，不能整个读进内存。
enum LineReader {
    static func read(_ fh: FileHandle, from offset: UInt64, to size: UInt64, _ body: (Data, UInt64) -> Void) throws -> UInt64 {
        try fh.seek(toOffset: offset)
        var remaining = size > offset ? size - offset : 0
        var pending = Data()
        var cursor = offset
        while remaining > 0 {
            guard let chunk = try fh.read(upToCount: Int(min(1 << 20, remaining))), !chunk.isEmpty else { break }
            remaining -= UInt64(chunk.count)
            pending.append(chunk)
            guard let lastNL = pending.lastIndex(of: 0x0A) else { continue }
            let end = pending.index(after: lastNL)
            for line in pending[pending.startIndex..<end].split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                autoreleasepool { body(Data(line), cursor) }
                cursor += UInt64(line.count + 1)
            }
            pending = Data(pending[end...])
        }
        return cursor
    }
}
