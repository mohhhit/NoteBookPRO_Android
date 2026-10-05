import 'package:flutter/material.dart';
import 'package:notebook_pro_app/screens/notebook_screen.dart';

void main() {
  runApp(MyApp());
}

class MyApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Notebook Pro App',
      home: NotebookScreen(),
    );
  }
}