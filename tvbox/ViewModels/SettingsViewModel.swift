import Foundation
import SwiftUI

/// 设置 ViewModel
@MainActor
class SettingsViewModel: ObservableObject {
    struct PendingMultiRepoSelection: Identifiable {
        enum Target {
            case vod
            case live
            
            var title: String {
                switch self {
                case .vod: return "点播"
                case .live: return "直播"
                }
            }
        }
        
        let id = UUID()
        let target: Target
        let sourceUrl: String
        let options: [ApiConfig.MultiRepoOption]
    }
    
    @Published var vodApiUrl: String = ""
    @Published var liveApiUrl: String = ""
    @Published var isLoadingConfig = false
    @Published var configError: String?
    @Published var configSuccess = false
    @Published var pendingMultiRepoSelection: PendingMultiRepoSelection?
    @Published var apiHistory: [String] = []
    @Published var vodPlayerEngine: PlayerEngine = .system
    @Published var livePlayerEngine: PlayerEngine = .system
    @Published var decodeMode: VideoDecodeMode = .auto
    @Published var vlcBufferMode: VLCBufferMode = .defaultMode
    @Published var playTimeStep: Int = 10
    @Published var cacheSizeString: String = "0 KB"
    
    let playTimeStepOptions: [Int] = [5, 10, 15, 30, 60]
    let playerEngineOptions: [PlayerEngine] = PlayerEngine.availableEngines
    let decodeModeOptions: [VideoDecodeMode] = VideoDecodeMode.allCases
    let vlcBufferModeOptions: [VLCBufferMode] = VLCBufferMode.allCases
    
    init() {
        let defaults = UserDefaults.standard
        let savedVod = defaults.string(forKey: HawkConfig.API_URL) ?? ""
        vodApiUrl = savedVod
        if let savedLive = defaults.string(forKey: HawkConfig.LIVE_API_URL) {
            liveApiUrl = savedLive
        } else {
            liveApiUrl = savedVod
        }
        loadApiHistory()
        let hasLegacyPlayer = defaults.object(forKey: HawkConfig.PLAY_TYPE) != nil
        let legacyPlayerRaw = defaults.integer(forKey: HawkConfig.PLAY_TYPE)
        let defaultVodRaw = PlayerEngine.system.rawValue
        let defaultLiveRaw = PlayerEngine.isVLCAvailable
            ? PlayerEngine.vlc.rawValue
            : PlayerEngine.system.rawValue
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_VOD) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultVodRaw, forKey: HawkConfig.PLAY_TYPE_VOD)
        }
        if defaults.object(forKey: HawkConfig.PLAY_TYPE_LIVE) == nil {
            defaults.set(hasLegacyPlayer ? legacyPlayerRaw : defaultLiveRaw, forKey: HawkConfig.PLAY_TYPE_LIVE)
        }
        vodPlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_VOD)
        )
        livePlayerEngine = PlayerEngine.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_TYPE_LIVE)
        )
        decodeMode = VideoDecodeMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_DECODE_MODE)
        )
        vlcBufferMode = VLCBufferMode.fromStoredValue(
            defaults.integer(forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
        )
        
        let savedStep = defaults.integer(forKey: HawkConfig.PLAY_TIME_STEP)
        playTimeStep = savedStep > 0 ? savedStep : 10
        refreshCacheSize()
    }
    
    /// 加载配置
    func loadConfig() async {
        let trimmedVod = vodApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedLive = liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedVod.isEmpty else {
            configError = "请输入点播接口地址"
            return
        }
        
        isLoadingConfig = true
        configError = nil
        configSuccess = false
        pendingMultiRepoSelection = nil
        
        do {
            let resolvedLive = trimmedLive.isEmpty ? trimmedVod : trimmedLive
            
            if let pending = try await detectPendingMultiRepoSelection(
                vodUrl: trimmedVod,
                liveUrl: resolvedLive
            ) {
                pendingMultiRepoSelection = pending
                isLoadingConfig = false
                return
            }
            
            try await ApiConfig.shared.loadConfigs(vodApiUrl: trimmedVod, liveApiUrl: resolvedLive)
            UserDefaults.standard.set(trimmedVod, forKey: HawkConfig.API_URL)
            UserDefaults.standard.set(trimmedLive, forKey: HawkConfig.LIVE_API_URL)
            vodApiUrl = trimmedVod
            liveApiUrl = trimmedLive
            addToApiHistory(trimmedVod)
            addToApiHistory(resolvedLive)
            configSuccess = true
        } catch {
            configError = error.localizedDescription
        }
        
        isLoadingConfig = false
    }
    
    func selectPendingMultiRepoOption(_ option: ApiConfig.MultiRepoOption) async {
        guard let pending = pendingMultiRepoSelection else { return }
        let normalizedSource = ApiConfig.normalizeConfigUrl(pending.sourceUrl)
        
        switch pending.target {
        case .vod:
            let normalizedLive = ApiConfig.normalizeConfigUrl(liveApiUrl)
            let shouldSyncLive = !liveApiUrl.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                && normalizedLive == normalizedSource
            vodApiUrl = option.url
            if shouldSyncLive {
                liveApiUrl = option.url
            }
        case .live:
            liveApiUrl = option.url
        }
        
        pendingMultiRepoSelection = nil
        await loadConfig()
    }
    
    func cancelPendingMultiRepoSelection() {
        pendingMultiRepoSelection = nil
        isLoadingConfig = false
    }
    
    private func detectPendingMultiRepoSelection(
        vodUrl: String,
        liveUrl: String
    ) async throws -> PendingMultiRepoSelection? {
        if let vodOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: vodUrl) {
            guard !vodOptions.isEmpty else {
                throw ConfigError.parseError("点播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .vod,
                sourceUrl: vodUrl,
                options: vodOptions
            )
        }
        
        let normalizedVod = ApiConfig.normalizeConfigUrl(vodUrl)
        let normalizedLive = ApiConfig.normalizeConfigUrl(liveUrl)
        guard normalizedLive != normalizedVod else {
            return nil
        }
        
        if let liveOptions = try await ApiConfig.shared.fetchMultiRepoOptions(from: liveUrl) {
            guard !liveOptions.isEmpty else {
                throw ConfigError.parseError("直播多仓库配置中没有可用地址")
            }
            return PendingMultiRepoSelection(
                target: .live,
                sourceUrl: liveUrl,
                options: liveOptions
            )
        }
        
        return nil
    }
    
    // MARK: - API 历史
    
    private func loadApiHistory() {
        apiHistory = UserDefaults.standard.stringArray(forKey: "api_history") ?? []
    }
    
    private func addToApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        apiHistory.insert(url, at: 0)
        if apiHistory.count > 10 {
            apiHistory = Array(apiHistory.prefix(10))
        }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    func removeApiHistory(_ url: String) {
        apiHistory.removeAll { $0 == url }
        UserDefaults.standard.set(apiHistory, forKey: "api_history")
    }
    
    /// 清除所有缓存
    func clearCache() {
        URLCache.shared.removeAllCachedResponses()
        ImageLoader.shared.clearCache()
        ImageCache.shared.clear()
        refreshCacheSize()
    }
    
    /// 设置快进步长
    func setPlayTimeStep(_ step: Int) {
        guard step > 0 else { return }
        playTimeStep = step
        UserDefaults.standard.set(step, forKey: HawkConfig.PLAY_TIME_STEP)
    }
    
    /// 设置点播播放器内核
    func setVodPlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        vodPlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_VOD)
    }
    
    /// 设置直播播放器内核
    func setLivePlayerEngine(_ engine: PlayerEngine) {
        guard playerEngineOptions.contains(engine) else { return }
        livePlayerEngine = engine
        UserDefaults.standard.set(engine.rawValue, forKey: HawkConfig.PLAY_TYPE_LIVE)
    }
    
    /// 设置视频解码模式
    func setDecodeMode(_ mode: VideoDecodeMode) {
        guard decodeModeOptions.contains(mode) else { return }
        decodeMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_DECODE_MODE)
    }

    /// 设置 VLC 缓冲策略
    func setVLCBufferMode(_ mode: VLCBufferMode) {
        guard vlcBufferModeOptions.contains(mode) else { return }
        vlcBufferMode = mode
        UserDefaults.standard.set(mode.rawValue, forKey: HawkConfig.PLAY_VLC_BUFFER_MODE)
    }
    
    private func refreshCacheSize() {
        let sharedDisk = URLCache.shared.currentDiskUsage
        let imageDisk = ImageLoader.shared.cacheUsage.disk
        cacheSizeString = Self.formatSize(bytes: sharedDisk + imageDisk)
    }
    
    private static func formatSize(bytes: Int) -> String {
        let size = max(0, bytes)
        if size < 1024 * 1024 {
            return String(format: "%.1f KB", Double(size) / 1024.0)
        }
        return String(format: "%.1f MB", Double(size) / 1024.0 / 1024.0)
    }
}
