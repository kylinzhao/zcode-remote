import Foundation

/// ntfy /json 流事件解析与 topic 工具（纯函数；Android Ntfy.kt 的对应物，语义逐条对齐）。
enum Ntfy {
    struct Event: Equatable {
        let event: String
        let topic: String
        let title: String
        let message: String
    }

    /// 单行 /json 流事件 → Event；格式异常返回 nil（keepalive 等非消息行同样走这里）。
    static func parse(line: String) -> Event? {
        guard let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let event = obj["event"] as? String,
              let topic = obj["topic"] as? String,
              !event.isEmpty, !topic.isEmpty
        else { return nil }
        return Event(event: event, topic: topic,
                     title: obj["title"] as? String ?? "",
                     message: obj["message"] as? String ?? "")
    }

    /// 合法 topic：字母、数字、-、_，1-64 位（Android 版正则的 ASCII 等价实现）。
    static func isValidTopic(_ s: String) -> Bool {
        (1...64).contains(s.count) && s.allSatisfy { c in
            c == "-" || c == "_" || (c.isASCII && (c.isLetter || c.isNumber))
        }
    }

    /// 随机私有 topic：ntfy 的安全模型是「不知道 topic 名就收不到」。
    static func randomTopic() -> String {
        "zcode-" + UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)
    }
}
