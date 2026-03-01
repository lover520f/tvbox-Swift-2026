import Foundation

/// 网络请求封装 - 对应 Android 版 OkGo
class NetworkManager {
    /// 全局共享实例。
    static let shared = NetworkManager()
    
    /// 兜底字符集名称列表（按常见中文资源站编码优先级排序）。
    private static let fallbackCharsetNames: [String] = [
        "utf-8",
        "gb18030",
        "gbk",
        "gb2312",
        "utf-16",
        "utf-16le",
        "utf-16be",
        "utf-32",
        "windows-1252",
        "iso-8859-1"
    ]
    
    /// 兜底字符串编码列表（与字符集列表互补）。
    private static let fallbackStringEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16LittleEndian,
        .utf16BigEndian,
        .utf32,
        .utf32LittleEndian,
        .utf32BigEndian,
        .windowsCP1252,
        .isoLatin1
    ]
    
    /// 内部会话对象，统一超时与连接上限配置。
    private let session: URLSession
    /// JSON 解码器。
    private let decoder = JSONDecoder()
    
    /// 私有初始化，防止外部创建多个请求管理器。
    private init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 15
        config.timeoutIntervalForResource = 30
        config.httpMaximumConnectionsPerHost = 5
        self.session = URLSession(configuration: config)
    }
    
    /// GET 请求获取字符串
    func getString(from urlString: String, headers: [String: String]? = nil) async throws -> String {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }
        
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        headers?.forEach { request.setValue($1, forHTTPHeaderField: $0) }
        
        let (data, response) = try await session.data(for: request)
        
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NetworkError.invalidResponse
        }
        
        guard (200...299).contains(httpResponse.statusCode) else {
            throw NetworkError.httpError(httpResponse.statusCode)
        }
        
        // 统一走字符集探测 + 多编码兜底，降低跨源乱码概率。
        guard let str = Self.decodeString(data: data, response: httpResponse) else {
            throw NetworkError.decodingError("文本解码失败")
        }
        
        return str
    }
    
    /// GET 请求解码 JSON
    func getJSON<T: Decodable>(from urlString: String, type: T.Type, headers: [String: String]? = nil) async throws -> T {
        let str = try await getString(from: urlString, headers: headers)
        guard let data = str.data(using: .utf8) else {
            throw NetworkError.decodingError("字符串转 Data 失败")
        }
        return try decoder.decode(T.self, from: data)
    }
    
    /// GET 请求获取原始 Data
    func getData(from urlString: String) async throws -> Data {
        guard let url = URL(string: urlString.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw NetworkError.invalidURL(urlString)
        }
        let (data, _) = try await session.data(from: url)
        return data
    }
    
    /// 文本解码策略：
    /// 1) 先用响应头声明字符集；
    /// 2) 再按常见字符集与编码顺序尝试；
    /// 3) 最后用 UTF-8 宽容解码兜底。
    private static func decodeString(data: Data, response: HTTPURLResponse) -> String? {
        // 优先使用服务端声明的字符集（如 gbk / gb2312 / gb18030）
        if let charset = response.textEncodingName,
           let declaredEncoding = encoding(fromIANACharset: charset),
           let value = String(data: data, encoding: declaredEncoding) {
            return value
        }
        
        for charset in fallbackCharsetNames {
            if let encoding = encoding(fromIANACharset: charset),
               let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        for encoding in fallbackStringEncodings {
            if let value = String(data: data, encoding: encoding) {
                return value
            }
        }
        
        // 最后兜底，避免单纯因编码不一致直接报错
        if !data.isEmpty {
            return String(decoding: data, as: UTF8.self)
        }
        
        return nil
    }
    
    /// IANA 字符集名转 `String.Encoding`。
    private static func encoding(fromIANACharset charset: String) -> String.Encoding? {
        let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
        guard cfEncoding != kCFStringEncodingInvalidId else {
            return nil
        }
        let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
        return String.Encoding(rawValue: nsEncoding)
    }
}

/// 网络层错误定义。
enum NetworkError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case httpError(Int)
    case decodingError(String)
    
    /// 面向 UI/日志的错误描述。
    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "无效的URL: \(url)"
        case .invalidResponse: return "无效的响应"
        case .httpError(let code): return "HTTP 错误: \(code)"
        case .decodingError(let msg): return "解码错误: \(msg)"
        }
    }
}
