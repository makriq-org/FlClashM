import 'package:flclashm/models/models.dart' hide Action;
import 'package:flclashm/pages/send_to_tv_page.dart';
import 'package:flclashm/product/ui/profiles/profiles_view.dart' as p;
import 'package:flclashm/views/profiles/add_profile.dart';
import 'package:flclashm/views/profiles/edit_profile.dart';
import 'package:flclashm/views/profiles/override_profile.dart';
import 'package:flclashm/views/profiles/scripts.dart';
import 'package:flclashm/widgets/sheet.dart';
import 'package:flutter/widgets.dart';

class ProfilesView extends StatelessWidget {
  const ProfilesView({super.key});

  @override
  Widget build(BuildContext context) => p.ProfilesView(
        addProfileViewBuilder: (context) => AddProfileView(context: context),
        editProfileViewBuilder: (context, profile) => EditProfileView(
          context: context,
          profile: profile,
        ),
        overrideProfileViewBuilder: (profileId) =>
            OverrideProfileView(profileId: profileId),
        scriptsViewBuilder: (_) => const ScriptsView(),
        sendToTvPageBuilder: (profileUrl) =>
            SendToTvPage(profileUrl: profileUrl),
      );
}

class ProfileItem extends StatelessWidget {
  const ProfileItem({
    super.key,
    required this.profile,
    required this.groupValue,
    required this.onChanged,
  });

  final Profile profile;
  final String? groupValue;
  final void Function(String? value) onChanged;

  @override
  Widget build(BuildContext context) => p.ProfileItem(
        key: key,
        profile: profile,
        groupValue: groupValue,
        onChanged: onChanged,
        editProfileViewBuilder: (context, profile) => EditProfileView(
          context: context,
          profile: profile,
        ),
        overrideProfileViewBuilder: (profileId) =>
            OverrideProfileView(profileId: profileId),
        sendToTvPageBuilder: (profileUrl) =>
            SendToTvPage(profileUrl: profileUrl),
      );
}

class ReorderableProfilesSheet extends StatelessWidget {
  const ReorderableProfilesSheet({
    super.key,
    required this.profiles,
    required this.type,
  });

  final List<Profile> profiles;
  final SheetType type;

  @override
  Widget build(BuildContext context) => p.ReorderableProfilesSheet(
        key: key,
        profiles: profiles,
        type: type,
      );
}
