# Local File Portal v3 — Kendi Ağını Kuran P2P Transfer Mimarisi

> Hedef: sunucuyu çalıştıran cihazın **kendisi ağ olsun**. Bağlanacak cihazların hazır bir
> Wi-Fi ağına (router / gemi ağı / otel Wi-Fi'si) ihtiyacı olmasın. Bağlanma tek QR ile olsun.
> Dosya baytları mümkün olduğunca cihazdan cihaza **doğrudan** aksın, sunucu diskine uğramasın.

Bu doküman mevcut `LocalFilePortal.ps1` (v2) üzerine **eklemeli** bir tasarımdır. HTTP katmanı,
oturum modeli, bundle/ZIP mantığı aynen korunur.

---

## 0. Terim netleştirmesi: "Wi-Fi gerektirmeksizin"

İki farklı okuması var, tasarım ikisini de kapsıyor:

| Okuma | Anlamı | Bu mimarideki karşılığı |
|---|---|---|
| **A** (varsayılan) | Hazır bir Wi-Fi **ağına** / router'a gerek yok. Sunucu cihazı kendi ağını yayınlar. | **L0-A / L0-B** — birincil tasarım |
| **B** (uç durum) | Wi-Fi **radyosu** hiç kullanılmayacak. | **L0-D / L0-E** — USB tether ve Bluetooth PAN, dokümante edilmiş yedek |

Adaptör AP olamıyorsa üçüncü bir yol var: **L0-C**, mevcut bir ağa istemci olarak katılmak.
O durumda "kendi ağını kur" hedefinden vazgeçilir ama transfer çalışmaya devam eder.

Pratikte istenen A'dır: telefon hâlâ Wi-Fi radyosunu kullanır ama bağlandığı ağ **dizüstünün
kendisidir**; altyapı, internet, kablo, router yoktur. Gemide çalışacak senaryo budur.

---

## 1. Katman modeli

```
L4  Uygulama    Dosya/klasör transfer arayüzü  (mevcut dashboard — değişmiyor)
L3  Veri düzlemi WebRTC DataChannel (P2P doğrudan)  ||  HTTP relay (mevcut, fallback)
L2  Sinyalleşme  PowerShell sunucu: offer/answer/ICE posta kutusu (bayt taşımaz)
L1  Katılım      QR (WIFI: yükü) + captive-portal ile otomatik açılış
L0  Taşıyıcı     SoftAP (Mobile Hotspot | Wi-Fi Direct GO) | mevcut Wi-Fi | USB | BT-PAN
```

Kritik tasarım özelliği: **L0 değişikliği üst katmanlara sızmaz.** Windows SoftAP host'a
`192.168.137.1` verir ve `LocalFilePortal.ps1:1828` zaten `192.168.137.*` adresini tercih ediyor.
Yani AP'yi ayağa kaldırmak, geri kalan 2110 satıra dokunmadan çalışır.

---

## 2. L0 — Taşıyıcı: cihazın kendisi ağ olur

Başlangıçta sırayla denenir, ilk tutan kazanır:

### A. Mobile Hotspot — `NetworkOperatorTetheringManager` (BİRİNCİL)

Bu makinede yoklandı: `TetheringCapability = Enabled`, `MaxClientCount = 8`.

```powershell
$ni   = [Windows.Networking.Connectivity.NetworkInformation, Windows.Networking.Connectivity, ContentType=WindowsRuntime]
$prof = $ni::GetInternetConnectionProfile()
$tm   = [Windows.Networking.NetworkOperators.NetworkOperatorTetheringManager, Windows.Networking.NetworkOperators, ContentType=WindowsRuntime]
$mgr  = $tm::CreateFromConnectionProfile($prof)
# ConfigureAccessPointAsync(ssid, passphrase) -> StartTetheringAsync()
```

- Host IP: `192.168.137.1/24`. DHCP ve DNS'i Windows ICS kendisi sağlar — ayrıca yazmaya gerek yok.
- Telefon normal WPA2 ağı olarak görür → QR'daki `WIFI:` yükü doğrudan çalışır.
- **Kısıt:** bir `ConnectionProfile` ister. Gemide hiç internet yoksa
  `GetInternetConnectionProfile()` `null` dönebilir → o zaman `GetConnectionProfiles()` içinden
  herhangi bir adaptör profili denenir; o da yoksa **B**'ye düşülür.
- **Doğrulanacak:** yükseltilmiş yetki (admin) gerekiyor mu. Ayarlar'daki/Action Center'daki
  aynı kod yolu olduğu için gerekmemesi beklenir, ama saha testi şart (bkz. §8).

### B. Wi-Fi Direct otonom Group Owner — `WiFiDirectAdvertisementPublisher` (YEDEK)

Yoklandı: tipler ve `LegacySettings` mevcut. **İnternet profili istemez** — A'nın tek zayıf
noktasını kapatan yol budur.

```powershell
$pub = New-Object 'Windows.Devices.WiFiDirect.WiFiDirectAdvertisementPublisher'
$pub.Advertisement.IsAutonomousGroupOwnerEnabled = $true
$pub.Advertisement.LegacySettings.IsEnabled      = $true
$pub.Advertisement.LegacySettings.Ssid           = 'FTPHAKAN-A3F1'
$pub.Advertisement.LegacySettings.Passphrase     = (New-Object 'Windows.Security.Credentials.PasswordCredential' -ArgumentList '','', $pass)
$pub.Start()
```

`LegacySettings` sayesinde telefonlar bunu **sıradan bir WPA2 ağı** olarak görür; Wi-Fi Direct
desteklemeleri gerekmez. Host yine `192.168.137.1` alır.

- **Doğrulanacak:** saf WFD-GO modunda DHCP dağıtılıyor mu. Dağıtılmıyorsa istemci
  `169.254.x.x` alır ve portal görünmez → o durumda QR'a sabit IP talimatı eklenir ya da
  A yoluna geri dönülür.

### C. İstasyon modu — bildiğimiz bir ağa katıl (ÜÇÜNCÜ YOL)

A ve B, adaptörün **AP olabilmesini** varsayar. Olamıyorsa (eski sürücü, WFD desteği yok,
radyo başka işte) ikisi de düşer ve eskiden iş orada biterdi. Artık portal ağ olmayı bırakıp
makinenin **zaten kayıtlı olduğu** bir ağa katılıyor: telefonun hotspot'u, gemi Wi-Fi'si,
taşınabilir router. Üst katmanlar yine değişmiyor — portal kendisine verilen adrese bağlanıyor.

```powershell
netsh wlan show profiles    # kayıtlı olanlar
netsh wlan show networks    # şu an menzilde olanlar
netsh wlan connect name="<SSID>"
```

`netsh` tercih edildi çünkü WinRT `Windows.Devices.WiFi` konum izni onayı istiyor ve arka
planda çalışan bir script bunu geçemiyor; `netsh connect` ise kayıtlı profile karşı
yükseltilmiş yetki istemiyor.

**Ölçüm:** 10 kayıtlı profil, 2'si menzilde, 1 aday; bağlandı ve `192.168.115.2/24` aldı.

**Kritik fark: burada misafiriz.** Bu yüzden istasyon modunda captive portal ve otomatik
oturum **kendiliğinden kapanıyor**:
- Başkasının ağında her DNS sorgusunu kendimize yönlendirmek o ağdaki diğer tüm cihazları bozardı.
- Bedava oturum dağıtmak portalı o ağdaki yabancılara açardı.

### D. USB tethering (RNDIS) — manuel katman
Telefonu kabloyla bağlayıp USB tethering açmak PC'ye yeni bir subnet verir. PC tarafından
script'lenemez, kullanıcı hareketi ister. Wi-Fi radyosu kapalıyken tek hızlı yol budur.

### D2. Yerel ağ (`lan`) — hiçbir şey kurmadan hizmet ver — **uygulandı**
Makinenin **hâlihazırda üyesi olduğu altyapı ağı** üzerinden servis: gateway'i, DHCP'si ve
üzerinde başka insanlar olan ağ. Gemide bu tipik olarak kablolu LAN. Radyo harcamaz, çalışan
bir LAN varsa en hızlı yol budur.

**"LAN" ile "kablosuz olan" aynı şey değil.** İlk sürüm kablosuzu öncelikledi ve saha testinde
şunu seçti: laptop'ın Ethernet portu `advspring.local` üzerinde (domain, internet erişimi),
Wi-Fi radyosu ise bir **Canon yazıcının** Wi-Fi Direct grubuna (`DIRECT-LT0A-GX6000series`,
`Public`, internet yok) bağlıydı — ve yazıcı kazandı. Seçim artık medya tipinden tahmin
edilmiyor, Windows'un zaten bildiği şey soruluyor:

| Sinyal | Ağırlık |
|---|---|
| `IPv4Connectivity = Internet` | +8 |
| `NetworkCategory = DomainAuthenticated` / `Private` | +4 / +3 |
| Varsayılan ağ geçidi var | +2 |
| Kablolu | +1 |
| Profil adı `DIRECT-*` | **−10** |

Son satır göründüğünden önemli: `DIRECT-*` bir yazıcı/TV/kamera grubudur, adres verir ama
üzerinde başka cihaz yoktur — yani LAN'ın tam tersi. Kartta **ağın adı** gösteriliyor,
adaptörün adı değil: `advspring.local`, `Ethernet 2` değil.

İkinci incelik: **host birden çok yerel subnet üzerinde olabilir.** Ethernet'te 10.0.7.35/8 ve
Wi-Fi'de 192.168.115.3/24 iken sadece birini kabul etmek, diğerindeki cihazı sessizce dışarıda
bırakıyordu — ölçümle çıktı, test client'ı Ethernet'ten gelince `DENY` yedi. Artık en iyi adres
duyurulan adres, geri kalan yerel subnet'ler kayıtta `Alt` olarak taşınıyor ve kabul filtresi
hepsine bakıyor.

### E. Bluetooth PAN — seçilebilir taşıyıcı — **uygulandı, ölçüm değişmedi**
Link hızı hâlâ **3 Mbps** (~0.3 MB/s gerçek). Karar değişmedi, sunum değişti: artık otomatik
zincirde değil ama `$Global:BluetoothPan = $true` ile açılabilen bir taşıyıcı. Windows PAN'ı
kendiliğinden ayağa kaldırmıyor — eşleştirme ve "ağa katıl" telefonun kendi Bluetooth
ayarlarından yapılıyor — dolayısıyla portal yalnızca adaptör adres taşımaya başladıktan sonra
ona bağlanıyor. Panelde ve notta hız açıkça yazıyor; 2 GB'lık transferin yarısında öğrenilmesin.

### Seçim mantığı

**v2'de sıra ters çevrildi: artık B (Wi-Fi Direct) birincil.** Gerekçe ölçümle netleşti:

- **Tethering tanımı gereği internet paylaşımıdır.** `NetworkOperatorTetheringManager` bir
  `ConnectionProfile` alıp onu paylaşır; "paylaşmadan tethering" diye bir mod yok.
- **WFD ise kapalı ada.** Ölçüm: WFD ayaktayken `UDP/67`'de DHCP dağıtılıyor
  (ICS, scope `192.168.137.1`) ama AP arayüzünde `Forwarding: Disabled` ve
  `TetheringOperationalState: Off`. Yani adres var, çıkış yolu yok.
- **WFD kayıtlı hotspot ayarlarına dokunmuyor.** A yolu `ConfigureAccessPointAsync` ile
  makinenin kayıtlı SSID/parolasını **kalıcı olarak** eziyor (bkz. §8-c).
- **WFD'de boşta-kapanma yok.** Ölçüm: 8 dakika kesintisiz ayakta; A yolu 5. dakikada düşüyor.

```
Start-BearerChain ($Global:BearerOrder, varsayılan wifidirect -> hotspot -> station -> lan):
  - ayarlarda kapalı olan atlanır (SelfAp / StationFallback / LanBearer / BluetoothPan)
  - host'un bilerek kapattığı atlanır  ($Global:BearerOff)
  - ilk ayağa kalkan PRIMARY olur; MultiConnect açıksa zincir DURMAZ,
    kalkabilen her taşıyıcı yedek olarak ayakta bırakılır
  - tüm koşu boyunca TEK SSID + TEK parola kullanılır
Stop-Bearer <kind>: sadece o yolu kapatır; AP yollarında OS durumu geri sarılır
```

### v3'te eklenen: çoklu taşıyıcı, devretme ve elle değiştirme

**MultiConnect.** Zincir ilk başarıda durmuyor; kalkabilen her taşıyıcı ayakta kalıyor ve
dinleyici tek adres yerine **tüm arayüzlere** bağlanıyor. Wi-Fi Direct grubundaki telefon ile
gemi LAN'ındaki laptop aynı portalı görüyor, aynı cihaz listesinde birbirlerini buluyorlar.

Tüm arayüzlere bağlanmanın ikinci ve asıl gerekçesi yapısal: bir taşıyıcı düşüp yeniden
kalktığında (hotspot'un boşta kapanması) ya da adresi değiştiğinde (LAN'da DHCP) dinleyicinin
canlı yüklemelerin altından yeniden kurulması gerekmiyor.

Bunu "portalı tüm gemiye açmak"tan ayıran şey `Test-AllowedClient`: bir bağlantı ancak kaynak
adresi **ayakta olan bir taşıyıcının** subnet'ine düşüyorsa kabul ediliyor. Taşıyıcı kapanınca
o subnet bir sonraki bağlantıda dışarıda kalıyor, rebind yok.

**Devretme.** Supervisor thread'i her 3 saniyede her taşıyıcıyı yokluyor. Taşıyan düşerse
zincirden bir sonrakini yükseltiyor ve **oturum açmış her cihaza haber veriyor** — bildirim
`/api/state` üzerindeki sıra numaralı notice akışıyla gidiyor, websocket yok. Lobi sayfası da
kendi QR'ını yeniden çiziyor; ekranda ölü bir ağa katılan kod kalmıyor. Tek SSID kararı tam da
bunun için: hotspot → Wi-Fi Direct devretmesi telefonun okuduğu QR'ı geçersizleştirmiyor.

**Elle değiştirme.** Host ekranındaki Network paneli. Sadece host: `Test-HostRequest` loopback
ve kendi taşıyıcı adreslerimizi kabul ediyor, ikisi de uzaktaki bir istemcinin kaynak adres
olarak taklit edemeyeceği şeyler. Aynı AP'deki telefon portala girebiliyor ama paneli hiç
görmüyor.

İstek satır içinde işlenmiyor: bir posta kutusuna bırakılıyor, supervisor thread'i boşaltıyor.
Gerekçe mimari — WinRT AP nesneleri (`$Global:ApHotspotMgr`, `$Global:ApPublisher`) tek bir
runspace'e ait; bir HTTP worker kendi runspace'inden `StopTethering` çağırsa nesneyi `null`
bulur ve hotspot sessizce ayakta kalırdı. Bunu bir test yapısal olarak doğruluyor
(`Run-IsolationTests.ps1`).

**Son yol kapatılamıyor.** Kapatmayı geri alacak bir yol kalmazdı.

### Boşta-kapanma: üç savunma

Ölçüm değişmedi — hotspot, istemci yokken tam 5. dakikada kendini kapatıyor. Değişen, buna ne
kadar direndiğimiz. **Artık bir taşıyıcıyı yalnızca host, portal üzerinden kapatabiliyor.**

1. Portal zaten yetkili çalışıyorsa `icssvc\Settings\PeerlessTimeoutEnabled` sıfırlanıyor ve
   çıkışta eski değer geri konuyor. Asıl çözüm bu, ve admin isteyen tek şey bu.
2. Değilse supervisor düşüşü ~3 saniyede fark edip AP'yi yeniden kaldırıyor. Bağlı
   `TcpListener` boşluktan sağ çıkıyor (doğrulandı), rebind gerekmiyor.
3. Host'un **bilerek** kapattığı taşıyıcı kapalı olarak hatırlanıyor. Aksi hâlde düşen
   taşıyıcıları geri getiren dakikalık re-arm onu da geri getirir, Stop düğmesi bozuk görünürdü.

Eski watchdog'da bulunan gerçek hata: önce `GetInternetConnectionProfile()` soruyor, `null`
gelince `continue` ediyordu — yani **tam olarak bu aracın var olma sebebi olan internetsiz
durumda hiç çalışmıyordu.** Kayıtlı tethering manager'ı profil aramasına hiç ihtiyaç duymuyor;
profil taraması artık yalnızca yedek ve adaptör sahibi herhangi bir profili kabul ediyor.

### İstasyon modunda devretmeyi zararsızlaştırmak

Saha testinde çıktı: `Start-StationBearer` kayıtlı profiller arasından ilkini seçerken makineyi
bağlı olduğu ağdan koparıp bir **yazıcının** Wi-Fi Direct grubuna (`DIRECT-LT0A-GX6000series`)
taşıdı. İki kural eklendi:

- **Zaten bağlı olunan ağ mutlak öncelikli.** Yeniden ilişkilendirme her bağlantıyı birkaç
  saniye düşürüyor; devretmenin amacı portalı ulaşılabilir tutmak, host'u başka yere taşımak değil.
- **`DIRECT-*` profilleri atlanıyor** (`StationPrefer`'da açıkça adı geçmedikçe). Bunlar
  yazıcı/TV/kamera grupları: katılınca adres alınıyor ama üzerinde başka cihaz olmuyor —
  yani başarı gibi görünüyor, işe yaramıyor, ve host'un gerçek ağına mal oluyor.

---

## 3. L1 — QR ile katılım

### Kritik gözlem
Davet QR'ı **sunucunun ekranında** olmalı, dashboard'da değil. Katılacak telefon henüz ağda
değil, dashboard'ı açamaz. Mevcut v2'de QR sadece dashboard'da (`README.md:22`) — bu, self-AP
senaryosunda tavuk-yumurta problemi yaratır.

**Çözüm:** host tarayıcısında açılan `/lobby` sayfası. Gömülü `qr.js` ile iki QR'ı büyük basar,
istemci sayısını canlı gösterir. Ek bağımlılık yok.

### QR #1 — Ağa katıl
```
WIFI:T:WPA;S:FTPHAKAN-A3F1;P:<oturumluk-parola>;H:false;;
```
iOS 11+ Kamera ve Android 10+ Kamera/Lens bu formatı yerel olarak tanır, "Ağa katıl" çıkarır.
Offline çalışır, uygulama gerekmez.

### QR #2 — Portalı aç
```
http://192.168.137.1:8080/
```

### QR #2'yi yok etme: captive portal — **uygulandı**
Android `http://connectivitycheck.gstatic.com/generate_204`, iOS
`http://captive.apple.com/hotspot-detect.html` yoklar. Bu yoklamayı yakalayıp portala
yönlendirince telefon **kendiliğinden** portalı açıyor — tek QR yetiyor.

Endişe ICS'in `192.168.137.1:53`'ü tutmasıydı. **Ölçüldü: tutmuyor** — her iki bearer'da da
UDP/53 boş ve bind ediliyor; Windows'ta 1024 altı port bağlamak yükseltilmiş yetki de
istemiyor. Bu yüzden captive portal artık varsayılan.

(Test sırasında bir kez "bind edilemedi" görüldü ve ICS sanıldı; sebep aslında aynı anda
çalışan ikinci bir portal örneğiydi. Yine de bind başarısız olursa lobby iki QR'a geri
dönüyor — söz verip tutamamaktansa.)

Uygulama: kendi DNS yanıtlayıcımız her A sorgusuna `192.168.137.1` dönüyor, HTTP tarafında
`Host` başlığı bize ait olmayan her istek portala 302'leniyor.

**Bilinçli takas:** telefon bu ağda "internet yok" gösterecek — ki kendi açısından bu doğru.
Faz 1'in diğer yarısı (`generate_204`'e gerçekten 204 dönüp Android'i ağda tutmak) bunun
tam tersini gerektiriyor; ikisi aynı anda olamaz. Tek QR hızı seçildi.

### Gemide asıl önemli olan yan etki
İnternet olmayan bir AP'de Android "İnternet yok" der ve **mobil veriye geri düşüp AP'yi
bırakabilir**. Eğer DNS'i ele geçirebilirsek `generate_204` yoklamasına gerçekten `204` dönmek
telefonu ağda tutar. Bu, captive-portal işinin asıl kazancıdır — otomatik açılış ikincil.

---

## 4. L2 — Sinyalleşme

Yeni kalıcı bağlantı modeli **eklenmiyor**. Mevcut 4 saniyelik `/api/state` yoklaması taşıyıcı
olarak kullanılır:

- `GET /api/state` → yanıta `signals: [...]` dizisi eklenir (cihazın posta kutusu, okununca boşalır)
- `POST /rtc/signal` → `{ to: <pubId>, kind: offer|answer|ice, data: <json> }`
- Sunucu tarafı: `$Global:Signals` (synchronized hashtable, `pubId -> Queue`), 60 sn TTL

**Neden SSE/WebSocket değil:** sunucu 32 runspace'lik havuzla çalışıyor
(`LocalFilePortal.ps1:23`). Kalıcı stream başına bir worker kilitlenir; 8 istemcide sorun
olmasa da tasarımı kırılgan yapar. Yoklama ile sıfır risk.

**Gecikme:** müzakere sırasında istemci yoklama aralığını 4 sn → 1 sn'ye düşürür, bağlantı
kurulunca geri çıkar. P2P kurulumu ~2-3 sn'de tamamlanır, kabul edilebilir.

**Yetkilendirme:** yalnız oturum açmış iki cihaz arasında sinyal taşınır; `to` alanı
`$Global:PubIndex` içinde doğrulanır. Sunucu **hiçbir dosya baytı görmez**.

---

## 5. L3 — Veri düzlemi: WebRTC DataChannel

```js
new RTCPeerConnection({ iceServers: [] })   // STUN/TURN YOK — kasıtlı
```

Tek L2 segmentindeyiz ve internet zaten yok. Boş `iceServers` ile sadece **host candidate**
toplanır: hızlı, offline, dış bağımlılıksız.

- Aktarım: 16 KB parça, `bufferedAmountLowThreshold` ile geri-basınç, ordered+reliable
- Şifreleme: WebRTC zorunlu DTLS → sunucu isteseydi bile içeriği okuyamaz

### Bilinen tuzaklar ve karşılıkları

| Tuzak | Etki | Karşılık |
|---|---|---|
| **mDNS candidate gizleme** — Chrome yerel IP yerine `xxx.local` yayar | Peer çözemezse ICE takılır | Her iki mobil OS de mDNS çözer; yine de 8 sn timeout → relay'e düş |
| **AP client isolation** | İstemci↔istemci P2P ölür | Windows ICS varsayılanda izole etmez; saha testi §8'de. İzole ise host↔istemci P2P ve relay çalışmaya devam eder |
| **iOS Safari bellek tavanı** | Büyük dosya Blob'da patlar | Büyük dosya ve iOS için **relay** yolu tercih edilir (diske stream eder) |
| **SoftAP yarı-çift yönlü** | İstemci↔istemci trafiği havada 2 sekme, bant genişliği yarılanır | Kazanç yine de gerçek: host diski yazılmaz, çift HTTP yok, depolama tüketilmez |
| **Plain HTTP'de WebRTC** | Tarayıcı kısıtlaması riski | `RTCPeerConnection` güvenli bağlam istemez (`getUserMedia` ister, onu kullanmıyoruz). Saha testi §8 |

### Geri düşme merdiveni
```
P2P dene (8 sn) → DataChannel açılmadıysa → mevcut HTTP upload/download relay
```
Arayüzde rozet: `⚡ P2P` / `☁ Sunucu`. Kullanıcı asla takılı kalmaz; en kötü durumda bugünkü
davranışa döner.

---

## 6. Güvenlik modeli (v2'den farklar)

- SoftAP parolası **her oturumda rastgele** üretilir, sabit değildir; yalnızca lobby QR'ında görünür. WPA2 hava linkini şifreler.
- Mevcut paylaşılan parola ile oturum açma korunur (`$Global:Password`).
- v2'deki "Wi-Fi subnet dışını reddet" kontrolü (`LocalFilePortal.ps1:2047`) self-AP'de **daha güçlü** hale gelir: yalnız `192.168.137.0/24`. Ethernet/LAN portalı hiç görmez.
- P2P yükü uçtan uca DTLS ile şifreli — sunucu prensipte bile okuyamaz.
- Değişmeyen: düz HTTP, güvenilen yerel ağ varsayımı. Portu internete açma.

---

## 7. Repoda ne değişir

**Yeni**
- `Bearer.ps1` — `Start-SelfAp` / `Stop-SelfAp` / `Get-BearerInfo` (A→B kaskadı)
- `/lobby` rotası + gömülü lobby HTML (iki büyük QR + canlı istemci sayacı)
- Gömülü `rtc.js` — istemci P2P mantığı + relay'e düşme
- `StartPortalAP.vbs` — self-AP modunda gizli başlatıcı

**Değişen**
- `Get-WifiInterface` → `Get-BearerInterface` (AP ayaktayken `192.168.137.1`'i tanı)
- `/api/state` → `signals` alanı; `POST /rtc/signal` eklenir
- `StopPortal.vbs` → süreçle birlikte AP'yi de kapatır
- `README.md` → yeni uç noktalar ve taşıyıcı tablosu

**Değişmeyen**
- Streaming multipart parser, `LFP.FastScan`, bundle/ZIP, oturum kalıcılığı, dashboard UI iskeleti

---

## 8. Saha testi sonuçları

Tasarımın belirsiz noktaları uygulama sırasında ölçüldü. Sonuçlar:

| # | Soru | Sonuç |
|---|---|---|
| 1 | Hotspot admin gerektiriyor mu? | **Hayır.** Yükseltilmemiş PowerShell'den `StartTethering -> Success` |
| 2 | SoftAP adaptörünü mevcut filtre yakalıyor mu? | **Evet.** `PhysicalMediaType = "Native 802.11"` → `Get-WifiInterface` `192.168.137.1/24` döndü, `Hotspot=True`. Alt katmanlara hiç dokunulmadı |
| 3 | B yolu (Wi-Fi Direct) çalışıyor mu? | **Evet.** `publisher status: Started`, aynı `192.168.137.1`. İnternet profiline hiç bakmıyor |
| 4 | Sinyalleşme uçtan uca çalışıyor mu? | **Evet.** İki oturum arası offer taşındı, posta kutusu tek okumada boşaldı, yetkisiz/bozuk istekler 401/400/404 ile reddedildi |

### Uygulama sırasında çıkan, tasarımda öngörülmemiş iki sorun

**a) Adres ~4 sn `Tentative` kalıyor.** `StartTetheringAsync` `Success` döndükten sonra
`192.168.137.1` hemen `Get-NetIPAddress`'te görünüyor ama IPv4 duplicate-address-detection
bitene kadar bind edilemiyor — `"The requested address is not valid in its context"`.
Ölçüm: t=1.1 sn'de `Tentative`, t=4.3 sn'de `Preferred` ve bindable.
Çözüm: `Get-WifiInterface` artık `AddressState -eq 'Preferred'` filtreliyor, başlangıç
15 sn'ye kadar bekliyor.

**b) Hotspot 5 dakikada kendini kapatıyor.** İstemci bağlanmazsa Windows AP'yi düşürüyor.
Ölçüm: 20:37:42'de kalktı, **20:42:41'de düştü** — tam 5 dakika. Portalı açıp diğer cihaza
yürürken bu süre rahat aşılır, yani tasarımın tamamını sessizce çökertiyordu.
Kalıcı kapatması `HKLM\...\icssvc\Settings\PeerlessTimeoutEnabled` yazmayı, o da admin
gerektiriyor — aracın "admin yok" ilkesine aykırı.
Çözüm: watchdog runspace'i 10 sn'de bir `TetheringOperationalState`'i yokluyor ve `Off`
görürse yeniden kaldırıyor. Ölçüm: 20:42:47'de geri geldi (6 sn).
Ayrıca test edildi — **bağlı `TcpListener` bu boşluktan sağ çıkıyor**, yeniden bind gerekmiyor.

**c) Tethering makinenin kayıtlı hotspot ayarlarını kalıcı olarak eziyor.**
`ConfigureAccessPointAsync` süreç kapsamlı değil — sistem ayarını değiştiriyor. Ölçüm:
başlangıçta SSID `000` idi, portal çalıştıktan sonra `FTPHAKAN-90E3` olarak kalmıştı.
Çözüm: A yolu kullanılırsa orijinaller `ap-restore.json`'a park ediliyor, hem temiz çıkışta
hem de `taskkill /F` sonrası `StopAccessPoint.ps1` tarafından geri yükleniyor.
Asıl çözüm ise B yolunu birincil yapmak: WFD bu ayarlara hiç dokunmuyor.

**d) WFD'de boşta-kapanma yok.** Ölçüm: 8 dakika kesintisiz `Started` ve `192.168.137.1`
ayakta. Watchdog yalnızca A yolu için gerekli.

### v3 sırasında çıkan, yine öngörülmemiş dört sorun

**e) Watchdog internetsiz durumda hiç çalışmıyordu.** (b)'nin çözümü olarak yazılan döngü
önce `GetInternetConnectionProfile()` soruyor, `null` gelince `continue` ediyordu. Yani
hotspot'u ayakta tutması gereken kod, tam olarak bu aracın var olma sebebi olan "internet yok"
durumunda hiçbir şey yapmıyordu. Kayıtlı manager profil aramasına ihtiyaç duymuyor; artık
öncelikli yol o.

**f) PowerShell tek elemanlı diziyi açıyor, `.Count` hashtable'ın anahtar sayısını veriyor.**
`(Get-ActiveBearers).Count -le 1` kontrolü tek taşıyıcı varken `9` görüp geçiriyordu — yani
"son yolu kapatma" koruması hiç çalışmıyordu. Testte yakalandı, `@(...)` ile sarıldı. Aynı
tuzağın ikinci örneği bir satır ötede duruyordu ve kazara doğru sonuç veriyordu.

**g) Captive yakalama, kendi DNS'imiz kalkmasa da devreye giriyordu.** Koşul
`$Bearer.Mode -ne 'none'` idi; `lan` taşıyıcısı gelince bu koşul her zaman doğru oldu ve
portala adresle düzgünce ulaşan cihaz login'e yönlendirilmeye başladı. Doğru koşul
`$Bearer.Dns` — yönlendirme yalnızca sorguyu bizim çözücümüz yanıtladıysa anlamlı. Ayrıca
"benim adresim" listesi artık tüm aktif taşıyıcıları ve onların yan subnet adreslerini içeriyor.

**h) `lan` taşıyıcısı LAN yerine bir yazıcıyı seçti.** İlk sıralama kablosuzu öncelikliyordu.
Saha makinesinde Ethernet `advspring.local` üzerindeydi (domain, internet), Wi-Fi ise bir Canon
yazıcının Wi-Fi Direct grubuna bağlıydı — ve yazıcı kazandı. `Get-NetConnectionProfile` bu
farkı zaten biliyor: bağlanabilirlik, ağ kategorisi ve `DIRECT-*` adı. Ayrıntı için §2/D2.

**i) Test paketi gerçek bir erişim noktası kaldırdı.** Zincir testlerinden biri `Start-Bearer`
mock'unu kendi `It` bloğu içinde tanımlıyordu; bir başkası tanımlamayı unutunca gerçek WinRT
çağrısı çalıştı ve geliştirme makinesinde **gerçekten bir Wi-Fi Direct ağı yayınlandı** —
üstelik koşu zaman aşımıyla öldürülünce arkada kaldı. Radyoya dokunan her şey artık script
kapsamında, tek yerde mock'lanıyor; ayrıca mock'ların yerinde durduğunu doğrulayan bir test var.

**j) Kaynak dosyada düz emoji mojibake oluyor.** Dosyanın BOM'u yok, PowerShell 5.1 de BOM'suz
dosyayı ANSI okuyor; taşıyıcı ikonları tarayıcıya `ðŸ"¶` diye gitti. Sayfanın geri kalanının
neden hep `&#128193;` ve `🗜` kullandığı da böylece anlaşıldı. Dosya artık baştan
sona 7-bit ASCII — yanlış çözümlenebilecek bayt kalmadı. Aynı hata upStats satırındaki iki düz
`·` karakterinde de vardı ve v2'den beri duruyordu.

### Hâlâ açık kalanlar

- **İki telefon birbirini görüyor mu (client isolation)?** İki gerçek cihaz gerektiriyor, test edilmedi. İzolasyon varsa P2P istemci↔istemci yolu düşer, relay çalışmaya devam eder.
- **DataChannel üzerinden gerçek dosya akışı.** Sinyalleşme doğrulandı, veri düzlemi iki gerçek tarayıcıyla denenmedi.
- **iOS Safari'de düz HTTP üzerinden `RTCPeerConnection`.**
- **ICS'in UDP/53'ü tutup tutmadığı** (Faz 1 captive portal için).

---

## 9. Fazlama

| Faz | İçerik | Kazanç | Risk |
|---|---|---|---|
| **0** ✅ | Self-AP (A→B) + `/lobby` çift QR | **"Wi-Fi gerektirmez" şartı burada tamamen karşılanır.** Transfer mevcut relay ile çalışır. | Düşük — üst katmanlara dokunulmaz |
| **1** ✅ | Captive portal: otomatik açılış (tek QR) | Katılma tek adıma indi | ICS DNS çakışması ölçüldü — yok |
| **2** ✅ | WebRTC P2P veri düzlemi + relay'e düşme | Sunucu diski yazılmaz, çift atlama yok | Orta — mDNS / izolasyon |
| **3** ✅ | BT-PAN seçilebilir taşıyıcı, USB tether dokümantasyonu | Wi-Fi radyosu tamamen kapalıyken çalışır | Düşük — manuel eşleştirme, 3 Mbps |
| **4** ✅ | Çoklu taşıyıcı, devretme + bildirim, elle değiştirme, `lan` taşıyıcısı | Tek bir yolun düşmesi kesinti değil, düşüş oluyor; host taşıyıcıyı portaldan seçiyor | Orta — kabul filtresi tek subnet yerine çoklu subnet mantığına geçti |

Faz 0, 1 ve 2 uygulandı. Faz 1'in yalnızca yarısı hayata geçti: otomatik açılış (tek QR) var,
`204` ile Android'i "internet var" sanmaya ikna etme yok — ikisi birbirini dışlıyor, çünkü
biri probe'a yönlendirme, diğeri 204 dönmeyi gerektiriyor. Hız tercih edildi.

Faz 3 (BT-PAN / USB) hâlâ açık ve manuel.

**Faz 0 tek başına talebi karşılar.** P2P (Faz 2) bir optimizasyondur, ön şart değil — bu ayrım
bilinçli: "router'sız çalışsın" ile "baytlar doğrudan aksın" bağımsız iki hedeftir ve
birbirlerini beklememelidir.
