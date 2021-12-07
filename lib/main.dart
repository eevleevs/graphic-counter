import 'dart:collection';
import 'dart:convert';
import 'dart:io';
import 'package:adaptive_dialog/adaptive_dialog.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:collection/collection.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/painting.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:flutter_palette/flutter_palette.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:path_provider/path_provider.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await Firebase.initializeApp();
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
  var first = true;

  @override
  void initState() {
    super.initState();
    FirebaseAuth.instance.authStateChanges().listen((User? _user) {
      setState(() {
        user = _user;
        if (first && user == null) signInWithGoogle();
        first = false;
      });
    });
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      theme: ThemeData.light(),
      darkTheme: ThemeData.dark(),
      themeMode: ThemeMode.system,
      home: user == null ? const SignInPage() : const MainPage(),
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
  final periods = {'days': 1, 'weeks': 7, 'months': 30, 'years': 365};
  final numberOfPeriods = 12;

  late String exportPath;
  late DocumentReference<Map<String, dynamic>> userRef;
  late Stream<DocumentSnapshot<Map<String, dynamic>>> userStream;

  @override
  void initState() {
    super.initState();
    userRef =
        FirebaseFirestore.instance.collection('users').doc(FirebaseAuth.instance.currentUser?.uid)
          ..get().then((snapshot) {
            if (!snapshot.exists) {
              userRef.set({'counters': {}, 'period': 'days'});
            }
          });
    userStream = userRef.snapshots();

    getExternalStorageDirectory().then((externalStorage) {
      exportPath = '${externalStorage?.path}/data.json';
    });
  }

  int today() {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day).millisecondsSinceEpoch ~/ 100000;
  }

  @override
  Widget build(BuildContext context) {
    final portrait = MediaQuery.of(context).orientation == Orientation.portrait;
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
        stream: userStream,
        builder: (BuildContext context, AsyncSnapshot<DocumentSnapshot> snapshot) {
          if (!snapshot.hasData) return const SizedBox.shrink();
          final data = snapshot.data!.data() as Map<String, dynamic>;
          final period = data['period'];
          final counters = SplayTreeMap.of(data['counters']);
          final colors = counters.isNotEmpty
              ? ColorPalette.polyad(const HSLColor.fromAHSL(1, 0, 0.5, 0.5).toColor(),
                  numberOfColors: counters.length)
              : [];
          final _today = today();

          // prepare graph data
          double maxY = 3; // min value for Y axis maximum
          Map<String, List<FlSpot>> spots = {};
          for (final name in counters.keys) {
            final data = {};
            for (final entry in counters[name].entries) {
              final difference = (double.parse(entry.key) - _today) ~/ (864 * periods[period]!);
              if (difference > -numberOfPeriods) {
                data[difference] = (data[difference] ?? 0) + entry.value;
              }
            }
            spots[name] = [];
            for (var i = 1 - numberOfPeriods; i <= 0; i++) {
              spots[name]?.add(FlSpot(i.toDouble(), (data[i] ?? 0).toDouble()));
            }
            maxY = [maxY, ...data.values].reduce((a, b) => a > b ? a : b).toDouble();
          }

          return Scaffold(
              appBar: AppBar(
                  actions: List<Widget>.of(periods.keys.map((value) => IconButton(
                        tooltip: 'last 12 $value',
                        icon: Text(value[0].toUpperCase(),
                            style: TextStyle(
                                color: Theme.of(context).appBarTheme.actionsIconTheme?.color,
                                fontWeight: period == value ? FontWeight.bold : FontWeight.normal,
                                fontSize: 16)),
                        onPressed: () => userRef.update({'period': value}),
                      )))),
              drawer: SizedBox(
                  width: 200,
                  child: Drawer(
                      child: ListView(
                    children: [
                      ListTile(
                        leading: const Icon(Icons.cloud_download),
                        title: const Text('Export data'),
                        onTap: () async {
                          await File(exportPath).writeAsString(jsonEncode({'counters': counters}));
                          Fluttertoast.showToast(
                              msg: 'Data exported to $exportPath', toastLength: Toast.LENGTH_LONG);
                          Navigator.pop(context);
                        },
                      ),
                      ListTile(
                        leading: const Icon(Icons.cloud_upload),
                        title: const Text('Import data'),
                        onTap: () async {
                          final file = File(exportPath);
                          if (!file.existsSync()) {
                            Fluttertoast.showToast(msg: 'Export file not present');
                            return;
                          }
                          if (await showOkCancelAlertDialog(
                                context: context,
                                message: 'overwrite data?',
                              ) !=
                              OkCancelResult.ok) return;
                          userRef.update(jsonDecode(file.readAsStringSync()));
                          Fluttertoast.showToast(msg: 'Data imported');
                          Navigator.pop(context);
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
                                backgroundColor: Theme.of(context).canvasColor,
                                borderData: FlBorderData(show: false),
                                titlesData: FlTitlesData(
                                  rightTitles: SideTitles(showTitles: false),
                                  topTitles: SideTitles(showTitles: false),
                                ),
                                axisTitleData: FlAxisTitleData(
                                    bottomTitle:
                                        AxisTitle(showTitle: true, titleText: period, margin: 15)),
                                maxY: maxY.toDouble(),
                                lineBarsData: counters.keys
                                    .mapIndexed((index, name) => LineChartBarData(
                                        isCurved: true,
                                        preventCurveOverShooting: true,
                                        colors: [
                                          colors[index],
                                        ],
                                        spots: spots[name]))
                                    .toList()))))),
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
                                            userRef.update({
                                              'counters.$name': {today().toString(): 0}
                                            });
                                          },
                                          child: const Text('New counter'))));
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
        });
  }
}
