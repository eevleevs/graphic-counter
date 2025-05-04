// ignore_for_file: use_build_context_synchronously

import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:download/download.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart' hide EmailAuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_ui_auth/firebase_ui_auth.dart';
import 'package:firebase_ui_oauth_google/firebase_ui_oauth_google.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:get_storage/get_storage.dart';
import 'package:path_provider/path_provider.dart';

import 'firebase_options.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp(options: DefaultFirebaseOptions.currentPlatform);
  await GetStorage.init();

  // Configure Firebase UI Auth
  FirebaseUIAuth.configureProviders([
    GoogleProvider(clientId: clientId),
  ]);

  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Counter App',
      theme: ThemeData(
        brightness: Brightness.light,
        textTheme: GoogleFonts.notoSansTextTheme(),
        primaryColor: Colors.teal,
        useMaterial3: true,
      ),
      darkTheme: ThemeData(
        brightness: Brightness.dark,
        textTheme: GoogleFonts.notoSansTextTheme(
            ThemeData(brightness: Brightness.dark).textTheme),
        primaryColor: Colors.teal,
        useMaterial3: true,
      ),
      initialRoute: '/',
      routes: {
        '/': (context) => const AuthGate(),
        '/home': (context) => const MainPage(),
      },
    );
  }
}

class AuthGate extends StatelessWidget {
  const AuthGate({super.key});

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<User?>(
      stream: FirebaseAuth.instance.authStateChanges(),
      builder: (context, snapshot) {
        // Show loading indicator while connection state is active
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const Scaffold(
            body: Center(
              child: CircularProgressIndicator(),
            ),
          );
        }

        // User is not signed in
        if (!snapshot.hasData) {
          return const LoginScreen();
        }

        // User is signed in
        return const MainPage();
      },
    );
  }
}

class LoginScreen extends StatelessWidget {
  const LoginScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return SignInScreen(
      providers: [
        GoogleProvider(clientId: clientId),
      ],
      actions: [
        AuthStateChangeAction<SignedIn>((context, state) {
          Navigator.pushReplacementNamed(context, '/home');
        }),
      ],
      headerBuilder: (context, constraints, shrinkOffset) {
        return Padding(
          padding: const EdgeInsets.all(20),
          child: Text(
            'Welcome! Please sign in.',
            style: Theme.of(context).textTheme.headlineSmall,
          ),
        );
      },
      footerBuilder: (context, action) {
        return const Padding(
          padding: EdgeInsets.only(top: 16),
          child: Text(
            'By signing in, you agree to our terms and conditions.',
            style: TextStyle(color: Colors.grey),
          ),
        );
      },
    );
  }
}

class MainPage extends StatefulWidget {
  const MainPage({super.key});

  @override
  MainPageState createState() => MainPageState();
}

/// Generates an equidistant color palette in HSL space
/// starting from a base HSL color
List<Color> generateEquidistantPalette({
  required HSLColor baseColor,
  required int count,
}) {
  final List<Color> colors = [];
  final double step = 360.0 / count;

  for (int i = 0; i < count; i++) {
    // Calculate the new hue with even spacing around the color wheel
    final double newHue = (baseColor.hue + (i * step)) % 360;

    // Create a new HSLColor with the new hue
    final HSLColor hslColor = baseColor.withHue(newHue);

    // Add the converted Color to our list
    colors.add(hslColor.toColor());
  }

  return colors;
}

class MainPageState extends State<MainPage> {
  final periods = {
    'days': 1,
    'weeks': 7,
    'months': 30,
    'seasons': 90,
    'years': 365
  };
  final numberOfPeriods = 12;

  List<Color> colors = [];
  var counters = SplayTreeMap();
  var exportPath = '';
  double maxY = 0;
  var period = GetStorage().read('period') ?? 'days';
  Map<String, List<FlSpot>> spots = {};

  late DocumentReference<Map<String, dynamic>> userRef;
  late StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> userStream;

  @override
  void initState() {
    super.initState();
    userRef = FirebaseFirestore.instance
        .collection('users')
        .doc(FirebaseAuth.instance.currentUser?.uid);
    userStream = userRef.snapshots().listen((snapshot) {
      if (!snapshot.exists) {
        userRef.set({'counters': {}});
        return;
      }
      final data = snapshot.data() as Map<String, dynamic>;
      counters = SplayTreeMap.of(data['counters'] ?? {});
      colors = counters.isNotEmpty
          ? generateEquidistantPalette(
              baseColor: Theme.of(context).brightness == Brightness.dark
                  ? HSLColor.fromAHSL(1, 0, 1, 0.7)
                  : HSLColor.fromAHSL(1, 0, 0.7, 0.5),
              count: counters.length,
            )
          : [];
      prepareChart();
    });

    if (!kIsWeb) {
      getExternalStorageDirectory().then((externalStorage) {
        exportPath = '${externalStorage?.path}/data.json';
      });
    }
  }

  @override
  void dispose() {
    userStream.cancel();
    super.dispose();
  }

  void decreaseCounter(name, day) {
    if (!counters[name].containsKey(day)) return;
    userRef.update({
      'counters.$name.$day': counters[name][day] > 1
          ? counters[name][day] - 1
          : FieldValue.delete()
    });
  }

  void importData() async {
    Navigator.pop(context);
    var json = '';
    if (kIsWeb) {
      final result = await FilePicker.platform.pickFiles();
      if (result == null) return;
      json = String.fromCharCodes(result.files.single.bytes ?? []);
    } else {
      final file = File(exportPath);
      if (!file.existsSync()) {
        ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
          content: Text('Export file not present'),
        ));
        return;
      }
      json = file.readAsStringSync();
    }
    Map<String, dynamic> importedData = {};
    try {
      importedData = jsonDecode(json);
    } on TypeError catch (_) {
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
        content: Text('Invalid input data'),
      ));
      return;
    }
    final result = await showModalActionSheet(
      context: context,
      actions: [
        const SheetAction(key: 'overwrite', label: 'Overwrite current data'),
        const SheetAction(key: 'merge', label: 'Merge with current data'),
      ],
    );
    if (!['overwrite', 'merge'].contains(result)) return;
    Map<String, dynamic> data = {};
    if (result == 'overwrite') {
      data = {'counters': importedData['counters'] ?? {}};
    } else {
      data = {'counters': Map.from(counters)};
      for (final counter in (importedData['counters'] ?? {}).entries) {
        for (final entry in counter.value.entries) {
          data['counters'].putIfAbsent(counter.key, () => {})[entry.key] =
              entry.value;
        }
      }
    }
    userRef.update(data);
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('Data imported')));
  }

  void increaseCounter(name, day) =>
      userRef.update({'counters.$name.$day': (counters[name][day] ?? 0) + 1});

  void newCounter() async {
    var alreadyUsed = false;
    String? name;
    while (true) {
      name = (await showTextInputDialog(
          context: context,
          textFields: const [DialogTextField()],
          message: alreadyUsed
              ? '$name is already used'
              : 'name the new counter'))?[0];
      if ([null, ''].contains(name)) return;
      if (!counters.containsKey(name)) break;
      alreadyUsed = true;
    }
    userRef.update({
      'counters.$name': {today(): 0}
    });
  }

  void prepareChart() {
    setState(() {
      maxY = 3; // min value for Y axis maximum
      spots = {};
      final today_ = DateTime.parse(today());
      for (final name in counters.keys) {
        final counter = {};
        for (final entry in counters[name].entries) {
          final difference =
              DateTime.parse(entry.key).difference(today_).inDays ~/
                  periods[period]!;
          if (difference > -numberOfPeriods) {
            counter[difference] = (counter[difference] ?? 0) + entry.value;
          }
        }
        spots[name] = [];
        for (var i = 1 - numberOfPeriods; i <= 0; i++) {
          spots[name]?.add(FlSpot(i.toDouble(), (counter[i] ?? 0).toDouble()));
        }
        maxY = [maxY, ...counter.values]
            .reduce((a, b) => a > b ? a : b)
            .toDouble();
      }
    });
  }

  String today({int offset = 0}) => DateTime.now()
      .add(Duration(days: offset))
      .toString()
      .substring(0, 10)
      .replaceAll('-', '');

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    return Scaffold(
        appBar: AppBar(
            actions: List<Widget>.of(periods.keys.map((value) => Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(
                      width: 1,
                      style: period == value
                          ? BorderStyle.solid
                          : BorderStyle.none,
                      color: Theme.of(context).hintColor),
                ),
                child: IconButton(
                  splashColor: Colors.transparent,
                  tooltip: 'last 12 $value',
                  icon: Text(value[0].toUpperCase(),
                      style: TextStyle(
                          color: Theme.of(context)
                              .appBarTheme
                              .actionsIconTheme
                              ?.color,
                          fontSize: 16)),
                  onPressed: () {
                    period = value;
                    GetStorage().write('period', value);
                    prepareChart();
                  },
                ))))),
        drawer: SizedBox(
            width: 200,
            child: Drawer(
                child: ListView(
              children: [
                ListTile(
                  leading: const Icon(Icons.cloud_download),
                  title: const Text('Export data'),
                  onTap: () async {
                    Navigator.pop(context);
                    final json = jsonEncode({'counters': counters});
                    if (kIsWeb) {
                      download(
                          Stream.fromIterable(json.codeUnits), 'data.json');
                    } else {
                      File(exportPath).writeAsString(json);
                      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                          content: Text('Data exported to $exportPath'),
                          duration: const Duration(seconds: 8)));
                    }
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_upload),
                  title: const Text('Import data'),
                  onTap: importData,
                ),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.logout),
                  title: const Text('Sign out'),
                  onTap: () {
                    FirebaseAuth.instance.signOut();
                    Navigator.pop(context);
                  },
                ),
              ],
            ))),
        floatingActionButton: FloatingActionButton(
            onPressed: newCounter, child: const Icon(Icons.add)),
        body: counters.isEmpty
            ? const Center(
                child: Text('Add the first counter with the + button'))
            : Flex(
                direction: portrait ? Axis.vertical : Axis.horizontal,
                children: [
                    Expanded(
                        flex: portrait ? 45 : 60,
                        child: Container(
                            color: Theme.of(context).canvasColor,
                            child: Container(
                                margin:
                                    const EdgeInsets.fromLTRB(0, 20, 20, 15),
                                child: LineChart(LineChartData(
                                  titlesData: FlTitlesData(
                                      bottomTitles: AxisTitles(
                                        axisNameWidget: Text(period),
                                        sideTitles: SideTitles(
                                          getTitlesWidget: (value, meta) =>
                                              Text(value.toString()),
                                          interval: 1,
                                          showTitles: true,
                                        ),
                                      ),
                                      rightTitles: AxisTitles(
                                        sideTitles:
                                            SideTitles(showTitles: false),
                                      ),
                                      topTitles: AxisTitles(
                                        sideTitles:
                                            SideTitles(showTitles: false),
                                      )),
                                  backgroundColor:
                                      Theme.of(context).canvasColor,
                                  borderData: FlBorderData(show: false),
                                  lineTouchData: LineTouchData(
                                      touchTooltipData: LineTouchTooltipData(
                                          fitInsideHorizontally: true,
                                          fitInsideVertically: true)),
                                  lineBarsData: counters.keys
                                      .mapIndexed((index, name) =>
                                          LineChartBarData(
                                              color: colors[index],
                                              isCurved: true,
                                              preventCurveOverShooting: true,
                                              spots: spots[name]!))
                                      .toList(),
                                  maxY: maxY,
                                ))))),
                    Expanded(
                        flex: portrait ? 55 : 40,
                        child: ListView.separated(
                          padding: const EdgeInsets.only(top: 10, bottom: 80),
                          separatorBuilder: (_, __) => Divider(
                              height: 5, color: Theme.of(context).canvasColor),
                          itemCount: counters.keys.length,
                          itemBuilder: (context, index) {
                            final color = colors[index];
                            final name = List.of(counters.keys)[index];
                            return ListTile(
                              tileColor: Theme.of(context).cardColor,
                              title: Text(
                                name,
                                style: TextStyle(color: color),
                              ),
                              trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    InkWell(
                                        onTap: () =>
                                            increaseCounter(name, today()),
                                        onLongPress: () => increaseCounter(
                                            name, today(offset: -1)),
                                        child: Ink(
                                            height: 40,
                                            width: 40,
                                            child:
                                                Icon(Icons.add, color: color))),
                                    InkWell(
                                        onTap: () =>
                                            decreaseCounter(name, today()),
                                        onLongPress: () => decreaseCounter(
                                            name, today(offset: -1)),
                                        child: Ink(
                                            height: 40,
                                            width: 40,
                                            child: Icon(Icons.remove,
                                                color: color))),
                                    InkWell(
                                        onTap: () async {
                                          if (await showModalActionSheet(
                                                  context: context,
                                                  actions: [
                                                    SheetAction(
                                                        key: 'remove',
                                                        label: 'Remove $name')
                                                  ]) ==
                                              'remove') {
                                            userRef.update({
                                              'counters.$name':
                                                  FieldValue.delete()
                                            });
                                          }
                                        },
                                        child: Ink(
                                            height: 40,
                                            width: 40,
                                            child: Icon(Icons.close,
                                                color: color))),
                                  ]),
                            );
                          },
                        )),
                  ]));
  }
}
