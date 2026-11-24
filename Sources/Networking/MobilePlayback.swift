// SPDX-License-Identifier: GPL-3.0-only
// Adapted from N3urda/hongguoTV 6672b55, including the issue 61 capability repair.
import Foundation

extension DramaAPI {
    static let mobileVideoURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

    /// video_tab 属于 player 签名族，走 v5 无正文 GET（2026-11-20 起唯一可用的取源路径）。
    static let videoTabV5URL = "https://api5-normal-sinfonlineb.fqnovel.com/reading/bookapi/video_tab/multi_video_model/v1/"

    static let videoTabV5UserAgent = "com.phoenix.read/73932 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3; "
        + "Cronet/TTNetVersion:04657795 2026-01-23 QuicVersion:c67e9834 2025-09-08)"

    /// 官方播放 query 的完整设备上下文（2026-11-24 对齐 hongguo-android c0821c6 / lvguo-tv 的可用形态）。
    ///
    /// 此前只发 12～21 个参数，缺 resolution / dpi / os_api / rom_version / host_abi /
    /// dragon_device_type / compliance_status / player_so_load 等分量。签名本身合法，
    /// 但上游把这些当作「设备画像不完整」，同样回 200 + 0 字节。注册下发 klink_egdi 时附带
    /// （空值不写，避免污染签名串）。
    static func deviceQuery(_ identity: RegisteredIdentity) -> [String: String] {
        var values: [String: String] = [
            "device_platform":"android", "os":"android", "ssmix":"a",
            "cdid":identity.cdid, "channel":"vivo_8662_64",
            "aid":"8662", "app_name":"novelread",
            "version_code":"74332", "version_name":"7.4.3.32",
            "manifest_version_code":"74332", "update_version_code":"74332",
            "resolution":"1920*1080", "dpi":"280",
            "device_type":"PGT-AN10", "device_brand":"HONOR",
            "language":"zh", "os_api":"31", "os_version":"12",
            "ac":"wifi", "host_abi":"arm64-v8a",
            "dragon_device_type":"phone", "pv_player":"74332",
            "compliance_status":"0", "need_personal_recommend":"1",
            "player_so_load":"1", "is_android_pad_screen":"0",
            "rom_version":"V417IR+release-keys",
            "iid":identity.installID, "device_id":identity.deviceID,
        ]
        if !identity.egdi.isEmpty { values["klink_egdi"] = identity.egdi }
        return values
    }

    /// video_tab 的 v5 无正文 GET 查询参数（7.4.3.32 档位）。设备上下文来自 deviceQuery，
    /// 业务参数对齐 hongguo-android MobilePlayerV5.requestVideoTab。
    static func videoTabV5Query(_ identity: RegisteredIdentity, episodeID: String) throws -> [[String]] {
        guard ProtocolJSON.identifier(episodeID) != nil else { throw HGError.message("分集编号无效") }
        var values = deviceQuery(identity)
        for (name, value) in [("video_id",episodeID),("video_id_type","0"),("device_level","1"),
                              ("need_all_video_definition","1"),("need_mp4_align","0"),("use_os_player","0"),
                              ("video_platform","1024"),("source","0"),("from_video_id","")] { values[name] = value }
        return values.keys.sorted().map { [$0, values[$0]!] }
    }

    /// medusa 信封的 `who`（设备画像）。签名器从中取 device_id / device_type / device_brand / os_version /
    /// version_name / channel；键按字母排序，保证同一台设备每次生成相同顺序。
    static func mobileDevice(_ identity: RegisteredIdentity) -> [String: String] {
        deviceQuery(identity).filter { ["aid","app_name","version_code","version_name","channel","device_platform","device_type",
                                         "device_brand","os_version","update_version_code","iid","cdid","device_id"].contains($0.key) }
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
