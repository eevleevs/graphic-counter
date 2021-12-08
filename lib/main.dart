import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
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
  var userUndefined = true;

  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((User? _user) {
      setState(() {
        user = _user;
        if (userUndefined && user == null) signInWithGoogle();
        userUndefined = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: userUndefined
          ? const SizedBox.shrink()
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
  double maxY = 0;
  var period = GetStorage().read('period');
  Map<String, List<FlSpot>> spots = {};
  var _today = 0;

  late String exportPath;
  late DocumentReference<Map<String, dynamic>> userRef;

  @override
  void initState() {
    super.initState();
    userRef =
        FirebaseFirestore.instance.collection('users').doc(FirebaseAuth.instance.currentUser?.uid)
          ..snapshots().listen((snapshot) {
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
                        : const HSLColor.fromAHSL(1, 0, 0.6, 0.5).toColor(),
                    numberOfColors: counters.length)
                : [];
            prepareChart();
          });

    getExternalStorageDirectory().then((externalStorage) {
      exportPath = '${externalStorage?.path}/data.json';
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
                  color: period == value
                      ? Theme.of(context).highlightColor
                      : Theme.of(context).appBarTheme.backgroundColor,
                  shape: BoxShape.circle,
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
                    await File(exportPath).writeAsString(jsonEncode({'counters': counters}));
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                        content: Text('Data exported to $exportPath'),
                        duration: const Duration(seconds: 8)));
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_upload),
                  title: const Text('Import data'),
                  onTap: () async {
                    Navigator.pop(context);
                    final file = File(exportPath);
                    if (!file.existsSync()) {
                      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
                        content: Text('Export file not present'),
                        elevation: 50,
                      ));
                      return;
                    }
                    if (await showOkCancelAlertDialog(
                          context: context,
                          message: 'overwrite data?',
                        ) !=
                        OkCancelResult.ok) return;
                    userRef.update(jsonDecode(file.readAsStringSync()));
                    ScaffoldMessenger.of(context)
                        .showSnackBar(const SnackBar(content: Text('Data imported')));
                  },
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
        body: Flex(direction: portrait ? Axis.vertical : Axis.horizontal, children: [
          Expanded(
              flex: portrait ? 45 : 60,
              child: Container(
                  color: Theme.of(context).canvasColor,
                  child: Container(
                      margin: const EdgeInsets.fromLTRB(0, 20, 20, 15),
                      child: LineChart(LineChartData(
                        axisTitleData: FlAxisTitleData(
                            bottomTitle: AxisTitle(showTitle: true, titleText: period, margin: 15)),
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
                          rightTitles: SideTitles(showTitles: false),
                          topTitles: SideTitles(showTitles: false),
                        ),
                      ))))),
          Expanded(
              flex: portrait ? 55 : 40,
              child: Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: ListView.separated(
                    separatorBuilder: (_, __) =>
                        Divider(height: 5, color: Theme.of(context).canvasColor),
                    itemCount: counters.keys.isNotEmpty ? counters.keys.length + 1 : 1,
                    itemBuilder: (context, index) {
                      if (index == counters.keys.length) {
                        return Align(
                            alignment: Alignment.center,
                            child: Padding(
                                padding: const EdgeInsets.only(bottom: 5),
                                child: ElevatedButton(
                                    child: const Text('New counter'),
                                    onPressed: () async {
                                      var alreadyUsed = false;
                                      String? name;
                                      while (true) {
                                        name = (await showTextInputDialog(
                                            context: context,
                                            textFields: const [DialogTextField()],
                                            message: alreadyUsed
                                                ? '$name is already used'
                                                : 'name the counter'))?[0];
                                        if ([null, ''].contains(name)) return;
                                        if (!counters.containsKey(name)) break;
                                        alreadyUsed = true;
                                      }
                                      userRef.update({
                                        'counters.$name': {today().toString(): 0}
                                      });
                                    })));
                      }
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
                                userRef.update(
                                    {'counters.$name.$_today': (counters[name][_today] ?? 0) + 1});
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
                                if (await showOkCancelAlertDialog(
                                      context: context,
                                      message: 'remove $name?',
                                    ) ==
                                    OkCancelResult.ok) {
                                  userRef.update({'counters.$name': FieldValue.delete()});
                                }
                              },
                              icon: const Icon(Icons.close)),
                        ]),
                      );
                    },
                  ))),
        ]));
  }
}
