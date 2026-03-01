import Foundation

/// 核心配置管理器 - 对应 Android 版 ApiConfig.java
/// 负责加载和解析远程 JSON 配置，管理视频源列表
@MainActor
class ApiConfig: ObservableObject {
    static let shared = ApiConfig()
    
    @Published var sourceBeanList: [SourceBean] = []
    @Published var homeSourceBean: SourceBean?
    @Published var parseBeanList: [ParseBean] = []
    @Published var liveChannelGroupList: [LiveChannelGroup] = []
    @Published var dohList: [(name: String, url: String)] = []
    @Published var isLoaded: Bool = false
    @Published var configUrl: String = ""
    @Published var liveConfigUrl: String = ""
    @Published var wallpaper: String = ""
    
    private let network = NetworkManager.shared
    
    private init() {}
    
    /// 加载远程配置
    func loadConfig(from apiUrl: String) async throws {
        try await loadConfigs(vodApiUrl: apiUrl, liveApiUrl: apiUrl)
    }
    
    /// 分别加载点播配置和直播配置
    func loadConfigs(vodApiUrl: String, liveApiUrl: String) async throws {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            throw ConfigError.parseError("点播接口地址不能为空")
        }
        
        let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
        self.configUrl = trimmedVod
        self.liveConfigUrl = resolvedLive
        
        if trimmedVod == resolvedLive {
            let config = try await fetchConfig(from: trimmedVod)
            parseConfig(config, apiUrl: trimmedVod, includeSources: true, includeLive: true)
        } else {
            let vodConfig = try await fetchConfig(from: trimmedVod)
            parseConfig(vodConfig, apiUrl: trimmedVod, includeSources: true, includeLive: false)
            
            let liveConfig = try await fetchConfig(from: resolvedLive)
            parseConfig(liveConfig, apiUrl: resolvedLive, includeSources: false, includeLive: true)
        }
        
        self.isLoaded = true
    }
    
    private func fetchConfig(from apiUrl: String) async throws -> AppConfigData {
        let jsonStr = try await network.getString(from: apiUrl)
        
        // 清理非标准 JSON（Android 端 Gson 默认支持注释，Swift 需要手动处理）
        let cleanedJson = Self.stripJsonComments(jsonStr)
        
        guard let data = cleanedJson.data(using: .utf8) else {
            throw ConfigError.parseError("无法解析配置数据")
        }
        
        return try JSONDecoder().decode(AppConfigData.self, from: data)
    }
    
    /// 去除 JSON 中的 // 行注释，兼容 TVBox 配置文件格式
    /// Android 端 Gson 原生支持注释，Swift 的 JSONDecoder 不支持
    static func stripJsonComments(_ json: String) -> String {
        let lines = json.components(separatedBy: "\n")
        var result: [String] = []
        
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // 跳过纯注释行（以 // 开头）
            if trimmed.hasPrefix("//") {
                continue
            }
            // 处理行尾注释：只在引号外的 // 才是注释
            let cleaned = removeInlineComment(from: line)
            result.append(cleaned)
        }
        
        var joined = result.joined(separator: "\n")
        
        // 修复尾部逗号问题：,] 或 ,} （注释行被删除后可能产生）
        // 使用正则替换 , 后面跟着空白和 ] 或 } 的情况
        joined = joined.replacingOccurrences(
            of: ",\\s*([\\]\\}])",
            with: "$1",
            options: .regularExpression
        )
        
        return joined
    }
    
    /// 移除行内注释（只处理不在字符串内的 //）
    private static func removeInlineComment(from line: String) -> String {
        var inString = false
        var escape = false
        let chars = Array(line)
        
        for i in 0..<chars.count {
            let c = chars[i]
            if escape {
                escape = false
                continue
            }
            if c == "\\" && inString {
                escape = true
                continue
            }
            if c == "\"" {
                inString.toggle()
                continue
            }
            if !inString && c == "/" && i + 1 < chars.count && chars[i + 1] == "/" {
                // 找到行内注释，截断
                return String(chars[0..<i]).trimmingCharacters(in: .whitespaces).hasSuffix(",")
                    ? String(String(chars[0..<i]).trimmingCharacters(in: .whitespaces).dropLast())
                    : String(chars[0..<i])
            }
        }
        return line
    }
    
    /// 解析配置数据
    private func parseConfig(
        _ config: AppConfigData,
        apiUrl: String,
        includeSources: Bool,
        includeLive: Bool
    ) {
        if includeSources {
            // 解析站点列表
            var sources: [SourceBean] = []
            if let sites = config.sites {
                for site in sites {
                    let bean = SourceBean(
                        key: site.key ?? UUID().uuidString,
                        name: site.name ?? "未命名",
                        api: site.api ?? "",
                        searchable: site.searchable?.value ?? 1,
                        filterable: site.filterable?.value ?? 1,
                        playerType: site.playerType?.value ?? 0,
                        type: site.type?.value ?? 1,
                        ext: site.ext?.stringValue
                    )
                    sources.append(bean)
                }
            }
            self.sourceBeanList = sources
            
            // 设置默认主页源：优先选择 Swift 支持的源
            if let saved = UserDefaults.standard.string(forKey: HawkConfig.HOME_API),
               let found = sources.first(where: { $0.key == saved }) {
                self.homeSourceBean = found
            } else {
                // 优先选择支持的源（type 0/1/4），跳过 type=3 (JAR)
                self.homeSourceBean = sources.first(where: { $0.isSupportedInSwift }) ?? sources.first
            }
            
            // 解析解析器列表
            if let parses = config.parses {
                self.parseBeanList = parses.map { p in
                    ParseBean(name: p.name ?? "", url: p.url ?? "", type: p.type?.value ?? 0)
                }
            }
            
            // 解析 DoH 列表
            if let dohs = config.doh {
                self.dohList = dohs.compactMap { d in
                    guard let name = d.name, let url = d.url else { return nil }
                    return (name: name, url: url)
                }
            }
            
            // 壁纸
            self.wallpaper = config.wallpaper ?? ""
        }
        
        if includeLive {
            if let lives = config.lives {
                parseLives(lives, apiUrl: apiUrl)
            } else {
                liveChannelGroupList = []
            }
        }
    }
    
    /// 解析直播列表
    private func parseLives(_ lives: [AppConfigData.LiveConfig], apiUrl: String) {
        Task {
            var mergedGroups: [String: LiveChannelGroup] = [:]
            
            for live in lives {
                // 如果有 url，从远程加载
                if let liveUrl = live.url, !liveUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    let resolvedUrl = resolveLiveUrl(liveUrl, baseConfigUrl: apiUrl)
                    do {
                        let content = try await network.getString(from: resolvedUrl)
                        let groups = parseLiveContent(content)
                        mergeLiveGroups(groups, into: &mergedGroups)
                    } catch {
                        print("加载直播源失败: \(resolvedUrl), error: \(error)")
                    }
                }
                
                // 如果有内嵌频道
                if let channels = live.channels {
                    let inlineGroups = parseInlineLiveChannels(channels)
                    mergeLiveGroups(inlineGroups, into: &mergedGroups)
                }
            }
            
            self.liveChannelGroupList = sortedGroups(from: mergedGroups)
        }
    }
    
    /// 解析 m3u / txt 格式的直播内容
    private func parseLiveContent(_ content: String) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        var currentGroupName = "默认"
        
        let lines = content.components(separatedBy: .newlines)
        let firstNonEmptyLine = lines.first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        let isM3U = firstNonEmptyLine?.uppercased().hasPrefix("#EXTM3U") == true
        
        // 检测是否为 M3U 格式
        if isM3U {
            var currentName = ""
            var currentGroup = "默认"
            
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("#EXTINF:") {
                    // 解析频道名和分组
                    if let nameRange = trimmed.range(of: ",", options: .backwards) {
                        currentName = String(trimmed[nameRange.upperBound...]).trimmingCharacters(in: .whitespaces)
                    }
                    currentGroup = "默认"
                    if let groupMatch = trimmed.range(of: "group-title=\"") {
                        let afterGroup = trimmed[groupMatch.upperBound...]
                        if let endQuote = afterGroup.firstIndex(of: "\"") {
                            currentGroup = String(afterGroup[..<endQuote])
                        }
                    }
                } else if Self.isLiveStreamUrl(trimmed) {
                    if !currentName.isEmpty {
                        appendChannel(
                            named: currentName,
                            urls: [trimmed],
                            logo: "",
                            to: currentGroup,
                            groups: &groups
                        )
                        currentName = ""
                    }
                }
            }
        } else {
            // TXT 格式: 分组名,#genre#  或  频道名,url
            for line in lines {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                guard !trimmed.isEmpty else { continue }
                
                if trimmed.hasSuffix(",#genre#") || trimmed.hasSuffix("，#genre#") {
                    currentGroupName = trimmed
                        .replacingOccurrences(of: ",#genre#", with: "")
                        .replacingOccurrences(of: "，#genre#", with: "")
                        .trimmingCharacters(in: .whitespaces)
                    continue
                }
                
                let parts = trimmed.components(separatedBy: ",")
                if parts.count >= 2 {
                    let name = parts[0].trimmingCharacters(in: .whitespaces)
                    let url = parts[1...].joined(separator: ",").trimmingCharacters(in: .whitespaces)
                    
                    if !name.isEmpty && Self.isLiveStreamUrl(url) {
                        appendChannel(
                            named: name,
                            urls: [url],
                            logo: "",
                            to: currentGroupName,
                            groups: &groups
                        )
                    }
                }
            }
        }
        
        return sortedGroups(from: groups)
    }
    
    private func parseInlineLiveChannels(_ channels: [AppConfigData.LiveConfig.LiveChannelConfig]) -> [LiveChannelGroup] {
        var groups: [String: LiveChannelGroup] = [:]
        for channel in channels {
            appendChannel(
                named: channel.name ?? "",
                urls: channel.urls ?? [],
                logo: channel.logo ?? "",
                to: channel.group ?? "其他",
                groups: &groups
            )
        }
        return sortedGroups(from: groups)
    }
    
    private func mergeLiveGroups(_ incomingGroups: [LiveChannelGroup], into groups: inout [String: LiveChannelGroup]) {
        for group in incomingGroups {
            for channel in group.channels {
                appendChannel(
                    named: channel.channelName,
                    urls: channel.channelUrls,
                    logo: channel.logo,
                    to: group.groupName,
                    groups: &groups
                )
            }
        }
    }
    
    private func appendChannel(
        named channelName: String,
        urls: [String],
        logo: String,
        to groupName: String,
        groups: inout [String: LiveChannelGroup]
    ) {
        let normalizedName = Self.normalizeChannelName(channelName)
        guard !normalizedName.isEmpty else { return }
        
        let validUrls = Self.uniqueLiveUrls(urls)
        guard !validUrls.isEmpty else { return }
        
        let normalizedGroupName = Self.normalizeGroupName(groupName)
        if groups[normalizedGroupName] == nil {
            groups[normalizedGroupName] = LiveChannelGroup(
                groupName: normalizedGroupName,
                groupIndex: groups.count
            )
        }
        
        guard var group = groups[normalizedGroupName] else { return }
        
        if let existingIndex = group.channels.firstIndex(where: {
            Self.normalizeChannelName($0.channelName) == normalizedName
        }) {
            var existing = group.channels[existingIndex]
            var existingUrls = Set(existing.channelUrls.map(Self.normalizeLiveUrl))
            for url in validUrls {
                let normalizedUrl = Self.normalizeLiveUrl(url)
                if !existingUrls.contains(normalizedUrl) {
                    existing.channelUrls.append(url)
                    existingUrls.insert(normalizedUrl)
                }
            }
            let trimmedLogo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            if existing.logo.isEmpty && !trimmedLogo.isEmpty {
                existing.logo = trimmedLogo
            }
            group.channels[existingIndex] = existing
        } else {
            var item = LiveChannelItem(channelName: normalizedName, channelIndex: group.channels.count)
            item.channelUrls = validUrls
            item.logo = logo.trimmingCharacters(in: .whitespacesAndNewlines)
            group.channels.append(item)
        }
        
        groups[normalizedGroupName] = group
    }
    
    private func sortedGroups(from groups: [String: LiveChannelGroup]) -> [LiveChannelGroup] {
        groups.values
            .sorted { $0.groupIndex < $1.groupIndex }
            .map { group in
                var reindexedGroup = group
                reindexedGroup.channels = group.channels.enumerated().map { index, channel in
                    var reindexedChannel = channel
                    reindexedChannel.channelIndex = index
                    return reindexedChannel
                }
                return reindexedGroup
            }
    }
    
    private func resolveLiveUrl(_ urlString: String, baseConfigUrl: String) -> String {
        let trimmed = urlString.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return trimmed }
        if let url = URL(string: trimmed), url.scheme != nil {
            return trimmed
        }
        guard let baseUrl = URL(string: baseConfigUrl),
              let resolved = URL(string: trimmed, relativeTo: baseUrl)?.absoluteURL else {
            return trimmed
        }
        return resolved.absoluteString
    }
    
    private static func uniqueLiveUrls(_ urls: [String]) -> [String] {
        var result: [String] = []
        var seen: Set<String> = []
        
        for url in urls {
            let normalized = normalizeLiveUrl(url)
            guard !normalized.isEmpty, isLiveStreamUrl(normalized), !seen.contains(normalized) else { continue }
            seen.insert(normalized)
            result.append(normalized)
        }
        
        return result
    }
    
    private static func normalizeGroupName(_ groupName: String) -> String {
        let trimmed = groupName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? "默认" : trimmed
    }
    
    private static func normalizeChannelName(_ channelName: String) -> String {
        channelName.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func normalizeLiveUrl(_ url: String) -> String {
        url.trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private static func isLiveStreamUrl(_ url: String) -> Bool {
        let lowercased = url.lowercased()
        return lowercased.hasPrefix("http://")
            || lowercased.hasPrefix("https://")
            || lowercased.hasPrefix("rtmp://")
            || lowercased.hasPrefix("rtsp://")
    }
    
    /// 获取指定 key 的源
    func getSource(key: String) -> SourceBean? {
        sourceBeanList.first(where: { $0.key == key })
    }
    
    /// 获取可搜索的源列表
    func getSearchableSources() -> [SourceBean] {
        sourceBeanList.filter { $0.isSearchable }
    }
    
    /// 设置主页源
    func setHomeSource(_ source: SourceBean) {
        self.homeSourceBean = source
        UserDefaults.standard.set(source.key, forKey: HawkConfig.HOME_API)
    }
}

enum ConfigError: LocalizedError {
    case parseError(String)
    case networkError(String)
    
    var errorDescription: String? {
        switch self {
        case .parseError(let msg): return "配置解析错误: \(msg)"
        case .networkError(let msg): return "网络错误: \(msg)"
        }
    }
}
