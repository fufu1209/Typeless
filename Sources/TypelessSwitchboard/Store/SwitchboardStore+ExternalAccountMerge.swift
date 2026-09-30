import Foundation
import TypelessSwitchboardCore

// MARK: - 外部写入合并
//
// `store.json` 是**整份覆写**（`SwitchboardStore.save()` 一次编码整个 `state`），
// 而 GUI 是常驻进程 —— 内存里拿着启动那一刻的账号池副本。
// 维护脚本（`revive-account-sessions.js` 复活会话、`sync-account-quotas.js` 同步额度）
// 直接改 `store.json` 之后，GUI 的任意一次落盘都会把脚本的成果**整份还原**；
// 而脚本那一侧打印的是「✓ 已写回账号池」、官方接口当场也验证通过。
//
// 2026-09-30 实测：17 个账号复活后只剩 5 个留在文件里（活下来的恰好每 3 个一个，
// 正是覆写周期的指纹）。退出 GUI 后 `store.json` 的 mtime 连续 65 秒纹丝不动，
// 确认覆盖者就是它。属**静默假成功**。
//
// 这里在落盘前看一眼磁盘，把外部改动采纳回来。合并规则见 `AccountExternalFieldMerge`。

extension SwitchboardStore {

    /// 落盘前采纳外部脚本对 store.json 的改动（账号池字段 + 额度同步时刻）。
    ///
    /// 没有外部写入时开销只是一次 `stat` —— 这一点很重要：`save()` 会被
    /// UI 的逐字符输入触发，不能在每次落盘前都读一遍 50 KB 的文件。
    func adoptExternalStoreUpdatesIfNeeded() {
        guard let disk = readStoreFromDiskIfExternallyChanged() else { return }

        // ① 外部新注册进来的账号（基线里没有、内存里也没有）→ 追加。
        //    判据同样是基线：基线里有而内存没有，那是用户自己删了，不能复活。
        let addedIDs = AccountExternalFieldMerge.externallyAddedIDs(
            disk: disk.accounts.map(\.id),
            baseline: baselineAccounts.map(\.id),
            memory: state.accounts.map(\.id)
        )
        var adoptedCount = 0
        if !addedIDs.isEmpty {
            let existing = Set(state.accounts.map(\.id))
            let additions = disk.accounts.filter { addedIDs.contains($0.id) && !existing.contains($0.id) }
            state.accounts.append(contentsOf: additions)
            adoptedCount += additions.count
        }

        // ② 外部改过的账号 → 只采纳那三个字段（详见 AccountExternalFieldMerge 的规则表）。
        let adoptions = AccountExternalFieldMerge.adoptions(
            disk: disk.accounts.map(Self.externalFields(of:)),
            memory: state.accounts.map(Self.externalFields(of:)),
            baseline: baselineAccounts.map(Self.externalFields(of:))
        )
        if !adoptions.isEmpty {
            for index in state.accounts.indices {
                guard let fresh = adoptions[state.accounts[index].id] else { continue }
                state.accounts[index].rawUserDataPayload = fresh.rawUserDataPayload
                state.accounts[index].usedCharacters = fresh.usedCharacters
                state.accounts[index].monthlyLimit = fresh.monthlyLimit
                adoptedCount += 1
            }
        }

        // ③ v2.6.6：状态级的「额度同步时刻」也采纳 —— **取较新者**。
        //    脚本同步与 App 同步都是「同步事件」，谁晚谁准。不做这一步，
        //    `sync-account-quotas.js` 刚写进去的时刻会被这次落盘用内存里的旧值盖掉 ——
        //    与 v2.6.5 修的账号字段是同一类问题，只是发生在状态级字段上。
        let adoptedClock = (disk.lastQuotaSyncAt ?? .distantPast) > (lastQuotaSyncAt ?? .distantPast)
        if adoptedClock {
            lastQuotaSyncAt = disk.lastQuotaSyncAt
        }

        guard adoptedCount > 0 || adoptedClock else { return }
        lastExternalAdoptionCount = adoptedCount
        lastExternalAdoptionAt = Date()
        // 留一条痕迹：这件事以前是完全静默的，排查时最缺的就是它。
        var parts: [String] = []
        if adoptedCount > 0 {
            parts.append("\(adoptedCount) 个账号（含外部新增 \(addedIDs.count) 个）")
        }
        if adoptedClock {
            parts.append("额度同步时刻")
        }
        let dir = fileURL.deletingLastPathComponent().appendingPathComponent("Logs", isDirectory: true)
        LogFileRotator.append(
            line: "[\(ISO8601DateFormatter().string(from: Date()))] 落盘前采纳外部改动："
                + parts.joined(separator: "、") + " —— 否则这次覆写会把它们抹掉",
            to: dir.appendingPathComponent("external-merge.log")
        )
    }

    /// 磁盘上的 `store.json` —— **仅当它相对我们上次写盘确有变化时**才读。
    ///
    /// 返回 nil 表示「没有外部写入」或「读不出来」，两种情况都不该改动内存状态。
    private func readStoreFromDiskIfExternallyChanged() -> PersistedState? {
        guard let fingerprint = currentStoreFileFingerprint() else { return nil }
        if let written = lastWrittenFileFingerprint, written == fingerprint { return nil }
        guard let data = try? Data(contentsOf: fileURL),
              let disk = try? JSONDecoder.appDecoder.decode(PersistedState.self, from: data) else {
            return nil
        }
        return disk
    }

    /// 文件指纹：大小 + 修改时间。两者都没变就认为内容没变。
    func currentStoreFileFingerprint() -> String? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: fileURL.path) else { return nil }
        let size = (attrs[.size] as? NSNumber)?.intValue ?? -1
        let mtime = (attrs[.modificationDate] as? Date)?.timeIntervalSince1970 ?? -1
        return "\(size)-\(Int(mtime))"
    }

    private static func externalFields(of account: Account) -> AccountExternalFieldMerge.ExternalFields {
        AccountExternalFieldMerge.ExternalFields(
            id: account.id,
            rawUserDataPayload: account.rawUserDataPayload,
            usedCharacters: account.usedCharacters,
            monthlyLimit: account.monthlyLimit
        )
    }
}
