import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:download/download.dart';
import 'package:file_picker/file_picker.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_signin_button/flutter_signin_button.dart';
import 'package:flutter_palette/flutter_palette.dart';
import 'package:get_storage/get_storage.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  await GetStorage.init();
  runApp(const MyApp());
}

Future<UserCredential> signInWithGoogle() async {
  final GoogleSignInAccount? googleUser = await GoogleSignIn().signIn();
  final GoogleSignInAuthentication? googleAuth = await googleUser?.authentication;
  final credential = GoogleAuthProvider.credential(
    accessToken: googleAuth?.accessToken,
    idToken: googleAuth?.idToken,
  );
  return await FirebaseAuth.instance.signInWithCredential(credential);
}

class MyApp extends StatefulWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  State<MyApp> createState() => _MyAppState();
}

class _MyAppState extends State<MyApp> {
  User? user;
  var initialised = false;

  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((User? _user) {
      setState(() {
        user = _user;
        if (!initialised && user == null) signInWithGoogle();
        initialised = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.light().copyWith(brightness: Brightness.light, primaryColor: Colors.teal),
      darkTheme: ThemeData.dark().copyWith(brightness: Brightness.dark, primaryColor: Colors.teal),
      themeMode: ThemeMode.system,
      home: !initialised
          ? Container()
          : user == null
              ? const SignInPage()
              : const MainPage(),
    );
  }
}

class SignInPage extends StatelessWidget {
  const SignInPage({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return Scaffold(
        body: Center(
            child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      SignInButton(Buttons.Google, onPressed: signInWithGoogle),
    ])));
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final periods = {'days': 1, 'weeks': 7, 'months': 30, 'years': 365};
  final numberOfPeriods = 12;

  var colors = [];
  var counters = SplayTreeMap();
  var exportPath = '';
  double maxY = 0;
  var period = GetStorage().read('period') ?? 'days';
  Map<String, List<FlSpot>> spots = {};
  var _today = 0;

  late DocumentReference<Map<String, dynamic>> userRef;
  late StreamSubscription<DocumentSnapshot<Map<String, dynamic>>> userStream;

  @override
  void initState() {
    super.initState();
    userRef =
        FirebaseFirestore.instance.collection('users').doc(FirebaseAuth.instance.currentUser?.uid);
    userStream = userRef.snapshots().listen((snapshot) {
      if (!snapshot.exists) {
        userRef.set({'counters': {}});
        return;
      }
      final data = snapshot.data() as Map<String, dynamic>;
      counters = SplayTreeMap.of(data['counters']);
      colors = counters.isNotEmpty
          ? ColorPalette.polyad(
              Theme.of(context).brightness == Brightness.dark
                  ? const HSLColor.fromAHSL(1, 0, 1, 0.7).toColor()
                  : const HSLColor.fromAHSL(1, 0, 0.7, 0.5).toColor(),
              numberOfColors: counters.length)
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
          data['counters'].putIfAbsent(counter.key, () => {})[entry.key] = entry.value;
        }
      }
    }
    userRef.update(data);
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Data imported')));
  }

  void newCounter() async {
    var alreadyUsed = false;
    String? name;
    while (true) {
      name = (await showTextInputDialog(
          context: context,
          textFields: const [DialogTextField()],
          message: alreadyUsed ? '$name is already used' : 'name the new counter'))?[0];
      if ([null, ''].contains(name)) return;
      if (!counters.containsKey(name)) break;
      alreadyUsed = true;
    }
    userRef.update({
      'counters.$name': {today().toString(): 0}
    });
  }

  void prepareChart() => setState(() {
        maxY = 3; // min value for Y axis maximum
        spots = {};
        _today = today();
        for (final name in counters.keys) {
          final counter = {};
          for (final entry in counters[name].entries) {
            final difference = (double.parse(entry.key) - _today) ~/ (864 * periods[period]!);
            if (difference > -numberOfPeriods) {
              counter[difference] = (counter[difference] ?? 0) + entry.value;
            }
          }
          spots[name] = [];
          for (var i = 1 - numberOfPeriods; i <= 0; i++) {
            spots[name]?.add(FlSpot(i.toDouble(), (counter[i] ?? 0).toDouble()));
          }
          maxY = [maxY, ...counter.values].reduce((a, b) => a > b ? a : b).toDouble();
        }
      });

  int today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 100000;
  }

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
                      style: period == value ? BorderStyle.solid : BorderStyle.none,
                      color: Theme.of(context).hintColor),
                ),
                child: IconButton(
                  splashColor: Colors.transparent,
                  tooltip: 'last 12 $value',
                  icon: Text(value[0].toUpperCase(),
                      style: TextStyle(
                          color: Theme.of(context).appBarTheme.actionsIconTheme?.color,
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
                      download(Stream.fromIterable(json.codeUnits), 'data.json');
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
        floatingActionButton:
            FloatingActionButton(onPressed: newCounter, child: const Icon(Icons.add)),
        body: counters.isEmpty
            ? const Center(child: Text('Add the first counter with the + button'))
            : Flex(direction: portrait ? Axis.vertical : Axis.horizontal, children: [
                Expanded(
                    flex: portrait ? 45 : 60,
                    child: Container(
                        color: Theme.of(context).canvasColor,
                        child: Container(
                            margin: const EdgeInsets.fromLTRB(0, 20, 20, 15),
                            child: LineChart(LineChartData(
                              axisTitleData: FlAxisTitleData(
                                  bottomTitle:
                                      AxisTitle(showTitle: true, titleText: period, margin: 0)),
                              backgroundColor: Theme.of(context).canvasColor,
                              borderData: FlBorderData(show: false),
                              lineTouchData: LineTouchData(
                                  touchTooltipData: LineTouchTooltipData(
                                      fitInsideHorizontally: true, fitInsideVertically: true)),
                              lineBarsData: counters.keys
                                  .mapIndexed((index, name) => LineChartBarData(
                                      colors: [colors[index]],
                                      isCurved: true,
                                      preventCurveOverShooting: true,
                                      spots: spots[name]))
                                  .toList(),
                              maxY: maxY,
                              titlesData: FlTitlesData(
                                bottomTitles: SideTitles(showTitles: true, interval: 1),
                                rightTitles: SideTitles(showTitles: false),
                                topTitles: SideTitles(showTitles: false),
                              ),
                            ))))),
                Expanded(
                    flex: portrait ? 55 : 40,
                    child: ListView.separated(
                      padding: const EdgeInsets.only(top: 10, bottom: 80),
                      separatorBuilder: (_, __) =>
                          Divider(height: 5, color: Theme.of(context).canvasColor),
                      itemCount: counters.keys.length,
                      itemBuilder: (context, index) {
                        final color = colors[index];
                        final name = List.of(counters.keys)[index];
                        final _today = today().toString();
                        return ListTile(
                          tileColor: Theme.of(context).cardColor,
                          title: Text(
                            name,
                            style: TextStyle(color: color),
                          ),
                          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                            IconButton(
                                color: color,
                                onPressed: () {
                                  final _today = today().toString();
                                  userRef.update({
                                    'counters.$name.$_today': (counters[name][_today] ?? 0) + 1
                                  });
                                },
                                icon: const Icon(Icons.add)),
                            IconButton(
                                color: color,
                                onPressed: () {
                                  if (counters[name].containsKey(_today) &&
                                      counters[name][_today] > 0) {
                                    userRef.update(
                                        {'counters.$name.$_today': counters[name][_today] - 1});
                                  }
                                },
                                icon: const Icon(Icons.remove)),
                            IconButton(
                                color: color,
                                onPressed: () async {
                                  if (await showModalActionSheet(context: context, actions: [
                                        SheetAction(key: 'remove', label: 'Remove $name')
                                      ]) ==
                                      'remove') {
                                    userRef.update({'counters.$name': FieldValue.delete()});
                                  }
                                },
                                icon: const Icon(Icons.close)),
                          ]),
                        );
                      },
                    )),
              ]));
  }
}
