import 'dart:io';
import 'package:cloud_functions/cloud_functions.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:file_picker/file_picker.dart';

class FirebaseService {
  final FirebaseFunctions _functions = FirebaseFunctions.instance;
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  // Use emulator for local development (set to false for production)
  void useEmulator({bool enabled = false}) {
    if (enabled) {
      _functions.useFunctionsEmulator('localhost', 5001);
      _firestore.useFirestoreEmulator('localhost', 8080);
      _storage.useStorageEmulator('localhost', 9199);
    }
  }

  // ==================== SPACES ====================

  Future<Map<String, dynamic>> createSpace(String name) async {
    try {
      final result = await _functions.httpsCallable('createSpace').call({
        'name': name,
      });
      return result.data as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Failed to create space: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getSpaces() async {
    try {
      final result = await _functions.httpsCallable('getSpaces').call();
      final spaces = (result.data['spaces'] as List)
          .map((s) => s as Map<String, dynamic>)
          .toList();
      return spaces;
    } catch (e) {
      throw Exception('Failed to get spaces: $e');
    }
  }

  // ==================== FILES ====================

  Future<Map<String, dynamic>> uploadFiles(
      String spaceId, List<PlatformFile> files) async {
    try {
      final List<Map<String, dynamic>> uploadedFiles = [];

      for (final file in files) {
        // Upload file to Firebase Storage
        final storageRef = _storage.ref().child('spaces/$spaceId/${file.name}');
        
        UploadTask uploadTask;
        if (file.bytes != null) {
          uploadTask = storageRef.putData(file.bytes!);
        } else if (file.path != null) {
          uploadTask = storageRef.putFile(File(file.path!));
        } else {
          throw Exception('File has no bytes or path');
        }

        await uploadTask;

        // Call Cloud Function to process the file
        // The function will download from Storage, process, and add to Pinecone
        final result = await _functions.httpsCallable('processUploadedFile').call({
          'spaceId': spaceId,
          'filename': file.name,
          'storagePath': 'spaces/$spaceId/${file.name}',
        });

        uploadedFiles.add({
          'filename': file.name,
          'chunks': result.data['chunks'],
        });
      }

      return {
        'success': true,
        'files': uploadedFiles,
      };
    } catch (e) {
      throw Exception('Failed to upload files: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getFiles(String spaceId) async {
    try {
      final result = await _functions.httpsCallable('getFiles').call({
        'spaceId': spaceId,
      });
      final files = (result.data['files'] as List)
          .map((f) => f as Map<String, dynamic>)
          .toList();
      return files;
    } catch (e) {
      throw Exception('Failed to get files: $e');
    }
  }

  // ==================== CHATS ====================

  Future<Map<String, dynamic>> createChat(String spaceId, String title) async {
    try {
      final result = await _functions.httpsCallable('createChat').call({
        'spaceId': spaceId,
        'title': title,
      });
      return result.data as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Failed to create chat: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getChats(String spaceId) async {
    try {
      final result = await _functions.httpsCallable('getChats').call({
        'spaceId': spaceId,
      });
      final chats = (result.data['chats'] as List)
          .map((c) => c as Map<String, dynamic>)
          .toList();
      return chats;
    } catch (e) {
      throw Exception('Failed to get chats: $e');
    }
  }

  // ==================== MESSAGES ====================

  Future<String> sendMessage(
    String spaceId,
    String chatId,
    String message,
    String mode,
  ) async {
    try {
      final result = await _functions.httpsCallable('sendMessage').call({
        'spaceId': spaceId,
        'chatId': chatId,
        'message': message,
        'mode': mode,
      });
      return result.data['response'] as String;
    } catch (e) {
      throw Exception('Failed to send message: $e');
    }
  }

  Future<List<Map<String, dynamic>>> getMessages(String chatId) async {
    try {
      final result = await _functions.httpsCallable('getMessages').call({
        'chatId': chatId,
      });
      final messages = (result.data['messages'] as List)
          .map((m) => m as Map<String, dynamic>)
          .toList();
      return messages;
    } catch (e) {
      throw Exception('Failed to get messages: $e');
    }
  }

  // ==================== REAL-TIME LISTENERS ====================

  // Listen to new messages in a chat (real-time updates!)
  Stream<List<Map<String, dynamic>>> listenToMessages(String chatId) {
    return _firestore
        .collection('chats')
        .doc(chatId)
        .collection('messages')
        .orderBy('timestamp', descending: false)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        final data = doc.data();
        return {
          'role': data['role'],
          'content': data['content'],
          'timestamp': data['timestamp'],
        };
      }).toList();
    });
  }

  // Listen to chats in a space (real-time updates!)
  Stream<List<Map<String, dynamic>>> listenToChats(String spaceId) {
    return _firestore
        .collection('chats')
        .where('spaceId', isEqualTo: spaceId)
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return {
          'id': doc.id,
          ...doc.data(),
        };
      }).toList();
    });
  }

  // Listen to spaces (real-time updates!)
  Stream<List<Map<String, dynamic>>> listenToSpaces() {
    return _firestore
        .collection('spaces')
        .orderBy('createdAt', descending: true)
        .snapshots()
        .map((snapshot) {
      return snapshot.docs.map((doc) {
        return {
          'id': doc.id,
          ...doc.data(),
        };
      }).toList();
    });
  }
}
