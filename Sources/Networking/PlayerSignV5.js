// SPDX-License-Identifier: GPL-3.0-only
// v5 playback adapted from N3urda/hongguoTV 6672b55 (2026-11-16).
// Uses the existing GPL PureSign primitives; catalogue/account signing is unchanged.
// Protocol constants below are application constants, not account credentials.
function hashF13V5(querySm3, bodyMd5, tsBytes, khronos) {
    const low = getIv(getIv(getIv(0x20230928, querySm3), bodyMd5), tsBytes) & 15;
    if (low !== 12) throw new Error('Unsupported v5 hash branch');
    const ivV1 = 0x9d4a97c2, countV1 = (ivV1 + khronos + 1) & 255, countV2 = u32(ivV1 + khronos);
    const tt02 = [0xebb64faf,0x7aadcc2,0xcf3187bf,0xe01138ff,0x6d0bfcff,0x5a30a3be,0xb41ad638,0x34180eb8,0xf233eb6f,0xb1a584cc,0xccc30dc7,0x47d1db51,0xd55653de,0x70a84fa1,0x57473c12,0xf76f0288,0x2c077f0a,0xda0dcad0,0xfbb86f6c,0xfdc4cf00,0x688a020d,0xe676c6a6,0x8cd6338b,0x1a3c8d0e,0xcce8b06b,0x6ad0ed0b,0xa0522717,0xdc71ac83,0x2285db71,0xd5b4dda6,0x736f8650,0x6560306c,0x617ce2a6,0xe423417e,0xa40e143,0x544e4032,0x88dffb2a,0x716c1ae0,0x4c467a88,0x5b23bb3,0xe1d0b866,0xbaa3dcb8,0xae3374d3,0xc3381a50,0x1702f75b,0xfe6da368,0xf0b4cf48,0x4e0ffbb8,0x72aad10d,0x26c53a3d,0xf2bce0f6,0xb4557581,0x4a257fdd,0x8c3182a2,0xab0b3b86,0x3d5dfb14,0x4f103634,0xd37b52d7,0x444eff16,0xeb0a33d1,0x6ca86f6e,0x284ba7,0x8387cfa,0x5fb37586];
    const tt = tt02.map((value) => ror32(value, countV1)); const n0 = (countV2 + 2) & 7; const seed = [0xfa,0x45,0x61,0xd7]; const pad = Buffer.from(seed.map((value) => ((value | (value << 8)) >> n0) & 255));
    const data = Buffer.concat([querySm3, bodyMd5, tsBytes, pad, Buffer.from('00000000000001a0','hex')]); const di = []; for (let i = 0; i < data.length; i += 4) di.push(data.readUInt32BE(i)); let di0 = di[0]; for (let i = 0; i < 112; i += 1) { const di1 = di[i + 1]; const di14 = di[i + 14]; const r1 = rol32(di1, 14) ^ rol32(di1, 25) ^ (di1 >>> 3); const r2 = rol32(di14, 13) ^ rol32(di14, 15) ^ (di14 >>> 10); di.push(u32(di0 + di[i + 9] + r1 + r2)); di0 = di1; }
    const init = [0x7aba4fc8,0x67166507,0x6403fa00,0x340f512f,984304912,3005047866,2874125293,2152413264].map((v) => ror32(v, countV2 & 31)); const chosen = [96,1,3,4,0,6,5,2,0,7,7]; let d = init.slice(); for (let i = 0; i < chosen[0]; i += 1) { const base = ivV1 + i; const n0v = di[base & 127]; const n1 = ((d[chosen[3]] ^ d[chosen[4]]) & d[chosen[1]]) ^ d[chosen[3]]; const n2 = rol32(d[chosen[1]],26)^rol32(d[chosen[1]],21)^rol32(d[chosen[1]],7); const n4 = u32(n0v+n1+n2+tt[base&63]+d[chosen[5]]); const n5=rol32(d[chosen[2]],30)^rol32(d[chosen[2]],19)^rol32(d[chosen[2]],10); const n6=(d[chosen[2]]&d[chosen[6]])|((d[chosen[2]]|d[chosen[6]])&d[chosen[7]]); const n7=u32(n5+n6); const old=d[chosen[9]]; d.unshift(d.pop()); d[chosen[10]]=u32(n7+n4); d[chosen[8]]=u32(old+n4); }
    const ret = Buffer.alloc(32); for (let i = 0; i < 8; i += 1) ret.writeUInt32BE(u32(d[i]+init[i]), i*4); const folded = bxor(ret.subarray(0,16), ret.subarray(16)); folded.copy(ret,0); return Buffer.concat([ret.subarray(0,16), le32(sumMd5(ret.subarray(0,16)) | 0x20)]);
}

const V5_SBOX = Buffer.from('53290fe9e51f316f90f74a7e034d367784ab49237cd0135cdc632c322fd3be0e2624a417ecd9151a7ff64f60730a87f9445ec6ada2f865d22b696c4188f24c0df37b75510b939f6bc2fe6883e68bc8c722181ba0bdb08c9871b50c9a16b46eea8eed20ba4b8a14e0fcf1468dbbef05a93e5a9d7dcf06898635c1fd99f5de287a80c594daaab19b6279fbd75070cb52eb2555c456e39e7839853874e2f0013ac0b64742d8ca10e4b79c955de8b843ce4ed464a6a72ed508091c92e7b3eedd1e1dd12afac321618fa3d65f9167c982f43d66a53c6a1997585b346dbf9672ff37cdbc073b2dae11453304df00815476b2a13fccdb30b957a8acafe127400248591238922563e36406d37a24100b7902a028044e218453c2a399199c9d13dc40c55ba67e502273850ebdc1a2e2188b8f2d9e3cb909b8c46a2a9f4a6dd93007eafa65b7b3a881aa908cc74f0ad76bbbb58617c37012ca05a469fd44e62eecf1e4272ce860c0ae5eadf99b20d8f0234174006f3f110d7657d01645d4eff8f71471cbfe1cb2f52648727bf3c9de55153e031b4d61757db63dbf7782eeafe9018a8891362fb14759ac32bab03b349aeb5a377c5156be4c8dfbe13a684bda39cf836697c894545fe0f2491acea9fc6252f4ff1e0fe72bd2df6e67a7f635e5bcc6d1a5dd951d89960887a18eb40c785cdb1f80ed42299333ab98cdd67f316cd54346585dccd759fb722789b08807cc0fda293f7e5e1819bb0353517020b31d3d00374952bea2c421e862040a9ec892a05b266b7a0d0cc316f483b81af39715657ffe32ad8de0c13077646035236ee5363e5f900e9a7cf850a81cd9960b6df73317226f99eaa6fff15cec34acb98246639b918ab2851466a7cdfc4ad1b52c2ae95a58d3734e47ddd5b7560193f644ef9c408b7dee39b4d6aabf4de761e3252d4c7ba3843187745d55e6a5db05d42b45caed43c0c5d0b64bfa9d94a4a9d8f2f0e1a108dcfd288fd2bc1fc7bd675412138169cb09249875ba3b68cfb11180afae104fc9789571c6dfce02413886796ae21e3c488cc21b9f423a066c2eabf98e2fdeeb5776e4f5d09a515ba58cbbab3e37b09fd4f6d9244df80512e84cd7956be301cf64f1429d58577cc241f3a2c655144f81aaf95a4e108da894b38970561ae9002619fbbac91fa922ed202bfc62cb08e0de2a7f3631435f8b47c8a3c563b4db4071ce74c46da6fa696a9e282d1e825d663b93bfd56c48dce1884bb10fccea063929f746443fd830a4232e53da21a1f2d1bdfebc3a02c10a1b8ad31d04fd616590d272ac737e98eb33af60528716bee78ec0ee8699031177277d9cff32542c67caf5f44591681335ae0e178f3409a7803db83892dde5b9b7f0c750e24aef077badd678a09b850b84ec1597e4963cb5e675df1c0d6fb618496ecd76c35c798325590c2fb27a5e','hex');
class AesV5 extends AesV3 {
    constructor(key, khronos) { super(key,khronos); this.wordSize=khronos&3; this.box=V5_SBOX.subarray(this.wordSize*256,(this.wordSize+1)*256); this.con=[[1,0,2,3],[1,3,0,2],[0,1,3,2],[1,0,2,3]][this.wordSize]; this.con2=[[2,0,3,1],[1,3,2,0],[3,2,1,0],[2,3,1,0]][this.wordSize]; this.order=[[0,9,14,15,4,13,2,7,8,1,6,3,12,5,10,11],[0,9,14,11,4,13,2,3,8,1,6,15,12,5,10,7],[0,9,14,3,4,13,2,15,8,1,6,11,12,5,10,7],[0,9,14,15,4,13,2,3,8,1,6,11,12,5,10,7]][this.wordSize]; const init=[0xbbb5de72,0xd4638d5b,0x92a5f73b,0x89f8a1c9][this.wordSize]; const initial=Buffer.alloc(16); for(let i=0;i<4;i+=1)initial.writeUInt32LE(init,i*4); const mk=xorBytes(initial,key); const expanded=Buffer.concat([mk,Buffer.alloc(32)]); let rounds=8; for(let i=4;i<12;i+=1){let at=4*(i-1);let a=expanded[at],b=expanded[at+1],c=expanded[at+2],d=expanded[at+3];if((i&3)===0){const t=(u32(init>>((rounds&24)))^this.box[b])&255;b=this.box[c];c=this.box[d];d=this.box[a];a=t;}rounds+=2;expanded[at+4]=a^expanded[at-12];expanded[at+5]=b^expanded[at-11];expanded[at+6]=c^expanded[at-10];expanded[at+7]=d^expanded[at-9];} this.keys=Array.from({length:12},(_v,i)=>Array.from(expanded.subarray(i*4,i*4+4))); }
    encrypt(source, iv) {
        if (source.length < 248) throw new Error('Invalid v5 carrier');
        const wire=[6,5,3,4,2,7,1,0], compact=[1,7,3,6,2,0,4,5], plaintext=Buffer.alloc(32);
        for(let i=0;i<31;i++) for(let j=0;j<8;j++) plaintext[i]|=((source[i*8+j]>>>wire[j])&1)<<compact[j];
        plaintext[31]=1;
        const first=this.block(xorBytes(plaintext.subarray(0,16),iv));
        const key=Buffer.concat([first,this.block(xorBytes(plaintext.subarray(16),first))]);
        const out=Buffer.from(source);
        for(let i=0;i<31;i++) for(let j=0;j<8;j++) {
            const at=i*8+j;
            out[at]=(out[at]&~(1<<wire[j]))|(((key[i]>>>compact[j])&1)<<wire[j]);
        }
        return Buffer.concat([key.subarray(31),out]);
    }
}
function heliosV5(khronos) {
    const random = Math.floor(Math.random() * 0x100000000); const data = Buffer.concat([le32(random), Buffer.from('8662')]); const digest = crypto.createHash('md5').update(data).digest(); const ascii = Buffer.from(digest.toString('hex'), 'ascii'); const words = [];
    for (let i = 0; i < 4; i += 1) words.push(ascii.readBigUInt64LE(i * 8)); const table = [words[0]]; let b0 = words[0]; let b8 = words[1]; words.splice(0, 2);
    for (let i = 0; i < 34; i += 1) { let x8 = BigInt.asUintN(64, ror64(b8, 8) + b0); x8 = BigInt.asUintN(64, x8 ^ BigInt(i)); words.push(x8); x8 = BigInt.asUintN(64, x8 ^ ror64(b0, 61)); table.push(x8); b0 = x8; b8 = words.shift(); }
    const text = Buffer.from(`${khronos}-646637794-8662`); const pad = Buffer.alloc(Math.ceil((text.length + 1) / 16) * 16, 16 - (text.length % 16)); text.copy(pad); const output = [];
    for (let at = 0; at < pad.length; at += 16) { let a = pad.readBigUInt64LE(at); let b = pad.readBigUInt64LE(at + 8); for (let i = 0; i < 34; i += 1) { b = BigInt.asUintN(64, table[i] ^ (a + ror64(b, 8))); a = BigInt.asUintN(64, b ^ ror64(a, 61)); } const block = Buffer.alloc(16); block.writeBigUInt64LE(a); block.writeBigUInt64LE(b, 8); output.push(block); }
    return Buffer.concat([le32(random), ...output]).toString('base64');
}


function medusaV5(url, body, ts, who) {
    const query=sm3(url.split('?')[1]), f13=hashF13V5(query,crypto.createHash('md5').update(body).digest(),le32(ts),ts);
    const flags=Buffer.alloc(8), magic=Buffer.from('2d4b4fca49750d433fb5ae2c226dcc56','hex');
    const info=proto([[1,1,'sint'],[2,2,'sint'],[3,'8662'],[4,who.device_id],[5,PROCESS_NONCE],[6,'!noperm!'],[12,'Asia/Shanghai,8'],[13,'zh_CN'],[22,who.os_version],[25,PROCESS_STARTED,'sint'],[30,who.device_type],[31,'HONOR'],[32,who.device_type],[34,'HONOR']]);
    const env=proto([[6,'v04.10.03.04-bugfix'],[8,who.channel],[12,info,'message'],[14,who.version_name]]);
    const message=proto([[1,magic,'bytes'],[2,5,'sint'],[3,Math.floor(Math.random()*0x100000000),'sint'],[4,'8662'],[5,who.device_id],[6,'646637794'],[7,who.version_name],[8,'v04.10.03-ml-android'],[9,0x040a0300,'sint'],[10,flags,'bytes'],[12,ts,'sint'],[13,f13,'bytes'],[14,query.subarray(0,6),'bytes'],[15,proto([[1,1,'sint'],[2,1,'sint'],[3,1,'sint'],[5,1,'sint']]),'message'],[17,ts,'sint'],[20,'none'],[21,377,'sint'],[23,env,'message'],[24,'{"cmr":16777216,"cmr2":16777216,"un_h":11,"vpn":0,"kd":0,"dyn":"","do":1,"tk":true}']]);
    const nonce=Math.floor(Math.random()*0x100000000), key=Buffer.from('b23c2a470a20d105dc3f8c4438f8272ed46d6c89ffdcdedd5108698d26e9489d','hex');
    const [hash,seed]=keyHash(key,nonce), transformed=Buffer.concat([flags,xmxor(message,hash)]).reverse();
    for(let i=0;i<transformed.length;i++)transformed[i]^=seed[(~i)&3];
    const check=0x18000001|((query[0]&63)<<14)|((f13[0]&63)<<8);
    const packed=Buffer.concat([Buffer.from([0xca]),le32(Math.floor(Math.random()*0x100000000)),le32(check),transformed,Buffer.from([nonce>>>16,nonce>>>24])]);
    const encrypted=new AesV5(crypto.createHash('md5').update(key.subarray(0,16)).digest(),ts).encrypt(packed,crypto.createHash('md5').update(key.subarray(16)).digest());
    const prefix=Buffer.concat([le32(5),magic]);for(let i=0;i<prefix.length;i++)prefix[i]^=le32(ts)[i&3];
    return Buffer.concat([prefix,Buffer.from([nonce&255,(nonce>>>8)&255,0,1]),encrypted]).toString('base64');
}
// v5 无正文 GET 签名（video_tab 用；2026-11-20 起唯一可用的取源路径，同步自
// jackotom/hongguo-drama 7.7 / OOIUa/hongguo-android PR #12，GPL-3.0-only）。
// 与带正文的 v5 POST 相比：正文摘要按**空 body 的 MD5** 计算，且只返回
// x-khronos / x-helios / x-medusa 三个头，调用方不得附带 Content-Type /
// Content-Encoding / x-ss-stub。
function hgSignedPlaybackGetV5(base,pairsJSON,deviceJSON,now) {
    const pairs=JSON.parse(pairsJSON).filter(p=>p[0]!=='_rticket'), device=JSON.parse(deviceJSON);
    const ts=Math.floor(now/1000), body=Buffer.alloc(0), bodyHash=crypto.createHash('md5').update(body).digest();
    const encode=s=>encodeURIComponent(String(s)).replace(/[!'()]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
    for(let offset=0;offset<1024;offset++) {
        const query=pairs.concat([['_rticket',String(now+offset)]]).map(p=>encode(p[0])+'='+encode(p[1])).join('&');
        if((getIv(getIv(getIv(0x20230928,sm3(query)),bodyHash),le32(ts))&15)!==12)continue;
        const url=base+'?'+query;
        return JSON.stringify({url,headers:{'x-khronos':String(ts),'x-helios':heliosV5(ts),'x-medusa':medusaV5(url,body,ts,device)}});
    }
    throw new Error('v5 signature unavailable');
}
function hgSignedPlaybackV5(base,pairsJSON,bodyBase64,deviceJSON,now) {
    const pairs=JSON.parse(pairsJSON).filter(p=>p[0]!=='_rticket'), device=JSON.parse(deviceJSON), body=Buffer.from(bodyBase64,'base64');
    const ts=Math.floor(now/1000), bodyHash=crypto.createHash('md5').update(body).digest();
    const encode=s=>encodeURIComponent(String(s)).replace(/[!'()]/g,c=>'%'+c.charCodeAt(0).toString(16).toUpperCase());
    for(let offset=0;offset<1024;offset++) {
        const query=pairs.concat([['_rticket',String(now+offset)]]).map(p=>encode(p[0])+'='+encode(p[1])).join('&');
        if((getIv(getIv(getIv(0x20230928,sm3(query)),bodyHash),le32(ts))&15)!==12)continue;
        const url=base+'?'+query;
        return JSON.stringify({url,headers:{'x-khronos':String(ts),'x-helios':heliosV5(ts),'x-medusa':medusaV5(url,body,ts,device),'x-ss-stub':md5(body)}});
    }
    throw new Error('v5 signature unavailable');
}
function hgV5Fixture(kind,key,body,iv,ts) {
    return kind==='carrier'?new AesV5(Buffer.from(key,'hex'),ts).encrypt(Buffer.from(body,'hex'),Buffer.from(iv,'hex')).toString('hex'):hashF13V5(Buffer.from(key,'hex'),Buffer.from(body,'hex'),le32(ts),ts).toString('hex');
}
