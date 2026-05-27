import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import 'package:url_launcher/url_launcher.dart';


void main() {
  runApp(const RideGuardApp());
}

class RideGuardApp extends StatelessWidget {
  const RideGuardApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'RideGuard Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        scaffoldBackgroundColor: const Color(0xFF121212),
        primaryColor: Colors.redAccent,
        useMaterial3: true,
      ),
      home: const MainNavigationScreen(),
    );
  }
}

class MainNavigationScreen extends StatefulWidget {
  const MainNavigationScreen({super.key});

  @override
  State<MainNavigationScreen> createState() => _MainNavigationScreenState();
}

class _MainNavigationScreenState extends State<MainNavigationScreen> {

  // --- BLE ---
  BluetoothDevice? _device;
  BluetoothCharacteristic? _crashCharacteristic;
  BluetoothCharacteristic? _gpsCharacteristic;
  StreamSubscription? _connectionStateSubscription;
  bool _isConnected = false;
  bool _isScanning = false;
  bool _isReconnecting = false;

  // --- Crash / SOS ---
  bool _isCrashDetected = false;
  bool _isSosSent = false;
  int _countdownSeconds = 15;
  Timer? _countdownTimer;

  // --- GPS ---
  double _currentLat = 0.0;
  double _currentLng = 0.0;
  int _currentSpeed = 0;
  bool _hasGpsSignal = false;

  // --- Contact ---
  String _contactName = "Nume Contact";
  String _contactPhone = "0700000000";
  final TextEditingController _nameController = TextEditingController();
  final TextEditingController _phoneController = TextEditingController();

  // --- Nav ---
  int _currentIndex = 0;

  // ============================================================
  // LIFECYCLE
  // ============================================================

  @override
  void initState() {
    super.initState();
    _requestPermissions();
    _loadContact(); // <-- Încarcă contactul salvat la pornire
  }

  @override
  void dispose() {
    _countdownTimer?.cancel();
    _nameController.dispose();
    _phoneController.dispose();
    _connectionStateSubscription?.cancel();
    _isReconnecting = false;
    _device?.disconnect();
    super.dispose();
  }

  // ============================================================
  // CONTACT - PERSISTENT (shared_preferences)
  // ============================================================

  Future<void> _loadContact() async {
    final prefs = await SharedPreferences.getInstance();
    setState(() {
      _contactName = prefs.getString('contact_name') ?? 'Nume Contact';
      _contactPhone = prefs.getString('contact_phone') ?? '0700000000';
      _nameController.text = _contactName;
      _phoneController.text = _contactPhone;
    });
  }

  Future<void> _saveContact() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('contact_name', _nameController.text);
    await prefs.setString('contact_phone', _phoneController.text);
    setState(() {
      _contactName = _nameController.text;
      _contactPhone = _phoneController.text;
    });
  }

  // ============================================================
  // PERMISSIONS
  // ============================================================

  Future<void> _requestPermissions() async {
    await [
      Permission.bluetoothScan,
      Permission.bluetoothConnect,
      Permission.location,
    ].request();
  }

  // ============================================================
  // DISCORD ALERT
  // ============================================================

  Future<void> _sendDiscordAlert() async {
    final url = Uri.parse(
        'https://discord.com/api/webhooks/1509269795906912327/altceva');

    final payload = {
      "content":
          "🚨 **ALERTA RIDEGUARD!** 🚨\nMotociclistul a avut un impact!\n📍 Locație: $_currentLat, $_currentLng\n👤 Contact: $_contactName",
    };

    try {
      await http.post(
        url,
        headers: {"Content-Type": "application/json"},
        body: jsonEncode(payload),
      );
      debugPrint("Alertă trimisă pe Discord!");
    } catch (e) {
      debugPrint("Eroare trimitere Discord: $e");
    }
  }

  // ============================================================
  // BLE - SCAN & CONNECT
  // ============================================================

  void _startScan() async {
    setState(() { _isScanning = true; });
    await FlutterBluePlus.startScan(timeout: const Duration(seconds: 10));

    FlutterBluePlus.scanResults.listen((results) {
      for (ScanResult r in results) {
        if (r.device.advName == "RideGuard_Helmet" ||
            r.device.platformName == "RideGuard_Helmet") {
          FlutterBluePlus.stopScan();
          _connectToDevice(r.device);
          break;
        }
      }
    });

    // Timeout manual dacă nu găsim casca
    Future.delayed(const Duration(seconds: 11), () {
      if (mounted && _isScanning) {
        setState(() { _isScanning = false; });
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect(license: License.free);
      _device = device;

      // Ascultăm deconectările pentru auto-reconectare
      _connectionStateSubscription?.cancel();
      _connectionStateSubscription =
          device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() { _isConnected = false; });
          _startAutoReconnect(device);
        }
      });

      await _discoverServices(device);

      if (mounted) {
        setState(() {
          _isConnected = true;
          _isScanning = false;
          _isReconnecting = false;
        });
      }
    } catch (e) {
      debugPrint("EROARE CONECTARE: $e");
      if (mounted) {
        setState(() {
          _isScanning = false;
          _isReconnecting = false;
        });
      }
    }
  }

  Future<void> _discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString() == "4fafc201-1fb5-459e-8fcc-c5c9c331914b") {
        for (BluetoothCharacteristic c in service.characteristics) {

          // Canal Accident
          if (c.uuid.toString() == "beb5483e-36e1-4688-b7f5-ea07361b26a8") {
            _crashCharacteristic = c;
            await c.setNotifyValue(true);
            c.lastValueStream.listen((value) {
              if (value.isNotEmpty && value[0] == 49) {
                _triggerCrashSequence();
              }
            });
          }

          // Canal GPS
          else if (c.uuid.toString() ==
              "12345678-1234-5678-1234-56789abcdef0") {
            _gpsCharacteristic = c;
            await c.setNotifyValue(true);
            c.lastValueStream.listen((value) {
              if (value.isNotEmpty) {
                String gpsData = String.fromCharCodes(value);
                List<String> parts = gpsData.split(',');
                if (parts.length == 2 && mounted) {
                  setState(() {
                    _currentLat = double.tryParse(parts[0]) ?? 0.0;
                    _currentLng = double.tryParse(parts[1]) ?? 0.0;
                    _hasGpsSignal = (_currentLat != 0.0);
                  });
                }
              }
            });
          }
        }
      }
    }
  }

  // ============================================================
  // BLE - AUTO-RECONECTARE
  // ============================================================

  void _startAutoReconnect(BluetoothDevice device) async {
    if (_isReconnecting) return; // Evităm loop-uri multiple
    if (mounted) setState(() { _isReconnecting = true; });

    while (_isReconnecting && mounted) {
      await Future.delayed(const Duration(seconds: 3));
      if (!mounted) break;

      try {
        debugPrint(">>> Încerc reconectarea...");
        await _connectToDevice(device);
        break; // Dacă a reușit, ieșim
      } catch (_) {
        // Continuăm să încercăm
      }
    }
  }

  // ============================================================
  // CRASH SEQUENCE
  // ============================================================

  void _triggerCrashSequence() {
    if (_isCrashDetected) return;

    setState(() {
      _isCrashDetected = true;
      _isSosSent = false;
      _countdownSeconds = 15;
      _currentIndex = 0;
    });

    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          if (_countdownSeconds > 1) {
            _countdownSeconds--;
          } else {
            _countdownSeconds = 0;
            _isSosSent = true;
            _sendDiscordAlert();
            _countdownTimer?.cancel();
          }
        });
      }
    });
  }

  void _cancelAlarm() {
    _countdownTimer?.cancel();
    setState(() {
      _isCrashDetected = false;
      _isSosSent = false;
    });
    if (_crashCharacteristic != null) {
      _crashCharacteristic!.write([48]);
    }
  }

  // ============================================================
  // GOOGLE MAPS
  // ============================================================

  Future<void> _openInMaps() async {
    final uri = Uri.parse("geo:$_currentLat,$_currentLng?q=$_currentLat,$_currentLng");
    if (await canLaunchUrl(uri)) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  // ============================================================
  // BUILD
  // ============================================================

  @override
  Widget build(BuildContext context) {
    final List<Widget> screens = [
      _buildDashboardTab(),
      _buildMapTab(),
      _buildContactTab(),
    ];

    return Scaffold(
      body: SafeArea(child: screens[_currentIndex]),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          if (_isCrashDetected && !_isSosSent) return;
          setState(() { _currentIndex = index; });
        },
        backgroundColor: const Color(0xFF1E1E1E),
        selectedItemColor: Colors.redAccent,
        unselectedItemColor: Colors.grey,
        items: const [
          BottomNavigationBarItem(icon: Icon(Icons.dashboard), label: 'Status'),
          BottomNavigationBarItem(icon: Icon(Icons.speed), label: 'Telemetrie'),
          BottomNavigationBarItem(icon: Icon(Icons.contact_phone), label: 'Contact SOS'),
        ],
      ),
    );
  }

  // ============================================================
  // TAB 1: DASHBOARD
  // ============================================================

  Widget _buildDashboardTab() {
    // --- Ecran Crash ---
    if (_isCrashDetected) {
      return Container(
        color: _isSosSent ? Colors.black : const Color(0xFF7A0000),
        width: double.infinity,
        padding: const EdgeInsets.all(20),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(
              _isSosSent ? Icons.gpp_bad : Icons.warning_amber_rounded,
              size: 100,
              color: Colors.white,
            ),
            const SizedBox(height: 20),
            Text(
              _isSosSent ? "ALERTA SOS TRIMISĂ!" : "ACCIDENT DETECTAT!",
              style: const TextStyle(
                  fontSize: 32, fontWeight: FontWeight.bold, color: Colors.white),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            if (!_isSosSent) ...[
              const Text(
                "Se trimit coordonatele de urgență în:",
                style: TextStyle(fontSize: 18, color: Colors.white70),
              ),
              const SizedBox(height: 24),
              // CERC ANIMAT countdown
              Stack(
                alignment: Alignment.center,
                children: [
                  SizedBox(
                    width: 130,
                    height: 130,
                    child: CircularProgressIndicator(
                      value: _countdownSeconds / 15.0,
                      strokeWidth: 9,
                      color: Colors.yellowAccent,
                      backgroundColor: Colors.white24,
                    ),
                  ),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        "$_countdownSeconds",
                        style: const TextStyle(
                          fontSize: 52,
                          fontWeight: FontWeight.w900,
                          color: Colors.yellowAccent,
                        ),
                      ),
                      const Text(
                        "sec",
                        style: TextStyle(color: Colors.white70, fontSize: 14),
                      ),
                    ],
                  ),
                ],
              ),
            ] else ...[
              Card(
                color: Colors.grey[900],
                margin: const EdgeInsets.symmetric(vertical: 20),
                child: Padding(
                  padding: const EdgeInsets.all(15.0),
                  child: Column(
                    children: [
                      const Text("Pachet Cloud IP expediat cu succes!",
                          style: TextStyle(
                              color: Colors.greenAccent,
                              fontWeight: FontWeight.bold)),
                      const SizedBox(height: 5),
                      Text("Contact alertat: $_contactName",
                          style: const TextStyle(color: Colors.white)),
                      Text(
                          "Locație: ${_currentLat.toStringAsFixed(5)}, ${_currentLng.toStringAsFixed(5)}",
                          style: const TextStyle(color: Colors.white70)),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 40),
            ElevatedButton(
              onPressed: _cancelAlarm,
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.white,
                foregroundColor: Colors.black,
                padding:
                    const EdgeInsets.symmetric(horizontal: 40, vertical: 15),
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(30)),
              ),
              child: Text(
                _isSosSent ? "FOTO / RESETEAZĂ" : "SUNT OK - ANULEAZĂ SOS",
                style:
                    const TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      );
    }

    // --- Ecran Normal ---
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Text("RideGuard Pro",
              style: TextStyle(
                  fontSize: 36,
                  fontWeight: FontWeight.bold,
                  color: Colors.white)),
          const SizedBox(height: 5),
          const Text("Sistem Inteligent de Protecție Moto",
              style: TextStyle(fontSize: 14, color: Colors.grey)),
          const SizedBox(height: 50),

          // STATUS BLE (vizibil mereu, inclusiv când e reconectare)
          Container(
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              color: _isConnected
                  ? Colors.green.withOpacity(0.1)
                  : _isReconnecting
                      ? Colors.orange.withOpacity(0.1)
                      : Colors.red.withOpacity(0.1),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _isConnected
                    ? Colors.green
                    : _isReconnecting
                        ? Colors.orange
                        : Colors.red,
              ),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircleAvatar(
                  radius: 8,
                  backgroundColor: _isConnected
                      ? Colors.green
                      : _isReconnecting
                          ? Colors.orange
                          : Colors.red,
                ),
                const SizedBox(width: 12),
                Text(
                  _isConnected
                      ? "Casca Moto: CONECTATĂ"
                      : _isReconnecting
                          ? "Casca Moto: RECONECTARE..."
                          : "Casca Moto: DECONECTATĂ",
                  style: const TextStyle(
                      fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),

          const SizedBox(height: 60),

          if (!_isConnected && !_isReconnecting)
            ElevatedButton.icon(
              onPressed: _isScanning ? null : _startScan,
              icon: _isScanning
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(
                          color: Colors.white, strokeWidth: 2))
                  : const Icon(Icons.bluetooth),
              label: Text(_isScanning ? "Se caută casca..." : "Conectează prin BLE"),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.blueAccent,
                foregroundColor: Colors.white,
                padding:
                    const EdgeInsets.symmetric(horizontal: 30, vertical: 15),
              ),
            )
          else if (_isReconnecting)
            const Column(
              children: [
                CircularProgressIndicator(color: Colors.orange),
                SizedBox(height: 15),
                Text("Se reconectează automat la cască...",
                    style: TextStyle(color: Colors.orange)),
              ],
            )
          else
            Column(
              children: [
                Icon(Icons.security,
                    size: 80,
                    color: _hasGpsSignal
                        ? Colors.greenAccent
                        : Colors.orangeAccent),
                const SizedBox(height: 10),
                Text(
                  _hasGpsSignal
                      ? "Sistem Complet Operațional"
                      : "Se calibrează senzorii (Așteptare GPS)...",
                  style: const TextStyle(color: Colors.grey),
                ),
              ],
            ),
        ],
      ),
    );
  }

  // ============================================================
  // TAB 2: TELEMETRIE
  // ============================================================

  Widget _buildMapTab() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Telemetrie",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const Text("Date transmise live din casca moto",
              style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(
                child: _buildTelemetryCard(
                    "VITEZĂ", "$_currentSpeed", "km/h", Colors.orangeAccent),
              ),
              const SizedBox(width: 15),
              Expanded(
                child: _buildTelemetryCard(
                  "STATUS MPU",
                  _isCrashDetected ? "IMPACT" : "ACTIV",
                  "Senzor OK",
                  _isCrashDetected ? Colors.redAccent : Colors.greenAccent,
                ),
              ),
            ],
          ),
          const SizedBox(height: 30),
          const Text("Coordonate Modul NEO-6M",
              style: TextStyle(
                  fontWeight: FontWeight.bold, color: Colors.white70)),
          const SizedBox(height: 10),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 30),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1E1E),
              borderRadius: BorderRadius.circular(15),
              border: Border.all(color: Colors.grey[800]!),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  _isCrashDetected
                      ? Icons.fmd_bad
                      : (_hasGpsSignal
                          ? Icons.satellite_alt
                          : Icons.satellite_alt_outlined),
                  size: 50,
                  color: _isCrashDetected
                      ? Colors.red
                      : (_hasGpsSignal ? Colors.blueAccent : Colors.orange),
                ),
                const SizedBox(height: 15),
                Text(
                  _isCrashDetected
                      ? "LOCAȚIE IMPACT SALVATĂ"
                      : (_hasGpsSignal
                          ? "Conexiune Satelit Stabilă"
                          : "Căutare Sateliți (Afară)..."),
                  style: TextStyle(
                    color: _isCrashDetected
                        ? Colors.red
                        : (_hasGpsSignal ? Colors.greenAccent : Colors.orange),
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 15),
                Text("LAT: ${_currentLat.toStringAsFixed(6)}",
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 18,
                        color: Colors.white)),
                Text("LNG: ${_currentLng.toStringAsFixed(6)}",
                    style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 18,
                        color: Colors.white)),
                const SizedBox(height: 20),

                // BUTON GOOGLE MAPS (vizibil doar când avem semnal GPS)
                if (_hasGpsSignal)
                  ElevatedButton.icon(
                    onPressed: _openInMaps,
                    icon: const Icon(Icons.map_outlined),
                    label: const Text("Deschide în Google Maps"),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.blueAccent,
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 24, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12)),
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetryCard(
      String title, String value, String subtitle, Color color) {
    return Container(
      padding: const EdgeInsets.all(15),
      decoration: BoxDecoration(
          color: const Color(0xFF1E1E1E),
          borderRadius: BorderRadius.circular(15)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 5),
          FittedBox(
            fit: BoxFit.scaleDown,
            child: Text(value,
                style: TextStyle(
                    fontSize: 32,
                    fontWeight: FontWeight.bold,
                    color: color)),
          ),
          const SizedBox(height: 2),
          Text(subtitle,
              style: const TextStyle(fontSize: 12, color: Colors.grey)),
        ],
      ),
    );
  }

  // ============================================================
  // TAB 3: CONTACT SOS
  // ============================================================

  Widget _buildContactTab() {
    return Padding(
      padding: const EdgeInsets.all(20.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text("Contact de Urgență (SOS)",
              style: TextStyle(fontSize: 28, fontWeight: FontWeight.bold)),
          const Text(
              "Persoana care va fi notificată automat prin protocol internet în caz de impact.",
              style: TextStyle(color: Colors.grey, fontSize: 13)),
          const SizedBox(height: 30),
          TextField(
            controller: _nameController,
            decoration: const InputDecoration(
                labelText: 'Nume Contact', border: OutlineInputBorder()),
          ),
          const SizedBox(height: 20),
          TextField(
            controller: _phoneController,
            keyboardType: TextInputType.phone,
            decoration: const InputDecoration(
                labelText: 'Număr Telefon / Protocol',
                border: OutlineInputBorder()),
          ),
          const SizedBox(height: 30),
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: () {
                FocusScope.of(context).unfocus();
                _saveContact(); // <-- Salvează persistent
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                      content: Text("Datele de urgență au fost salvate!")),
                );
              },
              icon: const Icon(Icons.save),
              label:
                  const Text("Salvează Setările", style: TextStyle(fontSize: 16)),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.redAccent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 15),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
