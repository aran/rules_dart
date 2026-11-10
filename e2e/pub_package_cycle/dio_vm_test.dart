import 'dart:io';

import 'package:dio/dio.dart';

void main() {
  final dio = Dio(BaseOptions(baseUrl: 'https://example.invalid'));
  if (dio.options.baseUrl != 'https://example.invalid') exit(1);
  if (dio.httpClientAdapter.runtimeType.toString() != 'IOHttpClientAdapter') {
    stderr.writeln('unexpected adapter ${dio.httpClientAdapter.runtimeType}');
    exit(1);
  }
}
