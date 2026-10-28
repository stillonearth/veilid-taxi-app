import 'dart:async';

import 'package:flutter/material.dart';
import 'package:my_app/src/rust/frb_generated.dart';
import 'package:my_app/src/rust/api/logs.dart';
import 'package:my_app/src/rust/api/taxi.dart';
import 'package:async_button_handler/async_button_handler.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:geolocator/geolocator.dart';
import 'package:latlong2/latlong.dart';

Future<void> main() async {
  await RustLib.init();
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(brightness: Brightness.dark),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  // Veilid log lines shown while the network starts.
  final List<String> _logs = [];
  late final StreamSubscription<String> _logSub;

  // Completes once the app is created and connected to the veilid network.
  late final Future<Vp2PApp> _network = _connect();

  @override
  void initState() {
    super.initState();
    // Subscribe before startup begins (the build below starts it).
    _logSub = veilidLogStream().listen(
      (line) => setState(() {
        _logs.add(line);
        if (_logs.length > 500) _logs.removeAt(0);
      }),
    );
  }

  @override
  void dispose() {
    _logSub.cancel();
    super.dispose();
  }

  Future<Vp2PApp> _connect() async {
    final app = await initializeApp();
    await app.connectToNetwork();
    // Logs are only shown on the startup screen.
    await _logSub.cancel();
    return app;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Vp2PApp>(
      future: _network,
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return Scaffold(
            body: Column(
              children: [
                Expanded(
                  child: Center(
                    child: Text(
                      'Failed to connect to network: ${snapshot.error}',
                    ),
                  ),
                ),
                Expanded(child: LogPanel(lines: _logs)),
              ],
            ),
          );
        }

        if (!snapshot.hasData) {
          return Scaffold(
            body: Column(
              children: [
                const Expanded(child: Center(child: LoadingAnimation())),
                Expanded(child: LogPanel(lines: _logs)),
              ],
            ),
          );
        }

        return MapScreen(p2pApp: snapshot.data!);
      },
    );
  }
}

class MapScreen extends StatefulWidget {
  final Vp2PApp p2pApp;

  const MapScreen({super.key, required this.p2pApp});

  @override
  State<MapScreen> createState() => _MapScreenState();
}

class _MapScreenState extends State<MapScreen> {
  final _mapController = MapController();
  bool _mapReady = false;

  // Position reported by the device, if it could be detected.
  LatLng? _current;
  // Pickup point picked by tapping the map; overrides the detected position.
  LatLng? _selected;

  LatLng? get _pickup => _selected ?? _current;

  late final StreamSubscription<DriverRideRequestInfo> _offerSub;
  // Offer popups are shown one at a time, in arrival order.
  Future<void> _offerDialogs = Future.value();

  @override
  void initState() {
    super.initState();
    _detectPosition();
    _offerSub = widget.p2pApp.subscribeToP2PEvents().listen((offer) {
      _offerDialogs = _offerDialogs.then((_) => _showOfferDialog(offer));
    });
  }

  @override
  void dispose() {
    _offerSub.cancel();
    super.dispose();
  }

  Future<void> _acceptOffer(DriverRideRequestInfo offer) =>
      _respondToOffer(offer, accept: true);

  Future<void> _declineOffer(DriverRideRequestInfo offer) =>
      _respondToOffer(offer, accept: false);

  Future<void> _respondToOffer(
    DriverRideRequestInfo offer, {
    required bool accept,
  }) async {
    final messenger = ScaffoldMessenger.of(context);
    try {
      await widget.p2pApp.respondToDriverRideRequest(
        offer: offer,
        accept: accept,
      );
      messenger.showSnackBar(
        SnackBar(content: Text(accept ? 'Offer accepted' : 'Offer declined')),
      );
    } catch (e) {
      messenger.showSnackBar(
        SnackBar(content: Text('Failed to respond to driver: $e')),
      );
    }
  }

  Future<void> _showOfferDialog(DriverRideRequestInfo offer) async {
    if (!mounted) return;
    final request = offer.pedestrianRideRequest;
    final accepted = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Driver response'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              offer.message.isEmpty
                  ? 'A driver offers to take your ride.'
                  : offer.message,
            ),
            const SizedBox(height: 12),
            Text(
              'Max price: \$${(request.maxPriceCents / 100).toStringAsFixed(2)}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            SelectableText(
              'Request: ${request.requestKey}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Decline'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Accept'),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (accepted == true) {
      await _acceptOffer(offer);
    } else {
      await _declineOffer(offer);
    }
  }

  Future<void> _detectPosition() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) return;
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) {
        permission = await Geolocator.requestPermission();
      }
      if (permission == LocationPermission.denied ||
          permission == LocationPermission.deniedForever) {
        return;
      }
      final pos = await Geolocator.getCurrentPosition();
      if (!mounted) return;
      final current = LatLng(pos.latitude, pos.longitude);
      setState(() => _current = current);
      if (_mapReady && _selected == null) {
        _mapController.move(current, 15);
      }
    } catch (e) {
      debugPrint('Could not detect position: $e');
    }
  }

  Future<void> requestRide() async {
    final pickup = _pickup;
    if (pickup == null) return;
    try {
      final ride = await widget.p2pApp.requestRide(
        lat: pickup.latitude,
        lon: pickup.longitude,
      );
      if (!mounted) return;
      await _showRideDialog(ride);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text('Taxi request failed: $e')));
    }
  }

  Future<void> _showRideDialog(RideRequestInfo ride) {
    Widget row(String label, String value) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(label, style: Theme.of(context).textTheme.labelMedium),
          SelectableText(value),
        ],
      ),
    );

    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Taxi requested'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              row(
                'Pickup',
                '${ride.lat.toStringAsFixed(6)}, ${ride.lon.toStringAsFixed(6)}',
              ),
              row('Request key', ride.requestKey),
              row('Route ID', ride.routeId),
              row('Board key', ride.boardKey),
              row('Board slot', '${ride.slot}'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget map(BuildContext context) {
    return FlutterMap(
      mapController: _mapController,
      options: MapOptions(
        initialCenter: LatLng(
          51.509364,
          -0.128928,
        ), // Center the map over London, UK
        initialZoom: 9.2,
        onMapReady: () {
          _mapReady = true;
          if (_current != null && _selected == null) {
            _mapController.move(_current!, 15);
          }
        },
        onTap: (_, point) => setState(() => _selected = point),
      ),
      children: [
        TileLayer(
          // Bring your own tiles
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png', // For demonstration only
          userAgentPackageName: 'com.ztaxi.app',
        ),
        MarkerLayer(
          markers: [
            if (_current != null)
              Marker(
                point: _current!,
                width: 22,
                height: 22,
                child: Container(
                  decoration: BoxDecoration(
                    color: Colors.blue,
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 3),
                    boxShadow: const [
                      BoxShadow(color: Colors.black38, blurRadius: 4),
                    ],
                  ),
                ),
              ),
            if (_selected != null)
              Marker(
                point: _selected!,
                width: 40,
                height: 40,
                alignment: Alignment.topCenter,
                child: const Icon(
                  Icons.location_pin,
                  color: Colors.red,
                  size: 40,
                ),
              ),
          ],
        ),
        RichAttributionWidget(
          // Include a stylish prebuilt attribution widget that meets all requirments
          attributions: [
            TextSourceAttribution(
              'OpenStreetMap contributors',
              // onTap: () => launchUrl(Uri.parse('https://openstreetmap.org/copyright')), // (external)
            ),
            // Also add images...
          ],
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final pickup = _pickup;
    return Scaffold(
      body: Stack(
        children: [
          map(context),
          Positioned(
            top: 16,
            left: 16,
            right: 16,
            child: SafeArea(
              child: Card(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    pickup == null
                        ? 'Tap the map to set your pickup point'
                        : 'Pickup: ${pickup.latitude.toStringAsFixed(5)}, '
                              '${pickup.longitude.toStringAsFixed(5)}'
                              '${_selected == null ? ' (current position)' : ''}',
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.endFloat,
      floatingActionButton: pickup == null
          ? null
          : AsyncButtonHandler<Future<void>>(
              overlayLoading: false,
              onPressed: requestRide,
              loadingChild: const CircularProgressIndicator(),
              widget: const Text('Request Taxi'),
            ),
    );
  }
}

// Taxi icon that bounces over an expanding ripple while the network starts.
class LoadingAnimation extends StatefulWidget {
  const LoadingAnimation({super.key});

  @override
  State<LoadingAnimation> createState() => _LoadingAnimationState();
}

class _LoadingAnimationState extends State<LoadingAnimation>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1500),
  )..repeat();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.primary;
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        // Bounce: up and back down once per cycle.
        final bounce = -12 * Curves.easeInOut.transform(1 - (2 * t - 1).abs());
        final dots = '.' * (1 + (t * 3).floor() % 3);
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              width: 140,
              height: 140,
              child: Stack(
                alignment: Alignment.center,
                children: [
                  // Expanding, fading ripple.
                  Container(
                    width: 60 + 80 * t,
                    height: 60 + 80 * t,
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: color.withValues(alpha: 1 - t),
                        width: 3,
                      ),
                    ),
                  ),
                  Transform.translate(
                    offset: Offset(0, bounce),
                    child: Icon(
                      Icons.local_taxi,
                      size: 56,
                      color: Colors.amber,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 16),
            SizedBox(
              width: 260,
              child: Text(
                'Connecting to Veilid network$dots',
                style: Theme.of(context).textTheme.titleMedium,
              ),
            ),
          ],
        );
      },
    );
  }
}

// Scrolling, monospaced view of log lines that follows the newest line.
class LogPanel extends StatefulWidget {
  final List<String> lines;

  const LogPanel({super.key, required this.lines});

  @override
  State<LogPanel> createState() => _LogPanelState();
}

class _LogPanelState extends State<LogPanel> {
  final _scroll = ScrollController();

  @override
  void didUpdateWidget(LogPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Stick to the bottom unless the user scrolled up to read.
    if (_scroll.hasClients &&
        _scroll.position.pixels >= _scroll.position.maxScrollExtent - 24) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
      });
    }
  }

  @override
  void dispose() {
    _scroll.dispose();
    super.dispose();
  }

  Color _colorFor(String line) {
    if (line.startsWith('ERROR')) return Colors.redAccent;
    if (line.startsWith('WARN')) return Colors.amber;
    return Colors.white70;
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: Colors.black87,
        borderRadius: BorderRadius.circular(8),
      ),
      child: SelectionArea(
        child: ListView.builder(
          controller: _scroll,
          itemCount: widget.lines.length,
          itemBuilder: (context, i) => Text(
            widget.lines[i],
            style: TextStyle(
              fontFamily: 'monospace',
              fontSize: 12,
              color: _colorFor(widget.lines[i]),
            ),
          ),
        ),
      ),
    );
  }
}
