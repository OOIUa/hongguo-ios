// SPDX-License-Identifier: GPL-3.0-only
// Self-generated H.264 only. No upstream API, media, identity, or credentials.
import Foundation
import AVFoundation
import CoreVideo

struct Node {
    let type: String, start: Int, end: Int
    var payload: Int { start + 8 }
}
func u32(_ d: Data, _ p: Int) -> Int { (0..<4).reduce(0) { ($0 << 8) | Int(d[p + $1]) } }
func be32(_ n: Int) -> Data { Data((0..<4).map { UInt8(truncatingIfNeeded: n >> (24 - $0 * 8)) }) }
func box(_ type: String, _ body: Data) -> Data { be32(body.count + 8) + Data(type.utf8) + body }
func nodes(_ d: Data, _ start: Int, _ end: Int) -> [Node] {
    var p = start; var out: [Node] = []
    while p + 8 <= end { var size = u32(d, p); if size == 1 { size = u32(d, p + 12) }; guard size >= 8, p + size <= end else { break }; let t = String(data:d[(p+4)..<(p+8)],encoding:.ascii)!;out.append(Node(type:t,start:p,end:p+size));p+=size };return out
}
func child(_ d: Data, _ n: Node, _ type: String, skip: Int = 0) -> Node { nodes(d,n.payload + skip,n.end).first { $0.type == type }! }

struct ProgressiveFixture {
    let encrypted: Data, encrypted8: Data, clear: Data, clear8: Data, plain: Data
    let spade: String
    let offsets: [Int], sizes: [Int]
    static func make() async throws -> ProgressiveFixture {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("hongguo-media-test-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: base) }
        let origin = base.appendingPathComponent("original.mp4")
        try? FileManager.default.removeItem(at:origin)
        let writer = try AVAssetWriter(url:origin,fileType:.mp4)
        let input = AVAssetWriterInput(mediaType:.video,outputSettings:[AVVideoCodecKey:AVVideoCodecType.h264,AVVideoWidthKey:320,AVVideoHeightKey:180, AVVideoCompressionPropertiesKey:[AVVideoAverageBitRateKey:4_000_000,AVVideoMaxKeyFrameIntervalKey:20,AVVideoAllowFrameReorderingKey:false]])
        let adapter = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput:input,sourcePixelBufferAttributes:[kCVPixelBufferPixelFormatTypeKey as String:kCVPixelFormatType_32BGRA,kCVPixelBufferWidthKey as String:320,kCVPixelBufferHeightKey as String:180])
        writer.add(input);writer.startWriting();writer.startSession(atSourceTime:.zero)
        var seed: UInt32 = 0x13678ace
        for frame in 0..<180 {
            while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds:1_000_000) }
            var pixel:CVPixelBuffer?;CVPixelBufferCreate(kCFAllocatorDefault,320,180,kCVPixelFormatType_32BGRA,nil,&pixel)
            let buffer=pixel!;CVPixelBufferLockBaseAddress(buffer,[])
            let addr=CVPixelBufferGetBaseAddress(buffer)!.assumingMemoryBound(to:UInt8.self)
            for y in 0..<180 { for x in 0..<320 { let p=y*CVPixelBufferGetBytesPerRow(buffer)+x*4;seed ^= seed << 13; seed ^= seed >> 17; seed ^= seed << 5; addr[p]=UInt8(truncatingIfNeeded:seed);addr[p+1]=UInt8(truncatingIfNeeded:seed >> 8);addr[p+2]=UInt8(truncatingIfNeeded:seed >> 16);addr[p+3]=255 } }
            CVPixelBufferUnlockBaseAddress(buffer,[])
            precondition(adapter.append(buffer,withPresentationTime:CMTime(value:Int64(frame),timescale:20)))
        }
        input.markAsFinished();await writer.finishWriting();precondition(writer.status == .completed)
        let original=try Data(contentsOf:origin);try MP4Processor.validate(url:origin)
        let tops=nodes(original,0,original.count),moov=tops.first{$0.type=="moov"}!
        let trak=child(original,moov,"trak"),mdia=child(original,trak,"mdia"),minf=child(original,mdia,"minf"),stbl=child(original,minf,"stbl"),stsd=child(original,stbl,"stsd")
        let entry=nodes(original,stsd.payload+8,stsd.end)[0],stsz=child(original,stbl,"stsz"),stsc=child(original,stbl,"stsc"),stco=child(original,stbl,"stco")
        let count=u32(original,stsz.payload+8),uniform=u32(original,stsz.payload+4)
        let sizes=(0..<count).map{uniform>0 ? uniform:u32(original,stsz.payload+12+$0*4)}
        let chunkCount=u32(original,stco.payload+4),mappingCount=u32(original,stsc.payload+4)
        let mappings=(0..<mappingCount).map{(u32(original,stsc.payload+8+$0*12),u32(original,stsc.payload+12+$0*12))}
        var offsets:[Int]=[],mapping=0
        for chunk in 0..<chunkCount {while mapping+1<mappings.count && mappings[mapping+1].0<=chunk+1{mapping+=1};var p=u32(original,stco.payload+8+chunk*4);for _ in 0..<mappings[mapping].1{offsets.append(p);p+=sizes[offsets.count-1]}}
        precondition(offsets.count==count)
        let key=Data(hex:"287216bfa89e662a0f748120c305e199")!
        var encrypted=original,ivs=Data()
        for i in 0..<count {let iv=be32(0)+be32(i+1)+Data(repeating:0,count:8);ivs+=iv;let data=try HGCrypto.aesCTR(original.subdata(in:offsets[i]..<(offsets[i]+sizes[i])),key:key,iv:iv);encrypted.replaceSubrange(offsets[i]..<(offsets[i]+sizes[i]),with:data)}
        let sinf=box("sinf",box("frma",Data(entry.type.utf8))+box("schm",be32(0)+Data("cenc".utf8)+be32(0))+box("schi",box("tenc",be32(0)+Data([0,1,16])+Data(repeating:0,count:16))))
        let senc=box("senc",be32(0)+be32(count)+ivs)
        // AVAssetWriter places moov after mdat: inserting metadata preserves media offsets.
        precondition(moov.start>offsets.last!)
        encrypted.replaceSubrange((entry.start+4)..<(entry.start+8),with:Data("encv".utf8))
        let insertions=[(entry.end,sinf),(stbl.end,senc)].sorted{$0.0>$1.0}
        for (p,data) in insertions {encrypted.insert(contentsOf:data,at:p)}
        let growAll=sinf.count+senc.count
        for n in [moov,trak,mdia,minf,stbl] {encrypted.replaceSubrange(n.start..<(n.start+4),with:be32(n.end-n.start+growAll))}
        for n in [stsd,entry] {encrypted.replaceSubrange(n.start..<(n.start+4),with:be32(n.end-n.start+sinf.count))}
        let output=base.appendingPathComponent("encrypted.mp4");try encrypted.write(to:output)
        // Narrow IVs to their high 64 bits; CTR low words were zero in the original fixture.
        var encrypted8 = encrypted
        let top8=nodes(encrypted8,0,encrypted8.count),m8=top8.first{$0.type=="moov"}!,t8=child(encrypted8,m8,"trak"),md8=child(encrypted8,t8,"mdia"),mn8=child(encrypted8,md8,"minf"),sb8=child(encrypted8,mn8,"stbl"),sn8=child(encrypted8,sb8,"senc")
        var shortIVs=Data();for i in 0..<count {shortIVs += be32(0)+be32(i+1)}
        let shortSenc=box("senc",be32(0)+be32(count)+shortIVs)
        encrypted8.replaceSubrange(sn8.start..<sn8.end,with:shortSenc)
        for n in [m8,t8,md8,mn8,sb8] {encrypted8.replaceSubrange(n.start..<(n.start+4),with:be32(n.end-n.start-count*8))}
        let out8=base.appendingPathComponent("encrypted8.mp4");try encrypted8.write(to:out8)


        let spade=Data(hex:"93bc1df253ba1bf7618b19c448b806f64d810afc45b715fe5eb925f26cbf12f541ba098282")!.base64EncodedString()
        try MP4Processor.decrypt(url:output,spade:spade,progress:{_,_ in})
        try MP4Processor.decrypt(url:out8,spade:spade,progress:{_,_ in})
        return ProgressiveFixture(encrypted:encrypted, encrypted8:encrypted8,
            clear:try Data(contentsOf:output), clear8:try Data(contentsOf:out8),
            plain:original, spade:spade, offsets:offsets, sizes:sizes)
    }
}
