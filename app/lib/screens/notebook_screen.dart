import 'package:flutter/material.dart';

class NotebookScreen extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('Notebook Screen'),
      ),
      body: Center(
        child: Text('This is the Notebook Screen'),
      ),
    );
  }
}