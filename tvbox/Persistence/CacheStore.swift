import Foundation
import SwiftData

/// SwiftData 持久化模型 - 对应 Android 版 Room 数据库

/// 单部剧的续播状态
struct VodPlaybackState: Codable {
    /// 当前播放线路标识。
    var flag: String
    /// 剧集索引。
    var episodeIndex: Int
    /// 播放进度（秒）。
    var progressSeconds: Double
}

/// 视频收藏
@Model
final class VodCollect {
    /// 视频 ID（与 sourceKey 组成唯一语义键）。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 最近更新时间（收藏创建/刷新时间）。
    var updateTime: Date = Date()
    
    init(vodId: String, vodName: String, vodPic: String, sourceKey: String) {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.updateTime = Date()
    }
}

/// 播放历史记录
@Model
final class VodRecord {
    /// 视频 ID。
    var vodId: String = ""
    /// 片名。
    var vodName: String = ""
    /// 海报地址。
    var vodPic: String = ""
    /// 来源站点 key。
    var sourceKey: String = ""
    /// 播放标记，如“第5集 03:45”。
    var playNote: String = ""
    /// 续播状态 JSON（`VodPlaybackState` 编码结果）。
    var dataJson: String = ""
    /// 最近播放时间。
    var updateTime: Date = Date()
    
    init(vodId: String, vodName: String, vodPic: String, sourceKey: String, playNote: String = "") {
        self.vodId = vodId
        self.vodName = vodName
        self.vodPic = vodPic
        self.sourceKey = sourceKey
        self.playNote = playNote
        self.updateTime = Date()
    }
}

/// 通用缓存
@Model
final class CacheItem {
    /// 唯一缓存键。
    @Attribute(.unique) var key: String = ""
    /// 缓存值（字符串形式）。
    var value: String = ""
    /// 更新时间。
    var updateTime: Date = Date()
    
    init(key: String, value: String) {
        self.key = key
        self.value = value
        self.updateTime = Date()
    }
}

/// 缓存管理器
actor CacheStore {
    static let shared = CacheStore()
    
    private init() {}
    
    @MainActor
    func addCollect(_ video: Movie.Video, context: ModelContext) {
        // 先检查是否已存在
        let vodId = video.id
        let sourceKey = video.sourceKey
        let predicate = #Predicate<VodCollect> { item in
            item.vodId == vodId && item.sourceKey == sourceKey
        }
        let descriptor = FetchDescriptor<VodCollect>(predicate: predicate)
        
        if let existing = try? context.fetch(descriptor), !existing.isEmpty {
            return // 已收藏
        }
        
        let collect = VodCollect(
            vodId: video.id,
            vodName: video.name,
            vodPic: video.pic,
            sourceKey: video.sourceKey
        )
        context.insert(collect)
        try? context.save()
    }
    
    @MainActor
    func removeCollect(vodId: String, sourceKey: String, context: ModelContext) {
        // 收藏以 (vodId, sourceKey) 为业务唯一键，删除时也按该组合匹配。
        let predicate = #Predicate<VodCollect> { item in
            item.vodId == vodId && item.sourceKey == sourceKey
        }
        let descriptor = FetchDescriptor<VodCollect>(predicate: predicate)
        if let items = try? context.fetch(descriptor) {
            for item in items {
                context.delete(item)
            }
            try? context.save()
        }
    }
    
    @MainActor
    func isCollected(vodId: String, sourceKey: String, context: ModelContext) -> Bool {
        let predicate = #Predicate<VodCollect> { item in
            item.vodId == vodId && item.sourceKey == sourceKey
        }
        let descriptor = FetchDescriptor<VodCollect>(predicate: predicate)
        return (try? context.fetchCount(descriptor)) ?? 0 > 0
    }
    
    @MainActor
    func addRecord(
        _ video: Movie.Video,
        playNote: String,
        playbackState: VodPlaybackState? = nil,
        context: ModelContext
    ) {
        let vodId = video.id
        let sourceKey = video.sourceKey
        let record = fetchRecord(vodId: vodId, sourceKey: sourceKey, context: context)
        let encodedState = Self.encodePlaybackState(playbackState)
        
        // 更新或插入
        if let record {
            record.playNote = playNote
            if let encodedState {
                record.dataJson = encodedState
            }
            record.updateTime = Date()
        } else {
            let record = VodRecord(
                vodId: video.id,
                vodName: video.name,
                vodPic: video.pic,
                sourceKey: video.sourceKey,
                playNote: playNote
            )
            if let encodedState {
                record.dataJson = encodedState
            }
            context.insert(record)
        }
        try? context.save()
    }
    
    /// 读取续播状态（若无记录或 JSON 无法解码则返回 `nil`）。
    @MainActor
    func getPlaybackState(vodId: String, sourceKey: String, context: ModelContext) -> VodPlaybackState? {
        guard let record = fetchRecord(vodId: vodId, sourceKey: sourceKey, context: context) else {
            return nil
        }
        return Self.decodePlaybackState(record.dataJson)
    }
    
    @MainActor
    func clearHistory(context: ModelContext) {
        do {
            try context.delete(model: VodRecord.self)
            try context.save()
        } catch {
            print("清空历史记录失败: \(error)")
        }
    }
    
    @MainActor
    private func fetchRecord(vodId: String, sourceKey: String, context: ModelContext) -> VodRecord? {
        // 历史记录同样以 (vodId, sourceKey) 作为业务键。
        let predicate = #Predicate<VodRecord> { item in
            item.vodId == vodId && item.sourceKey == sourceKey
        }
        let descriptor = FetchDescriptor<VodRecord>(predicate: predicate)
        guard let records = try? context.fetch(descriptor) else { return nil }
        return records.first
    }
    
    private nonisolated static func encodePlaybackState(_ state: VodPlaybackState?) -> String? {
        guard let state else { return nil }
        guard let data = try? JSONEncoder().encode(state) else { return nil }
        return String(data: data, encoding: .utf8)
    }
    
    /// 从 JSON 字符串反序列化续播状态。
    private nonisolated static func decodePlaybackState(_ json: String) -> VodPlaybackState? {
        guard let data = json.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(VodPlaybackState.self, from: data)
    }
}
