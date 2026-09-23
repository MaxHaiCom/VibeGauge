import Foundation
import os

/// 检查新版本：每天最多问一次 GitHub「最新 release 是哪个」，有新的就在面板底栏提示、发一次通知。
/// 只读公开接口，不带任何身份信息；设置里可关（updateCheckEnabled）。
/// 不自动下载安装 —— 没有开发者签名的 App 不该从网上拉东西替换自己。
final class UpdateChecker {
    static let shared = UpdateChecker()
    static let repo = "MaxHaiCom/VibeGauge"
    /// 底栏「新版本」打开的地址：固定写死本仓库的最新发布页，不用接口返回的网址（带 ../ 的地址能骗过前缀检查）
    static let releasePage = URL(string: "https://github.com/\(repo)/releases/latest")!

    private let defaults = UserDefaults.standard
    private let log = Logger(subsystem: "com.haifeng.vibegauge", category: "update")

    var current: String { Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0" }
    var enabled: Bool { defaults.object(forKey: "updateCheckEnabled") as? Bool ?? true }

    /// "v1.10.0" 比 "1.9.2" 新：逐段按数字比，缺的段当 0
    static func isNewer(_ a: String, than b: String) -> Bool {
        func parts(_ s: String) -> [Int] {
            s.trimmingCharacters(in: CharacterSet(charactersIn: "vV")).split(separator: ".").map { Int($0.prefix { $0.isNumber }) ?? 0 }
        }
        let x = parts(a), y = parts(b)
        for i in 0..<max(x.count, y.count) {
            let p = i < x.count ? x[i] : 0, q = i < y.count ? y[i] : 0
            if p != q { return p > q }
        }
        return false
    }

    /// 距上次检查不足 24 小时就跳过（调用方可以每轮扫描都调）。发现没通知过的新版本 → onNew
    func checkIfDue(onNew: @escaping (String) -> Void) {
        guard enabled else { return }
        let now = Date().timeIntervalSince1970
        guard now - defaults.double(forKey: "lastUpdateCheck") >= 86400 else { return }
        defaults.set(now, forKey: "lastUpdateCheck")
        guard let url = URL(string: "https://api.github.com/repos/\(Self.repo)/releases/latest") else { return }
        var req = URLRequest(url: url)
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("VibeGauge/\(current)", forHTTPHeaderField: "User-Agent")
        req.timeoutInterval = 15
        URLSession.shared.dataTask(with: req) { [weak self] data, _, error in
            guard let self else { return }
            // 只取版本号，且必须是纯数字点分（1.2.0）：接口返回的其他内容一概不用
            guard let data, let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tag = json["tag_name"] as? String else {
                self.log.notice("检查更新失败 \(error?.localizedDescription ?? "响应不符合预期", privacy: .public)")
                return
            }
            let v = tag.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
            guard v.range(of: #"^\d{1,4}(\.\d{1,4}){0,3}$"#, options: .regularExpression) != nil else { return }
            self.defaults.set(v, forKey: "latestVersion")
            guard Self.isNewer(v, than: self.current), self.defaults.string(forKey: "notifiedVersion") != v else { return }
            self.defaults.set(v, forKey: "notifiedVersion")
            DispatchQueue.main.async { onNew(v) }
        }.resume()
    }
}
