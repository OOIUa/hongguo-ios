// SPDX-License-Identifier: GPL-3.0-only
// Adapted from N3urda/hongguoTV 6672b55, including the issue 61 capability repair.
import Foundation

extension DramaAPI {
    static let mobileVideoURL = "https://api5-normal-sinfonlinea.fqnovel.com/novel/player/multi_video_model/player/v1"

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
