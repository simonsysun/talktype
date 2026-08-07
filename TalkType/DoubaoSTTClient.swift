import Foundation

/// 豆包 / 火山引擎语音识别。录音期间优先走流式 2.0；这里的文件极速版保留为失败兜底。
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

    func startStreaming(terms: [String], timeout: TimeInterval) throws -> DoubaoStreamingSession {
        try DoubaoStreamingSession(apiKey: apiKey, terms: terms, timeout: timeout)
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

// MARK: - Streaming speech recognition 2.0

/// 火山流式 2.0 的二进制 WebSocket 协议。保持纯函数，方便不连网就能锁住 header、
/// 大端长度和请求字段；协议字段错一位，服务端只会回一个难定位的 45000xxx。
enum DoubaoStreamProtocol {
    static let endpoint = URL(string: "wss://openspeech.bytedance.com/api/v3/sauc/bigmodel_nostream")!
    static let resourceID = "volc.seedasr.sauc.duration"

    struct ParsedResponse {
        let text: String?
        let isFinal: Bool
    }

    static func makeRequest(apiKey: String, connectID: String,
                            timeout: TimeInterval) -> URLRequest {
        var request = URLRequest(url: endpoint)
        request.timeoutInterval = timeout
        request.setValue(apiKey, forHTTPHeaderField: "X-Api-Key")
        request.setValue(resourceID, forHTTPHeaderField: "X-Api-Resource-Id")
        request.setValue(connectID, forHTTPHeaderField: "X-Api-Connect-Id")
        return request
    }

    static func configFrame(terms: [String]) throws -> Data {
        var fields: [String: Any] = [
            "model_name": DoubaoSTTClient.modelName,
            "enable_punc": true,
            "enable_itn": true,
            "enable_ddc": true,
        ]
        if let context = DoubaoSTTClient.hotwordContext(terms) {
            fields["corpus"] = ["context": context]
        }
        let body: [String: Any] = [
            "user": ["uid": "talktype"],
            "audio": [
                "format": "pcm",
                "codec": "raw",
                "rate": 16_000,
                "bits": 16,
                "channel": 1,
            ],
            "request": fields,
        ]
        let payload = try JSONSerialization.data(withJSONObject: body)
        return frame(messageType: 0x1, flags: 0, serialization: 0x1, payload: payload)
    }

    static func audioFrame(_ pcm: Data, isFinal: Bool) -> Data {
        frame(messageType: 0x2, flags: isFinal ? 0x2 : 0, serialization: 0, payload: pcm)
    }

    static func parseServerFrame(_ data: Data) throws -> ParsedResponse {
        guard data.count >= 8 else { throw STTError.rejected("流式响应格式无效") }
        let first = data[data.startIndex]
        let headerSize = Int(first & 0x0F) * 4
        guard first >> 4 == 0x1, headerSize >= 4, data.count >= headerSize + 4 else {
            throw STTError.rejected("流式响应 header 无效")
        }

        let typeAndFlags = data[data.startIndex + 1]
        let messageType = typeAndFlags >> 4
        let flags = typeAndFlags & 0x0F
        var offset = headerSize

        if messageType == 0xF {
            guard data.count >= offset + 8 else { throw STTError.rejected("流式错误响应无效") }
            let code = data.readUInt32BE(at: offset)
            offset += 4
            let size = Int(data.readUInt32BE(at: offset))
            offset += 4
            guard size >= 0, data.count >= offset + size else {
                throw STTError.rejected("流式错误响应长度无效")
            }
            let payload = data.subdata(in: offset..<(offset + size))
            let detail = providerMessage(from: payload)
            throw STTError.rejected("\(code) \(detail)")
        }

        guard messageType == 0x9 else {
            throw STTError.rejected("未知流式响应类型 \(messageType)")
        }
        // bit 0 表示响应带 sequence；sequence 是有符号 int32，但这里只需跳过。
        if flags & 0x1 != 0 {
            guard data.count >= offset + 4 else { throw STTError.rejected("流式响应 sequence 无效") }
            offset += 4
        }
        guard data.count >= offset + 4 else { throw STTError.rejected("流式响应长度缺失") }
        let size = Int(data.readUInt32BE(at: offset))
        offset += 4
        guard size >= 0, data.count >= offset + size else {
            throw STTError.rejected("流式响应长度无效")
        }
        let payload = data.subdata(in: offset..<(offset + size))
        guard let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw STTError.rejected("流式响应不是 JSON")
        }
        let text = ((json["result"] as? [String: Any])?["text"] as? String)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ParsedResponse(text: text?.isEmpty == false ? text : nil,
                              isFinal: flags & 0x2 != 0)
    }

    /// Test fixture builder shares the production byte layout; unlike the parser tests' JSON,
    /// the frame itself is not provider data and has no useful public API.
    static func testServerFrame(messageType: UInt8, flags: UInt8, payload: Data,
                                errorCode: UInt32? = nil) -> Data {
        if messageType == 0xF {
            var result = Data([0x11, (messageType << 4) | flags, 0x10, 0x00])
            result.appendUInt32BE(errorCode ?? 0)
            result.appendUInt32BE(UInt32(payload.count))
            result.append(payload)
            return result
        }
        return frame(messageType: messageType, flags: flags, serialization: 0x1,
                     payload: payload)
    }

    private static func frame(messageType: UInt8, flags: UInt8, serialization: UInt8,
                              payload: Data) -> Data {
        // v1, 4-byte header, no compression. Avoiding gzip saves CPU and keeps the live audio
        // packets directly inspectable; the protocol explicitly supports uncompressed frames.
        var result = Data([0x11, (messageType << 4) | flags, serialization << 4, 0x00])
        result.appendUInt32BE(UInt32(payload.count))
        result.append(payload)
        return result
    }

    private static func providerMessage(from payload: Data) -> String {
        if let json = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
           let message = json["message"] as? String, !message.isEmpty {
            return message
        }
        return String(data: payload, encoding: .utf8) ?? "unknown error"
    }
}

/// Stateful resampling and PCM16 packetization for the audio tap. The tap only enqueues work;
/// conversion and WebSocket I/O stay on the session's private queue.
struct StreamingPCM16Packetizer {
    private static let targetSampleRate = 16_000
    private static let packetBytes = targetSampleRate / 5 * 2 // 200 ms, mono Int16

    private var sourceRate: Int?
    private var previousSample: Float?
    private var sourcePosition: Double = 0
    private var pcm = Data()

    mutating func append(samples: [Float], sampleRate: Int) -> [Data] {
        guard !samples.isEmpty, sampleRate > 0 else { return [] }
        let converted: [Float]
        if sampleRate == Self.targetSampleRate {
            sourceRate = sampleRate
            previousSample = nil
            sourcePosition = 0
            converted = samples
        } else {
            converted = resample(samples, sampleRate: sampleRate)
        }
        appendPCM16(converted)

        var packets: [Data] = []
        while pcm.count >= Self.packetBytes {
            packets.append(pcm.subdata(in: 0..<Self.packetBytes))
            pcm.removeSubrange(0..<Self.packetBytes)
        }
        return packets
    }

    mutating func finish() -> Data {
        let result = pcm
        pcm.removeAll(keepingCapacity: false)
        previousSample = nil
        sourcePosition = 0
        return result
    }

    private mutating func resample(_ samples: [Float], sampleRate: Int) -> [Float] {
        if sourceRate != sampleRate {
            sourceRate = sampleRate
            previousSample = nil
            sourcePosition = 0
        }
        let combined: [Float]
        if let previousSample = previousSample {
            combined = [previousSample] + samples
        } else {
            combined = samples
        }
        guard combined.count > 1 else {
            previousSample = combined.last
            return []
        }

        let step = Double(sampleRate) / Double(Self.targetSampleRate)
        var output: [Float] = []
        output.reserveCapacity(Int(Double(samples.count) / step) + 1)
        while sourcePosition + 1 < Double(combined.count) {
            let lower = Int(sourcePosition)
            let fraction = Float(sourcePosition - Double(lower))
            output.append(combined[lower] * (1 - fraction) + combined[lower + 1] * fraction)
            sourcePosition += step
        }
        previousSample = combined.last
        sourcePosition -= Double(combined.count - 1)
        return output
    }

    private mutating func appendPCM16(_ samples: [Float]) {
        pcm.reserveCapacity(pcm.count + samples.count * 2)
        for sample in samples {
            let clamped = max(-1, min(1, sample))
            let value = Int16((clamped * 32_767).rounded())
            pcm.append(UInt8(truncatingIfNeeded: value))
            pcm.append(UInt8(truncatingIfNeeded: value >> 8))
        }
    }
}

/// One WebSocket per dictation. Audio is sent while the key is held; release only flushes the
/// final packet and waits for text, which removes the file endpoint's long post-recording tail.
final class DoubaoStreamingSession {
    private let workQueue = DispatchQueue(label: "talktype.stt.stream", qos: .userInitiated)
    private let resultCondition = NSCondition()
    private let urlSession: URLSession
    private let task: URLSessionWebSocketTask
    private let timeout: TimeInterval

    private var packetizer = StreamingPCM16Packetizer()
    private var heldPacket: Data?
    private var sendFailure: Error?
    private var terminalResult: Result<String, Error>?
    private var latestText: String?
    private var acceptingAudio = true

    init(apiKey: String, terms: [String], timeout: TimeInterval) throws {
        self.timeout = timeout
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = timeout
        config.timeoutIntervalForResource = timeout + 5
        let session = URLSession(configuration: config)
        self.urlSession = session
        let request = DoubaoStreamProtocol.makeRequest(
            apiKey: apiKey, connectID: UUID().uuidString, timeout: timeout)
        self.task = session.webSocketTask(with: request)

        let configFrame = try DoubaoStreamProtocol.configFrame(terms: terms)
        task.resume()
        receiveNext()
        workQueue.async { [weak self] in
            self?.sendSynchronously(configFrame)
        }
    }

    /// Called from the realtime audio callback. Copying already happened in AudioRecorder;
    /// enqueueing is intentionally the only work performed on that callback thread.
    func append(samples: [Float], sampleRate: Int) {
        workQueue.async { [weak self] in
            guard let self = self, self.acceptingAudio, self.sendFailure == nil else { return }
            let packets = self.packetizer.append(samples: samples, sampleRate: sampleRate)
            for packet in packets {
                if let previous = self.heldPacket {
                    self.sendSynchronously(DoubaoStreamProtocol.audioFrame(previous, isFinal: false))
                }
                self.heldPacket = packet
            }
        }
    }

    func finish(timeout requestedTimeout: TimeInterval? = nil) throws -> String {
        let wait = requestedTimeout ?? timeout
        let deadline = Date().addingTimeInterval(wait)
        let flushed = DispatchSemaphore(value: 0)
        workQueue.async { [weak self] in
            guard let self = self else { flushed.signal(); return }
            self.acceptingAudio = false
            let remainder = self.packetizer.finish()
            if !remainder.isEmpty {
                if let previous = self.heldPacket {
                    self.sendSynchronously(DoubaoStreamProtocol.audioFrame(previous, isFinal: false))
                }
                self.heldPacket = remainder
            }
            // Holding one packet back lets the final *real* audio carry the protocol's final
            // flag. For recordings shorter than 200 ms, remainder is the only packet.
            let finalPCM = self.heldPacket ?? Data()
            self.heldPacket = nil
            self.sendSynchronously(DoubaoStreamProtocol.audioFrame(finalPCM, isFinal: true))
            flushed.signal()
        }

        guard flushed.wait(timeout: .now() + max(0, deadline.timeIntervalSinceNow)) == .success else {
            cancel()
            throw STTError.timedOut
        }
        if let sendFailure = workQueue.sync(execute: { self.sendFailure }) {
            cancel()
            throw sendFailure
        }

        resultCondition.lock()
        while terminalResult == nil, Date() < deadline {
            _ = resultCondition.wait(until: deadline)
        }
        let result = terminalResult
        resultCondition.unlock()
        guard let result = result else {
            cancel()
            throw STTError.timedOut
        }
        task.cancel(with: .normalClosure, reason: nil)
        urlSession.finishTasksAndInvalidate()
        return try result.get()
    }

    func cancel() {
        workQueue.async { [weak self] in self?.acceptingAudio = false }
        task.cancel(with: .goingAway, reason: nil)
        urlSession.invalidateAndCancel()
        complete(.failure(STTError.unreachable("流式连接已取消")))
    }

    private func sendSynchronously(_ frame: Data) {
        guard sendFailure == nil else { return }
        let sent = DispatchSemaphore(value: 0)
        var failure: Error?
        task.send(.data(frame)) { error in
            failure = error
            sent.signal()
        }
        if sent.wait(timeout: .now() + timeout) != .success {
            task.cancel(with: .goingAway, reason: nil)
            sendFailure = STTError.timedOut
        } else if let failure = failure {
            sendFailure = STTError.unreachable(failure.localizedDescription)
        }
        if let sendFailure = sendFailure {
            complete(.failure(sendFailure))
        }
    }

    private func receiveNext() {
        task.receive { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .failure(let error):
                let mapped = (error as? URLError)?.code == .timedOut
                    ? STTError.timedOut
                    : STTError.unreachable(error.localizedDescription)
                self.complete(.failure(mapped))
            case .success(let message):
                let data: Data
                switch message {
                case .data(let received): data = received
                case .string(let string): data = Data(string.utf8)
                @unknown default:
                    self.complete(.failure(STTError.rejected("未知流式消息")))
                    return
                }
                do {
                    let parsed = try DoubaoStreamProtocol.parseServerFrame(data)
                    if let text = parsed.text { self.latestText = text }
                    if parsed.isFinal {
                        if let text = self.latestText, !text.isEmpty {
                            self.complete(.success(text))
                        } else {
                            self.complete(.failure(STTError.emptyResponse))
                        }
                    } else {
                        self.receiveNext()
                    }
                } catch {
                    self.complete(.failure(error))
                }
            }
        }
    }

    private func complete(_ result: Result<String, Error>) {
        resultCondition.lock()
        if terminalResult == nil {
            terminalResult = result
            resultCondition.broadcast()
        }
        resultCondition.unlock()
    }
}

extension Data {
    func readUInt32BE(at offset: Int) -> UInt32 {
        guard offset >= 0, count >= offset + 4 else { return 0 }
        return (UInt32(self[startIndex + offset]) << 24)
            | (UInt32(self[startIndex + offset + 1]) << 16)
            | (UInt32(self[startIndex + offset + 2]) << 8)
            | UInt32(self[startIndex + offset + 3])
    }

    mutating func appendUInt32BE(_ value: UInt32) {
        append(UInt8(truncatingIfNeeded: value >> 24))
        append(UInt8(truncatingIfNeeded: value >> 16))
        append(UInt8(truncatingIfNeeded: value >> 8))
        append(UInt8(truncatingIfNeeded: value))
    }
}
