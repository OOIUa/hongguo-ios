// SPDX-License-Identifier: GPL-3.0-only
import Foundation
// Opt-in anonymous read-only catalogue probe. It does not download media or use an account.
@main struct LiveProtocolSmoke {
 static func main() async {
  let root = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
  let api=DramaAPI(resourceDirectory:root.appendingPathComponent("Sources/Networking"))
  do {
   let first=try await api.home(feed:"latest",offset:0), next=try await api.home(feed:"latest",offset:first.nextOffset)
   print("latest_pages",first.dramas.count,next.dramas.count,"overlap",Set(first.dramas.map(\.id)).intersection(next.dramas.map(\.id)).count,"cursor_advances",next.nextOffset>first.nextOffset)
  }catch{print("latest_error",error.localizedDescription)}
  for genre in ["comic_series","ai_series"] {
   do { let page=try await api.browse(genre:genre,filters:[:],offset:0); print(genre,"count",page.dramas.count,"cursor_advanced",page.nextOffset>0) }
   catch{print(genre,"error",error.localizedDescription)}
  }
  do { let page=try await api.home(feed:"comic",offset:0);print("comic_rank",page.dramas.count,"more",page.hasMore) }catch{print("rank_error",error.localizedDescription)}
  do {
   let first=try await api.search(query:"重生",offset:0), next=try await api.search(query:"重生",offset:first.nextOffset)
   print("search_pages",first.dramas.count,next.dramas.count,"overlap",Set(first.dramas.map(\.id)).intersection(next.dramas.map(\.id)).count)
  }catch{print("search_error",error.localizedDescription)}
 }
}
