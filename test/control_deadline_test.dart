import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:lanpair/src/control.dart';

void main() {
  test(
    'bounded reader joins split UTF-8 chunks without losing characters',
    () async {
      final bytes = utf8.encode('LANPair 日本語');
      final result = await readBounded(
        Stream.fromIterable([
          bytes.sublist(0, 9),
          bytes.sublist(9, 11),
          bytes.sublist(11),
        ]),
        limit: bytes.length,
        timeout: const Duration(seconds: 1),
      );
      expect(result, 'LANPair 日本語');
    },
  );

  test('a slow trickle cannot extend the total deadline and subscription is cancelled', () async {
    var cancelled = false;
    Timer? timer;
    late StreamController<List<int>> stream;
    stream = StreamController<List<int>>(
      onListen: () {
        stream.add([65]);
        timer = Timer.periodic(
          const Duration(milliseconds: 20),
          (_) => stream.add([65]),
        );
      },
      onCancel: () {
        cancelled = true;
        timer?.cancel();
      },
    );
    addTearDown(() async {
      timer?.cancel();
      await stream.close();
    });
    final clock = Stopwatch()..start();
    await expectLater(
      readBounded(
        stream.stream,
        limit: 1000,
        timeout: const Duration(milliseconds: 110),
      ).timeout(
        const Duration(seconds: 1),
        onTimeout: () => throw StateError(
          'The total deadline was replaced by an inactivity timeout.',
        ),
      ),
      throwsA(isA<TimeoutException>()),
    );
    clock.stop();
    expect(cancelled, isTrue);
    // A generous upper bound tolerates loaded CI while proving the test did not
    // wait indefinitely for an idle period in a continuously active stream.
    expect(clock.elapsed, lessThan(const Duration(seconds: 2)));
  });

  test(
    'oversized input aborts before collecting more data and cancels the stream',
    () async {
      var cancelled = false;
      final stream = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(stream.close);
      final result = readBounded(
        stream.stream,
        limit: 4,
        timeout: const Duration(seconds: 1),
      );
      stream.add([1, 2, 3]);
      stream.add([4, 5]);
      await expectLater(result, throwsFormatException);
      expect(cancelled, isTrue);
    },
  );

  test('invalid UTF-8 and stream errors remain explicit failures', () async {
    await expectLater(
      readBounded(
        Stream.value([0xff]),
        limit: 1,
        timeout: const Duration(seconds: 1),
      ),
      throwsFormatException,
    );
    await expectLater(
      readBounded(
        Stream.error(const FormatException('broken body')),
        limit: 1,
        timeout: const Duration(seconds: 1),
      ),
      throwsFormatException,
    );
  });

  test(
    'an empty completed body is valid and a silent body times out',
    () async {
      expect(
        await readBounded(
          const Stream.empty(),
          limit: 1,
          timeout: const Duration(seconds: 1),
        ),
        '',
      );
      var cancelled = false;
      final silent = StreamController<List<int>>(
        onCancel: () {
          cancelled = true;
        },
      );
      addTearDown(silent.close);
      await expectLater(
        readBounded(
          silent.stream,
          limit: 1,
          timeout: const Duration(milliseconds: 40),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(cancelled, isTrue);
    },
  );
}
