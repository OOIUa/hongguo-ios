// SPDX-License-Identifier: GPL-3.0-only
// Adapted from N3urda/hongguoTV 6672b55, including the issue 61 capability repair.
import Foundation

extension DramaAPI {
    static let mobileVideoURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

    /// video_tab 属于 player 签名族，走 v5 无正文 GET（2026-11-20 起唯一可用的取源路径）。
    static let videoTabV5URL = "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/"

    static let videoTabV5UserAgent = "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; "
        + "Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    /// video_tab 的 v5 无正文 GET 查询参数与头的形态对齐 hongguo-android PR #12 的
    /// MobilePlayerV5.requestVideoTab（7.4.3.32 档位）。
    static func videoTabV5Query(_ identity: RegisteredIdentity, episodeID: String) throws -> [[String]] {
        guard ProtocolJSON.identifier(episodeID) != nil else { throw HGError.message("分集编号无效") }
        let values: [String: String] = ["aid":"8662", "app_name":"novelread", "version_code":"74332",
            "version_name":"7.4.3.32", "channel":"vivo_8662_64", "device_platform":"android",
            "device_type":"PGT-AN10", "os_version":"12", "update_version_code":"74332",
            "iid":identity.installID, "cdid":identity.cdid, "device_id":identity.deviceID,
            "video_id":episodeID, "video_id_type":"0", "device_level":"1",
            "need_all_video_definition":"1", "need_mp4_align":"0", "use_os_player":"0",
            "video_platform":"1024", "source":"0", "from_video_id":""]
        return values.keys.sorted().map { [$0, values[$0]!] }
    }

    static func mobileDevice(_ identity: RegisteredIdentity) -> [String: String] {
        ["aid":"8662", "app_name":"novelread", "version_code":"74332", "version_name":"7.4.3.32",
         "channel":"vivo_8662_64", "device_platform":"android", "device_type":"PGT-AN10", "os_version":"12",
         "update_version_code":"74332", "iid":identity.installID, "cdid":identity.cdid, "device_id":identity.deviceID]
    }

    static func mobileBody(episodeID: String) throws -> Data {
        guard ProtocolJSON.identifier(episodeID) != nil else { throw HGError.message("分集编号无效") }
        return try HGCrypto.gzip(ProtocolJSON.data([
            "biz_param":["detail_page_version":0, "device_level":1, "disable_digg_stat":false,
                         "disable_video_relate_book":false, "need_all_video_definition":true, "need_mp4_align":false,
                         "use_os_player":false, "use_server_dns":false, "video_platform":1024],
            "mixed_video_id_map":["1004":[episodeID]], "dr_scene":"player"
        ]))
    }

    static func mobileVideoModel(_ data: Data, episodeID: String) throws -> [String: Any]? {
        guard data.count <= 2 * 1024 * 1024 else { throw HGError.message("播放信息过大") }
        try checkPlaybackBusinessRejection(data)
        guard let root = try? ProtocolJSON.object(data),
              ProtocolJSON.integer(root["code"] ?? root["Code"] ?? -1) == 0 else { return nil }
        let data = ProtocolJSON.dictionary(root["data"])
        let nested = ProtocolJSON.dictionary(data["1004"])
        let entries = nested.isEmpty ? data : nested
        let model = ProtocolJSON.dictionary(ProtocolJSON.dictionary(entries[episodeID])["video_model"])
        return model.isEmpty ? nil : model
    }
}
