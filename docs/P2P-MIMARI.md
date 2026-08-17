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
| **B** (uç durum) | Wi-Fi **radyosu** hiç kullanılmayacak. | **L0-C / L0-D** — USB tether ve Bluetooth PAN, dokümante edilmiş yedek |

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

### C. USB tethering (RNDIS) — manuel katman
Telefonu kabloyla bağlayıp USB tethering açmak PC'ye yeni bir subnet verir. PC tarafından
script'lenemez, kullanıcı hareketi ister. Wi-Fi radyosu kapalıyken tek hızlı yol budur.

### D. Bluetooth PAN — acil durum
Bu makinede adaptör var ama link hızı **3 Mbps** (~0.3 MB/s gerçek). Not ve küçük PDF için
kabul edilebilir, dosya transferi için değil. Otomatikleştirilmez, sadece dokümante edilir.

### Seçim mantığı

```
Start-Bearer:
  1. Self-AP istendiyse:  A dene -> olmazsa B dene
  2. Zaten bağlı Wi-Fi (STA) varsa: mevcut v2 davranışı
  3. Hiçbiri yoksa: hata + kullanıcıya C/D talimatı
Stop-Portal:  AP'yi de kapat (StopPortal.vbs genişletilecek)
```

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

### QR #2'yi yok etme: captive portal (opsiyonel, feature-flag'li)
Android `http://connectivitycheck.gstatic.com/generate_204`, iOS
`http://captive.apple.com/hotspot-detect.html` yoklar. Bu yoklamayı yakalayıp portala
yönlendirirsek telefon **kendiliğinden** portalı açar — tek QR yeter.

Bunun için `192.168.137.1:53`'te DNS'e sahip olmak gerekir. Yoklama anında UDP/53 boştu, **ama
hotspot açıkken ICS kendi DNS proxy'sini oraya bağlıyor** — çakışma ihtimali yüksek.
Bu yüzden captive portal **bağımlılık değil, iyileştirme** olarak tasarlanır; tutmazsa iki-QR
akışı sorunsuz devam eder.

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

## 8. Saha testi sırası (yazmadan önce doğrulanacaklar)

Tasarımın üç yerinde dürüst belirsizlik var. Kod yazmadan önce sırayla test edilmeli:

1. **Hotspot admin gerektiriyor mu?** `StartTetheringAsync()`'i yükseltilmemiş PowerShell'den çağır. Gerekiyorsa ya UAC prompt'u ya B yoluna kayış.
2. **Ethernet çıkınca ne oluyor?** Kabloyu çek, `GetInternetConnectionProfile()` null mı? Null ise A düşer, B'nin gerçekten çalıştığı doğrulanmalı — gemi senaryosunun tamamı buna bağlı.
3. **İki telefon birbirini görüyor mu?** AP'ye iki cihaz bağla, birinden diğerinin `192.168.137.x` adresine istek at. Görmüyorsa client isolation var, P2P istemci↔istemci yolu tasarımdan çıkar.

Ek doğrulamalar: ICS'in UDP/53'ü tutup tutmadığı (captive portal), iOS Safari'de düz HTTP
üzerinden `RTCPeerConnection` davranışı.

---

## 9. Fazlama

| Faz | İçerik | Kazanç | Risk |
|---|---|---|---|
| **0** | Self-AP (A→B) + `/lobby` çift QR | **"Wi-Fi gerektirmez" şartı burada tamamen karşılanır.** Transfer mevcut relay ile çalışır. | Düşük — üst katmanlara dokunulmaz |
| **1** | Captive portal: otomatik açılış + `204` ile Android'i ağda tutma | Tek QR; Android'in AP'yi bırakması engellenir | Orta — ICS DNS çakışması |
| **2** | WebRTC P2P veri düzlemi + relay'e düşme | Sunucu diski yazılmaz, çift atlama yok | Orta — mDNS / izolasyon |
| **3** | BT-PAN acil taşıyıcı, USB tether dokümantasyonu | Wi-Fi radyosu tamamen kapalıyken çalışır | Düşük — manuel |

**Faz 0 tek başına talebi karşılar.** P2P (Faz 2) bir optimizasyondur, ön şart değil — bu ayrım
bilinçli: "router'sız çalışsın" ile "baytlar doğrudan aksın" bağımsız iki hedeftir ve
birbirlerini beklememelidir.
