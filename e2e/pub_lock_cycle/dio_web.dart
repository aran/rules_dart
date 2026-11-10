import 'package:dio/dio.dart';
import 'package:dio_web_adapter/dio_web_adapter.dart';

void main() {
  final dio = Dio()..httpClientAdapter = BrowserHttpClientAdapter();
  print(dio.httpClientAdapter);
}
