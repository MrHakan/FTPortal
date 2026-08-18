# ==============================================================================
#  LocalFilePortal.ps1  v2.0
#  Single-file PowerShell local file transfer portal
#   - Wi-Fi only, no admin required (TcpListener)
#   - Connected devices visible, click-to-target + public broadcast
#   - No time limit, no size limit
#   - Streaming multipart parser + C# FastScan boundary -> fast upload
#   - Native PowerShell 5.1+, no external dependencies
# ==============================================================================

Add-Type -AssemblyName System.Web
Add-Type -AssemblyName System.IO.Compression -ErrorAction SilentlyContinue
Add-Type -AssemblyName System.IO.Compression.FileSystem -ErrorAction SilentlyContinue

# ============================== SETTINGS ======================================
$Global:Password    = 'hako123'
$Global:Port        = 8080
$Global:ShareFolder = 'C:\SharedTransfer'
$Global:MetaFolder  = Join-Path $Global:ShareFolder '.meta'
$Global:CookieName  = 'LDSID'
$Global:SessionTTL  = [TimeSpan]::FromDays(365)     # effectively no expiry
$Global:DeviceTTL   = [TimeSpan]::FromMinutes(5)    # 'online' threshold
$Global:MaxThreads  = 32
$Global:SweepEvery  = [TimeSpan]::FromMinutes(2)

# --- Self-AP: the host becomes the network, no router/Wi-Fi needed ------------
$Global:SelfAp      = $true          # raise our own access point at startup
$Global:ApSsid      = 'FTPHAKAN'     # a 4-hex suffix is appended at runtime
$Global:ApPassphrase= ''             # generated per run; never hard-coded
# 'wifidirect' is the default on purpose: it is a closed island (no internet is
# shared with clients) and it never touches the machine's saved Mobile Hotspot
# settings. 'hotspot' shares the host's internet connection by definition.
$Global:ApPrefer    = 'wifidirect'   # 'wifidirect' | 'hotspot'
# Own DNS + redirect unknown hosts, so the phone pops the portal by itself right
# after joining and one QR is enough. Costs the "internet available" indicator.
$Global:CaptivePortal = $true
$Global:DnsPort     = 53
# Where the machine's own hotspot SSID/passphrase is parked while we borrow it.
$Global:ApRestoreFile = Join-Path $PSScriptRoot 'ap-restore.json'
# --- P2P: browser-to-browser DataChannel, server only brokers the handshake ---
$Global:P2P         = $true
$Global:SignalTTL   = [TimeSpan]::FromSeconds(60)

$Global:Sessions    = [hashtable]::Synchronized(@{})   # sid -> @{Sid;PubId;Nick;IP;UA;Created;LastSeen}
$Global:PubIndex    = [hashtable]::Synchronized(@{})   # pubId -> sid
$Global:Transfers   = [hashtable]::Synchronized(@{})   # id -> @{Id;Name;Path;Size;Sender;SenderNick;Target;BundleId;Created}
$Global:UploadLock  = New-Object object
$Global:SessionLock = New-Object object
$Global:SweepState  = [hashtable]::Synchronized(@{ Last = [datetime]::MinValue })
$Global:Signals     = [hashtable]::Synchronized(@{})   # pubId -> ArrayList of pending WebRTC signals
$Global:SignalLock  = New-Object object
$Global:Bearer      = [hashtable]::Synchronized(@{ Mode='none'; Ssid=''; Pass=''; Dns=$false })
$Global:ApWatch     = [hashtable]::Synchronized(@{ Stop=$false; Restarts=0 })
# .dat extension on purpose: transfer import scans .meta\*.json and must skip this
$Global:SessionFile = Join-Path $Global:MetaFolder 'sessions.dat'

# Embedded qrcode.js (Kazuhiko Arase / davidshimjs, MIT) is injected below at
# build time so the invite QR works fully offline. Empty string = no QR.
$Global:QrJs = ''
$Global:QrJs = @'
var QRCode;!function(){function a(a){this.mode=c.MODE_8BIT_BYTE,this.data=a,this.parsedData=[];for(var b=[],d=0,e=this.data.length;e>d;d++){var f=this.data.charCodeAt(d);f>65536?(b[0]=240|(1835008&f)>>>18,b[1]=128|(258048&f)>>>12,b[2]=128|(4032&f)>>>6,b[3]=128|63&f):f>2048?(b[0]=224|(61440&f)>>>12,b[1]=128|(4032&f)>>>6,b[2]=128|63&f):f>128?(b[0]=192|(1984&f)>>>6,b[1]=128|63&f):b[0]=f,this.parsedData=this.parsedData.concat(b)}this.parsedData.length!=this.data.length&&(this.parsedData.unshift(191),this.parsedData.unshift(187),this.parsedData.unshift(239))}function b(a,b){this.typeNumber=a,this.errorCorrectLevel=b,this.modules=null,this.moduleCount=0,this.dataCache=null,this.dataList=[]}function i(a,b){if(void 0==a.length)throw new Error(a.length+"/"+b);for(var c=0;c<a.length&&0==a[c];)c++;this.num=new Array(a.length-c+b);for(var d=0;d<a.length-c;d++)this.num[d]=a[d+c]}function j(a,b){this.totalCount=a,this.dataCount=b}function k(){this.buffer=[],this.length=0}function m(){return"undefined"!=typeof CanvasRenderingContext2D}function n(){var a=!1,b=navigator.userAgent;return/android/i.test(b)&&(a=!0,aMat=b.toString().match(/android ([0-9]\.[0-9])/i),aMat&&aMat[1]&&(a=parseFloat(aMat[1]))),a}function r(a,b){for(var c=1,e=s(a),f=0,g=l.length;g>=f;f++){var h=0;switch(b){case d.L:h=l[f][0];break;case d.M:h=l[f][1];break;case d.Q:h=l[f][2];break;case d.H:h=l[f][3]}if(h>=e)break;c++}if(c>l.length)throw new Error("Too long data");return c}function s(a){var b=encodeURI(a).toString().replace(/\%[0-9a-fA-F]{2}/g,"a");return b.length+(b.length!=a?3:0)}a.prototype={getLength:function(){return this.parsedData.length},write:function(a){for(var b=0,c=this.parsedData.length;c>b;b++)a.put(this.parsedData[b],8)}},b.prototype={addData:function(b){var c=new a(b);this.dataList.push(c),this.dataCache=null},isDark:function(a,b){if(0>a||this.moduleCount<=a||0>b||this.moduleCount<=b)throw new Error(a+","+b);return this.modules[a][b]},getModuleCount:function(){return this.moduleCount},make:function(){this.makeImpl(!1,this.getBestMaskPattern())},makeImpl:function(a,c){this.moduleCount=4*this.typeNumber+17,this.modules=new Array(this.moduleCount);for(var d=0;d<this.moduleCount;d++){this.modules[d]=new Array(this.moduleCount);for(var e=0;e<this.moduleCount;e++)this.modules[d][e]=null}this.setupPositionProbePattern(0,0),this.setupPositionProbePattern(this.moduleCount-7,0),this.setupPositionProbePattern(0,this.moduleCount-7),this.setupPositionAdjustPattern(),this.setupTimingPattern(),this.setupTypeInfo(a,c),this.typeNumber>=7&&this.setupTypeNumber(a),null==this.dataCache&&(this.dataCache=b.createData(this.typeNumber,this.errorCorrectLevel,this.dataList)),this.mapData(this.dataCache,c)},setupPositionProbePattern:function(a,b){for(var c=-1;7>=c;c++)if(!(-1>=a+c||this.moduleCount<=a+c))for(var d=-1;7>=d;d++)-1>=b+d||this.moduleCount<=b+d||(this.modules[a+c][b+d]=c>=0&&6>=c&&(0==d||6==d)||d>=0&&6>=d&&(0==c||6==c)||c>=2&&4>=c&&d>=2&&4>=d?!0:!1)},getBestMaskPattern:function(){for(var a=0,b=0,c=0;8>c;c++){this.makeImpl(!0,c);var d=f.getLostPoint(this);(0==c||a>d)&&(a=d,b=c)}return b},createMovieClip:function(a,b,c){var d=a.createEmptyMovieClip(b,c),e=1;this.make();for(var f=0;f<this.modules.length;f++)for(var g=f*e,h=0;h<this.modules[f].length;h++){var i=h*e,j=this.modules[f][h];j&&(d.beginFill(0,100),d.moveTo(i,g),d.lineTo(i+e,g),d.lineTo(i+e,g+e),d.lineTo(i,g+e),d.endFill())}return d},setupTimingPattern:function(){for(var a=8;a<this.moduleCount-8;a++)null==this.modules[a][6]&&(this.modules[a][6]=0==a%2);for(var b=8;b<this.moduleCount-8;b++)null==this.modules[6][b]&&(this.modules[6][b]=0==b%2)},setupPositionAdjustPattern:function(){for(var a=f.getPatternPosition(this.typeNumber),b=0;b<a.length;b++)for(var c=0;c<a.length;c++){var d=a[b],e=a[c];if(null==this.modules[d][e])for(var g=-2;2>=g;g++)for(var h=-2;2>=h;h++)this.modules[d+g][e+h]=-2==g||2==g||-2==h||2==h||0==g&&0==h?!0:!1}},setupTypeNumber:function(a){for(var b=f.getBCHTypeNumber(this.typeNumber),c=0;18>c;c++){var d=!a&&1==(1&b>>c);this.modules[Math.floor(c/3)][c%3+this.moduleCount-8-3]=d}for(var c=0;18>c;c++){var d=!a&&1==(1&b>>c);this.modules[c%3+this.moduleCount-8-3][Math.floor(c/3)]=d}},setupTypeInfo:function(a,b){for(var c=this.errorCorrectLevel<<3|b,d=f.getBCHTypeInfo(c),e=0;15>e;e++){var g=!a&&1==(1&d>>e);6>e?this.modules[e][8]=g:8>e?this.modules[e+1][8]=g:this.modules[this.moduleCount-15+e][8]=g}for(var e=0;15>e;e++){var g=!a&&1==(1&d>>e);8>e?this.modules[8][this.moduleCount-e-1]=g:9>e?this.modules[8][15-e-1+1]=g:this.modules[8][15-e-1]=g}this.modules[this.moduleCount-8][8]=!a},mapData:function(a,b){for(var c=-1,d=this.moduleCount-1,e=7,g=0,h=this.moduleCount-1;h>0;h-=2)for(6==h&&h--;;){for(var i=0;2>i;i++)if(null==this.modules[d][h-i]){var j=!1;g<a.length&&(j=1==(1&a[g]>>>e));var k=f.getMask(b,d,h-i);k&&(j=!j),this.modules[d][h-i]=j,e--,-1==e&&(g++,e=7)}if(d+=c,0>d||this.moduleCount<=d){d-=c,c=-c;break}}}},b.PAD0=236,b.PAD1=17,b.createData=function(a,c,d){for(var e=j.getRSBlocks(a,c),g=new k,h=0;h<d.length;h++){var i=d[h];g.put(i.mode,4),g.put(i.getLength(),f.getLengthInBits(i.mode,a)),i.write(g)}for(var l=0,h=0;h<e.length;h++)l+=e[h].dataCount;if(g.getLengthInBits()>8*l)throw new Error("code length overflow. ("+g.getLengthInBits()+">"+8*l+")");for(g.getLengthInBits()+4<=8*l&&g.put(0,4);0!=g.getLengthInBits()%8;)g.putBit(!1);for(;;){if(g.getLengthInBits()>=8*l)break;if(g.put(b.PAD0,8),g.getLengthInBits()>=8*l)break;g.put(b.PAD1,8)}return b.createBytes(g,e)},b.createBytes=function(a,b){for(var c=0,d=0,e=0,g=new Array(b.length),h=new Array(b.length),j=0;j<b.length;j++){var k=b[j].dataCount,l=b[j].totalCount-k;d=Math.max(d,k),e=Math.max(e,l),g[j]=new Array(k);for(var m=0;m<g[j].length;m++)g[j][m]=255&a.buffer[m+c];c+=k;var n=f.getErrorCorrectPolynomial(l),o=new i(g[j],n.getLength()-1),p=o.mod(n);h[j]=new Array(n.getLength()-1);for(var m=0;m<h[j].length;m++){var q=m+p.getLength()-h[j].length;h[j][m]=q>=0?p.get(q):0}}for(var r=0,m=0;m<b.length;m++)r+=b[m].totalCount;for(var s=new Array(r),t=0,m=0;d>m;m++)for(var j=0;j<b.length;j++)m<g[j].length&&(s[t++]=g[j][m]);for(var m=0;e>m;m++)for(var j=0;j<b.length;j++)m<h[j].length&&(s[t++]=h[j][m]);return s};for(var c={MODE_NUMBER:1,MODE_ALPHA_NUM:2,MODE_8BIT_BYTE:4,MODE_KANJI:8},d={L:1,M:0,Q:3,H:2},e={PATTERN000:0,PATTERN001:1,PATTERN010:2,PATTERN011:3,PATTERN100:4,PATTERN101:5,PATTERN110:6,PATTERN111:7},f={PATTERN_POSITION_TABLE:[[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166],[6,30,58,86,114,142,170]],G15:1335,G18:7973,G15_MASK:21522,getBCHTypeInfo:function(a){for(var b=a<<10;f.getBCHDigit(b)-f.getBCHDigit(f.G15)>=0;)b^=f.G15<<f.getBCHDigit(b)-f.getBCHDigit(f.G15);return(a<<10|b)^f.G15_MASK},getBCHTypeNumber:function(a){for(var b=a<<12;f.getBCHDigit(b)-f.getBCHDigit(f.G18)>=0;)b^=f.G18<<f.getBCHDigit(b)-f.getBCHDigit(f.G18);return a<<12|b},getBCHDigit:function(a){for(var b=0;0!=a;)b++,a>>>=1;return b},getPatternPosition:function(a){return f.PATTERN_POSITION_TABLE[a-1]},getMask:function(a,b,c){switch(a){case e.PATTERN000:return 0==(b+c)%2;case e.PATTERN001:return 0==b%2;case e.PATTERN010:return 0==c%3;case e.PATTERN011:return 0==(b+c)%3;case e.PATTERN100:return 0==(Math.floor(b/2)+Math.floor(c/3))%2;case e.PATTERN101:return 0==b*c%2+b*c%3;case e.PATTERN110:return 0==(b*c%2+b*c%3)%2;case e.PATTERN111:return 0==(b*c%3+(b+c)%2)%2;default:throw new Error("bad maskPattern:"+a)}},getErrorCorrectPolynomial:function(a){for(var b=new i([1],0),c=0;a>c;c++)b=b.multiply(new i([1,g.gexp(c)],0));return b},getLengthInBits:function(a,b){if(b>=1&&10>b)switch(a){case c.MODE_NUMBER:return 10;case c.MODE_ALPHA_NUM:return 9;case c.MODE_8BIT_BYTE:return 8;case c.MODE_KANJI:return 8;default:throw new Error("mode:"+a)}else if(27>b)switch(a){case c.MODE_NUMBER:return 12;case c.MODE_ALPHA_NUM:return 11;case c.MODE_8BIT_BYTE:return 16;case c.MODE_KANJI:return 10;default:throw new Error("mode:"+a)}else{if(!(41>b))throw new Error("type:"+b);switch(a){case c.MODE_NUMBER:return 14;case c.MODE_ALPHA_NUM:return 13;case c.MODE_8BIT_BYTE:return 16;case c.MODE_KANJI:return 12;default:throw new Error("mode:"+a)}}},getLostPoint:function(a){for(var b=a.getModuleCount(),c=0,d=0;b>d;d++)for(var e=0;b>e;e++){for(var f=0,g=a.isDark(d,e),h=-1;1>=h;h++)if(!(0>d+h||d+h>=b))for(var i=-1;1>=i;i++)0>e+i||e+i>=b||(0!=h||0!=i)&&g==a.isDark(d+h,e+i)&&f++;f>5&&(c+=3+f-5)}for(var d=0;b-1>d;d++)for(var e=0;b-1>e;e++){var j=0;a.isDark(d,e)&&j++,a.isDark(d+1,e)&&j++,a.isDark(d,e+1)&&j++,a.isDark(d+1,e+1)&&j++,(0==j||4==j)&&(c+=3)}for(var d=0;b>d;d++)for(var e=0;b-6>e;e++)a.isDark(d,e)&&!a.isDark(d,e+1)&&a.isDark(d,e+2)&&a.isDark(d,e+3)&&a.isDark(d,e+4)&&!a.isDark(d,e+5)&&a.isDark(d,e+6)&&(c+=40);for(var e=0;b>e;e++)for(var d=0;b-6>d;d++)a.isDark(d,e)&&!a.isDark(d+1,e)&&a.isDark(d+2,e)&&a.isDark(d+3,e)&&a.isDark(d+4,e)&&!a.isDark(d+5,e)&&a.isDark(d+6,e)&&(c+=40);for(var k=0,e=0;b>e;e++)for(var d=0;b>d;d++)a.isDark(d,e)&&k++;var l=Math.abs(100*k/b/b-50)/5;return c+=10*l}},g={glog:function(a){if(1>a)throw new Error("glog("+a+")");return g.LOG_TABLE[a]},gexp:function(a){for(;0>a;)a+=255;for(;a>=256;)a-=255;return g.EXP_TABLE[a]},EXP_TABLE:new Array(256),LOG_TABLE:new Array(256)},h=0;8>h;h++)g.EXP_TABLE[h]=1<<h;for(var h=8;256>h;h++)g.EXP_TABLE[h]=g.EXP_TABLE[h-4]^g.EXP_TABLE[h-5]^g.EXP_TABLE[h-6]^g.EXP_TABLE[h-8];for(var h=0;255>h;h++)g.LOG_TABLE[g.EXP_TABLE[h]]=h;i.prototype={get:function(a){return this.num[a]},getLength:function(){return this.num.length},multiply:function(a){for(var b=new Array(this.getLength()+a.getLength()-1),c=0;c<this.getLength();c++)for(var d=0;d<a.getLength();d++)b[c+d]^=g.gexp(g.glog(this.get(c))+g.glog(a.get(d)));return new i(b,0)},mod:function(a){if(this.getLength()-a.getLength()<0)return this;for(var b=g.glog(this.get(0))-g.glog(a.get(0)),c=new Array(this.getLength()),d=0;d<this.getLength();d++)c[d]=this.get(d);for(var d=0;d<a.getLength();d++)c[d]^=g.gexp(g.glog(a.get(d))+b);return new i(c,0).mod(a)}},j.RS_BLOCK_TABLE=[[1,26,19],[1,26,16],[1,26,13],[1,26,9],[1,44,34],[1,44,28],[1,44,22],[1,44,16],[1,70,55],[1,70,44],[2,35,17],[2,35,13],[1,100,80],[2,50,32],[2,50,24],[4,25,9],[1,134,108],[2,67,43],[2,33,15,2,34,16],[2,33,11,2,34,12],[2,86,68],[4,43,27],[4,43,19],[4,43,15],[2,98,78],[4,49,31],[2,32,14,4,33,15],[4,39,13,1,40,14],[2,121,97],[2,60,38,2,61,39],[4,40,18,2,41,19],[4,40,14,2,41,15],[2,146,116],[3,58,36,2,59,37],[4,36,16,4,37,17],[4,36,12,4,37,13],[2,86,68,2,87,69],[4,69,43,1,70,44],[6,43,19,2,44,20],[6,43,15,2,44,16],[4,101,81],[1,80,50,4,81,51],[4,50,22,4,51,23],[3,36,12,8,37,13],[2,116,92,2,117,93],[6,58,36,2,59,37],[4,46,20,6,47,21],[7,42,14,4,43,15],[4,133,107],[8,59,37,1,60,38],[8,44,20,4,45,21],[12,33,11,4,34,12],[3,145,115,1,146,116],[4,64,40,5,65,41],[11,36,16,5,37,17],[11,36,12,5,37,13],[5,109,87,1,110,88],[5,65,41,5,66,42],[5,54,24,7,55,25],[11,36,12],[5,122,98,1,123,99],[7,73,45,3,74,46],[15,43,19,2,44,20],[3,45,15,13,46,16],[1,135,107,5,136,108],[10,74,46,1,75,47],[1,50,22,15,51,23],[2,42,14,17,43,15],[5,150,120,1,151,121],[9,69,43,4,70,44],[17,50,22,1,51,23],[2,42,14,19,43,15],[3,141,113,4,142,114],[3,70,44,11,71,45],[17,47,21,4,48,22],[9,39,13,16,40,14],[3,135,107,5,136,108],[3,67,41,13,68,42],[15,54,24,5,55,25],[15,43,15,10,44,16],[4,144,116,4,145,117],[17,68,42],[17,50,22,6,51,23],[19,46,16,6,47,17],[2,139,111,7,140,112],[17,74,46],[7,54,24,16,55,25],[34,37,13],[4,151,121,5,152,122],[4,75,47,14,76,48],[11,54,24,14,55,25],[16,45,15,14,46,16],[6,147,117,4,148,118],[6,73,45,14,74,46],[11,54,24,16,55,25],[30,46,16,2,47,17],[8,132,106,4,133,107],[8,75,47,13,76,48],[7,54,24,22,55,25],[22,45,15,13,46,16],[10,142,114,2,143,115],[19,74,46,4,75,47],[28,50,22,6,51,23],[33,46,16,4,47,17],[8,152,122,4,153,123],[22,73,45,3,74,46],[8,53,23,26,54,24],[12,45,15,28,46,16],[3,147,117,10,148,118],[3,73,45,23,74,46],[4,54,24,31,55,25],[11,45,15,31,46,16],[7,146,116,7,147,117],[21,73,45,7,74,46],[1,53,23,37,54,24],[19,45,15,26,46,16],[5,145,115,10,146,116],[19,75,47,10,76,48],[15,54,24,25,55,25],[23,45,15,25,46,16],[13,145,115,3,146,116],[2,74,46,29,75,47],[42,54,24,1,55,25],[23,45,15,28,46,16],[17,145,115],[10,74,46,23,75,47],[10,54,24,35,55,25],[19,45,15,35,46,16],[17,145,115,1,146,116],[14,74,46,21,75,47],[29,54,24,19,55,25],[11,45,15,46,46,16],[13,145,115,6,146,116],[14,74,46,23,75,47],[44,54,24,7,55,25],[59,46,16,1,47,17],[12,151,121,7,152,122],[12,75,47,26,76,48],[39,54,24,14,55,25],[22,45,15,41,46,16],[6,151,121,14,152,122],[6,75,47,34,76,48],[46,54,24,10,55,25],[2,45,15,64,46,16],[17,152,122,4,153,123],[29,74,46,14,75,47],[49,54,24,10,55,25],[24,45,15,46,46,16],[4,152,122,18,153,123],[13,74,46,32,75,47],[48,54,24,14,55,25],[42,45,15,32,46,16],[20,147,117,4,148,118],[40,75,47,7,76,48],[43,54,24,22,55,25],[10,45,15,67,46,16],[19,148,118,6,149,119],[18,75,47,31,76,48],[34,54,24,34,55,25],[20,45,15,61,46,16]],j.getRSBlocks=function(a,b){var c=j.getRsBlockTable(a,b);if(void 0==c)throw new Error("bad rs block @ typeNumber:"+a+"/errorCorrectLevel:"+b);for(var d=c.length/3,e=[],f=0;d>f;f++)for(var g=c[3*f+0],h=c[3*f+1],i=c[3*f+2],k=0;g>k;k++)e.push(new j(h,i));return e},j.getRsBlockTable=function(a,b){switch(b){case d.L:return j.RS_BLOCK_TABLE[4*(a-1)+0];case d.M:return j.RS_BLOCK_TABLE[4*(a-1)+1];case d.Q:return j.RS_BLOCK_TABLE[4*(a-1)+2];case d.H:return j.RS_BLOCK_TABLE[4*(a-1)+3];default:return void 0}},k.prototype={get:function(a){var b=Math.floor(a/8);return 1==(1&this.buffer[b]>>>7-a%8)},put:function(a,b){for(var c=0;b>c;c++)this.putBit(1==(1&a>>>b-c-1))},getLengthInBits:function(){return this.length},putBit:function(a){var b=Math.floor(this.length/8);this.buffer.length<=b&&this.buffer.push(0),a&&(this.buffer[b]|=128>>>this.length%8),this.length++}};var l=[[17,14,11,7],[32,26,20,14],[53,42,32,24],[78,62,46,34],[106,84,60,44],[134,106,74,58],[154,122,86,64],[192,152,108,84],[230,180,130,98],[271,213,151,119],[321,251,177,137],[367,287,203,155],[425,331,241,177],[458,362,258,194],[520,412,292,220],[586,450,322,250],[644,504,364,280],[718,560,394,310],[792,624,442,338],[858,666,482,382],[929,711,509,403],[1003,779,565,439],[1091,857,611,461],[1171,911,661,511],[1273,997,715,535],[1367,1059,751,593],[1465,1125,805,625],[1528,1190,868,658],[1628,1264,908,698],[1732,1370,982,742],[1840,1452,1030,790],[1952,1538,1112,842],[2068,1628,1168,898],[2188,1722,1228,958],[2303,1809,1283,983],[2431,1911,1351,1051],[2563,1989,1423,1093],[2699,2099,1499,1139],[2809,2213,1579,1219],[2953,2331,1663,1273]],o=function(){var a=function(a,b){this._el=a,this._htOption=b};return a.prototype.draw=function(a){function g(a,b){var c=document.createElementNS("http://www.w3.org/2000/svg",a);for(var d in b)b.hasOwnProperty(d)&&c.setAttribute(d,b[d]);return c}var b=this._htOption,c=this._el,d=a.getModuleCount();Math.floor(b.width/d),Math.floor(b.height/d),this.clear();var h=g("svg",{viewBox:"0 0 "+String(d)+" "+String(d),width:"100%",height:"100%",fill:b.colorLight});h.setAttributeNS("http://www.w3.org/2000/xmlns/","xmlns:xlink","http://www.w3.org/1999/xlink"),c.appendChild(h),h.appendChild(g("rect",{fill:b.colorDark,width:"1",height:"1",id:"template"}));for(var i=0;d>i;i++)for(var j=0;d>j;j++)if(a.isDark(i,j)){var k=g("use",{x:String(i),y:String(j)});k.setAttributeNS("http://www.w3.org/1999/xlink","href","#template"),h.appendChild(k)}},a.prototype.clear=function(){for(;this._el.hasChildNodes();)this._el.removeChild(this._el.lastChild)},a}(),p="svg"===document.documentElement.tagName.toLowerCase(),q=p?o:m()?function(){function a(){this._elImage.src=this._elCanvas.toDataURL("image/png"),this._elImage.style.display="block",this._elCanvas.style.display="none"}function d(a,b){var c=this;if(c._fFail=b,c._fSuccess=a,null===c._bSupportDataURI){var d=document.createElement("img"),e=function(){c._bSupportDataURI=!1,c._fFail&&_fFail.call(c)},f=function(){c._bSupportDataURI=!0,c._fSuccess&&c._fSuccess.call(c)};return d.onabort=e,d.onerror=e,d.onload=f,d.src="data:image/gif;base64,iVBORw0KGgoAAAANSUhEUgAAAAUAAAAFCAYAAACNbyblAAAAHElEQVQI12P4//8/w38GIAXDIBKE0DHxgljNBAAO9TXL0Y4OHwAAAABJRU5ErkJggg==",void 0}c._bSupportDataURI===!0&&c._fSuccess?c._fSuccess.call(c):c._bSupportDataURI===!1&&c._fFail&&c._fFail.call(c)}if(this._android&&this._android<=2.1){var b=1/window.devicePixelRatio,c=CanvasRenderingContext2D.prototype.drawImage;CanvasRenderingContext2D.prototype.drawImage=function(a,d,e,f,g,h,i,j){if("nodeName"in a&&/img/i.test(a.nodeName))for(var l=arguments.length-1;l>=1;l--)arguments[l]=arguments[l]*b;else"undefined"==typeof j&&(arguments[1]*=b,arguments[2]*=b,arguments[3]*=b,arguments[4]*=b);c.apply(this,arguments)}}var e=function(a,b){this._bIsPainted=!1,this._android=n(),this._htOption=b,this._elCanvas=document.createElement("canvas"),this._elCanvas.width=b.width,this._elCanvas.height=b.height,a.appendChild(this._elCanvas),this._el=a,this._oContext=this._elCanvas.getContext("2d"),this._bIsPainted=!1,this._elImage=document.createElement("img"),this._elImage.style.display="none",this._el.appendChild(this._elImage),this._bSupportDataURI=null};return e.prototype.draw=function(a){var b=this._elImage,c=this._oContext,d=this._htOption,e=a.getModuleCount(),f=d.width/e,g=d.height/e,h=Math.round(f),i=Math.round(g);b.style.display="none",this.clear();for(var j=0;e>j;j++)for(var k=0;e>k;k++){var l=a.isDark(j,k),m=k*f,n=j*g;c.strokeStyle=l?d.colorDark:d.colorLight,c.lineWidth=1,c.fillStyle=l?d.colorDark:d.colorLight,c.fillRect(m,n,f,g),c.strokeRect(Math.floor(m)+.5,Math.floor(n)+.5,h,i),c.strokeRect(Math.ceil(m)-.5,Math.ceil(n)-.5,h,i)}this._bIsPainted=!0},e.prototype.makeImage=function(){this._bIsPainted&&d.call(this,a)},e.prototype.isPainted=function(){return this._bIsPainted},e.prototype.clear=function(){this._oContext.clearRect(0,0,this._elCanvas.width,this._elCanvas.height),this._bIsPainted=!1},e.prototype.round=function(a){return a?Math.floor(1e3*a)/1e3:a},e}():function(){var a=function(a,b){this._el=a,this._htOption=b};return a.prototype.draw=function(a){for(var b=this._htOption,c=this._el,d=a.getModuleCount(),e=Math.floor(b.width/d),f=Math.floor(b.height/d),g=['<table style="border:0;border-collapse:collapse;">'],h=0;d>h;h++){g.push("<tr>");for(var i=0;d>i;i++)g.push('<td style="border:0;border-collapse:collapse;padding:0;margin:0;width:'+e+"px;height:"+f+"px;background-color:"+(a.isDark(h,i)?b.colorDark:b.colorLight)+';"></td>');g.push("</tr>")}g.push("</table>"),c.innerHTML=g.join("");var j=c.childNodes[0],k=(b.width-j.offsetWidth)/2,l=(b.height-j.offsetHeight)/2;k>0&&l>0&&(j.style.margin=l+"px "+k+"px")},a.prototype.clear=function(){this._el.innerHTML=""},a}();QRCode=function(a,b){if(this._htOption={width:256,height:256,typeNumber:4,colorDark:"#000000",colorLight:"#ffffff",correctLevel:d.H},"string"==typeof b&&(b={text:b}),b)for(var c in b)this._htOption[c]=b[c];"string"==typeof a&&(a=document.getElementById(a)),this._android=n(),this._el=a,this._oQRCode=null,this._oDrawing=new q(this._el,this._htOption),this._htOption.text&&this.makeCode(this._htOption.text)},QRCode.prototype.makeCode=function(a){this._oQRCode=new b(r(a,this._htOption.correctLevel),this._htOption.correctLevel),this._oQRCode.addData(a),this._oQRCode.make(),this._el.title=a,this._oDrawing.draw(this._oQRCode),this.makeImage()},QRCode.prototype.makeImage=function(){"function"==typeof this._oDrawing.makeImage&&(!this._android||this._android>=3)&&this._oDrawing.makeImage()},QRCode.prototype.clear=function(){this._oDrawing.clear()},QRCode.CorrectLevel=d}();
'@

foreach ($d in @($Global:ShareFolder, $Global:MetaFolder)) {
    if (-not (Test-Path -LiteralPath $d)) { New-Item -ItemType Directory -Path $d -Force | Out-Null }
}

# =================== FAST BOUNDARY SCANNER (C#) ===============================
# PowerShell array index access is slow. C# native scan -> ~100x faster.
if (-not ('LFP.FastScan' -as [type])) {
    Add-Type -TypeDefinition @'
namespace LFP {
    public static class FastScan {
        public static int IndexOf(byte[] hay, int start, int len, byte[] needle) {
            int nlen = needle.Length;
            if (nlen == 0 || len < nlen) return -1;
            int end = start + len - nlen;
            byte n0 = needle[0];
            for (int i = start; i <= end; i++) {
                if (hay[i] != n0) continue;
                int j = 1;
                while (j < nlen && hay[i+j] == needle[j]) j++;
                if (j == nlen) return i;
            }
            return -1;
        }
    }
}
'@
}

# ============================== HELPERS =======================================
function Get-IconForFile {
    param([string]$Name)
    $ext = [System.IO.Path]::GetExtension($Name).ToLowerInvariant().TrimStart('.')
    switch ($ext) {
        'pdf'                                   { return [char]0xD83D + [char]0xDCC4 }
        { $_ -in 'zip','rar','7z','tar','gz' }  { return [char]0xD83D + [char]0xDDDC }
        { $_ -in 'jpg','jpeg','png','gif','bmp','webp','svg','tiff' } { return [char]0xD83D + [char]0xDDBC }
        { $_ -in 'mp4','mkv','avi','mov','wmv','flv','webm' }         { return [char]0xD83C + [char]0xDFAC }
        { $_ -in 'mp3','wav','flac','aac','ogg','m4a' }              { return [char]0xD83C + [char]0xDFB5 }
        { $_ -in 'exe','msi','bat','cmd','ps1' }                     { return [char]0x2699 + [char]0xFE0F }
        { $_ -in 'doc','docx' }                 { return [char]0xD83D + [char]0xDCDD }
        { $_ -in 'xls','xlsx','csv' }           { return [char]0xD83D + [char]0xDCCA }
        { $_ -in 'ppt','pptx' }                 { return [char]0xD83D + [char]0xDCFD }
        { $_ -in 'txt','log','md','ini','cfg' } { return [char]0xD83D + [char]0xDCC3 }
        { $_ -in 'html','htm','css','js','json','xml' } { return [char]0xD83C + [char]0xDF10 }
        default                                 { return [char]0xD83D + [char]0xDCC1 }
    }
}

function Format-Size {
    param([double]$Bytes)
    if ($Bytes -ge 1GB) { return ('{0:N2} GB' -f ($Bytes / 1GB)) }
    if ($Bytes -ge 1MB) { return ('{0:N2} MB' -f ($Bytes / 1MB)) }
    if ($Bytes -ge 1KB) { return ('{0:N2} KB' -f ($Bytes / 1KB)) }
    return ('{0} B' -f [int]$Bytes)
}

function New-SessionId {
    $bytes = New-Object byte[] 32
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($bytes) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($bytes) -replace '-', '').ToLowerInvariant()
}

function New-ShortId {
    param([int]$Bytes = 4)
    $b = New-Object byte[] $Bytes
    $rng = [System.Security.Cryptography.RandomNumberGenerator]::Create()
    try { $rng.GetBytes($b) } finally { $rng.Dispose() }
    return ([System.BitConverter]::ToString($b) -replace '-','').ToLowerInvariant()
}

function Get-DeviceLabel {
    param([string]$UA, [string]$IP)
    $ua = if ($UA) { $UA.ToLowerInvariant() } else { '' }
    $os = 'Device'
    if     ($ua -match 'windows nt')       { $os = 'Windows' }
    elseif ($ua -match 'iphone')           { $os = 'iPhone' }
    elseif ($ua -match 'ipad')             { $os = 'iPad' }
    elseif ($ua -match 'android')          { $os = 'Android' }
    elseif ($ua -match 'macintosh|mac os') { $os = 'Mac' }
    elseif ($ua -match 'linux')            { $os = 'Linux' }
    $last = if ($IP -match '\.(\d+)$') { $Matches[1] } else { 'x' }
    return "$os-$last"
}

function Invoke-PeriodicSweep {
    $now = Get-Date
    [System.Threading.Monitor]::Enter($Global:SweepState)
    try {
        if (($now - $Global:SweepState.Last) -lt $Global:SweepEvery) { return }
        $Global:SweepState.Last = $now
    } finally { [System.Threading.Monitor]::Exit($Global:SweepState) }

    $dead = @()
    foreach ($k in @($Global:Sessions.Keys)) {
        $s = $Global:Sessions[$k]
        if ($null -eq $s -or ($now - $s.LastSeen) -gt $Global:SessionTTL) { $dead += $k }
    }
    foreach ($k in $dead) {
        $s = $Global:Sessions[$k]
        if ($s -and $s.PubId) { [void]$Global:PubIndex.Remove($s.PubId) }
        [void]$Global:Sessions.Remove($k)
    }
}

function ConvertTo-SafeRelPath {
    # Sanitize a client-supplied filename: keep slashes for folder structure,
    # drop path traversal, drop invalid path chars per segment, strip leading /.
    param([string]$Path)
    if ([string]::IsNullOrWhiteSpace($Path)) { return '' }
    $p = $Path -replace '\\', '/'
    $p = $p.TrimStart('/')
    $invalid = [System.IO.Path]::GetInvalidFileNameChars()
    $segs = $p.Split('/')
    $clean = New-Object System.Collections.Generic.List[string]
    foreach ($s in $segs) {
        $s = $s.Trim()
        if ([string]::IsNullOrEmpty($s)) { continue }
        if ($s -eq '.' -or $s -eq '..') { continue }
        foreach ($ch in $invalid) { $s = $s.Replace($ch, '_') }
        if ($s) { [void]$clean.Add($s) }
    }
    return ($clean -join '/')
}

function Save-TransferMeta {
    param($T)
    $obj = [ordered]@{
        id         = $T.Id
        name       = $T.Name
        path       = $T.Path
        size       = $T.Size
        sender     = $T.Sender
        senderNick = $T.SenderNick
        target     = $T.Target
        bundle     = $T.BundleId
        created    = $T.Created.ToString('o')
    }
    $json = $obj | ConvertTo-Json -Compress
    [System.IO.File]::WriteAllText((Join-Path $Global:MetaFolder ($T.Id + '.json')), $json, [System.Text.Encoding]::UTF8)
}

function Import-AllTransfers {
    if (-not (Test-Path -LiteralPath $Global:MetaFolder)) { return }
    Get-ChildItem -LiteralPath $Global:MetaFolder -File -Filter '*.json' -ErrorAction SilentlyContinue | ForEach-Object {
        try {
            $raw = Get-Content -LiteralPath $_.FullName -Raw -Encoding UTF8
            $j   = $raw | ConvertFrom-Json
            if (Test-Path -LiteralPath $j.path -PathType Leaf) {
                $Global:Transfers[$j.id] = @{
                    Id=$j.id; Name=$j.name; Path=$j.path; Size=[int64]$j.size
                    Sender=$j.sender; SenderNick=$j.senderNick; Target=$j.target
                    BundleId=$j.bundle
                    Created=[DateTime]::Parse($j.created)
                }
            } else {
                Remove-Item -LiteralPath $_.FullName -Force -ErrorAction SilentlyContinue
            }
        } catch {}
    }
}

function Remove-Transfer {
    param([string]$Id)
    $t = $Global:Transfers[$Id]
    if ($null -eq $t) { return $false }
    try { Remove-Item -LiteralPath $t.Path -Force -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item -LiteralPath (Join-Path $Global:MetaFolder ($Id + '.json')) -Force -ErrorAction SilentlyContinue } catch {}
    [void]$Global:Transfers.Remove($Id)
    return $true
}

function Save-Sessions {
    # Persist sessions so a server restart doesn't log everyone out.
    [System.Threading.Monitor]::Enter($Global:SessionLock)
    try {
        $arr = @()
        foreach ($k in @($Global:Sessions.Keys)) {
            $s = $Global:Sessions[$k]
            if ($null -eq $s) { continue }
            $arr += [ordered]@{
                sid=$s.Sid; pubId=$s.PubId; nick=$s.Nick; ip=$s.IP; ua=$s.UA
                created=$s.Created.ToString('o'); lastSeen=$s.LastSeen.ToString('o')
            }
        }
        $json = ConvertTo-Json -InputObject $arr -Compress
        [System.IO.File]::WriteAllText($Global:SessionFile, $json, [System.Text.Encoding]::UTF8)
    } catch {} finally {
        [System.Threading.Monitor]::Exit($Global:SessionLock)
    }
}

function Import-Sessions {
    if (-not (Test-Path -LiteralPath $Global:SessionFile)) { return }
    try {
        $raw = Get-Content -LiteralPath $Global:SessionFile -Raw -Encoding UTF8
        if ([string]::IsNullOrWhiteSpace($raw)) { return }
        foreach ($s in @(ConvertFrom-Json $raw)) {
            if (-not $s.sid) { continue }
            $Global:Sessions[$s.sid] = @{
                Sid=$s.sid; PubId=$s.pubId; Nick=$s.nick; IP=$s.ip; UA=$s.ua
                Created=[DateTime]::Parse($s.created); LastSeen=[DateTime]::Parse($s.lastSeen)
            }
            if ($s.pubId) { $Global:PubIndex[$s.pubId] = $s.sid }
        }
    } catch {}
}

# ============================== WEBRTC SIGNALLING =============================
# A mailbox per device, drained by the normal /api/state poll. Offers, answers
# and ICE candidates pass through; file bytes never do.

function Add-Signal {
    param([string]$ToPub, [string]$FromPub, [string]$Kind, [string]$Data)
    [System.Threading.Monitor]::Enter($Global:SignalLock)
    try {
        if (-not $Global:Signals.ContainsKey($ToPub)) {
            $Global:Signals[$ToPub] = New-Object System.Collections.ArrayList
        }
        $box = $Global:Signals[$ToPub]
        $cut = (Get-Date).Subtract($Global:SignalTTL)
        for ($i = $box.Count - 1; $i -ge 0; $i--) {
            if ($box[$i].At -lt $cut) { $box.RemoveAt($i) }
        }
        # A peer that never polls must not grow the box without bound.
        while ($box.Count -ge 200) { $box.RemoveAt(0) }
        [void]$box.Add([pscustomobject]@{ From = $FromPub; Kind = $Kind; Data = $Data; At = (Get-Date) })
    } finally { [System.Threading.Monitor]::Exit($Global:SignalLock) }
}

function Get-SignalsFor {
    param([string]$Pub)
    $out = @()
    if ([string]::IsNullOrEmpty($Pub)) { return $out }
    [System.Threading.Monitor]::Enter($Global:SignalLock)
    try {
        if ($Global:Signals.ContainsKey($Pub)) {
            $box = $Global:Signals[$Pub]
            $cut = (Get-Date).Subtract($Global:SignalTTL)
            foreach ($s in $box) {
                if ($s.At -ge $cut) { $out += [pscustomobject]@{ from = $s.From; kind = $s.Kind; data = $s.Data } }
            }
            $box.Clear()
        }
    } finally { [System.Threading.Monitor]::Exit($Global:SignalLock) }
    return $out
}

# ============================== HTTP LAYER ====================================
function Read-HttpRequest {
    param([System.IO.Stream]$Stream)
    $headerBytes = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $Stream.ReadByte()
        if ($b -lt 0) { break }
        $headerBytes.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($headerBytes.Count -gt 65536) { break }
    }
    if ($headerBytes.Count -eq 0) { return $null }

    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $headerText = $latin1.GetString($headerBytes.ToArray())
    $lines = $headerText -split "`r`n"
    if ($lines.Count -lt 1 -or [string]::IsNullOrWhiteSpace($lines[0])) { return $null }

    $reqParts = $lines[0].Split(' ')
    if ($reqParts.Count -lt 2) { return $null }
    $method    = $reqParts[0].ToUpperInvariant()
    $rawTarget = $reqParts[1]

    $path = $rawTarget; $query = ''
    $qi = $rawTarget.IndexOf('?')
    if ($qi -ge 0) { $path = $rawTarget.Substring(0,$qi); $query = $rawTarget.Substring($qi+1) }

    $headers = @{}
    for ($i=1; $i -lt $lines.Count; $i++) {
        $line = $lines[$i]
        if ([string]::IsNullOrEmpty($line)) { break }
        $ci = $line.IndexOf(':')
        if ($ci -gt 0) {
            $hn = $line.Substring(0,$ci).Trim().ToLowerInvariant()
            $hv = $line.Substring($ci+1).Trim()
            $headers[$hn] = $hv
        }
    }

    $cookies = @{}
    if ($headers.ContainsKey('cookie')) {
        foreach ($pair in $headers['cookie'].Split(';')) {
            $kv = $pair.Trim(); $ei = $kv.IndexOf('=')
            if ($ei -gt 0) { $cookies[$kv.Substring(0,$ei).Trim()] = $kv.Substring($ei+1).Trim() }
        }
    }

    $contentLength = 0
    if ($headers.ContainsKey('content-length')) { [void][int64]::TryParse($headers['content-length'], [ref]$contentLength) }
    $contentType = ''
    if ($headers.ContainsKey('content-type')) { $contentType = $headers['content-type'] }
    $userAgent = ''
    if ($headers.ContainsKey('user-agent')) { $userAgent = $headers['user-agent'] }

    return [pscustomobject]@{
        Method=$method; Path=$path.ToLowerInvariant(); RawTarget=$rawTarget; Query=$query
        Headers=$headers; Cookies=$cookies; ContentLength=$contentLength; ContentType=$contentType
        UserAgent=$userAgent; Stream=$Stream; Body=$null; ClientIp='?'
    }
}

function Read-RequestBody {
    param([System.IO.Stream]$Stream, [int64]$Length, [int64]$Cap = 4194304)
    if ($Length -le 0) { return New-Object byte[] 0 }
    $effective = [int][Math]::Min($Length, $Cap)
    $buf = New-Object byte[] $effective
    $got = 0
    while ($got -lt $effective) {
        $r = $Stream.Read($buf, $got, [int][Math]::Min(81920, $effective - $got))
        if ($r -le 0) { break }
        $got += $r
    }
    if ($got -lt $effective) {
        $trim = New-Object byte[] $got
        [System.Array]::Copy($buf, 0, $trim, 0, $got)
        return $trim
    }
    return $buf
}

function Get-HttpStatusText {
    param([int]$Code)
    switch ($Code) {
        200 { 'OK' } 204 { 'No Content' } 302 { 'Found' } 400 { 'Bad Request' }
        401 { 'Unauthorized' } 403 { 'Forbidden' } 404 { 'Not Found' }
        405 { 'Method Not Allowed' } 500 { 'Internal Server Error' } default { 'OK' }
    }
}

function Send-Response {
    param(
        [System.IO.Stream]$Stream, [int]$Status = 200,
        [string]$ContentType = 'text/html; charset=utf-8',
        [byte[]]$Body = $null, [hashtable]$ExtraHeaders = $null
    )
    if ($null -eq $Body) { $Body = New-Object byte[] 0 }
    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 $Status " + (Get-HttpStatusText $Status) + "`r`n")
    [void]$sb.Append("Content-Type: $ContentType`r`n")
    [void]$sb.Append("Content-Length: $($Body.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Connection: close`r`n")
    if ($ExtraHeaders) {
        foreach ($k in $ExtraHeaders.Keys) { [void]$sb.Append("$k`: $($ExtraHeaders[$k])`r`n") }
    }
    [void]$sb.Append("`r`n")
    $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)
    if ($Body.Length -gt 0) { $Stream.Write($Body, 0, $Body.Length) }
    $Stream.Flush()
}

function Send-HtmlResponse {
    param([System.IO.Stream]$Stream, [string]$Html, [int]$Status = 200, [hashtable]$ExtraHeaders = $null)
    Send-Response -Stream $Stream -Status $Status -ContentType 'text/html; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Html)) -ExtraHeaders $ExtraHeaders
}

function Send-JsonResponse {
    param([System.IO.Stream]$Stream, [string]$Json, [int]$Status = 200, [hashtable]$ExtraHeaders = $null)
    Send-Response -Stream $Stream -Status $Status -ContentType 'application/json; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($Json)) -ExtraHeaders $ExtraHeaders
}

function Send-RedirectResponse {
    param([System.IO.Stream]$Stream, [string]$Location, [hashtable]$ExtraHeaders = $null)
    $h = @{ 'Location' = $Location }
    if ($ExtraHeaders) { foreach ($k in $ExtraHeaders.Keys) { $h[$k] = $ExtraHeaders[$k] } }
    Send-Response -Stream $Stream -Status 302 -ContentType 'text/html; charset=utf-8' -Body (New-Object byte[] 0) -ExtraHeaders $h
}

function New-SessionCookieHeader {
    param([string]$Sid, [bool]$Expire = $false)
    if ($Expire) {
        return "$Global:CookieName=deleted; Path=/; HttpOnly; SameSite=Strict; Expires=Thu, 01 Jan 1970 00:00:00 GMT"
    }
    $exp = (Get-Date).Add($Global:SessionTTL).ToUniversalTime().ToString('R')
    return "$Global:CookieName=$Sid; Path=/; HttpOnly; SameSite=Strict; Expires=$exp"
}

function Test-ValidSession {
    param($Req)
    $sid = $Req.Cookies[$Global:CookieName]
    if ($sid -and $Global:Sessions.ContainsKey($sid)) {
        $Global:Sessions[$sid].LastSeen = Get-Date
        return $sid
    }
    return $null
}

function Resolve-TargetSid {
    param([string]$TargetParam)
    if ([string]::IsNullOrWhiteSpace($TargetParam) -or $TargetParam -eq 'public') { return 'public' }
    if ($Global:PubIndex.ContainsKey($TargetParam)) { return $Global:PubIndex[$TargetParam] }
    return $null
}

function Get-MultipartField {
    # Small multipart field reader (nick/id). Large files go through Save-UploadedFileStream.
    param([byte[]]$BodyBytes, [string]$ContentType, [string]$FieldName)
    if (-not $BodyBytes -or $BodyBytes.Length -eq 0) { return $null }
    if ($ContentType -notmatch 'boundary=(.+)$') { return $null }
    $boundary = $Matches[1].Trim().Trim('"')
    $latin1 = [System.Text.Encoding]::GetEncoding(28591)
    $text = $latin1.GetString($BodyBytes)
    $parts = $text -split [regex]::Escape('--' + $boundary)
    foreach ($p in $parts) {
        if ($p -match ('name="' + [regex]::Escape($FieldName) + '"')) {
            $idx = $p.IndexOf("`r`n`r`n")
            if ($idx -ge 0) {
                $val = $p.Substring($idx + 4)
                if ($val.EndsWith("`r`n")) { $val = $val.Substring(0, $val.Length - 2) }
                $bytes = $latin1.GetBytes($val)
                return [System.Text.Encoding]::UTF8.GetString($bytes)
            }
        }
    }
    return $null
}

# ===================== MULTIPART STREAMING PARSER =============================
function Save-UploadedFileStream {
    # Streams the network directly to disk in 256KB chunks. C# FastScan for boundary.
    # Single shared buffer (chunkSize + delimLen) keeps allocations minimal.
    param(
        [System.IO.Stream]$NetStream, [string]$ContentType,
        [string]$SenderSid, [string]$Target, [string]$BundleId
    )

    if ($ContentType -notmatch 'boundary=(.+)$') { return @{ ok=$false; status=400; msg='Boundary not found' } }
    $boundary = $Matches[1].Trim().Trim('"')
    $latin1   = [System.Text.Encoding]::GetEncoding(28591)
    $sw       = [System.Diagnostics.Stopwatch]::StartNew()

    # Read multipart part headers
    $hdrBuf = New-Object System.Collections.Generic.List[byte]
    $b0=-1;$b1=-1;$b2=-1;$b3=-1
    while ($true) {
        $b = $NetStream.ReadByte()
        if ($b -lt 0) { return @{ ok=$false; status=400; msg='Connection closed (header)' } }
        $hdrBuf.Add([byte]$b)
        $b0=$b1; $b1=$b2; $b2=$b3; $b3=$b
        if ($b0 -eq 13 -and $b1 -eq 10 -and $b2 -eq 13 -and $b3 -eq 10) { break }
        if ($hdrBuf.Count -gt 8192) { return @{ ok=$false; status=400; msg='Multipart header too large' } }
    }
    $hdrText  = $latin1.GetString($hdrBuf.ToArray())
    $rawName  = $null
    if ($hdrText -match 'filename="([^"]*)"') { $rawName = $Matches[1] }
    if ([string]::IsNullOrWhiteSpace($rawName)) { return @{ ok=$false; status=400; msg='No filename' } }
    # Filename may be UTF-8; re-decode the latin1 bytes
    $fnBytes = $latin1.GetBytes($rawName)
    try { $rawName = [System.Text.Encoding]::UTF8.GetString($fnBytes) } catch {}
    # Preserve relative path for display / ZIP folder tree; use basename for disk.
    $relPath  = ConvertTo-SafeRelPath -Path $rawName
    if ([string]::IsNullOrWhiteSpace($relPath)) { return @{ ok=$false; status=400; msg='Invalid filename' } }
    $fileName = ($relPath.Split('/'))[-1]

    # Reserve unique file path
    # NOTE: local variable is $targetPath - PowerShell is case-insensitive so using
    # $target would collide with the $Target parameter (recipient sid).
    $targetPath = $null
    [System.Threading.Monitor]::Enter($Global:UploadLock)
    try {
        $targetPath = Join-Path $ShareFolder $fileName
        if (Test-Path -LiteralPath $targetPath) {
            $base = [System.IO.Path]::GetFileNameWithoutExtension($fileName)
            $ext  = [System.IO.Path]::GetExtension($fileName)
            $n = 1
            do { $candidate = Join-Path $ShareFolder ("{0}_{1}{2}" -f $base,$n,$ext); $n++ } while (Test-Path -LiteralPath $candidate)
            $targetPath = $candidate
        }
        (New-Object System.IO.FileStream($targetPath,[System.IO.FileMode]::CreateNew,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None)).Close()
    } catch {
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        [System.Threading.Monitor]::Exit($Global:UploadLock)
    }

    # Stream network to disk; stop marker is \r\n--boundary
    $delimBytes = $latin1.GetBytes("`r`n--" + $boundary)
    $delimLen   = $delimBytes.Length
    $chunkSize  = 262144                 # 256 KB
    $bufSize    = $chunkSize + $delimLen
    $buf        = New-Object byte[] $bufSize
    $bufLen     = 0
    $bytesWrote = 0L

    $fs = $null
    try {
        $fs = New-Object System.IO.FileStream($targetPath,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Write,[System.IO.FileShare]::None,1048576,[System.IO.FileOptions]::SequentialScan)
        $found = $false

        while (-not $found) {
            $space = $bufSize - $bufLen
            $toRead = [Math]::Min($chunkSize, $space)
            if ($toRead -le 0) { $toRead = $chunkSize }
            $read = $NetStream.Read($buf, $bufLen, $toRead)
            if ($read -le 0) { break }
            $bufLen += $read

            $pos = [LFP.FastScan]::IndexOf($buf, 0, $bufLen, $delimBytes)
            if ($pos -ge 0) {
                if ($pos -gt 0) { $fs.Write($buf, 0, $pos); $bytesWrote += $pos }
                $found = $true
            } else {
                $safe = $bufLen - ($delimLen - 1)
                if ($safe -gt 0) {
                    $fs.Write($buf, 0, $safe); $bytesWrote += $safe
                    $keep = $bufLen - $safe
                    if ($keep -gt 0) { [System.Buffer]::BlockCopy($buf, $safe, $buf, 0, $keep) }
                    $bufLen = $keep
                }
            }
        }

        # Connection dropped before the closing boundary: reject the partial file
        # instead of registering a silently-truncated transfer.
        if (-not $found) { throw 'Upload interrupted - incomplete file discarded' }

        $fs.Flush()
    } catch {
        try { if ($fs) { $fs.Close() } } catch {}
        try { Remove-Item -LiteralPath $targetPath -Force -ErrorAction SilentlyContinue } catch {}
        return @{ ok=$false; status=500; msg=$_.Exception.Message }
    } finally {
        try { if ($fs) { $fs.Close() } } catch {}
    }

    $diskBase   = [System.IO.Path]::GetFileName($targetPath)
    # Display name = original relative path but with the (possibly deduped) basename.
    $displayName = if ($relPath -match '/') {
        ($relPath -replace '[^/]+$', '') + $diskBase
    } else { $diskBase }
    $size       = (Get-Item -LiteralPath $targetPath).Length
    $tid        = New-ShortId 8
    $senderNick = if ($Global:Sessions.ContainsKey($SenderSid)) { $Global:Sessions[$SenderSid].Nick } else { 'Unknown' }
    $t = @{
        Id=$tid; Name=$displayName; Path=$targetPath; Size=$size
        Sender=$SenderSid; SenderNick=$senderNick; Target=$Target
        BundleId=$BundleId
        Created=(Get-Date)
    }
    $Global:Transfers[$tid] = $t
    try { Save-TransferMeta -T $t } catch {}

    $sw.Stop()
    try {
        $mbps = if ($sw.Elapsed.TotalSeconds -gt 0.05) { ($size / 1MB) / $sw.Elapsed.TotalSeconds } else { 0 }
        Write-Host ("[{0}] UPLOAD {1,-42} {2,10}  {3,7:N1} MB/s" -f (Get-Date).ToString('HH:mm:ss'), $displayName, (Format-Size $size), $mbps) -ForegroundColor Cyan
    } catch {}

    return @{ ok=$true; status=200; id=$tid; msg=$displayName }
}

# ============================== DOWNLOAD ======================================
function Send-FileDownload {
    param($Req, [System.IO.Stream]$Stream, [string]$Sid)
    $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
    $id = $q['id']
    if ([string]::IsNullOrWhiteSpace($id) -or -not $Global:Transfers.ContainsKey($id)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>404 - file not found</h1>' -Status 404; return
    }
    $t = $Global:Transfers[$id]
    if ($t.Target -ne 'public' -and $t.Target -ne $Sid -and $t.Sender -ne $Sid) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>403 - access denied</h1>' -Status 403; return
    }
    if (-not (Test-Path -LiteralPath $t.Path -PathType Leaf)) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>404 - file missing on disk</h1>' -Status 404; return
    }

    $name    = [System.IO.Path]::GetFileName($t.Path)
    $nameEnc = [System.Web.HttpUtility]::UrlEncode($name) -replace '\+', '%20'
    $fi      = Get-Item -LiteralPath $t.Path

    $sb = New-Object System.Text.StringBuilder
    [void]$sb.Append("HTTP/1.1 200 OK`r`n")
    [void]$sb.Append("Content-Type: application/octet-stream`r`n")
    [void]$sb.Append("Content-Disposition: attachment; filename*=UTF-8''$nameEnc`r`n")
    [void]$sb.Append("Content-Length: $($fi.Length)`r`n")
    [void]$sb.Append("Cache-Control: no-store`r`n")
    [void]$sb.Append("Connection: close`r`n`r`n")
    $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
    $Stream.Write($headBytes, 0, $headBytes.Length)

    $fs = New-Object System.IO.FileStream($t.Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
    try {
        $buf = New-Object byte[] 262144
        while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
            $Stream.Write($buf, 0, $read)
        }
        $Stream.Flush()
    } finally { $fs.Dispose() }
}

# ============================== BULK ZIP DOWNLOAD =============================
function Send-ZipDownload {
    param([string[]]$Ids, [string]$Sid, [System.IO.Stream]$Stream)

    # Filter to accessible + existing files
    $selected = @()
    foreach ($id in $Ids) {
        if (-not $Global:Transfers.ContainsKey($id)) { continue }
        $t = $Global:Transfers[$id]
        if ($t.Target -ne 'public' -and $t.Target -ne $Sid -and $t.Sender -ne $Sid) { continue }
        if (-not (Test-Path -LiteralPath $t.Path -PathType Leaf)) { continue }
        $selected += $t
    }
    if ($selected.Count -eq 0) {
        Send-HtmlResponse -Stream $Stream -Html '<h1>403 - no accessible files</h1>' -Status 403
        return
    }

    # Build ZIP into a temp file (seekable). Central directory finalized on dispose.
    $tmp = [System.IO.Path]::Combine([System.IO.Path]::GetTempPath(), ('lfp-' + (New-ShortId 6) + '.zip'))
    try {
        $zipFs = [System.IO.File]::Open($tmp, [System.IO.FileMode]::CreateNew, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        try {
            $zip = New-Object System.IO.Compression.ZipArchive($zipFs, [System.IO.Compression.ZipArchiveMode]::Create, $false)
            try {
                $usedNames = @{}
                foreach ($t in $selected) {
                    $name = $t.Name
                    $key = $name.ToLowerInvariant()
                    if ($usedNames.ContainsKey($key)) {
                        $base = [System.IO.Path]::GetFileNameWithoutExtension($name)
                        $ext  = [System.IO.Path]::GetExtension($name)
                        $n = 1
                        do {
                            $name = "{0}_{1}{2}" -f $base, $n, $ext
                            $key  = $name.ToLowerInvariant()
                            $n++
                        } while ($usedNames.ContainsKey($key))
                    }
                    $usedNames[$key] = $true
                    $entry = $zip.CreateEntry($name, [System.IO.Compression.CompressionLevel]::Fastest)
                    $entryStream = $entry.Open()
                    try {
                        $src = New-Object System.IO.FileStream($t.Path,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
                        try { $src.CopyTo($entryStream, 262144) } finally { $src.Close() }
                    } finally { $entryStream.Close() }
                }
            } finally { $zip.Dispose() }
        } finally { $zipFs.Close() }

        $zipSize = (Get-Item -LiteralPath $tmp).Length
        $zipName = 'transfers-' + (Get-Date).ToString('yyyyMMdd-HHmmss') + '.zip'
        $nameEnc = [System.Web.HttpUtility]::UrlEncode($zipName) -replace '\+', '%20'

        $sb = New-Object System.Text.StringBuilder
        [void]$sb.Append("HTTP/1.1 200 OK`r`n")
        [void]$sb.Append("Content-Type: application/zip`r`n")
        [void]$sb.Append("Content-Disposition: attachment; filename*=UTF-8''$nameEnc`r`n")
        [void]$sb.Append("Content-Length: $zipSize`r`n")
        [void]$sb.Append("Cache-Control: no-store`r`n")
        [void]$sb.Append("Connection: close`r`n`r`n")
        $headBytes = [System.Text.Encoding]::GetEncoding(28591).GetBytes($sb.ToString())
        $Stream.Write($headBytes, 0, $headBytes.Length)

        $fs = New-Object System.IO.FileStream($tmp,[System.IO.FileMode]::Open,[System.IO.FileAccess]::Read,[System.IO.FileShare]::Read,1048576,[System.IO.FileOptions]::SequentialScan)
        try {
            $buf = New-Object byte[] 262144
            while (($read = $fs.Read($buf, 0, $buf.Length)) -gt 0) {
                $Stream.Write($buf, 0, $read)
            }
            $Stream.Flush()
        } finally { $fs.Dispose() }
    } finally {
        try { Remove-Item -LiteralPath $tmp -Force -ErrorAction SilentlyContinue } catch {}
    }
}

# ============================== STATE JSON ====================================
function Get-StateJson {
    param([string]$Sid)
    Invoke-PeriodicSweep
    $me  = $Global:Sessions[$Sid]
    $now = Get-Date

    $devList = @()
    foreach ($k in @($Global:Sessions.Keys)) {
        $s = $Global:Sessions[$k]
        if ($null -eq $s) { continue }
        $age    = $now - $s.LastSeen
        # Devices idle >24h stay signed in but drop off the picker to avoid clutter
        if ($age -gt [TimeSpan]::FromHours(24) -and $k -ne $Sid) { continue }
        $ageSec = [int]([math]::Floor($age.TotalSeconds))
        $online = $age -lt $Global:DeviceTTL
        $devList += [pscustomobject]@{
            pubId  = $s.PubId
            nick   = $s.Nick
            ageSec = $ageSec
            online = $online
        }
    }
    $devList = @($devList | Sort-Object -Property @{Expression={[int]$_.online};Descending=$true}, ageSec)

    # Split visible transfers into standalone singles + bundle groups (by BundleId)
    $singles = @()
    $bundles = @{}
    foreach ($k in @($Global:Transfers.Keys)) {
        $t = $Global:Transfers[$k]
        if ($null -eq $t) { continue }
        if (-not ($t.Target -eq 'public' -or $t.Target -eq $Sid -or $t.Sender -eq $Sid)) { continue }
        if ($t.BundleId) {
            if (-not $bundles.ContainsKey($t.BundleId)) { $bundles[$t.BundleId] = New-Object System.Collections.Generic.List[object] }
            [void]$bundles[$t.BundleId].Add($t)
        } else {
            $singles += $t
        }
    }

    $entries = @()

    foreach ($t in $singles) {
        $targetNick = 'Everyone'; $targetKind = 'public'
        if ($t.Target -ne 'public') {
            $targetKind = 'device'
            if ($Global:Sessions.ContainsKey($t.Target)) { $targetNick = $Global:Sessions[$t.Target].Nick }
            else { $targetNick = '(deleted)' }
        }
        $entries += [pscustomobject]@{
            kind       = 'single'
            id         = $t.Id
            name       = $t.Name
            size       = $t.Size
            senderNick = $t.SenderNick
            targetNick = $targetNick
            target     = $targetKind
            byMe       = ($t.Sender -eq $Sid)
            toMe       = ($t.Target -eq $Sid)
            created    = $t.Created.ToString('o')
            icon       = (Get-IconForFile $t.Name)
        }
    }

    foreach ($bid in @($bundles.Keys)) {
        $items = @($bundles[$bid] | Sort-Object { $_.Created })
        if ($items.Count -eq 0) { continue }
        $first = $items[0]
        $totalSize = 0L; foreach ($ii in $items) { $totalSize += [int64]$ii.Size }
        $minCreated = $first.Created
        foreach ($ii in $items) { if ($ii.Created -lt $minCreated) { $minCreated = $ii.Created } }
        $targetNick = 'Everyone'; $targetKind = 'public'
        if ($first.Target -ne 'public') {
            $targetKind = 'device'
            if ($Global:Sessions.ContainsKey($first.Target)) { $targetNick = $Global:Sessions[$first.Target].Nick }
            else { $targetNick = '(deleted)' }
        }
        $childArr = @()
        foreach ($ii in $items) {
            $childArr += [pscustomobject]@{
                id   = $ii.Id
                name = $ii.Name
                size = $ii.Size
                icon = (Get-IconForFile $ii.Name)
            }
        }
        $entries += [pscustomobject]@{
            kind       = 'bundle'
            bundleId   = $bid
            name       = ("Bundle - {0} files" -f $items.Count)
            size       = $totalSize
            senderNick = $first.SenderNick
            targetNick = $targetNick
            target     = $targetKind
            byMe       = ($first.Sender -eq $Sid)
            toMe       = ($first.Target -eq $Sid)
            created    = $minCreated.ToString('o')
            count      = $items.Count
            items      = $childArr
        }
    }

    $entries = @($entries | Sort-Object { $_.created } -Descending)

    $payload = [pscustomobject]@{
        me = [pscustomobject]@{ pubId = $me.PubId; nick = $me.Nick }
        devices   = $devList
        transfers = $entries
        p2p       = [bool]$Global:P2P
        signals   = @(Get-SignalsFor -Pub $me.PubId)
    }
    return ($payload | ConvertTo-Json -Depth 8 -Compress)
}

# ============================== UI PAGES ======================================
function Get-LoginPage {
    param([bool]$Error = $false)
    $errBlock = if ($Error) { '<div class="error-msg">Wrong password. Please try again.</div>' } else { '' }
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local File Portal - Sign In</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ctext y='.9em' font-size='90'%3E%F0%9F%93%81%3C/text%3E%3C/svg%3E">
<style>
  :root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e;--err:#f74f6a}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh;display:flex;align-items:center;justify-content:center;overflow:hidden}
  .grid-bg{position:fixed;inset:0;z-index:0;background-image:linear-gradient(rgba(79,142,247,.07) 1px,transparent 1px),linear-gradient(90deg,rgba(79,142,247,.07) 1px,transparent 1px);background-size:42px 42px;animation:drift 22s linear infinite}
  @keyframes drift{from{background-position:0 0}to{background-position:42px 42px}}
  .card{position:relative;z-index:1;background:var(--card);border:1px solid var(--border);border-radius:18px;padding:42px 38px;width:380px;max-width:92vw;box-shadow:0 24px 60px rgba(0,0,0,.55)}
  .logo{display:flex;align-items:center;gap:12px;margin-bottom:6px}.logo .icon{font-size:34px}.logo h1{font-size:20px;font-weight:700;letter-spacing:.5px}
  .sub{color:var(--muted);font-size:13px;margin-bottom:26px}
  label{display:block;font-size:12px;color:var(--muted);margin-bottom:8px;text-transform:uppercase;letter-spacing:1px}
  .pw-wrap{position:relative;margin-bottom:18px}
  input{width:100%;padding:13px 46px 13px 14px;background:var(--bg);border:1px solid var(--border);border-radius:10px;color:var(--text);font-size:15px;outline:none;transition:border .2s}
  input:focus{border-color:var(--accent)}
  .toggle{position:absolute;right:8px;top:50%;transform:translateY(-50%);background:none;border:none;color:var(--muted);cursor:pointer;font-size:18px;padding:6px}
  button.submit{width:100%;padding:13px;background:var(--accent);color:#fff;border:none;border-radius:10px;font-size:15px;font-weight:600;cursor:pointer}
  button.submit:hover{filter:brightness(1.1)}
  .error-msg{background:rgba(247,79,106,.12);border:1px solid var(--err);color:var(--err);padding:10px 12px;border-radius:8px;font-size:13px;margin-bottom:18px}
  .status{display:flex;align-items:center;gap:8px;margin-top:22px;font-size:12px;color:var(--muted);justify-content:center}
  .dot{width:9px;height:9px;border-radius:50%;background:var(--ok);box-shadow:0 0 8px var(--ok);animation:blink 1.4s ease-in-out infinite}
  @keyframes blink{0%,100%{opacity:1}50%{opacity:.25}}
</style></head><body>
  <div class="grid-bg"></div>
  <div class="card">
    <div class="logo"><span class="icon">&#128274;</span><h1>LOCAL FILE PORTAL</h1></div>
    <div class="sub">Pick a device name (optional) and sign in.</div>
    $errBlock
    <form method="POST" action="/">
      <label for="nick">Device Name</label>
      <input id="nick" name="nick" type="text" placeholder="e.g. Hakan's Phone" maxlength="32" style="margin-bottom:16px">
      <label for="pw">Password</label>
      <div class="pw-wrap">
        <input id="pw" name="password" type="password" placeholder="&#8226;&#8226;&#8226;&#8226;&#8226;&#8226;" autofocus required>
        <button type="button" class="toggle" id="tgl" title="Show/Hide">&#128065;</button>
      </div>
      <button type="submit" class="submit">Sign In</button>
    </form>
    <div class="status"><span class="dot"></span> Server online</div>
  </div>
<script>
  var pw=document.getElementById('pw'),tgl=document.getElementById('tgl');
  tgl.addEventListener('click',function(){if(pw.type==='password'){pw.type='text';tgl.style.color='#4f8ef7';}else{pw.type='password';tgl.style.color='';}});
</script>
</body></html>
"@
}

function Get-DashboardPage {
    return @"
<!DOCTYPE html><html lang="en"><head>
<meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local File Portal</title>
<link rel="icon" href="data:image/svg+xml,%3Csvg xmlns='http://www.w3.org/2000/svg' viewBox='0 0 100 100'%3E%3Ctext y='.9em' font-size='90'%3E%F0%9F%93%81%3C/text%3E%3C/svg%3E">
<style>
  :root{--bg:#0d0f12;--card:#141720;--border:#1e2330;--accent:#4f8ef7;--accent2:#8e6cf7;--text:#e8ecf5;--muted:#5a6480;--ok:#4ff78e;--err:#f74f6a;--warn:#f7c14f}
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:'Segoe UI',system-ui,sans-serif;background:var(--bg);color:var(--text);min-height:100vh}
  header{position:sticky;top:0;z-index:10;background:rgba(20,23,32,.92);backdrop-filter:blur(8px);border-bottom:1px solid var(--border);padding:14px 24px;display:flex;align-items:center;justify-content:space-between;gap:16px;flex-wrap:wrap}
  .brand{display:flex;align-items:center;gap:11px}.brand .icon{font-size:24px}.brand h1{font-size:16px;letter-spacing:.5px}
  .hdr-right{display:flex;align-items:center;gap:14px;font-size:13px;flex-wrap:wrap}
  .me-chip{display:flex;align-items:center;gap:8px;background:var(--bg);border:1px solid var(--border);padding:6px 12px;border-radius:20px}
  .me-chip .dot{width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}
  .me-chip b{font-weight:600}
  .me-chip .rename{background:none;border:none;color:var(--muted);cursor:pointer;font-size:14px;padding:0 2px}
  .me-chip .rename:hover{color:var(--accent)}
  .logout{color:var(--err);text-decoration:none;font-size:13px;border:1px solid var(--border);padding:6px 12px;border-radius:8px}
  .logout:hover{background:rgba(247,79,106,.1)}
  main{max-width:1100px;margin:0 auto;padding:24px}
  .panel{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:20px;margin-bottom:22px;overflow-x:auto}
  .panel h2{font-size:13px;text-transform:uppercase;letter-spacing:1.5px;color:var(--muted);margin-bottom:14px;display:flex;align-items:center;gap:10px;flex-wrap:wrap}
  .target-chip{background:rgba(79,142,247,.15);color:var(--accent);padding:4px 10px;border-radius:14px;font-size:12px;text-transform:none;letter-spacing:0;font-weight:600}
  .dev-grid{display:grid;grid-template-columns:repeat(auto-fill,minmax(170px,1fr));gap:10px}
  .dev{background:var(--bg);border:1px solid var(--border);border-radius:11px;padding:14px;cursor:pointer;transition:all .15s;display:flex;flex-direction:column;gap:4px;position:relative;min-height:96px}
  .dev:hover{border-color:var(--accent);transform:translateY(-1px)}
  .dev.selected{border-color:var(--accent);background:rgba(79,142,247,.08);box-shadow:0 0 0 2px rgba(79,142,247,.25)}
  .dev.public{background:linear-gradient(135deg,rgba(79,142,247,.08),rgba(142,108,247,.08));border-color:rgba(79,142,247,.3)}
  .dev.offline{opacity:.45}
  .dev.self{border-style:dashed;cursor:not-allowed;opacity:.55}
  .dev-icon{font-size:22px}
  .dev-name{font-size:14px;font-weight:600;word-break:break-all}
  .dev-sub{font-size:11px;color:var(--muted)}
  .dev-status{position:absolute;top:10px;right:10px;width:8px;height:8px;border-radius:50%;background:var(--ok);box-shadow:0 0 6px var(--ok)}
  .dev.offline .dev-status{background:var(--muted);box-shadow:none}
  .drop{border:2px dashed var(--border);border-radius:12px;padding:34px;text-align:center;color:var(--muted);cursor:pointer;transition:all .2s}
  .drop.over{border-color:var(--accent);background:rgba(79,142,247,.06);color:var(--text)}
  .drop .big{font-size:36px;margin-bottom:8px}
  .filelist{display:flex;flex-direction:column;gap:8px;margin:14px 0 0}
  .fileitem{display:flex;align-items:center;gap:12px;padding:9px 13px;background:var(--bg);border:1px solid var(--border);border-radius:10px;font-size:13px}
  .fileitem .fi-ic{font-size:18px}.fileitem .fi-name{flex:1;word-break:break-all}.fileitem .fi-size{color:var(--muted);font-size:12px;white-space:nowrap}
  .fileitem .fi-stat{font-size:12px;white-space:nowrap}
  .fileitem .fi-stat.ok{color:var(--ok)}.fileitem .fi-stat.err{color:var(--err)}.fileitem .fi-stat.up{color:var(--accent)}
  .fileitem .fi-x{cursor:pointer;color:var(--err);font-weight:700;padding:0 4px}
  .bar-wrap{display:none;margin-top:14px;background:var(--bg);border-radius:30px;overflow:hidden;height:8px;border:1px solid var(--border)}
  .bar-wrap.show{display:block}.bar{height:100%;width:0;background:linear-gradient(90deg,var(--accent),var(--accent2));transition:width .12s}
  .up-row{display:flex;align-items:center;gap:12px;margin-top:14px;flex-wrap:wrap}
  .btn{padding:10px 20px;background:var(--accent);color:#fff;border:none;border-radius:9px;font-size:14px;font-weight:600;cursor:pointer}
  .btn:disabled{opacity:.5;cursor:not-allowed}
  .btn.ghost{background:transparent;border:1px solid var(--border);color:var(--muted)}.btn.ghost:hover{color:var(--text)}
  .count-lbl{color:var(--muted);font-size:13px;margin-left:auto}
  .tabs{display:flex;gap:6px;margin-bottom:12px;flex-wrap:wrap}
  .tab{padding:6px 14px;background:transparent;border:1px solid var(--border);color:var(--muted);border-radius:8px;font-size:13px;cursor:pointer}
  .tab.on{background:rgba(79,142,247,.15);color:var(--accent);border-color:var(--accent)}
  input[type="checkbox"]{accent-color:var(--accent);cursor:pointer;width:15px;height:15px;margin:0;vertical-align:middle}
  .bundle-row td{background:rgba(142,108,247,.05)}
  .bundle-row:hover td{background:rgba(142,108,247,.09)}
  .bundle-child td{background:rgba(79,142,247,.03);border-bottom:1px dashed var(--border);font-size:12.5px}
  .bundle-child td.child-nm{color:var(--muted);padding-left:22px}
  .expand-btn{background:none;border:1px solid var(--border);color:var(--muted);cursor:pointer;padding:1px 7px;border-radius:5px;font-size:11px;margin-right:6px;font-family:inherit}
  .expand-btn:hover{color:var(--accent);border-color:var(--accent)}
  .folder-crumb{color:var(--muted);font-size:11px}
  .bundle-dl{background:rgba(142,108,247,.12);padding:3px 9px;border-radius:6px;color:var(--accent2)!important}
  .hbtn{background:transparent;border:1px solid var(--border);color:var(--muted);padding:6px 12px;border-radius:8px;font-size:13px;cursor:pointer}
  .hbtn:hover{color:var(--text)}
  .hbtn.on{color:var(--accent);border-color:var(--accent);background:rgba(79,142,247,.08)}
  .linkish{color:var(--accent);cursor:pointer;text-decoration:underline}
  .up-stats{margin-top:8px;font-size:12px;color:var(--muted);text-align:right;min-height:15px;font-variant-numeric:tabular-nums}
  .txt-row{display:flex;gap:10px;margin-top:14px}
  .txt-row input{flex:1;padding:10px 12px;background:var(--bg);border:1px solid var(--border);border-radius:9px;color:var(--text);font-size:13px;outline:none}
  .txt-row input:focus{border-color:var(--accent)}
  .connect-flex{display:flex;gap:26px;align-items:center;flex-wrap:wrap}
  .url-box{font-size:16px;font-weight:600;background:var(--bg);padding:11px 15px;border-radius:9px;border:1px solid var(--border);margin-bottom:12px;word-break:break-all;letter-spacing:.3px}
  #qrbox{background:#fff;padding:10px;border-radius:10px;line-height:0}
  .hint{color:var(--muted);font-size:12px;margin-top:10px}
  .modal-bg{display:none;position:fixed;inset:0;background:rgba(0,0,0,.6);z-index:60;align-items:center;justify-content:center}
  .modal-bg.show{display:flex}
  .modal{background:var(--card);border:1px solid var(--border);border-radius:14px;padding:18px;width:520px;max-width:92vw;box-shadow:0 24px 60px rgba(0,0,0,.55)}
  .modal-head{display:flex;justify-content:space-between;align-items:center;margin-bottom:12px;gap:12px}
  .modal-head b{word-break:break-all;font-size:14px}
  .modal textarea{width:100%;height:200px;background:var(--bg);border:1px solid var(--border);border-radius:9px;color:var(--text);font-size:13px;padding:10px;resize:vertical;outline:none;font-family:Consolas,monospace}
  .modal-actions{margin-top:12px;text-align:right}
  table{width:100%;border-collapse:collapse}
  th{text-align:left;font-size:11px;text-transform:uppercase;letter-spacing:1px;color:var(--muted);padding:8px 10px;border-bottom:1px solid var(--border)}
  td{padding:11px 10px;border-bottom:1px solid var(--border);font-size:13.5px;vertical-align:middle}
  td.ic{font-size:18px;width:36px}.td-nm{word-break:break-all}
  td.dt{color:var(--muted);font-size:12px;white-space:nowrap}
  tr:last-child td{border-bottom:none}tr:hover td{background:rgba(79,142,247,.04)}
  .pill{display:inline-block;padding:2px 8px;border-radius:11px;font-size:11px;background:rgba(79,142,247,.12);color:var(--accent);margin-right:4px;white-space:nowrap}
  .pill.pub{background:rgba(142,108,247,.15);color:var(--accent2)}
  .pill.me{background:rgba(79,247,142,.12);color:var(--ok)}
  .dl{color:var(--accent);text-decoration:none;font-size:13px;white-space:nowrap}.dl:hover{text-decoration:underline}
  .dl-x{background:none;border:1px solid var(--err);color:var(--err);padding:2px 8px;border-radius:6px;font-size:12px;cursor:pointer;margin-left:6px}
  .dl-x:hover{background:rgba(247,79,106,.12)}
  .empty{text-align:center;color:var(--muted);padding:28px;font-size:14px}
  .toast-box{position:fixed;right:22px;bottom:22px;z-index:50;display:flex;flex-direction:column;gap:10px}
  .toast{padding:12px 18px;border-radius:10px;font-size:13px;box-shadow:0 10px 30px rgba(0,0,0,.5);animation:slidein .25s ease;min-width:220px;max-width:380px}
  .toast.ok{background:#16321f;border:1px solid var(--ok);color:var(--ok)}
  .toast.err{background:#321016;border:1px solid var(--err);color:var(--err)}
  .toast.info{background:#15243a;border:1px solid var(--accent);color:var(--accent)}
  @keyframes slidein{from{transform:translateX(120%);opacity:0}to{transform:translateX(0);opacity:1}}
  @media(max-width:600px){header{padding:12px 14px}main{padding:14px}.panel{padding:16px}}
</style></head><body>
  <header>
    <div class="brand"><span class="icon">&#128193;</span><h1>LOCAL FILE PORTAL</h1></div>
    <div class="hdr-right">
      <div class="me-chip">
        <span class="dot"></span><span>Me:</span>
        <b id="myNick">...</b>
        <button class="rename" id="renameBtn" title="Change device name">&#9998;</button>
      </div>
      <span id="onlineCount" style="color:var(--muted)">...</span>
      <button class="hbtn" id="inviteBtn" title="Show connection link and QR code">&#128279; Invite</button>
      <button class="hbtn" id="notifBtn" title="Toggle sound + browser notifications">&#128276;</button>
      <a class="logout" href="/logout">&#128682; Sign Out</a>
    </div>
  </header>

  <main>
    <section class="panel" id="connectPanel" style="display:none">
      <h2>Invite a Device</h2>
      <div class="connect-flex">
        <div>
          <div class="url-box" id="urlBox"></div>
          <button class="btn" id="copyUrl">&#128203; Copy Link</button>
          <div class="hint">Other device must be on the same Wi-Fi.<br>Scan the QR or open the link, then enter the password.</div>
        </div>
        <div id="qrbox"></div>
      </div>
    </section>

    <section class="panel">
      <h2>Connected Devices <span id="targetLabel" class="target-chip">Target: Everyone</span></h2>
      <div id="devices" class="dev-grid"></div>
    </section>

    <section class="panel">
      <h2>Send Files</h2>
      <div class="drop" id="drop">
        <div class="big">&#128228;</div>
        <div>Drag &amp; drop files <b>or folders</b> here <br>click to select files &middot; <span class="linkish" id="pickDir">select a folder</span></div>
        <input type="file" id="file" multiple hidden>
        <input type="file" id="dirInp" webkitdirectory multiple hidden>
      </div>
      <div class="filelist" id="fileList"></div>
      <div class="up-row">
        <button class="btn" id="upBtn" disabled>Send</button>
        <button class="btn ghost" id="clearBtn" style="display:none">Clear</button>
        <span class="count-lbl" id="countLbl"></span>
      </div>
      <div class="bar-wrap" id="barWrap"><div class="bar" id="bar"></div></div>
      <div class="up-stats" id="upStats"></div>
      <div class="txt-row">
        <input type="text" id="txtMsg" placeholder="Quick note or link... (sent as .txt to current target)" maxlength="4000">
        <button class="btn ghost" id="txtBtn">Send Text</button>
      </div>
    </section>

    <section class="panel" id="p2pPanel" style="display:none">
      <h2>Direct Inbox <span class="target-chip" title="Received peer-to-peer, never stored on the server">&#9889; P2P</span></h2>
      <table>
        <thead><tr><th></th><th>File</th><th>Size</th><th>From</th><th></th></tr></thead>
        <tbody id="p2pBody"></tbody>
      </table>
      <div class="hint" style="margin-top:10px">These arrived straight from the other device and live in this tab only. Save them before closing the page.</div>
    </section>

    <section class="panel">
      <h2>Transfers</h2>
      <div class="tabs">
        <button class="tab on" data-f="all">All</button>
        <button class="tab" data-f="inbox">Inbox</button>
        <button class="tab" data-f="public">Public</button>
        <button class="tab" data-f="sent">Sent</button>
        <button class="btn zip-btn" id="zipBtn" disabled style="margin-left:auto;padding:6px 14px;font-size:13px">&#128230; Download Selected (0)</button>
      </div>
      <table>
        <thead><tr><th style="width:28px"><input type="checkbox" id="selAll" title="Select all"></th><th></th><th>File</th><th>Size</th><th>From / To</th><th>Date</th><th></th></tr></thead>
        <tbody id="transferBody"></tbody>
      </table>
    </section>
  </main>

  <div class="modal-bg" id="modalBg">
    <div class="modal">
      <div class="modal-head"><b id="modalTitle">Note</b><button class="hbtn" id="modalClose">&#10005;</button></div>
      <textarea id="modalText" readonly></textarea>
      <div class="modal-actions"><button class="btn" id="modalCopy">&#128203; Copy</button></div>
    </div>
  </div>
  <div class="toast-box" id="toasts"></div>

<script src="/qr.js"></script>
<script>
  var state={me:{},devices:[],transfers:[]};
  var target='public';
  var queued=[];
  var uploading=false;
  var seq=0;
  var filter='all';
  var toasts=document.getElementById('toasts');
  var lastEntryKeys=null;      // null = initial load; skip toasts until first fetch completes
  var selectedIds=new Set();   // individual transfer ids (children of bundles included)
  var expandedBundles=new Set();

  function randomHex(n){var s='',cs='0123456789abcdef';for(var i=0;i<n*2;i++)s+=cs[Math.floor(Math.random()*16)];return s;}
  function entryKey(t){return t.kind==='bundle' ? ('b:'+t.bundleId) : ('s:'+t.id);}

  function esc(s){return String(s).replace(/[&<>"]/g,function(c){return {'&':'&amp;','<':'&lt;','>':'&gt;','"':'&quot;'}[c];});}
  function toast(msg,type){var t=document.createElement('div');t.className='toast '+(type||'ok');t.textContent=msg;toasts.appendChild(t);setTimeout(function(){t.style.transition='opacity .3s';t.style.opacity='0';setTimeout(function(){t.remove();},300);},3500);}
  function fmtSize(b){if(b>=1073741824)return(b/1073741824).toFixed(2)+' GB';if(b>=1048576)return(b/1048576).toFixed(2)+' MB';if(b>=1024)return(b/1024).toFixed(2)+' KB';return b+' B';}
  function fmtSeen(sec){if(sec<60)return 'just now';if(sec<3600)return Math.floor(sec/60)+'m ago';if(sec<86400)return Math.floor(sec/3600)+'h ago';return Math.floor(sec/86400)+'d ago';}
  function fmtDate(iso){var d=new Date(iso);if(isNaN(d.getTime()))return iso;var y=d.getFullYear(),m=('0'+(d.getMonth()+1)).slice(-2),da=('0'+d.getDate()).slice(-2);var h=('0'+d.getHours()).slice(-2),mi=('0'+d.getMinutes()).slice(-2);return da+'.'+m+'.'+y+' '+h+':'+mi;}
  function devIcon(n){var s=(n||'').toLowerCase();if(s.indexOf('iphone')>=0||s.indexOf('ipad')>=0||s.indexOf('android')>=0)return '&#128241;';if(s.indexOf('mac')>=0||s.indexOf('windows')>=0)return '&#128187;';if(s.indexOf('linux')>=0)return '&#128421;';return '&#128242;';}

  async function fetchState(){
    try{
      var r=await fetch('/api/state',{cache:'no-store'});
      if(r.status===401){location.href='/';return;}
      if(!r.ok)return;
      var st=await r.json();
      // Signals must drain even mid-upload: a P2P sender is "uploading" while it
      // waits for the peer's answer, and bailing out here would deadlock it.
      if(st.signals&&st.signals.length)handleSignals([].concat(st.signals));
      if(uploading)return;
      var prev=lastEntryKeys;
      state=st;
      lastEntryKeys=new Set(state.transfers.map(entryKey));
      // Only toast when we have a prior snapshot to diff against. Skips initial load.
      if(prev!==null){
        state.transfers.forEach(function(t){
          if(prev.has(entryKey(t)))return;
          if(t.byMe)return;
          if(!(t.toMe || t.target==='public'))return;
          if(t.kind==='bundle'){
            toast(t.senderNick+' sent you a bundle ('+t.count+' files)','info');
            notifyInbound('New bundle from '+t.senderNick, t.count+' files ('+fmtSize(t.size)+')');
          } else {
            toast(t.senderNick+' sent you: '+t.name,'info');
            notifyInbound('New file from '+t.senderNick, t.name+' ('+fmtSize(t.size)+')');
          }
        });
      }
      renderAll();
    }catch(e){}
  }
  function renderAll(){
    document.getElementById('myNick').textContent=state.me.nick||'...';
    var others=state.devices.filter(function(d){return d.pubId!==state.me.pubId;});
    var onN=others.filter(function(d){return d.online;}).length;
    document.getElementById('onlineCount').textContent=onN+' other device(s) online';
    if(target!=='public' && !state.devices.some(function(d){return d.pubId===target;})){
      target='public';
    }
    renderDevices();
    renderTransfers();
    refreshTargetLabel();
  }
  function devCard(pubId,icon,label,sub,offline,self,showStatus){
    var c=document.createElement('div');
    c.className='dev'+(pubId===target?' selected':'')+(offline?' offline':'')+(self?' self':'')+(pubId==='public'?' public':'');
    var status=(showStatus && !self)?'<div class="dev-status"></div>':'';
    c.innerHTML=status+'<div class="dev-icon">'+icon+'</div><div class="dev-name">'+esc(label)+(self?' (me)':'')+'</div><div class="dev-sub">'+esc(sub)+'</div>';
    c.addEventListener('click',function(){
      if(self){toast("Can't send to yourself",'err');return;}
      target=pubId; renderDevices(); refreshTargetLabel();
    });
    return c;
  }
  function renderDevices(){
    var box=document.getElementById('devices');box.innerHTML='';
    box.appendChild(devCard('public','&#127760;','Everyone (Public)','Visible to all devices',false,false,false));
    state.devices.forEach(function(d){
      var sub=d.online?'online':fmtSeen(d.ageSec);
      box.appendChild(devCard(d.pubId,devIcon(d.nick),d.nick,sub,!d.online,d.pubId===state.me.pubId,true));
    });
  }
  function refreshTargetLabel(){
    var name='Everyone';
    if(target!=='public'){var d=state.devices.find(function(x){return x.pubId===target;});name=d?d.nick:'(none)';}
    document.getElementById('targetLabel').textContent='Target: '+name;
  }
  function renderTransfers(){
    var body=document.getElementById('transferBody');body.innerHTML='';
    var rows=state.transfers.filter(function(t){
      if(filter==='all')return true;
      if(filter==='public')return t.target==='public';
      if(filter==='inbox')return !t.byMe && (t.target==='public' || t.toMe);
      if(filter==='sent')return t.byMe;
      return true;
    });
    // Drop selected ids that no longer exist
    var liveIds=new Set();
    state.transfers.forEach(function(t){
      if(t.kind==='bundle'){t.items.forEach(function(it){liveIds.add(it.id);});}
      else{liveIds.add(t.id);}
    });
    selectedIds.forEach(function(id){if(!liveIds.has(id))selectedIds.delete(id);});
    if(rows.length===0){body.innerHTML='<tr><td colspan="7" class="empty">&#128230; No files yet.</td></tr>';syncSelAll();updateZipBtn();return;}
    rows.forEach(function(t){
      if(t.kind==='bundle')renderBundleRow(body,t);
      else renderSingleRow(body,t);
    });
    syncSelAll();
    updateZipBtn();
  }
  function isPreviewable(t){return /\.(txt|md|log|json|csv|ini|cfg)$/i.test(t.name) && t.size<=65536;}
  function renderSingleRow(body,t){
    var tr=document.createElement('tr');
    var pill=t.target==='public'?'<span class="pill pub">&#127760; Public</span>':('<span class="pill">'+esc(t.targetNick)+'</span>');
    var fromPill=t.byMe?'<span class="pill me">Me</span>':('<span class="pill">'+esc(t.senderNick)+'</span>');
    var del=t.byMe?'<button class="dl-x" data-id="'+t.id+'" title="Delete">&#10005;</button>':'';
    var peek=isPreviewable(t)?'<a class="dl peek" href="#" data-id="'+t.id+'" data-name="'+esc(t.name)+'" title="View text">&#128065; View</a> ':'';
    var chk=selectedIds.has(t.id)?' checked':'';
    tr.innerHTML='<td class="ic"><input type="checkbox" class="rowChk" data-id="'+t.id+'"'+chk+'></td>'+
                 '<td class="ic">'+t.icon+'</td>'+
                 '<td class="td-nm">'+esc(t.name)+'</td>'+
                 '<td>'+fmtSize(t.size)+'</td>'+
                 '<td>'+fromPill+' &rarr; '+pill+'</td>'+
                 '<td class="dt">'+fmtDate(t.created)+'</td>'+
                 '<td>'+peek+'<a class="dl" href="/download?id='+encodeURIComponent(t.id)+'">&#11015; Download</a>'+del+'</td>';
    body.appendChild(tr);
  }
  function renderBundleRow(body,t){
    var expanded=expandedBundles.has(t.bundleId);
    var arrow=expanded?'&#9662;':'&#9656;';   // filled tri down / right
    var pill=t.target==='public'?'<span class="pill pub">&#127760; Public</span>':('<span class="pill">'+esc(t.targetNick)+'</span>');
    var fromPill=t.byMe?'<span class="pill me">Me</span>':('<span class="pill">'+esc(t.senderNick)+'</span>');
    var del=t.byMe?'<button class="dl-x" data-bundle="'+t.bundleId+'" title="Delete bundle">&#10005;</button>':'';
    // Bundle checkbox reflects: all children currently selected?
    var childIds=t.items.map(function(x){return x.id;});
    var allSel=childIds.length>0 && childIds.every(function(id){return selectedIds.has(id);});
    var anySel=childIds.some(function(id){return selectedIds.has(id);});
    var chk=allSel?' checked':'';
    var tr=document.createElement('tr');
    tr.className='bundle-row';
    tr.innerHTML='<td class="ic"><input type="checkbox" class="bundleChk" data-bundle="'+t.bundleId+'"'+chk+'></td>'+
                 '<td class="ic">&#128230;</td>'+
                 '<td class="td-nm"><button class="expand-btn" data-bundle="'+t.bundleId+'">'+arrow+'</button> Bundle &middot; '+t.count+' files</td>'+
                 '<td>'+fmtSize(t.size)+'</td>'+
                 '<td>'+fromPill+' &rarr; '+pill+'</td>'+
                 '<td class="dt">'+fmtDate(t.created)+'</td>'+
                 '<td><a class="dl bundle-dl" href="#" data-bundle="'+t.bundleId+'">&#128230; ZIP</a>'+del+'</td>';
    body.appendChild(tr);
    if(anySel && !allSel){
      var bc=tr.querySelector('.bundleChk'); if(bc)bc.indeterminate=true;
    }
    if(expanded){
      // Render nested folder tree from item.name (slash-delimited)
      renderBundleTree(body,t);
    }
  }
  function renderBundleTree(body,t){
    // Group items by folder prefix; render sub-rows with indent.
    t.items.forEach(function(item){
      var parts=item.name.split('/');
      var base=parts[parts.length-1];
      var folder=parts.slice(0,-1).join('/');
      var subTr=document.createElement('tr');
      subTr.className='bundle-child';
      var indent=parts.length>1 ? ('&nbsp;&nbsp;'.repeat(parts.length-1)) : '';
      var prefix=folder ? ('<span class="folder-crumb">'+esc(folder)+'/</span>') : '';
      var chk=selectedIds.has(item.id)?' checked':'';
      var owned=t.byMe;
      var del=owned?'<button class="dl-x" data-id="'+item.id+'" title="Delete file">&#10005;</button>':'';
      subTr.innerHTML='<td class="ic"><input type="checkbox" class="rowChk" data-id="'+item.id+'" data-bundle="'+t.bundleId+'"'+chk+'></td>'+
                      '<td class="ic">'+item.icon+'</td>'+
                      '<td class="td-nm child-nm">'+indent+'&#8735; '+prefix+esc(base)+'</td>'+
                      '<td>'+fmtSize(item.size)+'</td>'+
                      '<td></td><td></td>'+
                      '<td><a class="dl" href="/download?id='+encodeURIComponent(item.id)+'">&#11015;</a>'+del+'</td>';
      body.appendChild(subTr);
    });
  }
  function updateZipBtn(){
    var n=selectedIds.size;
    var b=document.getElementById('zipBtn');
    b.disabled=(n===0);
    b.innerHTML='&#128230; Download Selected ('+n+')';
  }
  function syncSelAll(){
    var chks=document.querySelectorAll('.rowChk');
    var sa=document.getElementById('selAll');
    if(chks.length===0){sa.checked=false;sa.indeterminate=false;return;}
    var checkedN=0;
    chks.forEach(function(c){if(c.checked)checkedN++;});
    sa.checked=(checkedN===chks.length);
    sa.indeterminate=(checkedN>0 && checkedN<chks.length);
  }

  document.querySelectorAll('.tab').forEach(function(b){b.addEventListener('click',function(){
    document.querySelectorAll('.tab').forEach(function(x){x.classList.remove('on');});
    b.classList.add('on');filter=b.dataset.f;renderTransfers();
  });});
  function submitZipForm(spec){
    var f=document.createElement('form');
    f.method='POST'; f.action='/api/zip'; f.target='_blank';
    (spec.ids||[]).forEach(function(id){var i=document.createElement('input');i.type='hidden';i.name='id';i.value=id;f.appendChild(i);});
    (spec.bundles||[]).forEach(function(bid){var i=document.createElement('input');i.type='hidden';i.name='bundle';i.value=bid;f.appendChild(i);});
    document.body.appendChild(f); f.submit();
    setTimeout(function(){document.body.removeChild(f);},1000);
  }
  function openPeek(id,name){
    fetch('/api/peek?id='+encodeURIComponent(id)).then(function(r){return r.json();}).then(function(j){
      if(!j.ok){toast('Cannot preview','err');return;}
      document.getElementById('modalTitle').textContent=name;
      document.getElementById('modalText').value=j.text;
      document.getElementById('modalBg').classList.add('show');
    }).catch(function(){toast('Cannot preview','err');});
  }
  document.getElementById('modalClose').addEventListener('click',function(){document.getElementById('modalBg').classList.remove('show');});
  document.getElementById('modalBg').addEventListener('click',function(e){if(e.target===document.getElementById('modalBg'))document.getElementById('modalBg').classList.remove('show');});
  document.getElementById('modalCopy').addEventListener('click',function(){
    var ta=document.getElementById('modalText');
    if(navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(ta.value).then(function(){toast('Copied','ok');},function(){toast('Copy failed','err');});
    } else {
      ta.select();
      try{document.execCommand('copy');toast('Copied','ok');}catch(e){toast('Copy failed','err');}
    }
  });
  document.getElementById('transferBody').addEventListener('click',async function(e){
    // Text preview
    var pk=e.target.closest('.peek');
    if(pk){e.preventDefault();openPeek(pk.dataset.id,pk.dataset.name||'Note');return;}
    // Expand/collapse a bundle
    var eb=e.target.closest('.expand-btn');
    if(eb){
      var bid=eb.dataset.bundle;
      if(expandedBundles.has(bid))expandedBundles.delete(bid);
      else expandedBundles.add(bid);
      renderTransfers();
      return;
    }
    // Bundle ZIP download
    var bd=e.target.closest('.bundle-dl');
    if(bd){
      e.preventDefault();
      submitZipForm({bundles:[bd.dataset.bundle]});
      toast('Preparing ZIP...','info');
      return;
    }
    // Delete: single file OR whole bundle
    var x=e.target.closest('.dl-x');
    if(!x)return;
    var bid=x.dataset.bundle;
    var id=x.dataset.id;
    if(bid){
      if(!confirm('Delete this entire bundle from the server?'))return;
      var fd=new FormData(); fd.append('bundle',bid);
      var r=await fetch('/api/delete',{method:'POST',body:fd});
      if(r.ok){toast('Bundle deleted','ok');fetchState();}else{toast('Delete failed','err');}
    } else if(id){
      if(!confirm('Permanently delete this file?'))return;
      var fd=new FormData(); fd.append('id',id);
      var r=await fetch('/api/delete',{method:'POST',body:fd});
      if(r.ok){toast('Deleted','ok');fetchState();}else{toast('Delete failed','err');}
    }
  });
  document.getElementById('transferBody').addEventListener('change',function(e){
    // Bundle master checkbox: toggles all children
    var bc=e.target.closest('.bundleChk');
    if(bc){
      var bid=bc.dataset.bundle;
      var bundle=state.transfers.find(function(x){return x.kind==='bundle' && x.bundleId===bid;});
      if(bundle){
        bundle.items.forEach(function(item){
          if(bc.checked)selectedIds.add(item.id); else selectedIds.delete(item.id);
        });
        document.querySelectorAll('.rowChk[data-bundle="'+bid+'"]').forEach(function(c){c.checked=bc.checked;});
      }
      updateZipBtn(); syncSelAll();
      return;
    }
    // Individual row checkbox (single OR bundle child)
    var c=e.target.closest('.rowChk');
    if(!c)return;
    var id=c.dataset.id;
    if(c.checked)selectedIds.add(id); else selectedIds.delete(id);
    // If it's a bundle child, sync the parent bundleChk (checked/indeterminate)
    var parentBid=c.dataset.bundle;
    if(parentBid){
      var parent=state.transfers.find(function(x){return x.kind==='bundle' && x.bundleId===parentBid;});
      if(parent){
        var childIds=parent.items.map(function(it){return it.id;});
        var checkedN=childIds.filter(function(cid){return selectedIds.has(cid);}).length;
        var bChk=document.querySelector('.bundleChk[data-bundle="'+parentBid+'"]');
        if(bChk){
          bChk.checked=(checkedN===childIds.length);
          bChk.indeterminate=(checkedN>0 && checkedN<childIds.length);
        }
      }
    }
    updateZipBtn(); syncSelAll();
  });
  document.getElementById('selAll').addEventListener('change',function(){
    var chk=document.getElementById('selAll').checked;
    document.querySelectorAll('.rowChk').forEach(function(c){
      c.checked=chk;
      var id=c.dataset.id; if(!id)return;
      if(chk)selectedIds.add(id); else selectedIds.delete(id);
    });
    document.querySelectorAll('.bundleChk').forEach(function(bc){bc.checked=chk;bc.indeterminate=false;});
    updateZipBtn();
  });
  document.getElementById('zipBtn').addEventListener('click',function(){
    if(selectedIds.size===0)return;
    submitZipForm({ids:Array.from(selectedIds)});
    toast('Preparing ZIP ('+selectedIds.size+' files)...','info');
  });
  document.getElementById('renameBtn').addEventListener('click',async function(){
    var n=prompt('New device name:',state.me.nick);if(!n)return;
    n=n.trim().slice(0,32);if(!n)return;
    var fd=new FormData();fd.append('nick',n);
    var r=await fetch('/api/nick',{method:'POST',body:fd});
    if(r.ok){toast('Name updated','ok');fetchState();}
  });

  var drop=document.getElementById('drop'),fileInp=document.getElementById('file'),
      fileList=document.getElementById('fileList'),barWrap=document.getElementById('barWrap'),
      bar=document.getElementById('bar'),upBtn=document.getElementById('upBtn'),
      clearBtn=document.getElementById('clearBtn'),countLbl=document.getElementById('countLbl');

  function stageFiles(arr){
    // arr: [{file, rel}] - rel keeps folder structure (slash-delimited)
    if(uploading)return;
    arr.forEach(function(o){
      var key=o.rel||o.file.name;
      var dup=queued.some(function(q){return (q.rel||q.file.name)===key && q.file.size===o.file.size;});
      if(!dup){queued.push({file:o.file,rel:o.rel||'',id:++seq,status:'wait',loaded:0});}
    });
    renderQueue();
  }
  function addFiles(list){
    var arr=[];
    Array.prototype.forEach.call(list,function(f){arr.push({file:f,rel:(f.webkitRelativePath||f.name)});});
    stageFiles(arr);
  }
  // Recursive walk of dropped folders (webkitGetAsEntry API)
  function traverseEntry(entry,prefix,out,done){
    if(entry.isFile){
      entry.file(function(f){out.push({file:f,rel:prefix+entry.name});done();},function(){done();});
    } else if(entry.isDirectory){
      var reader=entry.createReader();
      var readBatch=function(){
        reader.readEntries(function(ents){
          if(!ents.length){done();return;}
          var sub=ents.length;
          var subDone=function(){sub--;if(sub===0)readBatch();};
          for(var i=0;i<ents.length;i++){traverseEntry(ents[i],prefix+entry.name+'/',out,subDone);}
        },function(){done();});
      };
      readBatch();
    } else { done(); }
  }
  function renderQueue(){
    fileList.innerHTML='';
    queued.forEach(function(q){
      var row=document.createElement('div');row.className='fileitem';
      var stat='';
      if(q.status==='ok')stat='<span class="fi-stat ok">&#10003; sent</span>';
      else if(q.status==='err')stat='<span class="fi-stat err">&#10007; error</span>';
      else if(q.status==='up')stat='<span class="fi-stat up">sending...</span>';
      var rm=uploading?'':'<span class="fi-x" data-id="'+q.id+'">&#10005;</span>';
      row.innerHTML='<span class="fi-ic">&#128196;</span><span class="fi-name">'+esc(q.rel||q.file.name)+'</span><span class="fi-size">'+fmtSize(q.file.size)+'</span>'+stat+rm;
      fileList.appendChild(row);
    });
    upBtn.disabled=(queued.length===0 || uploading);
    clearBtn.style.display=(queued.length && !uploading)?'inline-block':'none';
    countLbl.textContent=queued.length?(queued.length+' file(s) '+(uploading?'sending':'selected')):'';
  }
  fileList.addEventListener('click',function(e){
    var x=e.target.closest('.fi-x');if(!x)return;
    var id=parseInt(x.dataset.id,10);
    queued=queued.filter(function(q){return q.id!==id;});renderQueue();
  });
  var dirInp=document.getElementById('dirInp');
  drop.addEventListener('click',function(){if(!uploading)fileInp.click();});
  document.getElementById('pickDir').addEventListener('click',function(ev){ev.stopPropagation();if(!uploading)dirInp.click();});
  fileInp.addEventListener('change',function(){addFiles(fileInp.files);fileInp.value='';});
  dirInp.addEventListener('change',function(){addFiles(dirInp.files);dirInp.value='';});
  ['dragenter','dragover'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();if(!uploading)drop.classList.add('over');});});
  ['dragleave','drop'].forEach(function(e){drop.addEventListener(e,function(ev){ev.preventDefault();drop.classList.remove('over');});});
  drop.addEventListener('drop',function(ev){
    if(uploading)return;
    var items=ev.dataTransfer.items;
    if(items && items.length && items[0].webkitGetAsEntry){
      var collected=[];
      var pending=1;
      var doneOne=function(){pending--;if(pending===0)stageFiles(collected);};
      for(var i=0;i<items.length;i++){
        var entry=items[i].webkitGetAsEntry();
        if(entry){pending++;traverseEntry(entry,'',collected,doneOne);}
      }
      doneOne();
    } else {
      addFiles(ev.dataTransfer.files);
    }
  });
  clearBtn.addEventListener('click',function(){if(!uploading){queued=[];renderQueue();}});

  var currentRun=null;
  function fmtEta(s){s=Math.round(s);if(s<60)return s+'s';var m=Math.floor(s/60);return m+'m '+(s%60)+'s';}
  function updateOverall(){
    if(!currentRun)return;
    var total=0,loaded=0;
    currentRun.items.forEach(function(q){total+=q.file.size;loaded+=(q.status==='ok'?q.file.size:(q.loaded||0));});
    if(total>0)bar.style.width=((loaded/total)*100)+'%';
    var el=(Date.now()-currentRun.start)/1000;
    if(el>0.5 && loaded>0){
      var speed=loaded/el;
      var remain=speed>0?Math.max(0,(total-loaded)/speed):0;
      document.getElementById('upStats').textContent=fmtSize(loaded)+' / '+fmtSize(total)+'  ·  '+fmtSize(speed)+'/s  ·  ETA '+fmtEta(remain);
    }
  }
  function uploadOne(item,bundleId,done){
    item.status='up';item.loaded=0;renderQueue();
    var relName=item.rel||item.file.name;
    var fd=new FormData();
    fd.append('file',item.file,relName);
    var xhr=new XMLHttpRequest();
    var url='/upload?target='+encodeURIComponent(target);
    if(bundleId)url+='&bundle='+encodeURIComponent(bundleId);
    xhr.open('POST',url,true);
    xhr.upload.onprogress=function(e){if(e.lengthComputable){item.loaded=e.loaded;updateOverall();}};
    xhr.onload=function(){
      var ok=false,msg='';try{var r=JSON.parse(xhr.responseText);ok=r.ok;msg=r.msg||'';}catch(_){}
      if(ok){item.status='ok';item.loaded=item.file.size;}
      else{item.status='err';toast(relName+' error: '+(msg||xhr.status),'err');}
      updateOverall();renderQueue();done();
    };
    xhr.onerror=function(){item.status='err';toast(relName+' connection error','err');renderQueue();done();};
    xhr.send(fd);
  }
  function finishRun(msg,type){
    bar.style.width='100%';
    toast(msg,type||'ok');
    currentRun=null;
    setTimeout(function(){uploading=false;renderQueue();fetchState();bar.style.width='0';barWrap.classList.remove('show');document.getElementById('upStats').textContent='';},900);
  }
  function runRelay(list){
    // >1 file: auto-bundle so the receiver sees one package instead of N rows
    var bundleId=(list.length>1) ? randomHex(8) : null;
    if(bundleId)toast('Sending '+list.length+' files as one bundle...','info');
    var CONC=3,idx=0,active=0,finished=0;
    function pump(){
      while(active<CONC && idx<list.length){
        active++;
        uploadOne(list[idx++],bundleId,function(){active--;finished++;pump();});
      }
      if(finished===list.length && active===0){
        var okN=list.filter(function(q){return q.status==='ok';}).length;
        finishRun(bundleId?('Bundle sent ('+okN+' files)'):(okN+' file(s) sent'),'ok');
      }
    }
    pump();
  }
  async function runP2p(list){
    setPoll(800);                       // negotiation needs a tighter poll than 4s
    var p=null;
    try{p=await ensurePeer(target,8000);}catch(e){p=null;}
    setPoll(4000);
    if(!p||!p.ready)return false;
    for(var i=0;i<list.length;i++){
      var it=list[i];
      it.status='up';it.loaded=0;renderQueue();
      try{
        await p2pSendOne(p,it);
        it.status='ok';it.loaded=it.file.size;renderQueue();updateOverall();
      }catch(e){
        it.status='';renderQueue();     // hand whatever is left to the relay
        return false;
      }
    }
    return true;
  }
  upBtn.addEventListener('click',async function(){
    var todo=queued.filter(function(q){return q.status!=='ok';});
    if(!todo.length || uploading)return;
    uploading=true;renderQueue();
    barWrap.classList.add('show');bar.style.width='0';
    document.getElementById('upStats').textContent='';
    currentRun={items:todo,start:Date.now()};

    // Direct path only for a single named target. Broadcasting would need N
    // connections and the relay already handles that case well.
    var direct=false;
    if(p2pEnabled() && target!=='public'){
      toast('Connecting directly...','info');
      direct=await runP2p(todo);
      if(!direct)toast('No direct link, sending via server','info');
    }
    var left=todo.filter(function(q){return q.status!=='ok';});
    if(left.length)runRelay(left);
    else finishRun(todo.length+' file(s) sent directly \u26A1','ok');
  });

  // ---- Quick text share ----
  async function sendText(){
    var inp=document.getElementById('txtMsg');
    var v=inp.value.trim(); if(!v)return;
    var d=new Date();
    function p2(n){return ('0'+n).slice(-2);}
    var name='note-'+d.getFullYear()+p2(d.getMonth()+1)+p2(d.getDate())+'-'+p2(d.getHours())+p2(d.getMinutes())+p2(d.getSeconds())+'.txt';
    var fd=new FormData();
    fd.append('file',new Blob([v],{type:'text/plain'}),name);
    try{
      var r=await fetch('/upload?target='+encodeURIComponent(target),{method:'POST',body:fd});
      var j=await r.json();
      if(j.ok){toast('Text sent','ok');inp.value='';fetchState();}
      else toast('Failed: '+(j.msg||r.status),'err');
    }catch(e){toast('Connection error','err');}
  }
  document.getElementById('txtBtn').addEventListener('click',sendText);
  document.getElementById('txtMsg').addEventListener('keydown',function(e){if(e.key==='Enter')sendText();});

  // ---- Sound + browser notifications ----
  var notifOn=localStorage.getItem('lfpNotif')==='1';
  function syncNotifBtn(){document.getElementById('notifBtn').classList.toggle('on',notifOn);}
  document.getElementById('notifBtn').addEventListener('click',function(){
    notifOn=!notifOn;
    localStorage.setItem('lfpNotif',notifOn?'1':'0');
    if(notifOn && window.Notification && Notification.permission==='default'){Notification.requestPermission();}
    syncNotifBtn();
    toast(notifOn?'Notifications on':'Notifications off','info');
  });
  syncNotifBtn();
  function beep(){
    try{
      var ctx=new (window.AudioContext||window.webkitAudioContext)();
      var o=ctx.createOscillator();var g=ctx.createGain();
      o.connect(g);g.connect(ctx.destination);
      o.frequency.value=880;g.gain.value=0.06;
      o.start();
      setTimeout(function(){o.stop();ctx.close();},180);
    }catch(e){}
  }
  function notifyInbound(title,body){
    if(!notifOn)return;
    beep();
    if(document.hidden && window.Notification && Notification.permission==='granted'){
      try{new Notification(title,{body:body});}catch(e){}
    }
  }

  // ---- P2P: WebRTC DataChannel, server only brokers the handshake ----------
  // No STUN/TURN: one L2 segment, no internet. Host candidates are all we need.
  // Everything here is best-effort - any failure falls back to the HTTP relay.
  var RTC_OK=(typeof RTCPeerConnection!=='undefined');
  var peers={};            // pubId -> {pc,dc,ready,waiters,rx}
  var p2pInbox=[];         // files received directly, held in this tab only
  var pollMs=4000,pollTimer=null;

  function setPoll(ms){
    if(pollMs===ms&&pollTimer)return;
    pollMs=ms; if(pollTimer)clearInterval(pollTimer);
    pollTimer=setInterval(fetchState,ms);
  }
  function nickOf(pub){
    var d=(state.devices||[]).filter(function(x){return x.pubId===pub;})[0];
    return d?d.nick:pub;
  }
  function p2pEnabled(){return RTC_OK && state && state.p2p;}

  function rtcSignal(to,kind,data){
    var b='to='+encodeURIComponent(to)+'&kind='+encodeURIComponent(kind)+'&data='+encodeURIComponent(data||'');
    return fetch('/rtc/signal',{method:'POST',headers:{'Content-Type':'application/x-www-form-urlencoded'},body:b});
  }
  function dropPeer(pub){
    var p=peers[pub]; if(!p)return;
    try{if(p.dc)p.dc.close();}catch(e){}
    try{p.pc.close();}catch(e){}
    delete peers[pub];
  }
  // Gather fully before signalling. Trickling would race the offer through the
  // same mailbox and candidates could land before the description they belong to.
  function waitIce(pc,ms){
    return new Promise(function(res){
      if(pc.iceGatheringState==='complete'){res();return;}
      var done=false;
      var t=setTimeout(function(){if(!done){done=true;res();}},ms);
      pc.addEventListener('icegatheringstatechange',function(){
        if(pc.iceGatheringState==='complete'&&!done){done=true;clearTimeout(t);res();}
      });
    });
  }
  function wireChannel(p,dc){
    p.dc=dc; dc.binaryType='arraybuffer';
    dc.onopen=function(){
      p.ready=true;
      var w=p.waiters; p.waiters=[];
      w.forEach(function(fn){fn(p);});
    };
    dc.onclose=function(){p.ready=false;};
    dc.onmessage=function(e){
      if(typeof e.data==='string'){
        var m=null; try{m=JSON.parse(e.data);}catch(_){return;}
        if(m.t==='head'){p.rx={name:m.name,size:m.size,parts:[]};}
        else if(m.t==='end'&&p.rx){
          var blob=new Blob(p.rx.parts);
          var nm=p.rx.name;
          p2pInbox.unshift({key:'p'+(seq++),name:nm,size:blob.size,from:nickOf(p.pub),blob:blob});
          p.rx=null; renderP2pInbox();
          toast(nickOf(p.pub)+' sent you: '+nm+' (direct)','info');
          notifyInbound('Direct file from '+nickOf(p.pub),nm+' ('+fmtSize(blob.size)+')');
        }
      } else if(p.rx){
        p.rx.parts.push(e.data);
      }
    };
  }
  function newPeer(pub,initiator){
    var pc=new RTCPeerConnection({iceServers:[]});
    var p={pc:pc,dc:null,pub:pub,ready:false,waiters:[],rx:null};
    peers[pub]=p;
    pc.onconnectionstatechange=function(){
      var s=pc.connectionState;
      if(s==='failed'||s==='closed'||s==='disconnected'){
        var w=p.waiters; p.waiters=[];
        w.forEach(function(fn){fn(null);});
        if(s!=='disconnected')dropPeer(pub);
      }
    };
    if(initiator){wireChannel(p,pc.createDataChannel('lfp',{ordered:true}));}
    else{pc.ondatachannel=function(e){wireChannel(p,e.channel);};}
    return p;
  }
  function ensurePeer(pub,timeoutMs){
    return new Promise(function(resolve){
      var p=peers[pub];
      if(p&&p.ready){resolve(p);return;}
      if(!p){
        p=newPeer(pub,true);
        p.pc.createOffer()
          .then(function(o){return p.pc.setLocalDescription(o);})
          .then(function(){return waitIce(p.pc,2500);})
          .then(function(){return rtcSignal(pub,'offer',JSON.stringify(p.pc.localDescription));})
          .catch(function(){});
      }
      var done=false;
      var t=setTimeout(function(){if(!done){done=true;resolve(null);}},timeoutMs);
      p.waiters.push(function(res){if(!done){done=true;clearTimeout(t);resolve(res);}});
    });
  }
  function handleSignals(list){
    if(!p2pEnabled()&&!RTC_OK)return;
    list.forEach(function(s){
      var data=null; if(s.data){try{data=JSON.parse(s.data);}catch(_){return;}}
      if(s.kind==='bye'){dropPeer(s.from);return;}
      var p=peers[s.from];
      if(s.kind==='offer'){
        if(p)dropPeer(s.from);
        p=newPeer(s.from,false);
        p.pc.setRemoteDescription(data)
          .then(function(){return p.pc.createAnswer();})
          .then(function(a){return p.pc.setLocalDescription(a);})
          .then(function(){return waitIce(p.pc,2500);})
          .then(function(){return rtcSignal(s.from,'answer',JSON.stringify(p.pc.localDescription));})
          .catch(function(){dropPeer(s.from);});
      } else if(s.kind==='answer'){
        if(p)p.pc.setRemoteDescription(data).catch(function(){});
      } else if(s.kind==='ice'){
        if(p&&data)p.pc.addIceCandidate(data).catch(function(){});
      }
    });
  }
  function p2pSendOne(p,item){
    return new Promise(function(resolve,reject){
      var dc=p.dc,CH=16384,file=item.file,off=0;
      var HIGH=4194304;
      try{dc.send(JSON.stringify({t:'head',name:(item.rel||file.name),size:file.size}));}
      catch(e){reject(e);return;}
      var reader=new FileReader();
      reader.onerror=function(){reject(reader.error);};
      reader.onload=function(ev){
        try{dc.send(ev.target.result);}catch(e){reject(e);return;}
        off+=ev.target.result.byteLength;
        item.loaded=off; updateOverall();
        step();
      };
      function step(){
        if(dc.readyState!=='open'){reject(new Error('channel closed'));return;}
        if(off>=file.size){
          try{dc.send(JSON.stringify({t:'end'}));}catch(e){reject(e);return;}
          resolve(); return;
        }
        if(dc.bufferedAmount>HIGH){setTimeout(step,25);return;}
        reader.readAsArrayBuffer(file.slice(off,off+CH));
      }
      step();
    });
  }
  function renderP2pInbox(){
    var panel=document.getElementById('p2pPanel'),body=document.getElementById('p2pBody');
    if(!p2pInbox.length){panel.style.display='none';return;}
    panel.style.display='block';
    body.innerHTML='';
    p2pInbox.forEach(function(f){
      var tr=document.createElement('tr');
      tr.innerHTML='<td>'+esc(iconFor(f.name))+'</td><td>'+esc(f.name)+'</td><td>'+fmtSize(f.size)+
                   '</td><td>'+esc(f.from)+'</td><td style="text-align:right"></td>';
      var b=document.createElement('button');
      b.className='btn'; b.style.padding='5px 12px'; b.style.fontSize='13px'; b.textContent='Save';
      b.addEventListener('click',function(){
        var u=URL.createObjectURL(f.blob);
        var a=document.createElement('a'); a.href=u; a.download=f.name;
        document.body.appendChild(a); a.click(); document.body.removeChild(a);
        setTimeout(function(){URL.revokeObjectURL(u);},4000);
      });
      tr.lastChild.appendChild(b);
      body.appendChild(tr);
    });
  }
  // \u escapes on purpose: this .ps1 has no BOM, so PS 5.1 parses it as ANSI and
  // literal emoji would arrive at the browser mangled.
  function iconFor(n){
    var e=(n||'').split('.').pop().toLowerCase();
    if(['jpg','jpeg','png','gif','bmp','webp'].indexOf(e)>=0)return '\uD83D\uDDBC';
    if(['mp4','mkv','avi','mov','webm'].indexOf(e)>=0)return '\uD83C\uDFAC';
    if(e==='pdf')return '\uD83D\uDCC4';
    if(['zip','rar','7z'].indexOf(e)>=0)return '\uD83D\uDDDC';
    return '\uD83D\uDCC1';
  }

  // ---- Invite panel (link + QR) ----
  document.getElementById('inviteBtn').addEventListener('click',function(){
    var p=document.getElementById('connectPanel');
    var show=(p.style.display==='none');
    p.style.display=show?'block':'none';
    document.getElementById('inviteBtn').classList.toggle('on',show);
    if(show && !p.dataset.init){
      p.dataset.init='1';
      var u=location.origin+'/';
      document.getElementById('urlBox').textContent=u;
      var qb=document.getElementById('qrbox');
      if(window.QRCode){
        try{new QRCode(qb,{text:u,width:170,height:170,colorDark:'#000000',colorLight:'#ffffff',correctLevel:QRCode.CorrectLevel.M});}catch(e){qb.style.display='none';}
      } else { qb.style.display='none'; }
    }
  });
  document.getElementById('copyUrl').addEventListener('click',function(){
    var u=location.origin+'/';
    if(navigator.clipboard && navigator.clipboard.writeText){
      navigator.clipboard.writeText(u).then(function(){toast('Link copied','ok');},function(){toast('Copy failed','err');});
    } else {
      var ta=document.createElement('textarea');ta.value=u;document.body.appendChild(ta);ta.select();
      try{document.execCommand('copy');toast('Link copied','ok');}catch(e){toast('Copy failed','err');}
      document.body.removeChild(ta);
    }
  });

  fetchState();
  setPoll(4000);
  renderP2pInbox();
  window.addEventListener('focus',fetchState);
</script>
</body></html>
"@
}

# ============================== LOBBY PAGE ====================================
# Shown on the HOST screen. The joining phone is not on the network yet, so the
# dashboard's invite QR is unreachable by definition - this page carries the
# join QR instead. Step 1 joins our AP, step 2 opens the portal.
function Get-LobbyPage {
    param([string]$Url)
    $mode = $Global:Bearer.Mode
    $ssid = $Global:Bearer.Ssid
    $pass = $Global:Bearer.Pass
    $hasAp = ($mode -ne 'none' -and $ssid)
    # WIFI: payload is understood natively by iOS 11+ and Android 10+ cameras.
    # Escape the separators WPA passphrases are allowed to contain.
    $esc = { param($s) ($s -replace '([\\;:,"])', '\$1') }
    $wifiPayload = if ($hasAp) { 'WIFI:T:WPA;S:{0};P:{1};H:false;;' -f (& $esc $ssid), (& $esc $pass) } else { '' }
    $modeLabel = switch ($mode) {
        'hotspot'    { 'Mobile Hotspot' }
        'wifidirect' { 'Wi-Fi Direct group' }
        default      { 'Existing Wi-Fi (no self-AP)' }
    }
    # Pre-build the JS string literal; nesting quotes inside the here-string is brittle.
    $wifiJs = if ($wifiPayload) {
        "'" + ($wifiPayload -replace '\\', '\\' -replace "'", "\'") + "'"
    } else { 'null' }

    # Only promise one QR if DNS really bound. On the hotspot path ICS holds
    # UDP/53, so there the page must keep telling people to scan the second code.
    $oneQr = ($hasAp -and $Global:CaptivePortal -and $Global:Bearer.Dns)
    $stepLabel = if ($oneQr) { 'Scan this' } else { 'Step 1' }

    $step1 = if ($hasAp) { @"
      <div class="card">
        <div class="step">$stepLabel</div>
        <h2>Join this device</h2>
        <div id="qrWifi" class="qr"></div>
        <div class="kv"><span>Network</span><b>$([System.Web.HttpUtility]::HtmlEncode($ssid))</b></div>
        <div class="kv"><span>Password</span><b class="mono">$([System.Web.HttpUtility]::HtmlEncode($pass))</b></div>
        <p class="hint">Point the phone camera at the code and tap <i>Join network</i>.
        $(if ($oneQr) { 'The portal opens by itself a second later - nothing else to scan.' } else { 'No internet is needed.' })</p>
      </div>
"@ } else { @"
      <div class="card warn">
        <div class="step">Heads up</div>
        <h2>No self-AP running</h2>
        <p class="hint">The portal is using a Wi-Fi network this machine was already connected to.
        Other devices must join that same network themselves.</p>
      </div>
"@ }

    # Kept as a fallback card: some Android builds suppress the sign-in sheet.
    $step2 = @"
  <div class="card$(if ($oneQr) { ' muted' })">
    <div class="step">$(if ($oneQr) { 'If it does not' } else { 'Step 2' })</div>
    <h2>Open the portal</h2>
    <div id="qrUrl" class="qr"></div>
    <div class="url">$([System.Web.HttpUtility]::HtmlEncode($Url))</div>
    <p class="hint">$(if ($oneQr) { 'Only needed if the portal did not pop up on its own.' } else { 'Once joined, scan this or type the address.' }) Then enter the portal password.</p>
  </div>
"@

    return @"
<!DOCTYPE html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Local File Portal - Lobby</title>
<style>
:root{--bg:#0e1116;--panel:#171b22;--ink:#e6edf3;--muted:#8b949e;--acc:#2f81f7;--ok:#3fb950;--warn:#d29922}
*{box-sizing:border-box}
body{margin:0;background:var(--bg);color:var(--ink);font:16px/1.5 -apple-system,Segoe UI,Roboto,sans-serif;padding:28px}
h1{margin:0 0 4px;font-size:26px}
h2{margin:0 0 14px;font-size:19px}
.sub{color:var(--muted);margin:0 0 26px}
.grid{display:flex;gap:22px;flex-wrap:wrap;align-items:flex-start}
.card{background:var(--panel);border:1px solid #232a34;border-radius:14px;padding:22px;flex:1 1 320px;max-width:420px}
.card.warn{border-color:var(--warn)}
.card.muted{opacity:.45;transform:scale(.94);transform-origin:top left}
.card.muted:hover{opacity:1}
.step{display:inline-block;font-size:12px;letter-spacing:.09em;text-transform:uppercase;color:var(--acc);margin-bottom:6px}
.qr{background:#fff;padding:12px;border-radius:10px;width:212px;height:212px;display:flex;align-items:center;justify-content:center;margin-bottom:16px}
.qr img,.qr canvas{display:block}
.kv{display:flex;justify-content:space-between;gap:12px;padding:7px 0;border-top:1px solid #232a34}
.kv span{color:var(--muted)}
.mono{font-family:ui-monospace,Consolas,monospace;letter-spacing:.06em}
.hint{color:var(--muted);font-size:14px;margin:14px 0 0}
.url{font-family:ui-monospace,Consolas,monospace;font-size:17px;color:var(--ok);word-break:break-all;margin-bottom:14px}
.status{margin-top:26px;color:var(--muted);font-size:14px}
.dot{display:inline-block;width:9px;height:9px;border-radius:50%;background:var(--ok);margin-right:7px;vertical-align:middle}
</style></head><body>
<h1>Local File Portal</h1>
<p class="sub">$modeLabel &middot; this machine is the network</p>
<div class="grid">
$step1
$step2
</div>
<div class="status"><span class="dot"></span><span id="cnt">no devices signed in yet</span></div>
<script src="/qr.js"></script>
<script>
(function(){
  function draw(id,text){
    var el=document.getElementById(id);
    if(!el||!text||!window.QRCode){if(el)el.style.display='none';return;}
    try{new QRCode(el,{text:text,width:188,height:188,colorDark:'#000',colorLight:'#fff',correctLevel:QRCode.CorrectLevel.M});}
    catch(e){el.style.display='none';}
  }
  draw('qrWifi',$wifiJs);
  draw('qrUrl','$Url');
  function tick(){
    fetch('/api/lobby',{cache:'no-store'}).then(function(r){return r.json();}).then(function(j){
      var n=j.online||0;
      document.getElementById('cnt').textContent = n===0 ? 'no devices signed in yet'
        : (n+' device'+(n===1?'':'s')+' signed in');
    }).catch(function(){});
  }
  tick(); setInterval(tick,3000);
})();
</script>
</body></html>
"@
}

# ============================== ROUTER ========================================
function Invoke-RequestRouter {
    param($Req, [System.IO.Stream]$Stream)
    $path = $Req.Path; $method = $Req.Method

    # Captive-portal interception. Our DNS points every name here, so anything
    # arriving with a Host that is not ours is an OS connectivity probe (or a
    # stray request for some other site). Redirecting makes the phone show its
    # "sign in to network" sheet and open the portal on its own - one QR.
    if ($Global:CaptivePortal -and $Global:Bearer.Mode -ne 'none') {
        $hostHdr = ''
        if ($Req.Headers -and $Req.Headers.ContainsKey('host')) { $hostHdr = $Req.Headers['host'] }
        $mine = @(
            ('{0}:{1}' -f $Global:Bearer.IP, $Global:Port),
            $Global:Bearer.IP
        )
        if ($hostHdr -and ($mine -notcontains $hostHdr.ToLowerInvariant())) {
            $portal = 'http://{0}:{1}/' -f $Global:Bearer.IP, $Global:Port
            Write-Host ("[captive] {0} -> portal" -f $hostHdr) -ForegroundColor DarkCyan
            Send-RedirectResponse -Stream $Stream -Location $portal
            return
        }
    }

    switch ($path) {

        '/' {
            if ($method -eq 'POST') {
                $bodyText = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bodyText)
                $pw = $form['password']
                if ($pw -eq $Global:Password) {
                    $sid = New-SessionId
                    $pub = New-ShortId 4

                    # Same device logging in again (matching IP + user agent):
                    # adopt the old session instead of piling up ghost devices.
                    $oldSids = @()
                    foreach ($k in @($Global:Sessions.Keys)) {
                        $s = $Global:Sessions[$k]
                        if ($s -and $s.IP -eq $Req.ClientIp -and $s.UA -eq $Req.UserAgent) { $oldSids += $k }
                    }

                    $providedNick = $form['nick']
                    if ($providedNick) { $providedNick = $providedNick.Trim() }
                    $nick = if ($providedNick) { $providedNick }
                            elseif ($oldSids.Count -gt 0 -and $Global:Sessions[$oldSids[0]].Nick) { $Global:Sessions[$oldSids[0]].Nick }
                            else { Get-DeviceLabel -UA $Req.UserAgent -IP $Req.ClientIp }
                    if ($nick.Length -gt 32) { $nick = $nick.Substring(0,32) }
                    $now = Get-Date
                    $Global:Sessions[$sid] = @{
                        Sid=$sid; PubId=$pub; Nick=$nick
                        IP=$Req.ClientIp; UA=$Req.UserAgent
                        Created=$now; LastSeen=$now
                    }
                    $Global:PubIndex[$pub] = $sid

                    # Re-point old transfers at the new identity, then drop old sessions
                    foreach ($old in $oldSids) {
                        foreach ($tk in @($Global:Transfers.Keys)) {
                            $t = $Global:Transfers[$tk]
                            if ($null -eq $t) { continue }
                            $changed = $false
                            if ($t.Target -eq $old) { $t.Target = $sid; $changed = $true }
                            if ($t.Sender -eq $old) { $t.Sender = $sid; $changed = $true }
                            if ($changed) { try { Save-TransferMeta -T $t } catch {} }
                        }
                        $os = $Global:Sessions[$old]
                        if ($os -and $os.PubId) { [void]$Global:PubIndex.Remove($os.PubId) }
                        [void]$Global:Sessions.Remove($old)
                    }
                    Save-Sessions

                    $cookie = New-SessionCookieHeader -Sid $sid
                    Send-RedirectResponse -Stream $Stream -Location '/dashboard' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
                } else {
                    Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $true) -Status 401
                }
            } else {
                $sid = Test-ValidSession -Req $Req
                if ($sid) { Send-RedirectResponse -Stream $Stream -Location '/dashboard' }
                else { Send-HtmlResponse -Stream $Stream -Html (Get-LoginPage -Error $false) }
            }
        }

        '/dashboard' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-RedirectResponse -Stream $Stream -Location '/'; return }
            Send-HtmlResponse -Stream $Stream -Html (Get-DashboardPage)
        }

        '/qr.js' {
            $js = if ([string]::IsNullOrEmpty($Global:QrJs)) { '/* qr lib unavailable */' } else { $Global:QrJs }
            Send-Response -Stream $Stream -Status 200 -ContentType 'application/javascript; charset=utf-8' -Body ([System.Text.Encoding]::UTF8.GetBytes($js))
        }

        '/lobby' {
            # Host screen only: this page shows the Wi-Fi passphrase in clear text.
            # The listener binds to the bearer IP, so the host browser arrives from it.
            if ($Req.ClientIp -ne $Global:Bearer.IP) { Send-HtmlResponse -Stream $Stream -Html '<h1>404</h1>' -Status 404; return }
            Send-HtmlResponse -Stream $Stream -Html (Get-LobbyPage -Url ("http://{0}:{1}/" -f $Global:Bearer.IP, $Global:Port))
        }

        '/api/lobby' {
            if ($Req.ClientIp -ne $Global:Bearer.IP) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 404; return }
            $n = 0
            $now = Get-Date
            foreach ($k in @($Global:Sessions.Keys)) {
                $s = $Global:Sessions[$k]
                if ($s -and (($now - $s.LastSeen) -lt $Global:DeviceTTL)) { $n++ }
            }
            Send-JsonResponse -Stream $Stream -Json ('{"ok":true,"online":' + $n + '}') -Status 200
        }

        '/rtc/signal' {
            # WebRTC handshake relay: offer / answer / ICE only, never file bytes.
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 405; return }
            if (-not $Global:P2P) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"p2p disabled"}' -Status 403; return }
            $bt = [System.Text.Encoding]::UTF8.GetString($Req.Body)
            $form = [System.Web.HttpUtility]::ParseQueryString($bt)
            $to = $form['to']; $kind = $form['kind']; $data = $form['data']
            if ([string]::IsNullOrWhiteSpace($to) -or [string]::IsNullOrWhiteSpace($kind)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"bad request"}' -Status 400; return
            }
            if ($kind -notin @('offer','answer','ice','bye')) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"bad kind"}' -Status 400; return
            }
            if ($data -and $data.Length -gt 65536) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"payload too large"}' -Status 413; return
            }
            # Only signal between two signed-in devices.
            if (-not $Global:PubIndex.ContainsKey($to)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"unknown peer"}' -Status 404; return
            }
            Add-Signal -ToPub $to -FromPub $Global:Sessions[$sid].PubId -Kind $kind -Data $data
            Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
        }

        '/api/peek' {
            # Inline preview for small text files (notes, links) - no download needed
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
            $id = $q['id']
            if ([string]::IsNullOrWhiteSpace($id) -or -not $Global:Transfers.ContainsKey($id)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not found"}' -Status 404; return
            }
            $t = $Global:Transfers[$id]
            if ($t.Target -ne 'public' -and $t.Target -ne $sid -and $t.Sender -ne $sid) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"forbidden"}' -Status 403; return
            }
            if ($t.Size -gt 65536 -or $t.Name -notmatch '\.(txt|md|log|json|csv|ini|cfg)$') {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not previewable"}' -Status 415; return
            }
            if (-not (Test-Path -LiteralPath $t.Path -PathType Leaf)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"missing"}' -Status 404; return
            }
            $text = [System.IO.File]::ReadAllText($t.Path, [System.Text.Encoding]::UTF8)
            $payload = [pscustomobject]@{ ok = $true; text = $text }
            Send-JsonResponse -Stream $Stream -Json ($payload | ConvertTo-Json -Compress -Depth 3) -Status 200
        }

        '/api/state' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            $json = Get-StateJson -Sid $sid
            Send-JsonResponse -Stream $Stream -Json $json -Status 200
        }

        '/api/nick' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 405; return }
            $nick = $null
            if ($Req.ContentType -match 'multipart/form-data') {
                $nick = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'nick'
            } else {
                $bt = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bt)
                $nick = $form['nick']
            }
            if ([string]::IsNullOrWhiteSpace($nick)) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"empty"}' -Status 400; return }
            $nick = $nick.Trim(); if ($nick.Length -gt 32) { $nick = $nick.Substring(0,32) }
            $Global:Sessions[$sid].Nick = $nick
            Save-Sessions
            Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
        }

        '/api/delete' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false}' -Status 405; return }
            $id = $null; $bundle = $null
            if ($Req.ContentType -match 'multipart/form-data') {
                $id     = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'id'
                $bundle = Get-MultipartField -BodyBytes $Req.Body -ContentType $Req.ContentType -FieldName 'bundle'
            } else {
                $bt = [System.Text.Encoding]::UTF8.GetString($Req.Body)
                $form = [System.Web.HttpUtility]::ParseQueryString($bt)
                $id = $form['id']
                $bundle = $form['bundle']
            }
            if (-not [string]::IsNullOrWhiteSpace($bundle)) {
                $toDelete = @()
                foreach ($k in @($Global:Transfers.Keys)) {
                    $t = $Global:Transfers[$k]
                    if ($t -and $t.BundleId -eq $bundle -and $t.Sender -eq $sid) { $toDelete += $k }
                }
                if ($toDelete.Count -eq 0) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not found"}' -Status 404; return }
                foreach ($tid in $toDelete) { [void](Remove-Transfer -Id $tid) }
                Send-JsonResponse -Stream $Stream -Json ('{"ok":true,"deleted":' + $toDelete.Count + '}') -Status 200
                return
            }
            if ([string]::IsNullOrWhiteSpace($id) -or -not $Global:Transfers.ContainsKey($id)) {
                Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"not found"}' -Status 404; return
            }
            $t = $Global:Transfers[$id]
            if ($t.Sender -ne $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"forbidden"}' -Status 403; return }
            [void](Remove-Transfer -Id $id)
            Send-JsonResponse -Stream $Stream -Json '{"ok":true}' -Status 200
        }

        '/download' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-RedirectResponse -Stream $Stream -Location '/'; return }
            Send-FileDownload -Req $Req -Stream $Stream -Sid $sid
        }

        '/api/zip' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-HtmlResponse -Stream $Stream -Html '<h1>401 - sign in required</h1>' -Status 401; return }
            if ($method -ne 'POST') { Send-HtmlResponse -Stream $Stream -Html '<h1>405</h1>' -Status 405; return }
            $bodyText = [System.Text.Encoding]::UTF8.GetString($Req.Body)
            $form = [System.Web.HttpUtility]::ParseQueryString($bodyText)
            $collected = New-Object System.Collections.Generic.List[string]
            $rawIds = $form.GetValues('id')
            if ($rawIds) { foreach ($x in $rawIds) { if ($x) { [void]$collected.Add($x) } } }
            $rawBundles = $form.GetValues('bundle')
            if ($rawBundles) {
                foreach ($bid in $rawBundles) {
                    if (-not $bid) { continue }
                    foreach ($k in @($Global:Transfers.Keys)) {
                        $t = $Global:Transfers[$k]
                        if ($t -and $t.BundleId -eq $bid) { [void]$collected.Add($t.Id) }
                    }
                }
            }
            $ids = @($collected | Select-Object -Unique)
            if ($ids.Count -eq 0) { Send-HtmlResponse -Stream $Stream -Html '<h1>400 - no ids</h1>' -Status 400; return }
            Send-ZipDownload -Ids $ids -Sid $sid -Stream $Stream
        }

        '/upload' {
            $sid = Test-ValidSession -Req $Req
            if (-not $sid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"no session"}' -Status 401; return }
            if ($method -ne 'POST') { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"POST required"}' -Status 405; return }
            $q = [System.Web.HttpUtility]::ParseQueryString($Req.Query)
            $targetParam = $q['target']
            $targetSid = Resolve-TargetSid -TargetParam $targetParam
            if ($null -eq $targetSid) { Send-JsonResponse -Stream $Stream -Json '{"ok":false,"msg":"invalid target"}' -Status 400; return }
            $bundleParam = $q['bundle']
            if ($bundleParam) { $bundleParam = ($bundleParam -replace '[^a-zA-Z0-9]', '') }
            $r = Save-UploadedFileStream -NetStream $Stream -ContentType $Req.ContentType -SenderSid $sid -Target $targetSid -BundleId $bundleParam
            if ($r.ok) {
                $msg = ($r.msg -replace '\\','/' -replace '"',"'")
                Send-JsonResponse -Stream $Stream -Json ('{"ok":true,"id":"' + $r.id + '","msg":"' + $msg + '"}')
            } else {
                # Escape backslashes too - exception messages can contain paths,
                # and a lone \ makes the JSON unparseable on the client.
                $msg = ($r.msg -replace '\\','/' -replace '"',"'")
                Send-JsonResponse -Stream $Stream -Json ('{"ok":false,"msg":"' + $msg + '"}') -Status $r.status
            }
        }

        '/logout' {
            $sid = $Req.Cookies[$Global:CookieName]
            if ($sid -and $Global:Sessions.ContainsKey($sid)) {
                $pub = $Global:Sessions[$sid].PubId
                if ($pub) { [void]$Global:PubIndex.Remove($pub) }
                [void]$Global:Sessions.Remove($sid)
                Save-Sessions
            }
            $cookie = New-SessionCookieHeader -Sid '' -Expire $true
            Send-RedirectResponse -Stream $Stream -Location '/' -ExtraHeaders @{ 'Set-Cookie' = $cookie }
        }

        default {
            Send-HtmlResponse -Stream $Stream -Html '<h1>404</h1>' -Status 404
        }
    }
}

# ============================== SELF-AP BEARER ===============================
# Turns this machine into the network so clients need no router and no existing
# Wi-Fi. Two paths, tried in order:
#   A. Mobile Hotspot (NetworkOperatorTetheringManager) - needs a ConnectionProfile
#   B. Wi-Fi Direct autonomous GO  - needs nothing, works with zero internet
# Both land on 192.168.137.1/24 over "Microsoft Wi-Fi Direct Virtual Adapter",
# whose PhysicalMediaType is "Native 802.11" - so Get-WifiInterface below finds
# it unchanged. Verified on this hardware; neither path requires elevation.

function Invoke-WinRtOp {
    param($Op, [Type]$ResultType)
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $t = $m.MakeGenericMethod($ResultType).Invoke($null, @($Op))
    if (-not $t.Wait(30000)) { throw 'WinRT operation timed out' }
    return $t.Result
}

function Invoke-WinRtAction {
    param($Action)
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
        $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod -and
        $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
    $t = $m.Invoke($null, @($Action))
    if (-not $t.Wait(30000)) { throw 'WinRT action timed out' }
}

function New-ApPassphrase {
    # 10 chars, ambiguous glyphs removed so it can be read off a screen and typed
    $cs = '23456789abcdefghjkmnpqrstuvwxyz'
    $rng = New-Object System.Security.Cryptography.RNGCryptoServiceProvider
    $bytes = New-Object byte[] 10
    $rng.GetBytes($bytes)
    $s = ''
    foreach ($b in $bytes) { $s += $cs[$b % $cs.Length] }
    $rng.Dispose()
    return $s
}

function Start-ApHotspot {
    param([string]$Ssid, [string]$Pass)
    $ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
    $prof = $ni::GetInternetConnectionProfile()
    if (-not $prof) {
        # No internet (the ship case). Any profile that still owns an adapter may
        # work; if none does, the caller falls through to Wi-Fi Direct.
        foreach ($p in $ni::GetConnectionProfiles()) {
            if ($p.NetworkAdapter -and $p.GetNetworkConnectivityLevel() -ne 'None') { $prof = $p; break }
        }
    }
    if (-not $prof) { throw 'no usable ConnectionProfile' }

    $tm  = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]
    $mgr = $tm::CreateFromConnectionProfile($prof)
    $cfg = $mgr.GetCurrentAccessPointConfiguration()

    # ConfigureAccessPointAsync overwrites the machine's saved hotspot settings
    # permanently - they are not scoped to our process. Park the originals on
    # disk first so both the clean exit path and StopAccessPoint.ps1 (after a
    # taskkill) can put them back.
    try {
        $orig = [pscustomobject]@{ Ssid = $cfg.Ssid; Passphrase = $cfg.Passphrase; Saved = (Get-Date).ToString('o') }
        $orig | ConvertTo-Json | Set-Content -LiteralPath $Global:ApRestoreFile -Encoding UTF8 -Force
        $Global:ApOriginal = $orig
    } catch {}

    $cfg.Ssid = $Ssid
    $cfg.Passphrase = $Pass
    Invoke-WinRtAction $mgr.ConfigureAccessPointAsync($cfg)
    $res = Invoke-WinRtOp $mgr.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult])
    if ("$($res.Status)" -ne 'Success') { throw ("tethering: {0} {1}" -f $res.Status, $res.AdditionalErrorMessage) }
    $Global:ApHotspotMgr = $mgr
    return $true
}

function Start-ApWatchdog {
    param([string]$Ssid, [string]$Pass)
    # Windows powers the Mobile Hotspot down after ~5 minutes with no client
    # attached. Measured here: AP raised at T, gone by T+6min. That kills the
    # whole point - you start the portal, walk to the other device, and the
    # network has vanished. Disabling it permanently means writing
    # HKLM\SYSTEM\CurrentControlSet\Services\icssvc\Settings (admin), so instead
    # we watch and re-raise it. A bound TcpListener survives the gap, verified,
    # so nothing needs rebinding.
    $rs = [runspacefactory]::CreateRunspace($Host)
    $rs.Open()
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        param($ssid, $pass, $flag)
        [void][System.Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')
        function Await2($op, [Type]$rt) {
            $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
            $t = $m.MakeGenericMethod($rt).Invoke($null, @($op)); [void]$t.Wait(30000); $t.Result
        }
        function AwaitAction2($a) {
            $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object {
                $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and -not $_.IsGenericMethod -and
                $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncAction' })[0]
            $t = $m.Invoke($null, @($a)); [void]$t.Wait(30000)
        }
        $ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
        $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]
        while (-not $flag.Stop) {
            for ($i = 0; $i -lt 20 -and -not $flag.Stop; $i++) { Start-Sleep -Milliseconds 500 }
            if ($flag.Stop) { break }
            try {
                $prof = $ni::GetInternetConnectionProfile()
                if (-not $prof) { continue }
                $mgr = $tm::CreateFromConnectionProfile($prof)
                if ("$($mgr.TetheringOperationalState)" -eq 'Off') {
                    $cfg = $mgr.GetCurrentAccessPointConfiguration()
                    $cfg.Ssid = $ssid; $cfg.Passphrase = $pass
                    AwaitAction2 $mgr.ConfigureAccessPointAsync($cfg)
                    [void](Await2 $mgr.StartTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]))
                    $flag.Restarts = [int]$flag.Restarts + 1
                    Write-Host ("  [AP] Idle timeout hit - access point re-raised (x{0})." -f $flag.Restarts) -ForegroundColor DarkYellow
                }
            } catch {}
        }
    }).AddArgument($Ssid).AddArgument($Pass).AddArgument($Global:ApWatch)
    [void]$ps.BeginInvoke()
    $Global:ApWatchPs = $ps
    $Global:ApWatchRs = $rs
}

function Start-ApWifiDirect {
    param([string]$Ssid, [string]$Pass)
    # Short type names only resolve once the full WinRT name has been touched.
    $pubType  = [Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher, Windows.Devices.WiFiDirect, ContentType=WindowsRuntime]
    $credType = [Windows.Security.Credentials.PasswordCredential, Windows.Security.Credentials, ContentType=WindowsRuntime]
    $pub = [Activator]::CreateInstance($pubType)
    $pub.Advertisement.IsAutonomousGroupOwnerEnabled = $true
    $ls = $pub.Advertisement.LegacySettings
    $ls.IsEnabled = $true
    $ls.Ssid = $Ssid
    $cred = [Activator]::CreateInstance($credType)
    $cred.Password = $Pass
    $ls.Passphrase = $cred
    $pub.Start()
    for ($i = 0; $i -lt 40 -and "$($pub.Status)" -eq 'Created'; $i++) { Start-Sleep -Milliseconds 250 }
    if ("$($pub.Status)" -ne 'Started') { throw ("publisher status: {0}" -f $pub.Status) }
    # The publisher must stay referenced or the AP drops when it is collected.
    $Global:ApPublisher = $pub
    return $true
}

function Restore-ApConfig {
    # Puts the machine's own hotspot SSID/passphrase back. Safe to call twice:
    # the parked copy is deleted once it has been applied.
    if (-not (Test-Path -LiteralPath $Global:ApRestoreFile)) { return $false }
    try {
        $orig = Get-Content -LiteralPath $Global:ApRestoreFile -Raw | ConvertFrom-Json
        if (-not $orig -or [string]::IsNullOrEmpty($orig.Ssid)) { Remove-Item -LiteralPath $Global:ApRestoreFile -Force -ErrorAction SilentlyContinue; return $false }
        $ni = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
        $tm = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]
        $prof = $ni::GetInternetConnectionProfile()
        if (-not $prof) {
            foreach ($p in $ni::GetConnectionProfiles()) {
                if ($p.NetworkAdapter -and $p.GetNetworkConnectivityLevel() -ne 'None') { $prof = $p; break }
            }
        }
        if (-not $prof) { return $false }
        $mgr = $tm::CreateFromConnectionProfile($prof)
        $cfg = $mgr.GetCurrentAccessPointConfiguration()
        $cfg.Ssid = $orig.Ssid
        if ($orig.Passphrase) { $cfg.Passphrase = $orig.Passphrase }
        Invoke-WinRtAction $mgr.ConfigureAccessPointAsync($cfg)
        Remove-Item -LiteralPath $Global:ApRestoreFile -Force -ErrorAction SilentlyContinue
        Write-Host ('  [AP] Hotspot settings restored (SSID {0}).' -f $orig.Ssid) -ForegroundColor DarkGray
        return $true
    } catch {
        Write-Host ('  [AP] Could not restore hotspot settings: {0}' -f $_.Exception.Message) -ForegroundColor Yellow
        return $false
    }
}

function Start-SelfAp {
    $ssid = '{0}-{1}' -f $Global:ApSsid, ((New-ShortId 2).ToUpperInvariant())
    $pass = New-ApPassphrase
    [void][System.Reflection.Assembly]::LoadWithPartialName('System.Runtime.WindowsRuntime')

    # A previous run may have been killed before it could put things back.
    [void](Restore-ApConfig)

    # Wi-Fi Direct first by default: it is an island (nothing of the host's
    # internet reaches the clients) and it leaves the saved hotspot config alone.
    # Mobile Hotspot is the fallback because tethering *is* internet sharing.
    $order = if ($Global:ApPrefer -eq 'hotspot') { @('hotspot','wifidirect') } else { @('wifidirect','hotspot') }

    Write-Host '  Raising self access point...' -ForegroundColor Cyan
    foreach ($mode in $order) {
        try {
            if ($mode -eq 'wifidirect') {
                [void](Start-ApWifiDirect -Ssid $ssid -Pass $pass)
                $Global:Bearer.Mode = 'wifidirect'
                Write-Host ('  [AP] Wi-Fi Direct group up: {0} (no internet shared)' -f $ssid) -ForegroundColor Green
            } else {
                [void](Start-ApHotspot -Ssid $ssid -Pass $pass)
                $Global:Bearer.Mode = 'hotspot'
                Write-Host ('  [AP] Mobile Hotspot up: {0}' -f $ssid) -ForegroundColor Green
                Write-Host '  [AP] Note: tethering shares this machine internet connection.' -ForegroundColor DarkYellow
                Start-ApWatchdog -Ssid $ssid -Pass $pass
            }
            $Global:Bearer.Ssid = $ssid; $Global:Bearer.Pass = $pass
            return $true
        } catch {
            Write-Host ('  [AP] {0} path failed: {1}' -f $mode, $_.Exception.Message) -ForegroundColor Yellow
        }
    }
    Write-Host '  [AP] No self-AP; falling back to whatever Wi-Fi is already connected.' -ForegroundColor Yellow
    return $false
}

function Stop-SelfAp {
    $Global:ApWatch.Stop = $true
    if ($Global:ApWatchPs) {
        try { $Global:ApWatchPs.Dispose() } catch {}
        try { $Global:ApWatchRs.Close(); $Global:ApWatchRs.Dispose() } catch {}
        $Global:ApWatchPs = $null; $Global:ApWatchRs = $null
    }
    if ($Global:ApHotspotMgr) {
        try {
            [void](Invoke-WinRtOp $Global:ApHotspotMgr.StopTetheringAsync() ([Windows.Networking.NetworkOperators.NetworkOperatorTetheringOperationResult]))
            Write-Host '  [AP] Mobile Hotspot stopped.' -ForegroundColor DarkGray
        } catch {}
        $Global:ApHotspotMgr = $null
    }
    if ($Global:ApPublisher) {
        try { $Global:ApPublisher.Stop(); Write-Host '  [AP] Wi-Fi Direct group stopped.' -ForegroundColor DarkGray } catch {}
        $Global:ApPublisher = $null
    }
    [void](Restore-ApConfig)
    $Global:Bearer.Mode = 'none'
    $Global:Bearer.Ssid = ''
    $Global:Bearer.Pass = ''
}

# ============================== CAPTIVE PORTAL ===============================
# One QR instead of two. A phone that has just joined probes a known URL to see
# whether it really has internet:
#   Android  http://connectivitycheck.gstatic.com/generate_204   (wants 204)
#   iOS      http://captive.apple.com/hotspot-detect.html        (wants "Success")
#   Windows  http://www.msftconnecttest.com/connecttest.txt
# We resolve every name to ourselves and answer those probes with a redirect,
# so the OS decides it is behind a sign-in page and opens the portal by itself.
#
# Measured: UDP/53 is free on 192.168.137.1 with the AP up (ICS does not take
# it), and binding a port below 1024 needs no elevation on Windows.
#
# The trade-off is deliberate: the phone will show "no internet" on this
# network, because from its point of view that is exactly the truth.

# Implemented in C# with a raw Socket, for a measured reason: UdpClient.Receive
# does not fill in the "ref IPEndPoint" that names the sender - it stays
# 0.0.0.0:0, and every reply then fails with "requested address is not valid in
# its context". Verified in C# as well as PowerShell, so it is the API, not the
# host. Socket.ReceiveFrom reports the sender correctly. C# also owns its own
# thread here, so no extra runspace is needed.
if (-not ('LFP.CaptiveDns' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Net;
using System.Net.Sockets;
using System.Threading;

namespace LFP {
    public static class CaptiveDns {
        static Socket _sock;
        static Thread _thread;
        static volatile bool _stop;
        public static long Answered = 0;

        public static bool Start(string ip, int port) {
            IPAddress addr = IPAddress.Parse(ip);
            try {
                _sock = new Socket(AddressFamily.InterNetwork, SocketType.Dgram, ProtocolType.Udp);
                _sock.ReceiveTimeout = 1000;
                _sock.Bind(new IPEndPoint(addr, port));
            } catch { return false; }
            _stop = false;
            byte[] rdata = addr.GetAddressBytes();
            _thread = new Thread(delegate() { Loop(rdata); });
            _thread.IsBackground = true;
            _thread.Start();
            return true;
        }

        public static void Stop() {
            _stop = true;
            try { if (_sock != null) _sock.Close(); } catch {}
        }

        static void Loop(byte[] rdata) {
            byte[] buf = new byte[512];
            while (!_stop) {
                EndPoint from = new IPEndPoint(IPAddress.Any, 0);
                int n;
                try { n = _sock.ReceiveFrom(buf, ref from); }
                catch (SocketException) { continue; }   // 1s timeout re-checks _stop
                catch { break; }                        // socket closed on shutdown
                if (n < 12) continue;
                byte[] q = new byte[n];
                Array.Copy(buf, q, n);
                try {
                    // Walk the QNAME labels to find where the question ends.
                    int qEnd = 12;
                    while (qEnd < q.Length && q[qEnd] != 0) qEnd += q[qEnd] + 1;
                    qEnd++;        // root label
                    qEnd += 4;     // QTYPE + QCLASS
                    if (qEnd > q.Length) continue;
                    int qtype = (q[qEnd - 4] << 8) | q[qEnd - 3];
                    bool isA = (qtype == 1);

                    // A -> point at us. Anything else (AAAA especially) -> empty
                    // NOERROR, so the client drops to IPv4 without waiting.
                    byte[] r = new byte[qEnd + (isA ? 16 : 0)];
                    r[0] = q[0]; r[1] = q[1];              // transaction id
                    r[2] = 0x85; r[3] = 0x80;              // response, authoritative, RA
                    r[4] = 0; r[5] = 1;                    // QDCOUNT
                    r[6] = 0; r[7] = (byte)(isA ? 1 : 0);  // ANCOUNT
                    r[8] = 0; r[9] = 0;                    // NSCOUNT
                    r[10] = 0; r[11] = 0;                  // ARCOUNT
                    Array.Copy(q, 12, r, 12, qEnd - 12);   // echo the question
                    if (isA) {
                        int o = qEnd;
                        r[o++] = 0xC0; r[o++] = 0x0C;      // name: pointer to offset 12
                        r[o++] = 0; r[o++] = 1;            // TYPE A
                        r[o++] = 0; r[o++] = 1;            // CLASS IN
                        r[o++] = 0; r[o++] = 0; r[o++] = 0; r[o++] = 30;   // TTL
                        r[o++] = 0; r[o++] = 4;            // RDLENGTH
                        r[o++] = rdata[0]; r[o++] = rdata[1]; r[o++] = rdata[2]; r[o++] = rdata[3];
                    }
                    _sock.SendTo(r, from);
                    Answered++;
                } catch {}
            }
            try { _sock.Close(); } catch {}
        }
    }
}
'@
}

function Start-CaptiveDns {
    param([string]$Ip, [int]$Port)
    if ([LFP.CaptiveDns]::Start($Ip, $Port)) {
        Write-Host ('  [DNS] Answering every lookup with {0} (captive portal).' -f $Ip) -ForegroundColor Green
        return $true
    }
    Write-Host ('  [DNS] Could not bind {0}:{1} - captive portal off, two QRs needed.' -f $Ip, $Port) -ForegroundColor Yellow
    return $false
}

function Stop-CaptiveDns {
    try { [LFP.CaptiveDns]::Stop() } catch {}
}

# ============================== NETWORK SETUP ================================
function Get-WifiInterface {
    try {
        $wifiAdapters = Get-NetAdapter -ErrorAction SilentlyContinue | Where-Object {
            $_.Status -eq 'Up' -and (
                $_.PhysicalMediaType -match '802\.11' -or
                $_.NdisPhysicalMedium -eq 'Native802_11' -or
                $_.Name -match 'Wi-?Fi|Wireless|WLAN' -or
                $_.InterfaceDescription -match 'Wireless|Wi-?Fi|802\.11'
            )
        }
        $candidates = @()
        foreach ($a in $wifiAdapters) {
            # AddressState matters: a freshly raised SoftAP address stays 'Tentative'
            # for ~4s while duplicate-address detection runs, and binding a Tentative
            # address throws "requested address is not valid in its context".
            $ips = Get-NetIPAddress -AddressFamily IPv4 -InterfaceIndex $a.ifIndex -ErrorAction SilentlyContinue |
                   Where-Object { $_.IPAddress -ne '127.0.0.1' -and $_.IPAddress -notlike '169.254.*' -and
                                  ($null -eq $_.AddressState -or "$($_.AddressState)" -eq 'Preferred') }
            foreach ($ip in $ips) {
                $candidates += @{ IP = $ip.IPAddress; Prefix = $ip.PrefixLength; Name = $a.Name; Hotspot = ($ip.IPAddress -like '192.168.137.*') }
            }
        }
        if ($candidates.Count -gt 0) {
            $hot = $candidates | Where-Object { $_.Hotspot } | Select-Object -First 1
            if ($hot) { return $hot }
            return ($candidates | Select-Object -First 1)
        }
    } catch {}
    return $null
}

function Test-SameSubnet {
    param([string]$ClientIp, [string]$LocalIp, [int]$Prefix)
    try {
        $c = [System.Net.IPAddress]::Parse($ClientIp).GetAddressBytes()
        $l = [System.Net.IPAddress]::Parse($LocalIp).GetAddressBytes()
        if ($c.Length -ne $l.Length) { return $false }
        $bits = $Prefix
        for ($i = 0; $i -lt $c.Length; $i++) {
            $take = [Math]::Min(8, $bits)
            if ($take -le 0) { break }
            $mask = [byte](0xFF -shl (8 - $take))
            if (($c[$i] -band $mask) -ne ($l[$i] -band $mask)) { return $false }
            $bits -= 8
        }
        return $true
    } catch { return $false }
}

function Show-StartupBanner {
    param([hashtable]$Wifi)
    $logo = @"

   __    ____    ____    ___    ____  _____  __    __
  / /   |  _ \  |  _ \  / _ \  |  _ \|_   _| \ \  / /
 | |    | | | | | |_) || | | | | |_) | | |    \ \/ /
 | |___ | |_| | |  __/ | |_| | |  _ <  | |     |  |
 |_____||____/  |_|     \___/  |_| \_\ |_|     |__|

      L O C A L   F I L E   P O R T A L   v2.0
            Bidirectional Wi-Fi Transfer
"@
    Write-Host $logo -ForegroundColor Cyan

    $url = "http://$($Wifi.IP):$($Global:Port)/"
    Write-Host ''
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ('  |  URL          : {0,-38} |' -f $url)                                  -ForegroundColor Green
    Write-Host ('  |  Wi-Fi Adapter: {0,-38} |' -f $Wifi.Name)                            -ForegroundColor Gray
    Write-Host ('  |  Subnet       : {0,-38} |' -f ("$($Wifi.IP)/$($Wifi.Prefix)"))       -ForegroundColor Gray
    Write-Host ('  |  Time Limit   : {0,-38} |' -f 'NONE (1 year)')                       -ForegroundColor Gray
    Write-Host ('  |  Size Limit   : {0,-38} |' -f 'NONE')                                -ForegroundColor Gray
    Write-Host ('  |  Folder       : {0,-38} |' -f $Global:ShareFolder)                   -ForegroundColor Gray
    Write-Host ('  |  Concurrency  : {0,-38} |' -f ("$($Global:MaxThreads) threads"))     -ForegroundColor Gray
    Write-Host ('  |  Password     : {0,-38} |' -f $Global:Password)                      -ForegroundColor Magenta
    Write-Host '  +--------------------------------------------------------+' -ForegroundColor DarkGray
    Write-Host ''
    Write-Host '  [Wi-Fi only] Only Wi-Fi IP allowed, LAN clients rejected.' -ForegroundColor Green
    if ($Global:Bearer.Mode -ne 'none') {
        $label = if ($Global:Bearer.Mode -eq 'hotspot') { 'Mobile Hotspot' } else { 'Wi-Fi Direct group' }
        Write-Host ('  [Self-AP] {0} - this machine IS the network, no router needed.' -f $label) -ForegroundColor Green
        Write-Host ('            SSID: {0}   Password: {1}' -f $Global:Bearer.Ssid, $Global:Bearer.Pass) -ForegroundColor Magenta
        Write-Host ('  [Lobby]   Join QR on the host screen: {0}lobby' -f $url) -ForegroundColor Green
    } elseif ($Wifi.Hotspot) {
        Write-Host '  [Hotspot] Mobile Hotspot network (192.168.137.x).' -ForegroundColor Green
    }
    if ($Global:P2P) { Write-Host '  [P2P] Direct device-to-device transfer, server relay as fallback.' -ForegroundColor Green }
    Write-Host '  [Bidirectional] Device-to-device private + public broadcast.' -ForegroundColor Green
    Write-Host '  [Invite] Dashboard "Invite" button shows link + QR code.' -ForegroundColor Green
    Write-Host '  [No admin] TcpListener. Press Ctrl+C to stop.' -ForegroundColor DarkGray
    Write-Host ''
}

# ============================== MAIN LOOP ====================================
# Become the network first, then look for the interface. The SoftAP surfaces as
# "Microsoft Wi-Fi Direct Virtual Adapter" with PhysicalMediaType "Native 802.11",
# so Get-WifiInterface picks it up and prefers its 192.168.137.1 address.
if ($Global:SelfAp) { [void](Start-SelfAp) }

# Measured on this hardware: the AP address is bindable ~4.3s after StartTethering.
# Poll up to 15s so a slower adapter still makes it.
$wifi = $null
for ($try = 0; $try -lt 30; $try++) {
    $wifi = Get-WifiInterface
    if ($null -ne $wifi) { break }
    if ($try -eq 0) { Write-Host '  Waiting for the AP address to settle...' -ForegroundColor DarkGray }
    Start-Sleep -Milliseconds 500
}
if ($null -eq $wifi) {
    Stop-SelfAp
    Write-Host ''
    Write-Host '  [ERROR] No usable wireless interface found.' -ForegroundColor Red
    Write-Host '  The self-AP could not start and no Wi-Fi is connected.' -ForegroundColor Yellow
    Write-Host '  Connect to a Wi-Fi network or enable Mobile Hotspot, then retry.' -ForegroundColor Yellow
    Write-Host ''
    return
}
$Global:Bearer.IP = $wifi.IP
$Global:Bearer.Prefix = $wifi.Prefix
# Whether DNS actually bound decides what the lobby promises. On the hotspot
# path ICS already owns UDP/53, so the one-QR flow is not available there.
$Global:Bearer.Dns = $false
if ($Global:CaptivePortal -and $Global:Bearer.Mode -ne 'none') {
    $Global:Bearer.Dns = [bool](Start-CaptiveDns -Ip $wifi.IP -Port $Global:DnsPort)
}

# Restart-safe: load transfer records and sessions from disk
Import-AllTransfers
Import-Sessions

$bindAddr = [System.Net.IPAddress]::Parse($wifi.IP)
$listener = New-Object System.Net.Sockets.TcpListener($bindAddr, $Global:Port)

try {
    $listener.Start()
} catch {
    Stop-CaptiveDns
    Stop-SelfAp
    Write-Host ''
    Write-Host '  [ERROR] Failed to start listener.' -ForegroundColor Red
    Write-Host "  Message: $($_.Exception.Message)" -ForegroundColor Red
    Write-Host "  Port $($Global:Port) may be in use by another application." -ForegroundColor Yellow
    Write-Host '  Check: netstat -ano | findstr :8080' -ForegroundColor Cyan
    Write-Host ''
    return
}

Show-StartupBanner -Wifi $wifi
Write-Host ("  Worker threads: {0} | Loaded transfers: {1}" -f $Global:MaxThreads, $Global:Transfers.Count) -ForegroundColor Green
Write-Host ''

# Auto-open the portal in the default browser.
# NOTE: when this script itself runs with a hidden window (e.g. launched via
# StartPortalHidden.vbs -> powershell -WindowStyle Hidden), the spawned
# browser can inherit that hidden show-window hint and never become visible.
# -WindowStyle Normal on Start-Process overrides that. cmd's "start" and
# rundll32's URL handler are kept as fallbacks for odd shell-association setups.
# With a self-AP up, open the lobby: it carries the join QR the phone needs
# before it can reach anything else on this machine.
$startUrl = if ($Global:Bearer.Mode -ne 'none') { "http://$($wifi.IP):$($Global:Port)/lobby" }
            else { "http://$($wifi.IP):$($Global:Port)/" }
$opened = $false
try {
    Start-Process $startUrl -WindowStyle Normal -ErrorAction Stop | Out-Null
    $opened = $true
} catch {}
if (-not $opened) {
    try {
        Start-Process -FilePath 'cmd.exe' -ArgumentList @('/c','start','""',$startUrl) -WindowStyle Hidden -ErrorAction Stop | Out-Null
        $opened = $true
    } catch {}
}
if (-not $opened) {
    try {
        Start-Process -FilePath 'rundll32.exe' -ArgumentList @('url.dll,FileProtocolHandler',$startUrl) -WindowStyle Normal -ErrorAction Stop | Out-Null
        $opened = $true
    } catch {}
}
if ($opened) {
    Write-Host ('  [Browser] Opened {0}' -f $startUrl) -ForegroundColor DarkGray
} else {
    Write-Host ('  [Browser] Auto-open failed; open manually: {0}' -f $startUrl) -ForegroundColor DarkYellow
}
Write-Host ''

# ====================== RUNSPACE POOL ========================================
$iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
$iss.ApartmentState = 'MTA'

$funcNames = @(
    'Get-IconForFile','Format-Size','New-SessionId','New-ShortId','Get-DeviceLabel',
    'Invoke-PeriodicSweep','Save-TransferMeta','Remove-Transfer','ConvertTo-SafeRelPath',
    'Read-HttpRequest','Read-RequestBody','Get-HttpStatusText','Send-Response',
    'Send-HtmlResponse','Send-JsonResponse','Send-RedirectResponse','New-SessionCookieHeader',
    'Test-ValidSession','Resolve-TargetSid','Get-MultipartField','Save-Sessions',
    'Save-UploadedFileStream','Send-FileDownload','Send-ZipDownload','Get-StateJson',
    'Get-LoginPage','Get-DashboardPage','Get-LobbyPage','Invoke-RequestRouter',
    'Add-Signal','Get-SignalsFor'
)
foreach ($fn in $funcNames) {
    $def = (Get-Command $fn -CommandType Function).Definition
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry($fn, $def)))
}

$sharedVars = @{
    Password    = $Global:Password
    Port        = $Global:Port
    ShareFolder = $Global:ShareFolder
    MetaFolder  = $Global:MetaFolder
    CookieName  = $Global:CookieName
    SessionTTL  = $Global:SessionTTL
    DeviceTTL   = $Global:DeviceTTL
    SweepEvery  = $Global:SweepEvery
    Sessions    = $Global:Sessions
    PubIndex    = $Global:PubIndex
    Transfers   = $Global:Transfers
    UploadLock  = $Global:UploadLock
    SessionLock = $Global:SessionLock
    SessionFile = $Global:SessionFile
    SweepState  = $Global:SweepState
    QrJs        = $Global:QrJs
    Signals     = $Global:Signals
    SignalLock  = $Global:SignalLock
    SignalTTL   = $Global:SignalTTL
    Bearer      = $Global:Bearer
    P2P         = $Global:P2P
    # Needed by both the router's probe interception and Get-LobbyPage; without
    # it the workers see $null and silently fall back to the two-QR flow.
    CaptivePortal = $Global:CaptivePortal
}
foreach ($k in $sharedVars.Keys) {
    $iss.Variables.Add((New-Object System.Management.Automation.Runspaces.SessionStateVariableEntry($k, $sharedVars[$k], '')))
}

$pool = [runspacefactory]::CreateRunspacePool(1, $Global:MaxThreads, $iss, $Host)
$pool.Open()

$worker = {
    param($client, $ts, $remoteIp)
    Add-Type -AssemblyName System.Web
    $stream = $null
    try {
        $client.NoDelay = $true
        $client.SendTimeout    = 600000
        $client.ReceiveTimeout = 600000
        $stream = $client.GetStream()
        $stream.ReadTimeout  = 600000
        $stream.WriteTimeout = 600000

        $req = Read-HttpRequest -Stream $stream
        if ($null -eq $req) { return }
        $req.ClientIp = $remoteIp

        Write-Host ("[{0}] {1,-6} {2,-30} <- {3}" -f $ts, $req.Method, $req.RawTarget, $remoteIp) -ForegroundColor DarkGray

        $isUpload = ($req.Method -eq 'POST' -and $req.Path -eq '/upload')
        if (-not $isUpload) {
            if ($req.ContentLength -gt 0) {
                $req.Body = Read-RequestBody -Stream $stream -Length $req.ContentLength
            } else {
                $req.Body = New-Object byte[] 0
            }
        }

        Invoke-RequestRouter -Req $req -Stream $stream
    } catch {
        try { if ($stream) { Send-HtmlResponse -Stream $stream -Html '<h1>500</h1>' -Status 500 } } catch {}
    } finally {
        try { if ($stream) { $stream.Close() } } catch {}
        try { $client.Close() } catch {}
    }
}

$jobs = New-Object System.Collections.ArrayList

try {
    while ($true) {
        $client = $listener.AcceptTcpClient()
        $ts = (Get-Date).ToString('yyyy-MM-dd HH:mm:ss')

        $remoteIp = $null
        try { $remoteIp = $client.Client.RemoteEndPoint.Address.ToString() } catch {}
        if ($remoteIp -and $remoteIp -ne $wifi.IP -and -not (Test-SameSubnet -ClientIp $remoteIp -LocalIp $wifi.IP -Prefix $wifi.Prefix)) {
            Write-Host ("[{0}] DENY  Non-Wi-Fi client rejected: {1}" -f $ts, $remoteIp) -ForegroundColor Yellow
            try { $client.Close() } catch {}
            continue
        }

        $ps = [powershell]::Create()
        $ps.RunspacePool = $pool
        [void]$ps.AddScript($worker).AddArgument($client).AddArgument($ts).AddArgument($remoteIp)
        $handle = $ps.BeginInvoke()
        [void]$jobs.Add([pscustomobject]@{ PS = $ps; Handle = $handle })

        for ($i = $jobs.Count - 1; $i -ge 0; $i--) {
            if ($jobs[$i].Handle.IsCompleted) {
                try { $jobs[$i].PS.EndInvoke($jobs[$i].Handle) } catch {}
                try { $jobs[$i].PS.Dispose() } catch {}
                $jobs.RemoveAt($i)
            }
        }
    }
} finally {
    try { $listener.Stop() } catch {}
    foreach ($j in $jobs) { try { $j.PS.Dispose() } catch {} }
    try { $pool.Close(); $pool.Dispose() } catch {}
    Stop-CaptiveDns
    Stop-SelfAp
    Write-Host ''
    Write-Host '  Server stopped.' -ForegroundColor Yellow
}

# ==============================================================================
# RUN (NO ADMIN REQUIRED):
#   powershell.exe -ExecutionPolicy Bypass -File LocalFilePortal.ps1
#
# FEATURES:
#   - Self-AP: raises its own network (Mobile Hotspot, falling back to Wi-Fi
#     Direct when there is no internet at all). No router, no admin rights.
#     A watchdog re-raises it after Windows' ~5 min idle shutdown.
#   - /lobby on the host screen: join QR + portal QR, because a phone that is
#     not on the network yet cannot reach the dashboard's invite QR
#   - P2P: files to a single target go browser-to-browser over a WebRTC
#     DataChannel (no STUN/TURN, DTLS encrypted); the server only brokers the
#     handshake and falls back to the HTTP relay after 8 s
#   - Wi-Fi only (LAN denied; two checks: bind + subnet)
#   - Connected devices listed (all signed-in clients); click-to-target send
#   - "Everyone (Public)" card broadcasts to every device
#   - No size limit, no session expiry
#   - Streaming multipart parser + C# FastScan boundary (fast)
#   - 32-thread runspace pool, concurrent up/down; 3 parallel uploads client-side
#   - Multi-file uploads auto-bundle into one package; folder drag-drop keeps
#     the folder tree; bundle downloads as a single ZIP with structure intact
#   - Invite panel: connection link + offline QR code (embedded qrcode.js)
#   - Quick text/link share (sent as .txt to the current target)
#   - Sound + browser notifications for inbound files (bell toggle)
#   - Live upload stats: overall progress, MB/s, ETA
#   - Inline preview for small text files (View button, copy from modal)
#   - Restart-safe transfers (.meta\<id>.json) AND sessions (.meta\sessions.dat):
#     server restart does not log anyone out
#   - Re-login from the same device (IP+UA) adopts the previous identity -
#     old transfers are re-pointed, no ghost device cards pile up
#   - Interrupted uploads are discarded, never saved as silent partial files
#   - Device name picked at login, editable from dashboard
#
# STORAGE:
#   - Files: $Global:ShareFolder (default C:\SharedTransfer)
#   - Metadata sidecar: $ShareFolder\.meta\<id>.json (sender, target, ...)
#
# CONNECTING:
#   1. The lobby opens on this screen: scan QR 1 to join the network we raise
#   2. Scan QR 2 (or open the URL from the banner), password: hako123
#   3. After login: click a device card to send, or use Public to broadcast
#   Set $Global:SelfAp = $false to use an already-connected Wi-Fi instead.
#
# FIREWALL: On first request Windows may ask to allow -> tick "Private networks"
# ==============================================================================
