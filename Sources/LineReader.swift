import Foundation

/// JSONL 分块游标读取：从 offset 起每次读 1 MB，只把完整行（不含换行）交给 body，
/// 半行留给下次。返回最后一个完整行之后的偏移。会话日志动辄几十 MB，不能整个读进内存。
enum LineReader {
    static func read(_ fh: FileHandle, from offset: UInt64, to size: UInt64, _ body: (Data, UInt64) -> Void) throws -> UInt64 {
        try fh.seek(toOffset: offset)
        var remaining = size > offset ? size - offset : 0
        var pending = Data()
        var cursor = offset
        var done = false
        while remaining > 0, !done {
            // FileHandle 读出的块是 autorelease 的：不逐块放掉，几百 MB 的文件会一直堆到函数返回
            try autoreleasepool {
                guard let chunk = try fh.read(upToCount: Int(min(1 << 20, remaining))), !chunk.isEmpty else { done = true; return }
                remaining -= UInt64(chunk.count)
                pending.append(chunk)
                guard let lastNL = pending.lastIndex(of: 0x0A) else { return }
                let end = pending.index(after: lastNL)
                for line in pending[pending.startIndex..<end].split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                    body(Data(line), cursor)
                    cursor += UInt64(line.count + 1)
                }
                pending = Data(pending[end...])
            }
        }
        return cursor
    }
}
