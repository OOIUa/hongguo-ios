// Minimal binary runtime for the bundled GPL signing implementation.
// Copyright (c) 2026 Hongguo iOS contributors. GPL-3.0-only.
(function(global) {
  const chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';
  class BinaryBuffer extends Uint8Array {
    static from(input, encoding) {
      if (typeof input !== 'string') return new BinaryBuffer(input instanceof ArrayBuffer ? new Uint8Array(input) : input);
      const e = String(encoding || 'utf8').toLowerCase();
      if (e === 'hex') {
        const out = [];
        for (let i = 0; i + 1 < input.length; i += 2) { const n = parseInt(input.slice(i,i+2),16); if (!Number.isFinite(n)) break; out.push(n); }
        return new BinaryBuffer(out);
      }
      if (e === 'base64' || e === 'base64url') {
        const text = input.replace(/-/g,'+').replace(/_/g,'/').replace(/[^A-Za-z0-9+/]/g,'');
        const out = []; let bits=0, value=0;
        for (const c of text) { value=(value<<6)|chars.indexOf(c); bits+=6; if(bits>=8){bits-=8;out.push((value>>bits)&255);} }
        return new BinaryBuffer(out);
      }
      if (e === 'ascii' || e === 'latin1') return new BinaryBuffer(Array.from(input,c=>c.charCodeAt(0)&255));
      const escaped = unescape(encodeURIComponent(input));
      return new BinaryBuffer(Array.from(escaped,c=>c.charCodeAt(0)));
    }
    static alloc(length, fill=0) { const b=new BinaryBuffer(length); b.fill(fill); return b; }
    static isBuffer(input) { return input instanceof BinaryBuffer; }
    static concat(parts) { const out=new BinaryBuffer(parts.reduce((n,p)=>n+p.length,0));let i=0;for(const p of parts){out.set(p,i);i+=p.length;}return out; }
    subarray(start,end) { return new BinaryBuffer(super.subarray(start,end)); }
    copy(target,start=0,sourceStart=0,sourceEnd=this.length) { const p=this.subarray(sourceStart,sourceEnd);target.set(p.subarray(0,target.length-start),start);return Math.min(p.length,target.length-start); }
    toString(encoding='utf8') {
      if(encoding==='hex')return Array.from(this,v=>v.toString(16).padStart(2,'0')).join('');
      if(encoding==='base64'||encoding==='base64url'){
        let text='';for(let i=0;i<this.length;i+=3){const v=(this[i]<<16)|((this[i+1]||0)<<8)|(this[i+2]||0);text+=chars[(v>>>18)&63]+chars[(v>>>12)&63]+(i+1<this.length?chars[(v>>>6)&63]:'=')+(i+2<this.length?chars[v&63]:'=');}
        return encoding==='base64url'?text.replace(/\+/g,'-').replace(/\//g,'_').replace(/=+$/,''):text;
      }
      const text=Array.from(this,v=>String.fromCharCode(v)).join('');
      if(encoding==='ascii'||encoding==='latin1')return text;
      try{return decodeURIComponent(escape(text));}catch{return text;}
    }
    readUInt32LE(at=0) { return (this[at]|(this[at+1]<<8)|(this[at+2]<<16)|(this[at+3]<<24))>>>0; }
    readUInt32BE(at=0) { return ((this[at]<<24)|(this[at+1]<<16)|(this[at+2]<<8)|this[at+3])>>>0; }
    writeUInt32LE(n,at=0) { for(let i=0;i<4;i++)this[at+i]=(n>>>(i*8))&255;return at+4; }
    writeUInt32BE(n,at=0) { for(let i=0;i<4;i++)this[at+i]=(n>>>((3-i)*8))&255;return at+4; }
    writeFloatLE(n,at=0) { const a=new ArrayBuffer(4);new DataView(a).setFloat32(0,n,true);this.set(new Uint8Array(a),at);return at+4; }
    readBigUInt64LE(at=0) { let n=0n;for(let i=7;i>=0;i--)n=(n<<8n)|BigInt(this[at+i]);return n; }
    writeBigUInt64LE(n,at=0) { for(let i=0;i<8;i++){this[at+i]=Number(n&255n);n>>=8n;}return at+8; }
    writeBigUInt64BE(n,at=0) { for(let i=7;i>=0;i--){this[at+i]=Number(n&255n);n>>=8n;}return at+8; }
  }
  global.Buffer=BinaryBuffer;
  global.crypto={
    randomBytes(count){return BinaryBuffer.from(__hgRandom(count),'hex');},
    createHash(algorithm){let parts=[];return{update(value){parts.push(BinaryBuffer.isBuffer(value)?value:BinaryBuffer.from(value));return this;},digest(encoding){const digest=BinaryBuffer.from(__hgHash(algorithm,BinaryBuffer.concat(parts).toString('hex')),'hex');return encoding?digest.toString(encoding):digest;}};}
  };
})(this);
