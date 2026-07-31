import 'package:flclashx/models/models.dart';

import '../subscription/provider_advisory.dart';

bool profileRequestsAndroidSecure(Profile? profile) =>
    ProductProviderAdvisory.fromProfile(profile).behavior.androidSecure;

bool resolveGlobalGroupOverride(Map<dynamic, dynamic> group) =>
    group.containsKey('flclashm-override')
        ? group['flclashm-override'] == true
        : group['flclashx-override'] == true;
