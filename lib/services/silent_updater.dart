import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../data/prefs.dart';
import '../models/update_info.dart';
import 'update_service.dart';

enum SilentPhase {
  /// 没在做事，也没有下好的包
  idle,

  /// 正在查版本（不打扰，界面上不显示）
  checking,

  /// 正在后台下载（只有设置页会显示一行小字）
  downloading,

  /// 下好了，等用户点一下装
  ready,

  /// 这次没成，等退避时间过了再试
  failed,
}

class SilentUpdateState {
  final SilentPhase phase;
  final UpdateInfo? info;
  final String? path;
  final String? error;

  const SilentUpdateState({
    this.phase = SilentPhase.idle,
    this.info,
    this.path,
    this.error,
  });

  bool get hasReady => phase == SilentPhase.ready && (path?.isNotEmpty ?? false);

  SilentUpdateState copyWith({
    SilentPhase? phase,
    UpdateInfo? info,
    String? path,
    String? error,
    bool clearInfo = false,
    bool clearPath = false,
    bool clearError = false,
  }) =>
      SilentUpdateState(
        phase: phase ?? this.phase,
        info: clearInfo ? null : (info ?? this.info),
        path: clearPath ? null : (path ?? this.path),
        error: clearError ? null : (error ?? this.error),
      );
}

/// 后台静默升级。
///
/// 为什么要有它：`version.json` 放在 GitHub 上，国内读它时通时断，
/// 用户点「检查更新」经常要干等十几秒，体验很差。
/// 现在改成启动后自己在后台完成「查版本 → 下载安装包」，
/// 用户完全不用等；等哪天想升级了，界面上已经写着「新版已下好，点一下安装」。
///
/// 三条硬规矩（不然会变成流氓软件）：
///   1. 只下载，绝不自动安装——装不装由用户点；
///   2. 失败完全静默，不弹任何提示，也不影响聊天；
///   3. 失败后至少隔 6 小时再试，避免网络不好时反复拉包耗流量。
class SilentUpdater {
  SilentUpdater._();

  static final SilentUpdater instance = SilentUpdater._();

  /// 界面监听这个就行（首页/设置页各挂一个 ValueListenableBuilder）。
  final ValueNotifier<SilentUpdateState> state =
      ValueNotifier(const SilentUpdateState());

  final UpdateService _service = UpdateService();

  /// 失败退避
  static const Duration retryGap = Duration(hours: 6);

  /// 启动后等一会儿再干活，别跟首帧渲染抢资源。
  static const Duration startDelay = Duration(seconds: 4);

  bool _running = false;

  /// 冷启动调一次。内部自己判断要不要做，调用方不用 await。
  Future<void> autoStart() async {
    if (_running) return;
    _running = true;
    try {
      if (!await Prefs.autoUpdateCheck()) return;
      if (!await Prefs.silentUpdateEnabled()) return;

      // 1) 上次已经下好了：直接把状态亮出来，等用户点安装
      if (await _restorePending()) return;

      // 2) 失败退避期内不再打扰网络
      final last = await Prefs.silentUpdateAt();
      if (DateTime.now().millisecondsSinceEpoch - last <
          retryGap.inMilliseconds) {
        return;
      }

      await Future<void>.delayed(startDelay);
      await _run();
    } catch (_) {
      // 静默升级不允许把 App 搞崩
    } finally {
      _running = false;
    }
  }

  /// 用户手动点「检查更新」时也可以借它跑一次（设置页用）。
  Future<SilentUpdateState> runNow() async {
    await _run();
    return state.value;
  }

  Future<void> _run() async {
    state.value = state.value.copyWith(
      phase: SilentPhase.checking,
      clearError: true,
    );

    // 启动场景下用缓存秒判，网络在后台刷新；没有缓存才会真等
    final r = await _service.check(preferCache: true);
    await Prefs.setSilentUpdateAt(DateTime.now().millisecondsSinceEpoch);

    if (!r.hasUpdate || r.info == null) {
      state.value = const SilentUpdateState(phase: SilentPhase.idle);
      return;
    }

    final info = r.info!;
    state.value = state.value.copyWith(
      phase: SilentPhase.downloading,
      info: info,
      clearPath: true,
    );

    try {
      final path = await _service.downloadSilently(info.apkUrl);
      await _savePending(path, info);
      state.value = SilentUpdateState(
        phase: SilentPhase.ready,
        info: info,
        path: path,
      );
    } catch (e) {
      state.value = SilentUpdateState(
        phase: SilentPhase.failed,
        info: info,
        error: e.toString().replaceAll('Exception: ', ''),
      );
    }
  }

  /// 安装包可能被系统清理掉，也可能装完就没用了，这里每次都验一遍文件。
  Future<bool> _restorePending() async {
    final raw = await Prefs.pendingApk();
    if (raw.trim().isEmpty) return false;
    try {
      final m = jsonDecode(raw) as Map<String, dynamic>;
      final path = (m['path'] as String?) ?? '';
      final build = (m['build'] as int?) ?? 0;
      final f = File(path);
      final local = await _service.localVersion();
      if (path.isEmpty || !await f.exists() || build <= local.build) {
        await Prefs.setPendingApk('');
        return false;
      }
      if (await f.length() < 1024 * 1024) {
        // 小得像残缺包，删掉重来
        await Prefs.setPendingApk('');
        return false;
      }
      state.value = SilentUpdateState(
        phase: SilentPhase.ready,
        info: UpdateInfo(
          version: (m['version'] as String?) ?? '',
          build: build,
          publishedAt: (m['at'] as String?) ?? '',
          changelog: const [],
          apkUrl: '',
        ),
        path: path,
      );
      return true;
    } catch (_) {
      await Prefs.setPendingApk('');
      return false;
    }
  }

  Future<void> _savePending(String path, UpdateInfo info) async {
    await Prefs.setPendingApk(jsonEncode({
      'path': path,
      'build': info.build,
      'version': info.version,
      'at': info.publishedAt,
    }));
  }

  /// 用户点了「安装」之后（不管成没成）把待安装标记清掉，
  /// 免得下次启动又提示一遍同一个包。
  Future<void> consume() async {
    await Prefs.setPendingApk('');
    state.value = const SilentUpdateState(phase: SilentPhase.idle);
  }

  Future<void> install(String path) async {
    await _service.install(path);
  }
}
