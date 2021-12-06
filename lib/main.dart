import 'dart:collection';
import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:collection/collection.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_database/firebase_database.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_palette/flutter_palette.dart';
import 'package:google_sign_in/google_sign_in.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
  signInWithGoogle();
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
  bool ready = false;
  User? user;

  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((User? _user) {
      setState(() {
        user = _user;
        ready = true;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: !ready
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
    return const Scaffold(
        body: Center(
            child: ElevatedButton(onPressed: signInWithGoogle, child: Text('Google login'))));
  }
}

class MainPage extends StatefulWidget {
  const MainPage({Key? key}) : super(key: key);

  @override
  _MainPageState createState() => _MainPageState();
}

class _MainPageState extends State<MainPage> {
  final uid = FirebaseAuth.instance.currentUser?.uid;
  final periods = {'days': 1, 'weeks': 7, 'months': 30, 'years': 365};

  late DatabaseReference countersRef;
  late DatabaseReference periodRef;

  var colors = const ColorPalette([]);
  var counters = SplayTreeMap.of({});
  var period = 'days';
  bool ready = false;

  Map<String, List<FlSpot>> spots = {};
  double maxY = 0;

  @override
  void initState() {
    super.initState();
    periodRef = FirebaseDatabase.instance.reference().child('/users/$uid/period')
      ..onValue.listen((event) => setState(() {
            period = event.snapshot.value ?? 'days';
            setSpots();
          }));
    countersRef = FirebaseDatabase.instance.reference().child('/users/$uid/counters')
      ..onValue.listen((event) => setState(() {
            counters = SplayTreeMap.of(
                {for (final entry in event.snapshot.value?.entries ?? {}) entry.key: entry.value});
            if (counters.isNotEmpty) {
              colors = ColorPalette.polyad(const HSLColor.fromAHSL(1, 0, 0.5, 0.5).toColor(),
                  numberOfColors: counters.length);
              setSpots();
              ready = true;
            }
          }));
  }

  int today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 100000;
  }

  void setSpots() {
    const periodNumber = 12;
    final periodLength = periods[period];
    final _today = today();
    maxY = 3; // min value for Y axis maximum

    for (final key in counters.keys) {
      final data = {};
      for (final entry in counters[key].entries) {
        final difference = (double.parse(entry.key) - _today) ~/ (864 * periodLength!);
        if (difference > -periodNumber) {
          data[difference] = (data[difference] ?? 0) + entry.value;
        }
      }

      spots[key] = [];
      for (var i = 1 - periodNumber; i <= 0; i++) {
        spots[key]?.add(FlSpot(i.toDouble(), (data[i] ?? 0).toDouble()));
      }

      maxY = [maxY, ...data.values].reduce((a, b) => a > b ? a : b).toDouble();
    }
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    return Scaffold(
        appBar: AppBar(
            actions: List<Widget>.of(periods.keys.map((value) => IconButton(
                  tooltip: 'last 12 $value',
                  icon: Text(value[0].toUpperCase(),
                      style: TextStyle(
                          color: Theme.of(context).appBarTheme.actionsIconTheme?.color,
                          fontWeight: period == value ? FontWeight.bold : FontWeight.normal,
                          fontSize: 16)),
                  onPressed: () => periodRef.set(value),
                )))),
        // drawer: SizedBox(
        //     width: 200,
        //     child: Drawer(
        //         child: ListView(
        //       children: [
        //         ListTile(
        //           title: const Text('Sign out'),
        //           onTap: () => FirebaseAuth.instance.signOut(),
        //         ),
        //       ],
        //     ))),
        body: !ready
            ? const SizedBox.shrink()
            : Flex(direction: portrait ? Axis.vertical : Axis.horizontal, children: [
                Expanded(
                    flex: portrait ? 45 : 60,
                    child: Container(
                        margin: const EdgeInsets.fromLTRB(0, 20, 20, 15),
                        child: LineChart(LineChartData(
                            backgroundColor: Theme.of(context).canvasColor,
                            borderData: FlBorderData(show: false),
                            titlesData: FlTitlesData(
                              rightTitles: SideTitles(showTitles: false),
                              topTitles: SideTitles(showTitles: false),
                            ),
                            axisTitleData: FlAxisTitleData(
                                bottomTitle:
                                    AxisTitle(showTitle: true, titleText: period, margin: 15)),
                            maxY: maxY,
                            lineBarsData: counters.keys
                                .mapIndexed((index, key) => LineChartBarData(
                                    isCurved: true,
                                    preventCurveOverShooting: true,
                                    colors: [
                                      colors[index],
                                    ],
                                    spots: spots[key]))
                                .toList())))),
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
                                      padding: const EdgeInsets.only(top: 5),
                                      child: ElevatedButton(
                                          onPressed: () async {
                                            final name = (await showTextInputDialog(
                                                context: context,
                                                textFields: const [DialogTextField()],
                                                message: 'name the counter'))?[0];
                                            if (name == null || name == '') return;
                                            if (counters.containsKey(name)) {
                                              showOkAlertDialog(
                                                  context: context,
                                                  message: '$name is already used');
                                            }
                                            countersRef
                                                .child(name + '/' + today().toString())
                                                .set(0);
                                          },
                                          child: const Text('New counter'))));
                            }
                            final color = colors[index];
                            final key = List.of(counters.keys)[index];
                            final _today = today().toString();
                            return ListTile(
                              tileColor: Theme.of(context).cardColor,
                              title: Text(
                                key,
                                style: TextStyle(color: color),
                              ),
                              trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                                IconButton(
                                    color: color,
                                    onPressed: () {
                                      final _today = today().toString();
                                      countersRef.child('$key/$_today').set(
                                          counters[key].containsKey(_today)
                                              ? counters[key][_today] + 1
                                              : 1);
                                    },
                                    icon: const Icon(Icons.add)),
                                IconButton(
                                    color: color,
                                    onPressed: () {
                                      if (counters[key].containsKey(_today) &&
                                          counters[key][_today] > 0) {
                                        countersRef
                                            .child('$key/$_today')
                                            .set(counters[key][_today] - 1);
                                      }
                                    },
                                    icon: const Icon(Icons.remove)),
                                IconButton(
                                    color: color,
                                    onPressed: () async {
                                      if (await showOkCancelAlertDialog(
                                            context: context,
                                            message: 'remove $key?',
                                          ) ==
                                          OkCancelResult.ok) {
                                        countersRef.child(key).remove();
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
