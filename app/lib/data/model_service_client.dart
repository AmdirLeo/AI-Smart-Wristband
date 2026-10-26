import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import '../models/models.dart';

/// model_service 客户端 —— 严格对齐团队仓库 docs/API.md：
///   GET  /health                    探活（无需口令）
///   GET  /api/info                  服务信息与确认时限
///   GET  /api/samples/{id}          公开样例（normal/fall/false_positive/false_negative）
///   POST /api/predict               {"samples": [[t,ax,ay,az,gx,gy,gz], ...]} 整段 10–20 秒记录
///   GET  /api/events/{id}           查询事件（每秒轮询直至终态）
///   POST /api/events/{id}/confirm   {"choice": "safe" | "help"}
/// 错误响应统一为 {"detail": "..."}；已配置口令时需带 Bearer 认证。
class ModelServiceClient {
  String baseUrl;
  String accessToken;
  http.Client _http = http.Client();

  ModelServiceClient({required this.baseUrl, this.accessToken = ''});

  void configure({String? url, String? token}) {
    if (url != null) {
      baseUrl = url.trim().replaceAll(RegExp(r'/+$'), '');
      _http.close();
      _http = http.Client();
    }
    if (token != null) accessToken = token.trim();
  }

  Map<String, String> _headers({bool jsonBody = true}) => {
        if (jsonBody) 'Content-Type': 'application/json',
        if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
      };

  Future<http.Response> _send(String method, String path,
      {Object? body, bool auth = true, Duration timeout = const Duration(seconds: 10)}) {
    final fut = switch (method) {
      'POST' => _http.post(Uri.parse('$baseUrl$path'),
          headers: _headers(), body: jsonEncode(body)),
      'GET' => _http.get(Uri.parse('$baseUrl$path'),
          headers: _headers(jsonBody: false)),
      _ => _http.delete(Uri.parse('$baseUrl$path'), headers: _headers()),
    };
    return fut.timeout(timeout);
  }

  /// docs/API.md §6：先检查 HTTP 状态，再解析；错误体为 {"detail": ...}
  Map<String, dynamic> _ok(http.Response r) {
    if (r.statusCode >= 400) {
      String detail = 'HTTP ${r.statusCode}';
      try {
        final j = jsonDecode(utf8.decode(r.bodyBytes));
        if (j is Map && j['detail'] != null) detail = j['detail'].toString();
      } catch (_) {}
      throw ApiException(statusCode: r.statusCode, message: detail);
    }
    return jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, dynamic>;
  }

  /// 探活：/health 不需要口令
  Future<bool> ping() async {
    try {
      final j = _ok(await _send('GET', '/health', auth: false));
      return j['status'] == 'ok';
    } catch (_) {
      return false;
    }
  }

  Future<ServiceInfo> info() async {
    return ServiceInfo.fromJson(_ok(await _send('GET', '/api/info')));
  }

  /// 取公开样例的六轴数据（samples 二维数组）；元信息字段不能用于推理
  Future<List<List<double>>> sample(String id) async {
    final j = _ok(await _send('GET', '/api/samples/$id'));
    return _parseRows(j['samples']);
  }

  /// 上传整段六轴记录做跌倒分类；推理可能耗时，超时放宽到 30 秒
  Future<PredictResult> predict(List<List<double>> samples) async {
    final j = _ok(await _send('POST', '/api/predict', body: {'samples': samples},
        timeout: const Duration(seconds: 30)));
    return PredictResult.fromJson(j);
  }

  /// 查询事件；404 = 事件过期/被淘汰/服务重启（调用方应停止轮询）
  Future<MsEvent> event(String id) async {
    return MsEvent.fromJson(_ok(await _send('GET', '/api/events/$id')));
  }

  /// 确认安全或求助；409 = 已处理或已超时（调用方应重新查询而非重试）
  Future<MsEvent> confirm(String id, {required bool safe}) async {
    final j = _ok(await _send('POST', '/api/events/$id/confirm',
        body: {'choice': safe ? 'safe' : 'help'}));
    return MsEvent.fromJson(j);
  }

  static List<List<double>> _parseRows(dynamic data) {
    if (data is! List) throw ApiException(statusCode: 0, message: 'samples 字段格式异常');
    return data
        .map<List<double>>((row) => (row as List).map((v) => (v as num).toDouble()).toList())
        .toList();
  }

  void dispose() {
    _http.close();
  }
}

class ApiException implements Exception {
  final int statusCode;
  final String message;

  ApiException({required this.statusCode, required this.message});

  @override
  String toString() => message;
}
