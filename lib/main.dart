import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform, exit;
import 'dart:math';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:device_preview/device_preview.dart';
import 'package:flutter_windowmanager_plus/flutter_windowmanager_plus.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:geolocator/geolocator.dart';
import 'firebase_options.dart';

const int kInactivityMinutes = 2;

// ============================================================
//  CANAL DE SEGURIDAD NATIVO (RASP - Detección de ADB)
// ============================================================
class SecurityChannel {
  SecurityChannel._();
  static const MethodChannel _channel =
  MethodChannel('com.gael.movil/security');

  /// Consulta a Kotlin si Settings.Global.ADB_ENABLED está activo.
  /// Devuelve false si no es Android o si ocurre cualquier error.
  static Future<bool> isUsbDebuggingEnabled() async {
    if (!Platform.isAndroid) return false;
    try {
      final bool? result =
      await _channel.invokeMethod<bool>('isUsbDebuggingEnabled');
      return result ?? false;
    } on PlatformException catch (e) {
      debugPrint('[RASP] Error al consultar ADB: ${e.message}');
      return false;
    }
  }
}

// ============================================================
//  HANDLER DE BACKGROUND (top-level, requerido por FCM)
// ============================================================
@pragma('vm:entry-point')
Future<void> _firebaseMessagingBackgroundHandler(RemoteMessage message) async {
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  if (message.data['action'] == 'remote_wipe' &&
      message.data.containsKey('user_id')) {
    const storage = FlutterSecureStorage(
      aOptions: AndroidOptions(encryptedSharedPreferences: true),
    );
    final storedUserId = await storage.read(key: SecureStorageService.kUserId);
    if (storedUserId == message.data['user_id']) {
      await storage.deleteAll();
      debugPrint('[FCM BG] Wipe ejecutado para ${message.data['user_id']}');
    }
  }
}

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(
    options: DefaultFirebaseOptions.currentPlatform,
  );
  FirebaseMessaging.onBackgroundMessage(_firebaseMessagingBackgroundHandler);

  runApp(
    DevicePreview(
      enabled: !kReleaseMode,
      builder: (context) => const SecureLoginApp(),
    ),
  );
}

// ============================================================
//  ALMACENAMIENTO ENCRIPTADO
// ============================================================
class SecureStorageService {
  SecureStorageService._();
  static final SecureStorageService instance = SecureStorageService._();

  static const _storage = FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

  static const kToken         = 'auth_token';
  static const kUserId        = 'user_id';
  static const kFullName      = 'full_name';
  static const kEmail         = 'user_email';
  static const kCreditCard    = 'credit_card_last4';
  static const kFcmToken      = 'fcm_token';
  static const kInactivityMin = 'inactivity_minutes';
  static const kLastActivity  = 'last_activity';
  static const kLastLogout    = 'last_logout';

  Future<void> saveSession({
    required String token,
    required String userId,
    required int inactivityMinutes,
    String? fcmToken,
  }) async {
    await _storage.write(key: kToken,         value: token);
    await _storage.write(key: kUserId,        value: userId);
    await _storage.write(key: kFullName,      value: 'Gael Villalobos');
    await _storage.write(key: kEmail,         value: 'gael@upchiapas.edu.mx');
    await _storage.write(key: kCreditCard,    value: '4242');
    await _storage.write(key: kFcmToken,      value: fcmToken ?? '');
    await _storage.write(key: kInactivityMin, value: inactivityMinutes.toString());
    await _storage.write(key: kLastActivity,  value: DateTime.now().toIso8601String());
  }

  Future<void> saveLogout({
    required String token,
    required int inactivityMinutes,
  }) async {
    await _storage.write(key: kToken,         value: token);
    await _storage.write(key: kInactivityMin, value: inactivityMinutes.toString());
    await _storage.write(key: kLastLogout,    value: DateTime.now().toIso8601String());
  }

  Future<String?> getToken()            => _storage.read(key: kToken);
  Future<String?> getUserId()           => _storage.read(key: kUserId);
  Future<Map<String, String>> readAll() => _storage.readAll();
  Future<void> wipe()                   => _storage.deleteAll();
}

// ============================================================
//  SERVICIO FCM
// ============================================================
class FcmService {
  FcmService._();
  static final FcmService instance = FcmService._();

  final _messaging = FirebaseMessaging.instance;
  final _wipeController = StreamController<String>.broadcast();
  Stream<String> get onWipe => _wipeController.stream;

  Future<String?> initialize() async {
    await _messaging.requestPermission(alert: true, badge: true, sound: true);
    final token = await _messaging.getToken();
    debugPrint('[FCM] Token del dispositivo: $token');
    FirebaseMessaging.onMessage.listen(_handleMessage);
    FirebaseMessaging.onMessageOpenedApp.listen(_handleMessage);
    return token;
  }

  Future<void> _handleMessage(RemoteMessage message) async {
    final data = message.data;
    debugPrint('[FCM FG] Mensaje recibido: $data');
    if (data['action'] == 'remote_wipe' && data.containsKey('user_id')) {
      final storedUserId = await SecureStorageService.instance.getUserId();
      if (storedUserId == data['user_id']) {
        await SecureStorageService.instance.wipe();
        debugPrint('[FCM FG] Wipe ejecutado para ${data['user_id']}');
        _wipeController.add(data['user_id'] as String);
      } else {
        debugPrint('[FCM FG] user_id no coincide, wipe ignorado.');
      }
    }
  }

  void dispose() => _wipeController.close();
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
  bool _checkingEnvironment = true;
  bool _adbBlocked = false;

  @override
  void initState() {
    super.initState();
   // _secureScreen();
    _runRaspCheck();
  }
/*
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

 */

  // Verificación RASP: bloquea la app si ADB está activo,
  // excepto cuando se corre en modo debug (kDebugMode) para no
  // estorbar el flujo normal de desarrollo.
  Future<void> _runRaspCheck() async {
    if (kDebugMode) {
      setState(() => _checkingEnvironment = false);
      return;
    }

    final adbEnabled = await SecurityChannel.isUsbDebuggingEnabled();

    if (!mounted) return;
    setState(() {
      _checkingEnvironment = false;
      _adbBlocked = adbEnabled;
    });
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
      home: _checkingEnvironment
          ? const Scaffold(body: Center(child: CircularProgressIndicator()))
          : (_adbBlocked ? const AdbBlockedScreen() : const LoginScreen()),
    );
  }
}

// ============================================================
//  PANTALLA DE BLOQUEO POR DEPURACIÓN USB (RASP)
// ============================================================
class AdbBlockedScreen extends StatelessWidget {
  const AdbBlockedScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Builder(
              builder: (context) {
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  _showBlockingDialog(context);
                });
                return const Icon(
                  Icons.gpp_bad,
                  size: 80,
                  color: Colors.redAccent,
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  void _showBlockingDialog(BuildContext context) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return PopScope(
          canPop: false,
          child: AlertDialog(
            icon: const Icon(Icons.gpp_bad, color: Colors.red, size: 40),
            title: const Text('Entorno no seguro detectado'),
            content: const Text(
              'Esta aplicación ha detectado que la Depuración USB '
                  '(USB Debugging) está activa en este dispositivo.\n\n'
                  'Por políticas de seguridad de la información, no es posible '
                  'continuar mientras esta opción esté habilitada, ya que '
                  'representa un riesgo de intercepción y manipulación de datos.\n\n'
                  'Por favor, desactiva la Depuración USB desde:\n'
                  'Ajustes > Opciones de desarrollador > Depuración USB.',
            ),
            actions: [
              TextButton(
                onPressed: () {
                  if (Platform.isAndroid) {
                    SystemNavigator.pop();
                  } else {
                    exit(0);
                  }
                },
                child: const Text('Cerrar aplicación'),
              ),
            ],
          ),
        );
      },
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
  bool _isFakeGpsDetected  = false;
  bool _demoFakeGpsActive  = false;
  String? _fcmToken;

  static const _userId = 'user_gael_233392';

  @override
  void initState() {
    super.initState();
    _initFcm();
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

  Future<void> _initFcm() async {
    final token = await FcmService.instance.initialize();
    if (mounted) setState(() => _fcmToken = token);
  }

  String _generarToken() {
    final rnd   = Random.secure();
    final bytes = List<int>.generate(24, (_) => rnd.nextInt(256));
    return 'tok_${base64UrlEncode(bytes)}';
  }

  Future<void> _handleLoginAttempt() async {
    setState(() => _isCheckingSecurity = true);

    if (_demoFakeGpsActive) {
      await Future.delayed(const Duration(seconds: 1));
      if (!mounted) return;
      setState(() {
        _isFakeGpsDetected  = true;
        _isCheckingSecurity = false;
      });
      return;
    }

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
      final position = await Geolocator.getCurrentPosition(
        locationSettings:
        const LocationSettings(accuracy: LocationAccuracy.high),
      );

      if (position.isMocked) {
        if (!mounted) return;
        setState(() {
          _isFakeGpsDetected  = true;
          _isCheckingSecurity = false;
        });
      } else {
        final token = _generarToken();
        await SecureStorageService.instance.saveSession(
          token: token,
          userId: _userId,
          inactivityMinutes: kInactivityMinutes,
          fcmToken: _fcmToken,
        );
        if (!mounted) return;
        setState(() => _isCheckingSecurity = false);
        Navigator.of(context).pushReplacement(
          MaterialPageRoute(
            builder: (_) => HomeScreen(token: token, userId: _userId),
          ),
        );
      }
    } catch (e) {
      _showErrorSnackBar('Error al verificar la seguridad del dispositivo.');
      if (mounted) setState(() => _isCheckingSecurity = false);
    }
  }

  void _showErrorSnackBar(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), backgroundColor: Colors.redAccent),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isFakeGpsDetected) {
      return Scaffold(
        appBar: AppBar(
            title: const Text('Acceso Restringido'), centerTitle: true),
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
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
                  onPressed: () => setState(() {
                    _isFakeGpsDetected = false;
                    _demoFakeGpsActive = false;
                  }),
                  child: const Text('Volver al Login (Solo Desarrollo)'),
                ),
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
          padding: const EdgeInsets.all(24),
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
                        color: Colors.white, strokeWidth: 2),
                  )
                      : const Text('Iniciar Sesión',
                      style: TextStyle(fontSize: 16)),
                ),
              ),
              if (_fcmToken != null) ...[
                const SizedBox(height: 12),
                Container(
                  padding: const EdgeInsets.symmetric(
                      horizontal: 12, vertical: 8),
                  decoration: BoxDecoration(
                    color: Colors.blue.shade50,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      Icon(Icons.notifications_active,
                          size: 16, color: Colors.blue.shade700),
                      const SizedBox(width: 8),
                      const Expanded(
                        child: Text(
                          'FCM listo — borrado remoto habilitado',
                          style: TextStyle(
                              fontSize: 11, color: Colors.blueGrey),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const Spacer(),
              Container(
                padding: const EdgeInsets.symmetric(
                    horizontal: 16, vertical: 8),
                decoration: BoxDecoration(
                  color: Colors.grey.shade100,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: Colors.grey.shade300),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('Modo Demo: Fake GPS',
                        style: TextStyle(fontWeight: FontWeight.w500)),
                    Switch(
                      value: _demoFakeGpsActive,
                      activeColor: Colors.redAccent,
                      onChanged: (v) =>
                          setState(() => _demoFakeGpsActive = v),
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
//  HOME
// ============================================================
class HomeScreen extends StatefulWidget {
  final String token;
  final String userId;
  const HomeScreen({super.key, required this.token, required this.userId});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  Map<String, String> _stored = {};
  bool _loggingOut            = false;
  bool _wiped                 = false;
  DateTime _lastInteraction   = DateTime.now();
  Timer? _uiTimer;
  StreamSubscription<String>? _wipeSub;

  @override
  void initState() {
    super.initState();
    _loadStored();
    _uiTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    _wipeSub = FcmService.instance.onWipe.listen((userId) {
      if (!mounted) return;
      setState(() {
        _wiped  = true;
        _stored = {};
      });
      _showWipeDialog();
    });
  }

  Future<void> _loadStored() async {
    final data = await SecureStorageService.instance.readAll();
    if (!mounted) return;
    setState(() => _stored = data);
  }

  void _onActivity() => _lastInteraction = DateTime.now();

  int get _segundosRestantes {
    final transcurrido =
        DateTime.now().difference(_lastInteraction).inSeconds;
    final total    = kInactivityMinutes * 60;
    final restante = total - transcurrido;
    return restante < 0 ? 0 : restante;
  }

  Future<void> _cerrarSesion({String? motivo}) async {
    if (_loggingOut) return;
    _loggingOut = true;
    _uiTimer?.cancel();
    _wipeSub?.cancel();
    await SecureStorageService.instance.saveLogout(
      token: widget.token,
      inactivityMinutes: kInactivityMinutes,
    );
    if (!mounted) return;
    Navigator.of(context).pushReplacement(
      MaterialPageRoute(
          builder: (_) => LoginScreen(motivoCierre: motivo)),
    );
  }

  void _showWipeDialog() {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        icon:
        const Icon(Icons.delete_forever, color: Colors.red, size: 48),
        title: const Text('Borrado Remoto Ejecutado'),
        content: const Text(
          'Se recibió una orden de borrado remoto desde el servidor.\n\n'
              'Todos los datos sensibles han sido eliminados del dispositivo.',
          textAlign: TextAlign.center,
        ),
        actions: [
          FilledButton(
            style:
            FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () {
              Navigator.of(context).pop();
              _cerrarSesion(motivo: 'Sesión cerrada por borrado remoto.');
            },
            child: const Text('Entendido'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _uiTimer?.cancel();
    _wipeSub?.cancel();
    super.dispose();
  }

  String _labelLlave(String k) {
    const labels = {
      SecureStorageService.kToken:         'Token de sesión',
      SecureStorageService.kUserId:        'ID de usuario',
      SecureStorageService.kFullName:      'Nombre completo',
      SecureStorageService.kEmail:         'Correo electrónico',
      SecureStorageService.kCreditCard:    'Últimos 4 dígitos de tarjeta',
      SecureStorageService.kFcmToken:      'Token FCM del dispositivo',
      SecureStorageService.kInactivityMin: 'Inactividad permitida (min)',
      SecureStorageService.kLastActivity:  'Inicio de sesión',
      SecureStorageService.kLastLogout:    'Último cierre de sesión',
    };
    return labels[k] ?? k;
  }

  String _maskValue(String key, String value) {
    if (key == SecureStorageService.kToken && value.length > 16) {
      return '${value.substring(0, 12)}••••••••';
    }
    if (key == SecureStorageService.kFcmToken && value.length > 20) {
      return '${value.substring(0, 16)}••••••••';
    }
    if (key == SecureStorageService.kCreditCard) {
      return '•••• •••• •••• $value';
    }
    return value;
  }

  @override
  Widget build(BuildContext context) {
    final total    = kInactivityMinutes * 60;
    final restante = _segundosRestantes;
    final mm       = (restante ~/ 60).toString().padLeft(2, '0');
    final ss       = (restante % 60).toString().padLeft(2, '0');

    const sensibleKeys = [
      SecureStorageService.kUserId,
      SecureStorageService.kFullName,
      SecureStorageService.kEmail,
      SecureStorageService.kCreditCard,
    ];

    return InactivityDetector(
      timeout: Duration(minutes: kInactivityMinutes),
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
              onPressed: () =>
                  _cerrarSesion(motivo: 'Sesión cerrada.'),
            ),
          ],
        ),
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // Contador de inactividad
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
                              fontSize: 40,
                              fontWeight: FontWeight.bold),
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
                          style: TextStyle(
                              fontSize: 12, color: Colors.black54),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Tarjeta FCM con payload de prueba
                Card(
                  color: Colors.blue.shade50,
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(Icons.notifications_active,
                              color: Colors.blue.shade700),
                          const SizedBox(width: 8),
                          Text(
                            'Borrado remoto FCM activo',
                            style: TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Colors.blue.shade800),
                          ),
                        ]),
                        const SizedBox(height: 8),
                        Text(
                          'User ID: ${widget.userId}',
                          style: const TextStyle(
                              fontFamily: 'monospace', fontSize: 12),
                        ),
                        const SizedBox(height: 4),
                        const Text(
                          'Solo responde a mensajes cuyo user_id\ncoincida con el almacenado.',
                          style: TextStyle(
                              fontSize: 12, color: Colors.black54),
                        ),
                        const Divider(height: 20),
                        const Text(
                          'Payload para Firebase Console:',
                          style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w600),
                        ),
                        const SizedBox(height: 6),
                        Container(
                          padding: const EdgeInsets.all(10),
                          decoration: BoxDecoration(
                            color: Colors.grey.shade900,
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: SelectableText(
                            '{\n'
                                '  "message": {\n'
                                '    "token": "<FCM_DEVICE_TOKEN>",\n'
                                '    "data": {\n'
                                '      "action": "remote_wipe",\n'
                                '      "user_id": "${widget.userId}"\n'
                                '    }\n'
                                '  }\n'
                                '}',
                            style: const TextStyle(
                              fontFamily: 'monospace',
                              fontSize: 10,
                              color: Colors.greenAccent,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Campos sensibles
                Card(
                  child: Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(children: [
                          Icon(
                            _wiped
                                ? Icons.no_encryption
                                : Icons.lock_outline,
                            color: _wiped
                                ? Colors.red
                                : Colors.blueGrey,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _wiped
                                ? 'Datos eliminados remotamente'
                                : 'Datos sensibles protegidos',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: _wiped
                                  ? Colors.red
                                  : Colors.blueGrey,
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: 'Recargar',
                            icon: const Icon(Icons.refresh),
                            onPressed: _loadStored,
                          ),
                        ]),
                        const SizedBox(height: 8),
                        if (_wiped)
                          Container(
                            padding: const EdgeInsets.all(12),
                            decoration: BoxDecoration(
                              color: Colors.red.shade50,
                              borderRadius: BorderRadius.circular(8),
                              border:
                              Border.all(color: Colors.red.shade200),
                            ),
                            child: const Row(children: [
                              Icon(Icons.delete_forever,
                                  color: Colors.red),
                              SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  'El almacén seguro fue borrado remotamente.',
                                  style: TextStyle(color: Colors.red),
                                ),
                              ),
                            ]),
                          )
                        else
                          ...sensibleKeys.map((key) {
                            final value = _stored[key] ?? '—';
                            return Padding(
                              padding: const EdgeInsets.symmetric(
                                  vertical: 8),
                              child: Column(
                                crossAxisAlignment:
                                CrossAxisAlignment.start,
                                children: [
                                  Row(children: [
                                    const Icon(Icons.vpn_key,
                                        size: 14,
                                        color: Colors.blueGrey),
                                    const SizedBox(width: 4),
                                    Text(
                                      _labelLlave(key),
                                      style: const TextStyle(
                                          fontWeight: FontWeight.w600,
                                          fontSize: 13),
                                    ),
                                  ]),
                                  const SizedBox(height: 2),
                                  Text(
                                    _maskValue(key, value),
                                    style: const TextStyle(
                                        fontFamily: 'monospace',
                                        fontSize: 12,
                                        color: Colors.black87),
                                  ),
                                  const Divider(),
                                ],
                              ),
                            );
                          }),
                      ],
                    ),
                  ),
                ),

                const SizedBox(height: 16),

                // Token de sesión
                if (!_wiped)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text('Token de sesión',
                              style: TextStyle(
                                  fontWeight: FontWeight.bold)),
                          const SizedBox(height: 8),
                          SelectableText(
                            _maskValue(
                                SecureStorageService.kToken,
                                widget.token),
                            style: const TextStyle(
                                fontFamily: 'monospace',
                                fontSize: 12),
                          ),
                        ],
                      ),
                    ),
                  ),

                const SizedBox(height: 24),

                FilledButton.icon(
                  icon: const Icon(Icons.logout),
                  label: const Text('Cerrar sesión'),
                  onPressed: () =>
                      _cerrarSesion(motivo: 'Sesión cerrada.'),
                ),

                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}