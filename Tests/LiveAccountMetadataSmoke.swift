// Explicit anonymous read-only metadata and real poster decoding probe; no account session is used.
import Foundation
import ImageIO
@main struct LiveAccountMetadataSmoke {
    static func main() async {
        do {
            guard CommandLine.arguments.contains("--live") else { throw HGError.message("Explicit --live required") }
            let root=URL(fileURLWithPath:CommandLine.arguments.last!,isDirectory:true)
            let api=DramaAPI(resourceDirectory:root.appendingPathComponent("Sources/Networking"))
            let catalog=try await api.home(feed:"latest",offset:0)
            let selected=Array(catalog.dramas.prefix(12));guard !selected.isEmpty else { throw HGError.message("Empty catalog") }
            let config=URLSessionConfiguration.ephemeral;config.httpShouldSetCookies=false;config.httpCookieStorage=nil
            let session=URLSession(configuration:config)
            let identity=try await PlaybackRegistration.register(session:session)
            var device=identity.device
            for key in ["version_code","manifest_version_code","update_version_code","pv_player"] { device[key]="72232" }
            device["version_name"]="7.2.2.32";device["ts"]=String(Int64(Date().timeIntervalSince1970))
            let params=device.merging(["book_id":selected.map(\.id).joined(separator:","),"book_type":"2"]) { _,new in new }
            let signer=ProtocolSigner(resourceDirectory:root.appendingPathComponent("Sources/Networking"))
            let signed=try await signer.signedRequest(baseURL:"https://api5-normal-sinfonlinea.fqnovel.com/reading/bookapi/multi-detail/v1/",query:params.sorted{$0.key<$1.key}.map{[$0.key,$0.value]},body:nil,device:device)
            var request=URLRequest(url:signed.url,timeoutInterval:20)
            for (key,value) in signed.headers { request.setValue(value,forHTTPHeaderField:key) }
            request.setValue("com.phoenix.read/72232 (Linux; U; Android 16; zh_CN; 25053RT47C; Build/BP2A.250605.031.A3)",forHTTPHeaderField:"User-Agent")
            request.setValue(identity.appDeviceCookie,forHTTPHeaderField:"Cookie")
            let (data,response)=try await session.data(for:request)
            guard (response as? HTTPURLResponse)?.statusCode==200 else { throw HGError.message("Metadata HTTP unavailable") }
            let raw=try ProtocolJSON.object(data)
            guard ProtocolJSON.integer(raw["code"] ?? raw["Code"])==0 else { throw HGError.message("Anonymous metadata refused") }
            let rows=ProtocolJSON.array(raw["data"])
            let blanks=selected.map{Drama(id:$0.id,title:"剧集",coverURL:"",summary:"",episodeCount:0)}
            let filled=try await AccountRules.enrichDramas(blanks,previous:[]) { _ in raw }
            let named=filled.filter{ !$0.title.isEmpty && $0.title != "剧集" }.count
            let posters=filled.filter{ !$0.coverURL.isEmpty }.count
            var decoded=0,statuses=[Int]()
            for drama in filled where !drama.coverURL.isEmpty {
                guard let url=URL(string:drama.coverURL) else{continue}
                let (image,response)=try await session.data(for:URLRequest(url:url,timeoutInterval:12))
                let code=(response as? HTTPURLResponse)?.statusCode ?? 0
                if (200...299).contains(code),let source=CGImageSourceCreateWithData(image as CFData,nil),CGImageSourceCreateImageAtIndex(source,0,nil) != nil { decoded += 1 }
                else { statuses.append(code) }
            }
            session.invalidateAndCancel()
            let report:[String:Any]=["mode":"anonymous-real-metadata","requested":selected.count,"rowsReturned":rows.count,"namesParsed":named,"coversParsed":posters,"imagesDecoded":decoded,"imageFailureStatus":statuses]
            print(String(decoding:try JSONSerialization.data(withJSONObject:report,options:[.sortedKeys,.prettyPrinted]),as:UTF8.self))
            guard named==selected.count,posters==selected.count,decoded==posters else { throw HGError.message("Incomplete real image verification") }
        } catch { print("LIVE CHECK FAILED: \(String(reflecting:type(of:error)))");exit(1) }
    }
}
