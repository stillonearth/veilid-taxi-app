import 'package:flutter/material.dart';
import 'package:my_app/src/rust/frb_generated.dart';
import 'package:my_app/src/rust/api/taxi.dart';

Future<void> main() async {
  await RustLib.init();

  final app = await initializeApp(); // drop `await` if initializeApp is sync
  runApp(MyApp(p2pApp: app));
}

class MyApp extends StatelessWidget {
  final Vp2PApp p2pApp;

  const MyApp({super.key, required this.p2pApp});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData(
        primarySwatch: Colors.blue,
        brightness: Brightness.light,
      ),
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(brightness: Brightness.dark),
      home: Scaffold(
        body: Center(
          child: TextButton(
            onPressed: () {
              p2pApp.requestRide(lat: 33.0, lon: 33.0);
            },
            child: Text('Request Taxi'),
          ),
        ),
      ),
    );
  }
}
