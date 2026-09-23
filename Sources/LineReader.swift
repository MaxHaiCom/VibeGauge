import Foundation

/// JSONL 分块游标读取：从 offset 起每次读 1 MB，只把完整行（不含换行）交给 body，
/// 半行留给下次。返回最后一个完整行之后的偏移。会话日志动辄几十 MB，不能整个读进内存。
enum LineReader {
    /// 单行上限：超过就整行跳过（真实日志里单行最多几 MB，没有换行的超长数据多半是坏文件）
    static let maxLine = 32 << 20

    static func read(_ fh: FileHandle, from offset: UInt64, to size: UInt64, maxLine: Int = maxLine,
                     _ body: (Data, UInt64) -> Void) throws -> UInt64 {
        try fh.seek(toOffset: offset)
        var remaining = size > offset ? size - offset : 0
        var pending = Data()
        var cursor = offset
        var skipping = false            // 正在跳过一条超长行：丢到下一个换行为止
        var done = false
        while remaining > 0, !done {
            // FileHandle 读出的块是 autorelease 的：不逐块放掉，几百 MB 的文件会一直堆到函数返回
            try autoreleasepool {
                guard let chunk = try fh.read(upToCount: Int(min(1 << 20, remaining))), !chunk.isEmpty else { done = true; return }
                remaining -= UInt64(chunk.count)
                // 只在新块里找换行：每块都从头扫 pending 会变成平方级
                guard let lastNL = chunk.lastIndex(of: 0x0A) else {
                    if skipping { cursor += UInt64(chunk.count); return }
                    pending.append(chunk)
                    if pending.count > maxLine { cursor += UInt64(pending.count); pending = Data(); skipping = true }
                    return
                }
                var head = chunk[chunk.startIndex...lastNL]
                if skipping, let firstNL = head.firstIndex(of: 0x0A) {
                    let dropped = head.distance(from: head.startIndex, to: firstNL) + 1
                    cursor += UInt64(dropped)
                    head = head[head.index(after: firstNL)...]
                    skipping = false
                }
                pending.append(head)
                for line in pending.split(separator: 0x0A, omittingEmptySubsequences: false).dropLast() {
                    body(Data(line), cursor)
                    cursor += UInt64(line.count + 1)
                }
                pending = Data(chunk[chunk.index(after: lastNL)...])
            }
        }
        return cursor
    }
}
