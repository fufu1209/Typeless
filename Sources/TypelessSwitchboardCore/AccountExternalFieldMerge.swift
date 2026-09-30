import Foundation

// MARK: - AccountExternalFieldMerge
//
// 「外部脚本改了账号池，GUI 一落盘就把它抹掉」这个问题的合并规则。
//
// ## 问题
//
// `store.json` 是**整份覆写**：`SwitchboardStore.save()` 把整个 `state` 一次性编码落盘。
// 而 GUI 是常驻进程，内存里拿着启动那一刻的副本；维护脚本
// （`revive-account-sessions.js` 复活会话、`sync-account-quotas.js` 同步额度）
// 会直接改 `store.json`。两边各持一份，**谁后写谁赢** ——
// GUI 随后的一次落盘就把脚本的成果整份还原。
//
// 2026-09-30 实测：17 个账号复活后只剩 5 个留在文件里，而脚本那一侧
// 打印的是「✓ 已写回账号池」、官方接口当场也验证通过 —— 属**静默假成功**。
//
// ## 规则
//
// 不做通用 merge（那需要给每个字段加时钟，侵入面太大）。只处理外部脚本**真正会改**的
// 三个字段：`rawUserDataPayload` / `usedCharacters` / `monthlyLimit`。
// 其余字段（状态、备注、复核结果、暂停…）一律以 GUI 为准。
//
// 判据靠一份**加载时基线**：
//
// | 磁盘 vs 基线 | 内存 vs 基线 | 含义 | 处置 |
// |---|---|---|---|
// | 变了 | 没变 | 外部脚本改的 | **采纳磁盘** |
// | 变了 | 也变了 | GUI 自己改的（如刚换完号） | 以内存为准，**不采纳** |
// | 没变 | — | 没有外部改动 | 无需采纳 |
//
// 基线必须在**从磁盘加载之后、且任何 GUI 改动之前**采集。若图省事在首次 `save()`
// 时才懒采基线，就会把「GUI 刚换完号写进内存的 payload」当成基线，
// 于是磁盘上的旧 payload 反而被判定为「外部更新」而采纳回来 —— 换号结果被回退。
public enum AccountExternalFieldMerge {

    /// 一个账号里「外部脚本会改」的那几个字段。
    public struct ExternalFields: Equatable, Sendable {
        public let id: UUID
        public let rawUserDataPayload: String?
        public let usedCharacters: Int
        public let monthlyLimit: Int

        public init(id: UUID, rawUserDataPayload: String?, usedCharacters: Int, monthlyLimit: Int) {
            self.id = id
            self.rawUserDataPayload = rawUserDataPayload
            self.usedCharacters = usedCharacters
            self.monthlyLimit = monthlyLimit
        }
    }

    /// 算出「应当采纳磁盘版本」的账号（按 id 索引）。
    ///
    /// 只返回需要改动的账号；调用方把它们的那三个字段写回内存即可。
    public static func adoptions(disk: [ExternalFields],
                                 memory: [ExternalFields],
                                 baseline: [ExternalFields]) -> [UUID: ExternalFields] {
        let baselineByID = Dictionary(baseline.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let memoryByID = Dictionary(memory.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var result: [UUID: ExternalFields] = [:]
        for diskAccount in disk {
            // 基线里没有 → 是外部新加的账号，不属于「字段采纳」的范畴（由调用方另行处理）。
            guard let base = baselineByID[diskAccount.id] else { continue }
            // 内存里没有 → GUI 删掉了这个账号，不该把它拉回来。
            guard let mem = memoryByID[diskAccount.id] else { continue }

            let diskChanged = diskAccount != base
            let memoryChanged = mem != base
            guard diskChanged, !memoryChanged else { continue }

            result[diskAccount.id] = diskAccount
        }
        return result
    }

    /// 磁盘上「基线里没有、内存里也没有」的账号 —— 外部新注册进来的。
    ///
    /// 单独列出来是因为它需要整份 `Account` 才能追加，而本类型只带三个字段。
    /// 判据同样是基线：基线里没有才说明是**新出现**的；
    /// 基线里有而内存没有，那是用户自己删了，不能复活。
    public static func externallyAddedIDs(disk: [UUID], baseline: [UUID], memory: [UUID]) -> [UUID] {
        let baselineSet = Set(baseline)
        let memorySet = Set(memory)
        var seen = Set<UUID>()
        var result: [UUID] = []
        for id in disk where !baselineSet.contains(id) && !memorySet.contains(id) {
            guard seen.insert(id).inserted else { continue }
            result.append(id)
        }
        return result
    }
}
