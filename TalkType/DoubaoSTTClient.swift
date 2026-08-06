import Foundation

/// 豆包 / 火山引擎 —— 大模型录音文件识别「极速版」。
///
/// 火山的流式接口走 WebSocket 二进制帧，极速版是普通的一次 HTTP POST，音频 base64 放在
/// body 里，同步返回文字。听写只需要后者。
///
/// 标点、口语数字规整和语义顺滑都显式打开：TalkType 已经没有任何本地后处理，这三个开关
/// 决定返回结果能不能直接粘贴。
struct DoubaoSTTClient {
    static let endpoint = URL(string: "https://openspeech.bytedance.com/api/v3/auc/bigmodel/recognize/flash")!
    /// 极速版专用的 resource id；标准版是 `volc.bigasr.auc`，走的是提交 + 轮询两步。
    static let resourceID = "volc.bigasr.auc_turbo"
    static let modelName = "bigmodel"

    let apiKey: String
    private let session: URLSession?

    init(apiKey: String, session: URLSession? = nil) {
        self.apiKey = apiKey
        self.session = session
    }

    func transcribe(wav: Data, terms: [String], timeout: TimeInterval) throws -> String {
        let session = self.session ?? STTTransport.makeSession(timeout: timeout)
        let request = Self.makeRequest(apiKey: apiKey, wav: wav, terms: terms, timeout: timeout,
                                       requestID: UUID().uuidString)
        let data = try STTTransport.run(request, session: session, timeout: timeout)
        return try Self.parse(data)
    }

    // MARK: - Request

    static func makeRequest(apiKey: String, wav: Data, terms: [String],
                            timeout: TimeInterval, requestID: String) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(requestID, forHTTPHeaderField: "X-Api-Request-Id")
        request.setValue("-1", forHTTPHeaderField: "X-Api-Sequence")
        request.timeoutInterval = timeout
        request.httpBody = try? JSONSerialization.data(withJSONObject: body(wav: wav, terms: terms))
        return request
    }

    static func body(wav: Data, terms: [String]) -> [String: Any] {
        var requestFields: [String: Any] = [
            "model_name": modelName,
            "enable_punc": true,
            "enable_itn": true,
            "enable_ddc": true,
        ]
        if let context = hotwordContext(terms) {
            // 火山把热词塞在一个 JSON *字符串* 里，不是嵌套对象。这个格式来自流式接口文档；
            // 已用极速版实测：它会把 "Cloud Code" 拉回 "Claude Code"。只在真的有词时带上，
            // 避免每次请求多传一块无意义的结构。
            requestFields["corpus"] = ["context": context]
        }

        return [
            "user": ["uid": "talktype"],
            "audio": [
                "data": wav.base64EncodedString(),
                "format": "wav",
                "codec": "raw",
                "rate": 16000,
                "bits": 16,
                "channel": 1,
            ],
            "request": requestFields,
        ]
    }

    static func hotwordContext(_ terms: [String]) -> String? {
        let clean = terms
            .map { $0.replacingOccurrences(of: "[\r\n]+", with: " ", options: .regularExpression) }
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .prefix(100)          // 文档给的上限
        guard !clean.isEmpty else { return nil }
        let payload = ["hotwords": clean.map { ["word": $0] }]
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    // MARK: - Response

    /// 成功时文字在 `result.text`。火山也会用 HTTP 200 配一个错误 body 回应，所以拿不到
    /// 文字时要把它自己的说法带回去，而不是笼统报「没有返回」。
    static func parse(_ data: Data) throws -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw STTError.emptyResponse
        }
        if let result = json["result"] as? [String: Any],
           let text = (result["text"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
           !text.isEmpty {
            return text
        }
        if let message = json["message"] as? String, !message.isEmpty {
            let code = json["code"].map { "\($0) " } ?? ""
            throw STTError.rejected(code + message)
        }
        throw STTError.emptyResponse
    }
}
