import 'dart:collection';
import 'dart:convert';
import '../product/subscription/product_subscription.dart';
import 'dart:ui' show Brightness;
import 'dart:math';
import 'dart:typed_data';

import 'package:collection/collection.dart';
import 'package:flclashx/common/common.dart';
import 'package:flclashx/database/database.dart';
import 'package:flclashx/enum/enum.dart';
import 'package:flclashx/models/models.dart';
import 'package:flclashx/ui/ui.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import 'app.dart';
import 'config.dart';
import 'core.dart';
import 'database.dart';

part 'generated/state.g.dart';
part 'state/proxies.dart';
part 'state/navigation.dart';
part 'state/system.dart';
part 'state/theme.dart';
part 'state/managed.dart';
part 'state/profile.dart';
part 'state/custom.dart';
part 'state/custom_import.dart';

final currentProductAdvisoryProvider=Provider.autoDispose<ProductProviderAdvisory>((ref)=>ProductProviderAdvisory.fromProfile(ref.watch(currentProfileProvider)));
final effectiveNewDashboardProvider=Provider.autoDispose<bool>((ref)=>ref.watch(appSettingProvider).newDashboard ?? ref.watch(currentProductAdvisoryProvider).display.newDashboard);
final dashboardEditingLockedProvider=Provider.autoDispose<bool>((ref)=>ref.watch(currentProductAdvisoryProvider).display.denyDashboardEditing || ref.watch(effectiveNewDashboardProvider));
