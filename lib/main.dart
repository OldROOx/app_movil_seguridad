import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, exit;
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_preview/device_preview.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';

/// Minutos de inactividad permitidos antes de cerrar la sesión.
/// Cámbialo a tu gusto. Para probar rápido usa 1.
const int kInactivityMinutes = 2;

void main() {
  runApp(
    DevicePreview(
      enabled: !kReleaseMode, // activo solo en debug
      builder: (context) => const SecureLoginApp(),
    ),
  );
}

// ============================================================
//  ALMACENAMIENTO ENCRIPTADO (Keystore en Android)
// ============================================================
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const _kToken = 'auth_token';
  static const _kInactivityMinutes = 'inactivity_minutes';
  static const _kLastActivity = 'last_activity';
  static const _kLastLogout = 'last_logout';

  /// Al iniciar sesión: guarda token + variable de tiempo encriptados.
  Future<void> saveSession({
    required String token,
    required int inactivityMinutes,
  }) async {
    await _storage.write(key: _kToken, value: token);
    await _storage.write(
        key: _kInactivityMinutes, value: inactivityMinutes.toString());
    await _storage.write(
        key: _kLastActivity, value: DateTime.now().toIso8601String());
  }

  /// Al cerrar sesión: conserva el token y guarda el momento del cierre.
  Future<void> saveLogout({
    required String token,
    required int inactivityMinutes,
  }) async {
    await _storage.write(key: _kToken, value: token);
    await _storage.write(
        key: _kInactivityMinutes, value: inactivityMinutes.toString());
    await _storage.write(
        key: _kLastLogout, value: DateTime.now().toIso8601String());
  }

  Future<String?> getToken() => _storage.read(key: _kToken);
  Future<Map<String, String>> readAll() => _storage.readAll();
  Future<void> clearToken() => _storage.delete(key: _kToken);
  Future<void> wipe() => _storage.deleteAll();
}

// ============================================================
//  DETECTOR DE INACTIVIDAD
// ============================================================
class InactivityDetector extends StatefulWidget {
  final Widget child;
  final Duration timeout;
  final VoidCallback onTimeout;
  final VoidCallback? onActivity;

  const InactivityDetector({
    super.key,
    required this.child,
    required this.timeout,
    required this.onTimeout,
    this.onActivity,
  });

  @override
  State<InactivityDetector> createState() => _InactivityDetectorState();
}

class _InactivityDetectorState extends State<InactivityDetector> {
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _restartTimer();
  }

  void _restartTimer() {
    _timer?.cancel();
    _timer = Timer(widget.timeout, widget.onTimeout);
  }

  void _onUserInteraction([_]) {
    widget.onActivity?.call();
    _restartTimer();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: _onUserInteraction,
      onPointerMove: _onUserInteraction,
      onPointerHover: _onUserInteraction,
      onPointerSignal: _onUserInteraction,
      child: widget.child,
    );
  }
}

// ============================================================
//  APP
// ============================================================
class SecureLoginApp extends StatefulWidget {
  const SecureLoginApp({super.key});

  @override
  State<SecureLoginApp> createState() => _SecureLoginAppState();
}

class _SecureLoginAppState extends State<SecureLoginApp> {
  @override
  void initState() {
    super.initState();
    _secureScreen(); // FLAG_SECURE a nivel de app: protege todas las pantallas.
  }

  Future<void> _secureScreen() async {
    if (!kIsWeb && Platform.isAndroid) {
      try {
        await FlutterWindowManagerPlus.addFlags(
          FlutterWindowManagerPlus.FLAG_SECURE,
        );
      } catch (e) {
        debugPrint('No se pudo aplicar FLAG_SECURE: $e');
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      useInheritedMediaQuery: true,
      locale: DevicePreview.locale(context),
      builder: DevicePreview.appBuilder,
      debugShowCheckedModeBanner: false,
      title: 'Login Seguro',
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blueGrey),
        useMaterial3: true,
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          filled: true,
          fillColor: Colors.grey.shade50,
        ),
      ),
      home: const LoginScreen(),
    );
  }
}

// ============================================================
//  LOGIN
// ============================================================
class LoginScreen extends StatefulWidget {
  final String? motivoCierre;
  const LoginScreen({super.key, this.motivoCierre});

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  bool _isCheckingSecurity = false;
  bool _isFakeGpsDetected = false;
  bool _demoFakeGpsActive = false;

  @override
  void initState() {
    super.initState();
    if (widget.motivoCierre != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(widget.motivoCierre!),
            backgroundColor: Colors.orange.shade800,
          ),
        );
      });
    }
  }

  /// Genera un token simulado. En producción vendría de tu backend.
  String _generarToken() {
    final rnd = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return 'tok_${base64UrlEncode(bytes)}';
  }

  Future<void> _handleLoginAttempt() async {
    setState(() => _isCheckingSecurity = true);

    // 1. Modo demostrativo de Fake GPS
    if (_demoFakeGpsActive) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() {
        _isFakeGpsDetected = true;
        _isCheckingSecurity = false;
      });
      return;
    }

    // 2. Verificación real con Geolocator
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      _showErrorSnackBar('Debes activar el GPS para iniciar sesión.');
      if (mounted) setState(() => _isCheckingSecurity = false);
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        _showErrorSnackBar('Permisos de ubicación denegados.');
        if (mounted) setState(() => _isCheckingSecurity = false);
        return;
      }
    }

    try {
      Position position = await Geolocator.getCurrentPosition(
        locationSettings: const LocationSettings(
          accuracy: LocationAccuracy.high,
        ),
      );

      if (position.isMocked) {
        if (!mounted) return;
        setState(() {
          _isFakeGpsDetected = true;
          _isCheckingSecurity = false;
        });
      } else {
        // Login exitoso: generar token, guardarlo encriptado e iniciar sesión.
        final token = _generarToken();
        await SecureStorageService.instance.saveSession(
          token: token,
          inactivityMinutes: kInactivityMinutes,
        );
        if (!mounted) return;
        setState(() => _isCheckingSecurity = false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(builder: (_) => HomeScreen(token: token)),
        );
      }
    } catch (e) {
      _showErrorSnackBar('Error al verificar la seguridad del dispositivo.');
      if (mounted) setState(() => _isCheckingSecurity = false);
    }
  }

  void _showErrorSnackBar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isFakeGpsDetected) {
      return Scaffold(
        appBar: AppBar(
          title: const Text('Acceso Restringido'),
          centerTitle: true,
        ),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Icon(Icons.gpp_bad, size: 80, color: Colors.redAccent),
                const SizedBox(height: 20),
                const Text(
                  'Dispositivo no seguro.\nSe detectó una ubicación simulada.',
                  textAlign: TextAlign.center,
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 30),
                ElevatedButton.icon(
                  icon: const Icon(Icons.exit_to_app),
                  label: const Text('Cerrar Aplicación'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.redAccent,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    if (Platform.isAndroid) {
                      SystemNavigator.pop();
                    } else {
                      exit(0);
                    }
                  },
                ),
                TextButton(
                  onPressed: () {
                    setState(() {
                      _isFakeGpsDetected = false;
                      _demoFakeGpsActive = false;
                    });
                  },
                  child: const Text('Volver al Login (Solo Desarrollo)'),
                )
              ],
            ),
          ),
        ),
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('Acceso Seguro'),
        centerTitle: true,
        elevation: 0,
      ),
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(24.0),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Icon(Icons.shield_outlined,
                  size: 64, color: Colors.blueGrey),
              const SizedBox(height: 32),
              const TextField(
                decoration: InputDecoration(
                  labelText: 'Usuario',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              const TextField(
                obscureText: true,
                decoration: InputDecoration(
                  labelText: 'Contraseña',
                  prefixIcon: Icon(Icons.lock_outline),
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                height: 50,
                child: ElevatedButton(
                  onPressed:
                  _isCheckingSecurity ? null : _handleLoginAttempt,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.blueGrey,
                    foregroundColor: Colors.white,
                  ),
                  child: _isCheckingSecurity
                      ? const SizedBox(
                    height: 24,
                    width: 24,
                    child: CircularProgressIndicator(
                      color: Colors.white,
                      strokeWidth: 2,
                    ),
                  )
                      : const Text('Iniciar Sesión',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
              const Spacer(),
              Container(
                padding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text(
                      'Modo Demo: Fake GPS',
                      style: TextStyle(fontWeight: FontWeight.w500),
                    ),
                    Switch(
                      value: _demoFakeGpsActive,
                      activeColor: Colors.redAccent,
                      onChanged: (value) {
                        setState(() {
                          _demoFakeGpsActive = value;
                        });
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ============================================================
//  HOME (sesión activa + inactividad + datos encriptados)
// ============================================================
class HomeScreen extends StatefulWidget {
  final String token;
  const HomeScreen({super.key, required this.token});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, String> _stored = {};
  bool _loggingOut = false;
  DateTime _lastInteraction = DateTime.now();
  Timer? _uiTimer;

  @override
  void initState() {
    super.initState();
    _loadStored();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  Future<void> _loadStored() async {
    final data = await SecureStorageService.instance.readAll();
    if (!mounted) return;
    setState(() => _stored = data);
  }

  void _onActivity() {
    _lastInteraction = DateTime.now();
  }

  int get _segundosRestantes {
    final transcurrido =
        DateTime.now().difference(_lastInteraction).inSeconds;
    final total = kInactivityMinutes * 60;
    final restante = total - transcurrido;
    return restante < 0 ? 0 : restante;
  }

  Future<void> _cerrarSesion({String? motivo}) async {
    if (_loggingOut) return;
    _loggingOut = true;
    _uiTimer?.cancel();

    await SecureStorageService.instance.saveLogout(
      token: widget.token,
      inactivityMinutes: kInactivityMinutes,
    );

    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (_) => LoginScreen(motivoCierre: motivo)),
    );
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    super.dispose();
  }

  String _labelLlave(String k) {
    switch (k) {
      case 'auth_token':
        return 'Token (auth_token)';
      case 'inactivity_minutes':
        return 'Inactividad permitida (min)';
      case 'last_activity':
        return 'Inicio de sesión';
      case 'last_logout':
        return 'Último cierre de sesión';
      default:
        return k;
    }
  }

  @override
  Widget build(BuildContext context) {
    final total = kInactivityMinutes * 60;
    final restante = _segundosRestantes;
    final mm = (restante ~/ 60).toString().padLeft(2, '0');
    final ss = (restante % 60).toString().padLeft(2, '0');

    return InactivityDetector(
      timeout: const Duration(minutes: kInactivityMinutes),
      onTimeout: () =>
          _cerrarSesion(motivo: 'Sesión cerrada por inactividad.'),
      onActivity: _onActivity,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Sesión activa'),
          centerTitle: true,
          actions: [
            IconButton(
              tooltip: 'Cerrar sesión',
              icon: const Icon(Icons.logout),
              onPressed: () => _cerrarSesion(motivo: 'Sesión cerrada.'),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(20),
                    child: Column(
                      children: [
                        const Icon(Icons.timer_outlined,
                            size: 40, color: Colors.blueGrey),
                        const SizedBox(height: 12),
                        const Text('Cierre por inactividad en'),
                        const SizedBox(height: 6),
                        Text(
                          '$mm:$ss',
                          style: const TextStyle(
                              fontSize: 40, fontWeight: FontWeight.bold),
                        ),
                        const SizedBox(height: 12),
                        LinearProgressIndicator(
                          value: total == 0 ? 0 : restante / total,
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(4),
                        ),
                        const SizedBox(height: 8),
                        const Text(
                          'Toca o desplázate para reiniciar el contador.',
                          style:
                          TextStyle(fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text('Token de sesión',
                            style:
                            TextStyle(fontWeight: FontWeight.bold)),
                        const SizedBox(height: 8),
                        SelectableText(
                          widget.token,
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 16),
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          mainAxisAlignment:
                          MainAxisAlignment.spaceBetween,
                          children: [
                            const Expanded(
                              child: Text('Datos en almacén encriptado',
                                  style: TextStyle(
                                      fontWeight: FontWeight.bold)),
                            ),
                            IconButton(
                              tooltip: 'Recargar',
                              icon: const Icon(Icons.refresh),
                              onPressed: _loadStored,
                            ),
                          ],
                        ),
                        const SizedBox(height: 4),
                        if (_stored.isEmpty)
                          const Text('Sin datos.')
                        else
                          ..._stored.entries.map(
                                (e) => Padding(
                              padding:
                              const EdgeInsets.symmetric(vertical: 6),
                              child: Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Text(_labelLlave(e.key),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13)),
                                  Text(e.value,
                                      style: const TextStyle(
                                          fontFamily: 'monospace',
                                          fontSize: 12,
                                          color: Colors.black87)),
                                ],
                              ),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión'),
                  onPressed: () => _cerrarSesion(motivo: 'Sesión cerrada.'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}