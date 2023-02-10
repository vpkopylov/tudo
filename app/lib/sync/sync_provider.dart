import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart';
import 'package:rxdart/rxdart.dart';
import 'package:sqlite_crdt/sqlite_crdt.dart';

import '../auth/auth_provider.dart';
import '../config.dart';
import '../extensions.dart';
import '../util/build_info.dart';
import '../util/store.dart';
import 'sync_client.dart';

class SyncProvider {
  final SqlCrdt _crdt;
  late final SyncClient _client;

  var _online = false;
  Timer? _reconnectTimer;
  StreamSubscription? _sendSubscription;

  Stream<bool> get connectionState => _client.connectionState;

  SyncProvider(
      AuthProvider authProvider, StoreProvider storeProvider, this._crdt) {
    _client = SyncClient(authProvider.token, authProvider.userId, _crdt.nodeId)
      ..messages.listen((message) async {
        final changeset = (jsonDecode(message) as Map<String, dynamic>)
            .map((key, value) => MapEntry(
                  key,
                  (value as List).cast<Map<String, dynamic>>(),
                ));
        await _crdt.merge(changeset);
      });

    _client.connectionState.listen((isConnected) {
      if (isConnected) {
        // Sync whenever connection is established
        _sendChangeset();
      } else {
        _sendSubscription?.cancel();
        // Trigger reconnect
        if (_online) {
          _reconnectTimer = Timer(const Duration(seconds: 10), () => connect());
        }
      }
    });

    // Make sure all sockets are connected
    connect();
  }

  Future<void> connect() async {
    _reconnectTimer?.cancel();
    _online = true;
    _client.connect(await _crdt.peerLastModified);
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _online = false;
    _client.disconnect();
  }

  Future<void> _sendChangeset() async {
    var lastSend = await _client.getRemoteLastModified();
    _sendSubscription = _crdt
        .watchChangeset(
          onlyModifiedHere: true,
          modifiedSince: () => lastSend,
        )
        .debounceTime(const Duration(milliseconds: 200))
        .listen(
      (changeset) {
        lastSend = _crdt.canonicalTime;

        final count = changeset.recordCount;
        if (count > 0) {
          'SEND $count records'.log;
          _client.send(jsonEncode(changeset));
        }
      },
    );
  }

  Future<bool> isUpdateRequired() async {
    try {
      final result = await head(
        Uri.parse('$serverAddress/check_version'),
        headers: {HttpHeaders.userAgentHeader: BuildInfo.userAgent},
      );
      // There's actually a status code for this:
      // https://developer.mozilla.org/en-US/docs/Web/HTTP/Status/426
      return result.statusCode == 426;
    } catch (_) {
      return false;
    }
  }
}
