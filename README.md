

## 1. Prezentare Generală

RideGuard Pro este un sistem embedded de siguranță activă pentru motocicliști, compus dintr-o unitate hardware montată pe cască și o aplicație mobilă Flutter pentru Android.

Sistemul monitorizează în timp real mișcările bruste ale căștii folosind un accelerometru și un model de machine learning. La detectarea unui impact, aplicația pornește o numărătoare inversă de 15 secunde. Dacă motociclistul nu anulează alarma, se trimite automat o alertă cu coordonatele GPS ale locației impactului.

---

## 2. Arhitectura Sistemului

```
[MPU6050] --I2C--> [ESP32] --BLE--> [Telefon Android]
[NEO-6M]  --UART->    |                    |
                      |              [Aplicatie Flutter]
                 [Model ML]                |
                                   [Discord Webhook]
                                   [Google Maps]
```

---

## 3. Componente Hardware

### 3.1 Microcontroler — ESP32
- **Procesor:** Xtensa LX6 dual-core, 240 MHz
- **Memorie:** 520 KB SRAM
- **Conectivitate:** Wi-Fi 802.11 b/g/n, Bluetooth 4.2 BLE
- **Tensiune de operare:** 3.3V
- **Rol:** procesează datele senzorilor, rulează modelul ML, gestionează comunicația BLE și parsează datele GPS

### 3.2 Accelerometru/Giroscop — MPU6050
- **Interfață:** I2C
- **Pini conectați:** SDA → GPIO21, SCL → GPIO22
- **Alimentare:** 3.3V
- **Configurație:** range accelerometru ±8G, filtru 21 Hz
- **Rol:** măsoară accelerația pe 3 axe pentru detecția impactului

### 3.3 Modul GPS — NEO-6M
- **Interfață:** UART (Serial2)
- **Pini conectați:** TX (GPS) → GPIO16 (RX2), RX (GPS) → GPIO17 (TX2)
- **Baud rate:** 9600
- **Alimentare:** 3.3V
- **Rol:** furnizează coordonate GPS (latitudine, longitudine)

---

## 4. Firmware ESP32

### 4.1 Biblioteci utilizate
| Bibliotecă | Rol |
|---|---|
| `Adafruit_MPU6050` | Driver senzor accelerometru |
| `TinyGPS++` | Parsare NMEA sentences de la NEO-6M |
| `BLEDevice / BLEServer` | Stack Bluetooth Low Energy |
| `Arduino.h / Wire.h` | Framework de bază |

### 4.2 Parametri de eșantionare ML
- **SAMPLE_PERIOD_MS:** 10 ms (100 Hz)
- **WINDOW_SIZE:** definit în `model.h`
- **STEP_SIZE:** definit în `model.h`

### 4.3 Pipeline de detecție impact

**Pas 1:** Citire date accelerometru la 100 Hz

**Pas 2:** Calculare magnitudine vector de accelerație
```
mag = sqrt(ax² + ay² + az²)
```

**Pas 3:** Stocare în buffer circular de dimensiune `WINDOW_SIZE`

**Pas 4:** La fiecare `STEP_SIZE` eșantioane, extragere features:
- `mean_mag` — media magnitudinilor din fereastră
- `std_mag` — deviația standard
- `p2p_mag` — peak-to-peak (max − min)

**Pas 5:** Aplicare model de regresie logistică:
```
decision = W0 + W1·mean + W2·std + W3·p2p
prob     = 1 / (1 + e^(−decision))
```

**Pas 6:** Dacă `prob > 0.85` ȘI `p2p > 2.5` → **IMPACT DETECTAT**

### 4.4 Protocol BLE

| Câmp | Valoare |
|---|---|
| Nume dispozitiv | `RideGuard_Helmet` |
| Service UUID | `4fafc201-1fb5-459e-8fcc-c5c9c331914b` |

**Caracteristica 1 — Canal Accident**
- UUID: `beb5483e-36e1-4688-b7f5-ea07361b26a8`
- Proprietăți: READ, NOTIFY, WRITE
- Valori: `"1"` = impact detectat / `"0"` = resetat

**Caracteristica 2 — Canal GPS**
- UUID: `12345678-1234-5678-1234-56789abcdef0`
- Proprietăți: READ, NOTIFY, WRITE
- Format date: `"latitudine,longitudine"` (ex: `"44.426767,26.102538"`)
- Actualizare: la fiecare fix GPS valid de la NEO-6M

---

## 5. Antrenarea Modelului ML

### 5.1 Surse de date

Modelul de regresie logistică a fost antrenat pe două categorii de date cu origini diferite:

**Date normale (comportament de mers normal)**
Înregistrate manual pe motocicletă în condiții reale de rulare. Acestea captează profilul de vibrații și accelerații tipice unui mers normal, inclusiv gropi, frânări ușoare și viraje. Datele au fost colectate direct de pe senzorul MPU6050 montat pe cască.

**Date de accident (impact)**
Provenite din dataset-ul public de pe Kaggle:
> *Accelerometer Falling Detection* — Felliphn Nascimento
> https://www.kaggle.com/datasets/felliphnascimento/accelerometer-falling-detection

Dataset-ul conține înregistrări de accelerometru pentru detecția căzăturilor umane. Deoarece profilul unui impact pe motocicletă și cel al unei căzături umane prezintă similarități în forma semnalului (vârf brusc de magnitudine urmat de haos), datele au fost adaptate pentru contextul proiectului.

### 5.2 Procesul de adaptare a datelor

Atât datele normale cât și cele de accident au trecut printr-un proces de **downscaling** pentru a se potrivi cu condițiile de demo și cu rangul senzorului configurat (±8G):

1. **Normalizare** — valorile brute din dataset au fost aduse în același sistem de unități cu datele de pe MPU6050 (unități G, nu m/s²)
2. **Downscaling amplitudine** — magnitudinile au fost scalate proporțional pentru a se încadra în pragurile modelului (`p2p > 2.5`) fără a depăși rangul senzorului
3. **Downscaling date normale** — și datele de mers normal au fost reduse proporțional pentru a menține separabilitatea dintre clase
4. **Extragere features** — din fiecare fereastră temporală s-au extras `mean_mag`, `std_mag` și `p2p_mag`, aceleași features folosite în inferența de pe ESP32
5. **Antrenare regresie logistică** — modelul a fost antrenat în Python (scikit-learn), iar coeficienții rezultați (W0, W1, W2, W3) au fost exportați manual în `model.h`

### 5.3 Structura fișierului model.h

```cpp
namespace ShakeModel {
    constexpr float W0 = ...;  // bias
    constexpr float W1 = ...;  // coeficient mean_mag
    constexpr float W2 = ...;  // coeficient std_mag
    constexpr float W3 = ...;  // coeficient p2p_mag
    constexpr uint16_t WINDOW_SIZE = ...;
    constexpr uint16_t STEP_SIZE   = ...;
}
```

### 5.4 Prag de decizie

Modelul folosește un prag dublu pentru a reduce fals pozitivele:
- **prob > 0.85** — probabilitate ridicată clasificată de model
- **p2p > 2.5** — confirmare prin magnitudine brută

Ambele condiții trebuie îndeplinite simultan pentru a declanșa alarma.

---

## 6. Aplicația Mobilă — Flutter

### 6.1 Informații generale
- **Framework:** Flutter (Dart)
- **Platformă:** Android
- **Temă:** Dark mode, accent roșu

### 6.2 Pachete utilizate
| Pachet | Rol |
|---|---|
| `flutter_blue_plus` | Comunicație Bluetooth Low Energy |
| `permission_handler` | Gestionare permisiuni Android runtime |
| `http` | Trimitere alertă Discord (POST webhook) |
| `shared_preferences` | Persistență contact de urgență |
| `url_launcher` | Deschidere Google Maps cu coordonate GPS |

### 6.3 Structura interfeței

**Tab 1 — Status (Dashboard)**
- Indicator conectare BLE: CONECTAT / DECONECTAT / RECONECTARE
- Ecran normal: buton conectare, status GPS, iconiță securitate
- Ecran crash: alertă roșie, numărătoare inversă animată (cerc progress), buton anulare SOS, confirmare trimitere alertă

**Tab 2 — Telemetrie**
- Card viteză (rezervat, valoare 0 la demo)
- Card status senzor MPU6050
- Coordonate GPS live (LAT / LNG cu 6 zecimale)
- Buton „Deschide în Google Maps" (vizibil doar cu semnal GPS)

**Tab 3 — Contact SOS**
- Câmp nume contact de urgență
- Câmp număr de telefon
- Buton salvare (persistă prin reporniri ale aplicației)

### 6.4 Flux detecție și alertă

1. ESP32 detectează impact → trimite `"1"` pe canalul BLE Accident
2. Aplicația primește notificarea BLE
3. Se activează ecranul de crash, pornește countdown 15 secunde
4. Dacă utilizatorul **NU** apasă „SUNT OK":
   - Se trimite POST la Discord webhook cu mesaj de alertă, coordonate GPS și numele contactului
5. Dacă utilizatorul apasă „SUNT OK":
   - Se anulează countdown-ul
   - Se trimite `"0"` înapoi la ESP32 pe canalul BLE
   - Se resetează interfața

### 6.5 Auto-reconectare BLE
- La deconectarea căștii, aplicația intră automat în mod de reconectare (indicator portocaliu pe dashboard)
- Încearcă reconectarea la fiecare 3 secunde
- Nu necesită intervenție manuală din partea utilizatorului

### 6.6 Permisiuni Android (AndroidManifest.xml)
- `BLUETOOTH`, `BLUETOOTH_ADMIN`
- `BLUETOOTH_SCAN` (neverForLocation), `BLUETOOTH_CONNECT`
- `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION`
- `INTERNET`
- Bloc `<queries>` pentru url_launcher (scheme: `https`, `geo`)

---

## 7. Configurare și Instalare

### 7.1 Firmware ESP32
1. Instalează PlatformIO sau Arduino IDE
2. Adaugă bibliotecile: Adafruit MPU6050, TinyGPS++, ESP32 BLE Arduino
3. Asigură-te că fișierul `model.h` cu greutățile modelului ML (W0, W1, W2, W3, WINDOW_SIZE, STEP_SIZE) este prezent
4. Compilează și flash-uiește pe ESP32
5. Conectează hardware conform schemei electrice (secțiunea 8)

### 7.2 Aplicație Flutter
1. Instalează Flutter SDK
2. Rulează: `flutter pub get`
3. Conectează telefon Android cu USB debugging activat
4. Rulează: `flutter run`
5. Sau generează APK: `flutter build apk --release`

### 7.3 Prima utilizare
1. Pornește ESP32 (alimentează casca)
2. Deschide aplicația pe telefon
3. Tab Status → apasă „Conectează prin BLE"
4. Aplicația găsește automat `RideGuard_Helmet`
5. Setează contactul de urgență în Tab Contact SOS
6. Așteaptă semnal GPS (mesaj „Conexiune Satelit Stabilă")

---

## 8. Schema Electrică — Rezumat Conexiuni

**ESP32 ↔ MPU6050**
| ESP32 | MPU6050 |
|---|---|
| 3.3V | VCC |
| GND | GND |
| GPIO21 | SDA |
| GPIO22 | SCL |

**ESP32 ↔ NEO-6M GPS**
| ESP32 | NEO-6M |
|---|---|
| 3.3V | VCC |
| GND | GND |
| GPIO16 (RX2) | TX |
| GPIO17 (TX2) | RX |

---

## 9. Limitări Cunoscute

- Aplicația nu are notificări push când rulează în background
- Alertele SOS sunt trimise doar prin Discord webhook; nu există integrare SMS sau apel telefonic lipsind o cartela
- Modelul ML a fost antrenat pe date scalate pentru demo; precizia în condiții reale de trafic poate varia
- Datele de accident provin dintr-un dataset de detecție căzături umane, adaptat pentru contextul moto

---

*RideGuard Pro — Documentație Tehnică*
