## v0.10.0

- Free disk space before Android release build

- Reduce Android release disk usage in CI

- Support PKCS12 release keystores in CI

- Harden release continuity and Android install path

- Formalize cheap upstream maintenance boundaries

- Harden Android release continuity contract

- Adapt updater and profile split tunneling

- Integrate naiveproxy runtime adapter

- Stabilize mihomo runtime baseline

- Consolidate Android shell orchestration

- Extract product update and access services

- Extract product customization advisory seam

- Close product security policy seam

- Define runtime integration registry

- Add Android base verification gate

- Add release continuity guardrails

- Extract Android platform seam

- Extract runtime orchestration seam

- Extract compile pipeline

- Make FlClashM Android-only

- Rebrand public metadata and document FlClashX base

- Bootstrap FlClashM rebrand and continuity

- Merge upstream dev into main

- android fixes and enhanced

- fix stop broadcast delay

- android fixes

- android stability, fix notify android

- fix: subtle primary tint on hero card when active

- new board fix, android stability

- fix: unify support icon to contact_support everywhere

- fix: remove scroll, use AnimatedContainer for card bg transition

- hero: animate card background color sync with ring fill

- fix: increase bottom padding to 32px

- fix: add bottom safe area padding for Android navigation bar

- cleanup: remove unused imports from dashboard

- merge: NEW DASHBOARD VIEW

- NEW DASHBOARD VIEW ;)

- ci notify fix

- Android stability, tray fixes

- delete unused code, and more fixes

- fixes and more stability Android app

- fix: VPN cold-start NPE, editor line numbers, build-core version update

- - Sanitize Gson-deserialized VpnOptions to prevent null lists causing
-   iterator NPE on Always-on/tile cold start
- - Add line number gutter to config editor with soft-wrap awareness
- - Update build-core workflow to pull mihomo dependency matching input version

- fix: health check loading indicator and generated enum map

- Add loading state (value: 0) before URLTest so UI shows spinners.
- Include testUrl in delay messages so results land in the correct delayMap bucket.
- Add missing healthCheck entry to generated ActionMethod enum map.

- feat: domain-redirect via flclashx-newdomain header

- On subscription update, if the response contains a flclashx-newdomain header with a different domain, the profile URL is updated to use the new host. Preserves path, query params, and scheme.

- feat: core-side health check, delay test error handling, UI tooltips

- Move proxy group health check from client-side batch pinging to core URLTest for accuracy and efficiency. Add error handling in delayTest to report -1 on failure. Add tooltips to action buttons across dashboard, profiles, and proxies views. Add l10n strings for testAllDelay, goToSelected, expandAll, collapseAll.

- fix: process name detection, geo download timeout, windows arm64 build

- fix: windows arm64 build path

- fix: inno setup template, file naming, linux deb/rpm/appimage, kotlin version

- fix: desktop socket race condition, battery prompt once, build improvements

- - Fix socket race condition on macOS/desktop: _flushPendingCompleters was killing pending requests on first core connection, causing "core stopped" state
- - Move battery optimization request from every VPN start to one-time on first app launch
- - Fix setup.dart UTF-8 decode errors from Inno Setup output
- - Add Inno Setup installation step to CI workflow

- feat: android notification/tile/battery rework, shortcuts, desktop socket leak fix, macOS entitlement

- ci: force Node 24 for all actions

- feat: hwid headers update, merge provider headers on update, yaml highlight

- feat: yaml highlight controller, editor rewrite, runtime config highlight

- fix: editor content scroll with expands + maxLines

- fix: editor wrap, scroll, dark theme support

- ci: re-enable ARM builds

- refactor: replace re_editor with flutter_code_editor

- ci: disable ARM builds - re_editor incompatible with flutter master

- ci: re-enable ARM builds with flutter master channel

- fix: remove version from restart core button

- fix: add getCoreVersion to ActionMethodEnumMap (was missing in generated code)

- ci: upgrade artifact actions to v6 for Node 24

- ci: upgrade artifact actions to v6 for Node 24

- sync: getCoreVersion action + updated build-core workflow from dev

- fix: core update version display, workflow input simplification

- ci: upgrade actions to Node 24 compatible versions

- feat: getCoreVersion IPC action, update UI fixes, revert ARM builds

- fix: check core version from running instance, not build constant

- fix: remove unused shutdown_service function

- feat: core update progress bar and update highlight

- fix: stop core before replacing binary on update

- fix: flutter setup for windows arm and linux arm runners

- ci: add build-core workflow

- fix: install flutter from git on ARM runners

- fix: pin flutter version for ARM runners

- aidl refactor, desktop feature and more

- fix: recreate tun-interface

- fix: mihomo core integration
- fix: remove overrride tcp-concurrent, unified-delay, log-level, keep-alive-interval
- feat: custom parameter "description" proxy-group
- feat: external-ui logic

- pre-build without arm build

- build

- build

- fix build again xD

- fix build again

- stable flutter

- fix flutter version

- bump flutter version and go version

- original core Mihomo + another fix

- fix globalmode

- fix: app work is performed through the running tun on Android
- fix: removed validation on mixed port and off sysProxy with mixed-port = 0
- fix: corrections for the MATCH field in the override settings
- fix: include/exclude package on Android
- feat: new header flclashx-androidsecure, override mixed-port = 0 in Andriod, and hide port setting

- fix: update profile autostart app is off

- fix: readme default hex-theme

- fix: tg channel link

- release: version 0.3.2

- critical fix: ClashHelperService

- fix: ClashHelper installer

- feat: new tray icon, new title bar

- fix: tg notify

- fix: androidTV focusing dpad proxy page

- feat: new readme

- fix: windows logic service
- fix: Linux arm build

- fix 0.3.0 release

- fix: added pureblack variant hex header
- fix: optimize base
- fix: icon linux-based distrib

- fix: HWID notify logic
- fix: removed the proxy group type from the proxy page

- feat: 3 days notice of expiring subscription every day (only Android for now)

- feat: new header flclashx-globalmode
- feat: visible servicename and host in foreground notify
- fix: update dependencies packages
- fix: flclashx-custom logic
- fix: windows installer
- fix: update logic empty widgets visible
- fix: update notify TG

- ci: fix notify

- fix: android tile service
- feat: manual check in IPchecker widget
- feat: mode selector in ProxyPage
- feat: notify modal in HWID limit
- fix: logic geo updater

- fix: android tile service
- feat: manual check in IPchecker widget
- feat: mode selector in ProxyPage
- feat: notify modal in HWID limit
- fix: logic geo updater

- feat: manually check ip from networkDetection widget

- fix: cache icons

- fix: the proxy tab disappears when renewing a subscription or in other cases

- feat: add restart button in tray control
- feat: new pop-up window when HWID Limit is reached

- fix: blur on bottomsheets, sidesheets

- fix: memtagmode off (temp solution)

- fix: serivceinfo widget base64 issue

- fix: backup/restore app function

- fix: release script

- fix: init proxiesgroup for start/stop button

- feat: add button to check latency across all proxy groups
- feat: new header flclashx-hex (custom theme app)
- fix: search button in proxy groups
- fix: setting up proxy group sorting

- fix android tile service

- fix: andriod adaptive icon

- fix: release template

- fix: build pages RepaintBoundary widgets
- feat: notify release
- fix: modal pages opacity

- fix: windows arm actions

- fix: coreversion on build app

- fix: artefact slidemenu

- fix: serviceinfo and changeserver support latin or base64 header for cyrillic, unicode and emoji support
- fix: support https:// links announce widget

- update flclashx-serverinfo description
- fix: android icons and splashscreen
- refactor: changeserverbutton widget
- fear: new header flclashx-serverinfo
- refactor: update readme and templates
- fix: cache logo in service-logo header
- fix: theme opacity layer

- fix: optimize theme for opacity layers
- fix: deprecated core version
- fix: about page

- fix: release template

- new submodule init

- Remove old submodule

- Remove old submodule

- fix: visible log folder button on andriod

- fix: gtk flags

- fix: workflow

- feat: logs folder button in settings menu
- refactor: about page

- refactor: cleaning up excess logs

- feat: logger in file (logrotate10 days)

- fix: android hwid generator (Settings.Secure_ID)

- fix: running a single instance on Linux

- fix: pubsec.yaml

- fix: workflow flutter version

- update: geofiles

- fix: locale
- refactor: recive mixed-port from subscription

- fix: recieve App Setting from provider
- fix: en localization
- update: readme

- fix: migrate deprecated iconstyle

- feat: add flclashx-backgroud header (the ability to customize the application background)
- feat: button to hide/show all proxy groups
- fix: kill application when installing over an older version

- refactor: apply comprehensive linting rules and code style improvements
- Add extensive lint rules in analysis_options.yaml (100+ rules)
- Apply automated code formatting across entire codebase
- Changes to Linux distribution descriptions
- Adding full support for 120Hz screens on Android

- Delete workflow
- test comm
- test
- Merge pull request #29 from pluralplay/pluralplay-patch-1

- wf
- wf
- Merge branch 'main' of https://github.com/pluralplay/FlClashX

- Revert "fix: macos naming artifact"

- This reverts commit 72fe70aa9d4737e750bc41ffa180367c1113f149.

- Merge pull request #27 from pluralplay/dev

- 0.3.0-pre.6
- feat: recive parameters from a subscription and enabling from an override in client: allow-lan, ipv6, find-process-mode, tun-stack
- feat: the ability to completely reset application profiles from settings

- update: readme
- fix: exclude closeConnections provider control

- fix: android notification start bug
- refactor: cardType fill flexible

- Merge pull request #25 from katsukibtw/main

- Proxies list view refactoring using Expansible widget
- add custom logo and new header flclashx-servicelogo (work only with flclashx-servicename header)

- Merge pull request #26 from pluralplay/main

- fix: macos naming artifact
- fix: macos naming artifact

- remove standard icon style

- refactor: use Expansible for proxy groups in proxies list view

- update dev branch pre release

- update dev branch
- fix: notify icon android

- fix: main settings UI and default variable
- fix: hwid generator
- fix: macos version artifact rename

- fix: pre-release posting gh

- fix: delete message from update core version

- fix template

- fix: init FlClashX

- fix: init

- fix: init universal apk
- fix: init fork flutter_distributor

- feat: universal APK
- feat: new UI for geofiles menu
- feat: Application settings from sub-header (disableable setting override)
- feat: saving custom settings from the profile header
- fix: custom geofiles loader (check hash from URL)
- fix: safe_patch error
- fix: metainfo widget logical
- fix: localization

- fix about page and adding new translate

- fix declension
- adding hour counter remaining sub

- fix russian translate

- fix timecounter start/stop button

- fix lang metainfo card

- refactor about page

- update proxy state before update sub

- fix tray control and change color depending on Windows theme
- fix stop service helper
- fix external-ui subupdate

- fix server description standard card
- fix macos deeplink (add flclashx)
- add core version in About page
- fix uninstaller and uninstall logo
- fix deeplink first install

- Merge pull request #18 from prettyleaf/main

- feat(release): add Repology badge for FlClashX version tracking
- feat(release): add Repology badge for FlClashX version tracking

- Merge pull request #15 from kastov/macos-features

- New widgets, macOS signing&notarization, macOS tray
- feat(dashboard): enhance MetainfoWidget with improved expiration display and UI adjustments

- - Updated the logic to show days left until subscription expiration, limiting display to within 3 days.

- fix(utils): update time formatting for getTimeText method

- - Changed the default return value for null timestamps from '00:00:00' to '000:00:00' to accommodate larger hour values.
- - Adjusted the hour limit check from 99 to 999 to support longer durations.
- - Updated the return statement to ensure hours are padded to three digits for consistent formatting.

- chore(build): update macOS configuration and clean up Windows platform entries

- - Changed macOS version from 'macos-13' to 'macos-latest' for improved compatibility.
- - Commented out Windows platform configuration to simplify the build workflow.
- - Updated the Flutter subproject commit to indicate a dirty state.

- feat(build): clean up build workflow

- - Removed the Telegram bot service configuration from the GitHub Actions workflow to streamline the build process.

- feat(dashboard): add serviceInfo widget and update profile handling

- - Introduced the `serviceInfo` widget to the dashboard for enhanced service display.
- - Updated the `Profile` model to include a new `serviceName` field for better service management.
- - Enhanced README files to document the new `serviceInfo` widget and its usage.

- feat(proxy): enhance proxy card functionality and UI

- - Introduced a new 'oneline' card type for improved display options in the proxy list.
- - Updated the ProxyCard widget to handle the new card type, including layout adjustments and conditional rendering.
- - Enhanced the getItemHeight function to accommodate the new card type.
- - Refactored the handling of proxy descriptions and delay text for better clarity and user experience.
- - Added support for the new card type in the computed mark display logic.

- feat(proxy): enhance proxy handling with server descriptions and JSON integration

- - Added extraction of server descriptions from raw YAML config to improve proxy management.
- - Updated Proxy model to include an optional serverDescription field for better data representation.
- - Enhanced handleGetProxies function to include server descriptions in the returned JSON structure.
- - Adjusted UI components to display server descriptions where applicable, improving user experience.

- feat(macos): adjust popover dimensions and enhance macOS app layout

- - Updated the popover dimensions in AppDelegate and StatusBarController to 375x600 for better fit.
- - Added platform-specific handling in ApplicationState to adjust the app layout for macOS, including a FittedBox for improved display.
- - Ensured the app maintains a consistent appearance across different macOS environments.

- feat(dashboard): enhance StartButton with animation and tap feedback

- - Updated StartButton to use TickerProviderStateMixin for improved animation control.
- - Added a new press animation for tap feedback, enhancing user interaction.
- - Adjusted button duration for animations and improved visual feedback with scaling and size transitions.
- - Refactored button layout to include GestureDetector for handling tap events.
- - Updated text styling for better visibility and added keys for widget identification.

- fix(window_manager): simplify macOS logic in WindowHeaderContainer and remove unused import

- - Removed the unused import of app provider.
- - Streamlined the macOS-specific logic in the WindowHeaderContainer to improve clarity and maintainability.

- refactor: remove unused code

- feat(localization): add "Change Server" string to multiple language files and update UI elements for macOS

- - Added "Change Server" localization to English, Japanese, Russian, and Simplified Chinese ARB files.
- - Updated the localization messages in the respective Dart files.
- - Adjusted macOS UI elements for better integration, including window size and rounded corners for the popover.
- - Enhanced the window manager logic to handle macOS-specific behavior more effectively.

- feat(build): enhance Makefile and Xcode project for macOS notarization and code signing

- feat(macos): implement native status bar and code signing support

- Adds comprehensive macOS status bar integration and app signing capabilities:

- - Replaces window-based UI with native status bar menu
- - Implements secure core binary installation in Application Support
- - Adds code signing and notarization workflow
- - Updates build configuration for proper macOS code signing
- - Improves DMG creation process using create-dmg
- - Configures launch-at-login functionality
- - Sets minimum macOS version to 11.0

- This change significantly improves the native macOS experience by making the app behave more like a traditional menu bar utility while ensuring proper security measures through code signing and notarization.

- Update bug_report.yml
- Update bug_report.yml
- Update bug_report.yml
- Update feature_request.yml
- Update config.yml
- Update release_template.md
- clean
- update mihomo core

- update logo
- update mihomo core

- Merge pull request #6 from pluralplay/main

- todev
- Create FUNDING.yml
- update readme

- Merge branch 'dev'

- - add new widget "Meta Info"
- - add new catch-header (flclashx-view,flclashx-denywidgets,flclashx-custom)
- - bug-fixes qr-code scanner

- Update README.md
- Update README_EN.md
- Update README_EN.md
- Update README.md
- Update README.md
- Update README.md
- Update README.md
- Update README.md
- Merge pull request #4 from pluralplay/main

- new
- update snapshots

- Update flutter_distributor submodule to latest commit

- Update .gitmodules
- some changes

- change GI dependence

- enchance profile card UI
- add catch new header flclashx-widget
- flclashx-hidemode is deprecated
- add support button in profile

- enchance profile card UI
- add catch new header flclashx-widget
- flclashx-hidemode is deprecated
- add support button in profile

- Feature: add profile from mobile on AndroidTV (QR-code init)

- Merge pull request #3 from pluralplay/dev

- Feature: add profile from mobile on AndroidTV (QR-code init)
- Feature: add profile from mobile on AndroidTV (QR-code init)

- some changes

- Add button "Paste" in Add Profile from URL (Android TV optimisation)
- In Proxy page default mode - list
- New header catch - flclashx-hidemode (boolean) - hide all widgets form Main Page in first Add Profile
- Change About page

- delete cache

- Delete cache
- some changes

- add hidemode widget feature

- some changes

- - support redirect links (pinger work)
- - some fixes tun on android

- Update README.md
- Update README.md
- Delete cache
- tun mode android bug fixes

- some changes

- add ru locale instalation, some bugfixes

- some changes

- some changes

- Merge branch 'main' of https://github.com/pluralplay/FlClashX

- release 1

- Delete services/helper/target directory
- some changes

- Release 1

- Merge pull request #2 from pluralplay/dev

- final dev build v.0.0.1
- final dev build v.0.0.1

- Merge pull request #1 from pluralplay/dev

- new features
- add announce widget, change default settings

- add HWID

- Update changelog

- Fix windows tun issues

- Optimize android get system dns

- Optimize more details

- Update changelog

- Support override script

- Support proxies search

- Support svg display

- Optimize config persistence

- Add some scenes auto close connections

- Update core

- Optimize more details

- Fix issues that TUN repeat failed to open.

- Update changelog

- Fix windows service verify issues

- Update changelog

- Add windows server mode start process verify

- Add linux deb dependencies

- Add backup recovery strategy select

- Support custom text scaling

- Optimize the display of different text scale

- Optimize windows setup experience

- Optimize startTun performance

- Optimize android tv experience

- Optimize default option

- Optimize computed text size

- Optimize hyperOS freeform window

- Add developer mode

- Update core

- Optimize more details

- Add issues template

- Update changelog

- Optimize android vpn performance

- Add custom primary color and color scheme

- Add linux nad windows arm release

- Optimize requests and logs page

- Fix map input page delete issues

- Update changelog

- Add rule override

- Update core

- Optimize more details

- Update changelog

- Optimize dashboard performance

- Fix some issues

- Fix unselected proxy group delay issues

- Fix asn url issues

- Update changelog

- Fix tab delay view issues

- Fix tray action issues

- Fix get profile redirect client ua issues

- Fix proxy card delay view issues

- Add Russian, Japanese adaptation

- Fix some issues

- Update changelog

- Fix list form input view issues

- Fix traffic view issues

- Update changelog

- Optimize performance

- Update core

- Optimize core stability

- Fix linux tun authority check error

- Fix some issues

- Fix scroll physics error

- Update changelog

- Add windows storage corruption detection

- Fix core crash caused by windows resource manager restart

- Optimize logs, requests, access to pages

- Fix macos bypass domain issues

- Update changelog

- Fix some issues

- Update changelog

- Update popup menu

- Add file editor

- Fix android service issues

- Optimize desktop background performance

- Optimize android main process performance

- Optimize delay test

- Optimize vpn protect

- Update changelog

- Update core

- Fix some issues

- Update changelog

- Remake dashboard

- Optimize theme

- Optimize more details

- Update flutter version

- Update changelog

- Support better window position memory

- Add windows arm64 and linux arm64 build script

- Optimize some details

- Remake desktop

- Optimize change proxy

- Optimize network check

- Fix fallback issues

- Optimize lots of details

- Update change.yaml

- Fix android tile issues

- Fix windows tray issues

- Support setting bypassDomain

- Update flutter version

- Fix android service issues

- Fix macos dock exit button issues

- Add route address setting

- Optimize provider view

- Update changelog

- Update CHANGELOG.md

- Add android shortcuts

- Fix init params issues

- Fix dynamic color issues

- Optimize navigator animate

- Optimize window init

- Optimize fab

- Optimize save

- Fix the collapse issues

- Add fontFamily options

- Update core version

- Update flutter version

- Optimize ip check

- Optimize url-test

- Update release message

- Init auto gen changelog

- Fix windows tray issues

- Fix urltest issues

- Add auto changelog

- Fix windows admin auto launch issues

- Add android vpn options

- Support proxies icon configuration

- Optimize android immersion display

- Fix some issues

- Optimize ip detection

- Support android vpn ipv6 inbound switch

- Support log export

- Optimize more details

- Fix android system dns issues

- Optimize dns default option

- Fix some issues

- Update readme

- Fix build error2

- Fix build error

- Support desktop hotkey

- Support android ipv6 inbound

- Support android system dns

- fix some bugs

- Fix delete profile error

- Fix submit error 2

- Fix submit error

- Optimize DNS strategy

- Fix the problem that the tray is not displayed in some cases

- Optimize tray

- Update core

- Fix some error

- Fix tun update issues

- Add DNS override
- Fixed some bugs
- Optimize more detail

- Add Hosts override

- fix android tip error
- fix windows auto launch error

- Fix windows tray issues

- Optimize windows logic

- Optimize app logic

- Support windows administrator auto launch

- Support android close vpn

- Change flutter version

- Support profiles sort

- Support windows country flags display

- Optimize proxies page and profiles page columns

- Update flutter version

- Update version

- Update timeout time

- Update access control page

- Fix bug

- Optimize provider page

- Optimize delay test

- Support local backup and recovery

- Fix android tile service issues

- Fix linux core build error

- Add proxy-only traffic statistics

- Update core

- Optimize more details

- Add fdroid-repo

- Optimize proxies page

- Fix ua issues

- Optimize more details

- Fix windows build error

- Update app icon

- Fix desktop backup error

- Optimize request ua

- Change android icon

- Optimize dashboard

- Remove request validate certificate

- Sync core

- Fix windows error

- Fix setup.dart error

- Fix android system proxy not effective

- Add macos arm64

- Optimize proxies page

- Support mouse drag scroll

- Adjust desktop ui

- Revert "Fix android vpn issues"

- This reverts commit 891977408e6938e2acd74e9b9adb959c48c79988.

- Fix android vpn issues

- Fix android vpn issues

- Rollback partial modification

- Fix the problem that ui can't be synchronized when android vpn is occupied by an external

- Override default socksPort,port

- Fix fab issues

- Update version

- Fix the problem that vpn cannot be started in some cases

- Fix the problem that geodata url does not take effect

- Update ua

- Fix change outbound mode without check ip issues

- Separate android ui and vpn

- Fix url validate issues 2

- Add android hidden from the recent task

- Add geoip file

- Support modify geoData URL

- Fix url validate issues

- Fix check ip performance problem

- Optimize resources page

- Add ua selector

- Support modify test url

- Optimize android proxy

- Fix the error that async proxy provider could not selected the proxy

- Fix android proxy error

- Fix submit error

- Add windows tun

- Optimize android proxy

- Optimize change profile

- Update application ua

- Optimize delay test

- Fix android repeated request notification issues

- Fix memory overflow issues

- Optimize proxies expansion panel 2

- Fix android scan qrcode error

- Optimize proxies expansion panel

- Fix text error

- Optimize proxy

- Optimize delayed sorting performance

- Add expansion panel proxies page

- Support to adjust the proxy card size

- Support to adjust proxies columns number

- Fix autoRun show issues

- Fix Android 10 issues

- Optimize ip show

- Add intranet IP display

- Add connections page

- Add search in connections, requests

- Add keyword search in connections, requests, logs

- Add basic viewing editing capabilities

- Optimize update profile

- Update version

- Fix the problem of excessive memory usage in traffic usage.

- Add lightBlue theme color

- Fix start unable to update profile issues

- Fix flashback caused by process

- Add build version

- Optimize quick start

- Update system default option

- Update build.yml

- Fix android vpn close issues

- Add requests page

- Fix checkUpdate dark mode style error

- Fix quickStart error open app

- Add memory proxies tab index

- Support hidden group

- Optimize logs

- Fix externalController hot load error

- Add tcp concurrent switch

- Add system proxy switch

- Add geodata loader switch

- Add external controller switch

- Add auto gc on trim memory

- Fix android notification error

- Fix ipv6 error

- Fix android udp direct error

- Add ipv6 switch

- Add access all selected button

- Remove android low version splash

- Update version

- Add allowBypass

- Fix Android only pick .text file issues

- Fix search issues

- Fix LoadBalance, Relay load error

- Fix build.yml4

- Fix build.yml3

- Fix build.yml2

- Fix build.yml

- Add search function at access control

- Fix the issues with the profile add button to cover the edit button

- Adapt LoadBalance and Relay

- Add arm

- Fix android notification icon error

- Add one-click update all profiles
- Add expire show

- Temp remove tun mode

- Remove macos in workflow

- Change go version

- Update Version

- Fix tun unable to open

- Optimize delay test2

- Optimize delay test

- Add check ip

- add check ip request

- Fix the problem that the download of remote resources failed after GeodataMode was turned on, which caused the application to flash back.

- Fix edit profile error

- Fix quickStart change proxy error

- Fix core version

- Fix core version

- Update file_picker

- Add resources page

- Optimize more detail

- Add access selected sorted

- Fix notification duplicate creation issue

- Fix AccessControl click issue

- Fix Workflow

- Fix Linux unable to open

- Update README.md 3

- Create LICENSE
- Update README.md 2

- Update README.md

- Optimize workFlow

- optimize checkUpdate

- Fix submit error

- add WebDAV

- add Auto check updates

- Optimize more details

- optimize delayTest

- upgrade flutter version

- Update kernel
- Add import profile via QR code image

- Add compatibility mode and adapt clash scheme.

- update Version

- Reconstruction application proxy logic

- Fix Tab destroy error

- Optimize repeat healthcheck

- Optimize Direct mode ui

- Optimize Healthcheck

- Remove proxies position animation, improve performance
- Add Telegram Link

- Update healthcheck policy

- New Check URLTest

- Fix the problem of invalid auto-selection

- New Async UpdateConfig

- add changeProfileDebounce

- Update Workflow

- Fix ChangeProfile block

- Fix Release Message Error

- Update Selector 2

- Update Version

- Fix Proxies Select Error

- Fix the problem that the proxy group is empty in global mode.

- Fix the problem that the proxy group is empty in global mode.

- Add ProxyProvider2

- Add ProxyProvider

- Update Version

- Update ProxyGroup Sort

- Fix Android quickStart VpnService some problems

- Update version

- Set Android notification low importance

- Fix the issue that VpnService can't be closed correctly in special cases

- Fix the problem that TileService is not destroyed correctly in some cases

- Adjust tab animation defaults

- Add Telegram in README_zh_CN.md

- Add Telegram

- update mobile_scanner

- Initial commit

## v0.8.86

- Fix windows tun issues

- Optimize android get system dns

- Optimize more details

- Update changelog

## v0.8.85

- Support override script

- Support proxies search

- Support svg display

- Optimize config persistence

- Add some scenes auto close connections

- Update core

- Optimize more details

## v0.8.84

- Fix windows service verify issues

- Update changelog

## v0.8.83

- Add windows server mode start process verify

- Add linux deb dependencies

- Add backup recovery strategy select

- Support custom text scaling

- Optimize the display of different text scale

- Optimize windows setup experience

- Optimize startTun performance

- Optimize android tv experience

- Optimize default option

- Optimize computed text size

- Optimize hyperOS freeform window

- Add developer mode

- Update core

- Optimize more details

- Add issues template

- Update changelog

## v0.8.82

- Optimize android vpn performance

- Add custom primary color and color scheme

- Add linux nad windows arm release

- Optimize requests and logs page

- Fix map input page delete issues

- Update changelog

## v0.8.81

- Add rule override

- Update core

- Optimize more details

- Update changelog

## v0.8.80

- Optimize dashboard performance

- Fix some issues

- Fix unselected proxy group delay issues

- Fix asn url issues

- Update changelog

## v0.8.79

- Fix tab delay view issues

- Fix tray action issues

- Fix get profile redirect client ua issues

- Fix proxy card delay view issues

- Add Russian, Japanese adaptation

- Fix some issues

- Update changelog

## v0.8.78

- Fix list form input view issues

- Fix traffic view issues

- Update changelog

## v0.8.77

- Optimize performance

- Update core

- Optimize core stability

- Fix linux tun authority check error

- Fix some issues

- Fix scroll physics error

- Update changelog

## v0.8.75

- Add windows storage corruption detection

- Fix core crash caused by windows resource manager restart

- Optimize logs, requests, access to pages

- Fix macos bypass domain issues

- Update changelog

## v0.8.74

- Fix some issues

- Update changelog

## v0.8.73

- Update popup menu

- Add file editor

- Fix android service issues

- Optimize desktop background performance

- Optimize android main process performance

- Optimize delay test

- Optimize vpn protect

- Update changelog

## v0.8.72

- Update core

- Fix some issues

- Update changelog

## v0.8.71

- Remake dashboard

- Optimize theme

- Optimize more details

- Update flutter version

- Update changelog

## v0.8.70

- Support better window position memory

- Add windows arm64 and linux arm64 build script

- Optimize some details

## v0.8.69

- Remake desktop

- Optimize change proxy

- Optimize network check

- Fix fallback issues

- Optimize lots of details

- Update change.yaml

- Fix android tile issues

- Fix windows tray issues

- Support setting bypassDomain

- Update flutter version

- Fix android service issues

- Fix macos dock exit button issues

- Add route address setting

- Optimize provider view

- Update changelog

- Update CHANGELOG.md

## v0.8.67

- Add android shortcuts

- Fix init params issues

- Fix dynamic color issues

- Optimize navigator animate

- Optimize window init

- Optimize fab

- Optimize save

## v0.8.66

- Fix the collapse issues

- Add fontFamily options

## v0.8.65

- Update core version

- Update flutter version

- Optimize ip check

- Optimize url-test

## v0.8.64

- Update release message

- Init auto gen changelog

- Fix windows tray issues

- Fix urltest issues

- Add auto changelog

- Fix windows admin auto launch issues

- Add android vpn options

- Support proxies icon configuration

- Optimize android immersion display

- Fix some issues

- Optimize ip detection

- Support android vpn ipv6 inbound switch

- Support log export

- Optimize more details

- Fix android system dns issues

- Optimize dns default option

- Fix some issues

- Update readme

## v0.8.60

- Fix build error2

- Fix build error

- Support desktop hotkey

- Support android ipv6 inbound

- Support android system dns

- fix some bugs

## v0.8.59

- Fix delete profile error

## v0.8.58

- Fix submit error 2

- Fix submit error

- Optimize DNS strategy

- Fix the problem that the tray is not displayed in some cases

- Optimize tray

- Update core

- Fix some error

## v0.8.57

- Fix tun update issues

- Add DNS override
- Fixed some bugs
- Optimize more detail

- Add Hosts override

## v0.8.56

- fix android tip error
- fix windows auto launch error

## v0.8.55

- Fix windows tray issues

- Optimize windows logic

- Optimize app logic

- Support windows administrator auto launch

- Support android close vpn

## v0.8.53

- Change flutter version

- Support profiles sort

- Support windows country flags display

- Optimize proxies page and profiles page columns

## v0.8.52

- Update flutter version

- Update version

- Update timeout time

- Update access control page

- Fix bug

## v0.8.51

- Optimize provider page

- Optimize delay test

- Support local backup and recovery

- Fix android tile service issues

## v0.8.49

- Fix linux core build error

- Add proxy-only traffic statistics

- Update core

- Optimize more details

- Merge pull request #140 from txyyh/main

- 添加自建 F-Droid 仓库相关 workflow
- Rename readme fingerprint

- Rename workflow deploy repo name

- Add download guide to README

- Add push release files to fdroid-repo

## v0.8.48

- Optimize proxies page

- Fix ua issues

- Optimize more details

## v0.8.47

- Fix windows build error

## v0.8.46

- Update app icon

- Fix desktop backup error

- Optimize request ua

- Change android icon

- Optimize dashboard

## v0.8.44

- Remove request validate certificate

- Sync core

## v0.8.43

- Fix windows error

## v0.8.42

- Fix setup.dart error

- Fix android system proxy not effective

- Add macos arm64

## v0.8.41

- Optimize proxies page

- Support mouse drag scroll

- Adjust desktop ui

- Revert "Fix android vpn issues"

- This reverts commit 891977408e6938e2acd74e9b9adb959c48c79988.

## v0.8.40

- Fix android vpn issues

- Fix android vpn issues

- Rollback partial modification

## v0.8.39

- Fix the problem that ui can't be synchronized when android vpn is occupied by an external

- Override default socksPort,port

## v0.8.38

- Fix fab issues

## v0.8.37

- Update version

- Fix the problem that vpn cannot be started in some cases

- Fix the problem that geodata url does not take effect

## v0.8.36

- Update ua

- Fix change outbound mode without check ip issues

- Separate android ui and vpn

- Fix url validate issues 2

- Add android hidden from the recent task

- Add geoip file

- Support modify geoData URL

## v0.8.35

- Fix url validate issues

- Fix check ip performance problem

- Optimize resources page

## v0.8.34

- Add ua selector

- Support modify test url

- Optimize android proxy

- Fix the error that async proxy provider could not selected the proxy

## v0.8.33

- Fix android proxy error

- Fix submit error

- Add windows tun

- Optimize android proxy

- Optimize change profile

- Update application ua

- Optimize delay test

## v0.8.32

- Fix android repeated request notification issues

## v0.8.31

- Fix memory overflow issues

## v0.8.30

- Optimize proxies expansion panel 2

- Fix android scan qrcode error

## v0.8.29

- Optimize proxies expansion panel

- Fix text error

## v0.8.28

- Optimize proxy

- Optimize delayed sorting performance

- Add expansion panel proxies page

- Support to adjust the proxy card size

- Support to adjust proxies columns number

- Fix autoRun show issues

- Fix Android 10 issues

- Optimize ip show

## v0.8.26

- Add intranet IP display

- Add connections page

- Add search in connections, requests

- Add keyword search in connections, requests, logs

- Add basic viewing editing capabilities

- Optimize update profile

## v0.8.25

- Update version

- Fix the problem of excessive memory usage in traffic usage.

- Add lightBlue theme color

- Fix start unable to update profile issues

- Fix flashback caused by process

## v0.8.23

- Add build version

- Optimize quick start

- Update system default option

## v0.8.22

- Update build.yml

- Fix android vpn close issues

- Add requests page

- Fix checkUpdate dark mode style error

- Fix quickStart error open app

- Add memory proxies tab index

- Support hidden group

- Optimize logs

- Fix externalController hot load error

## v0.8.21

- Add tcp concurrent switch

- Add system proxy switch

- Add geodata loader switch

- Add external controller switch

- Add auto gc on trim memory

- Fix android notification error

## v0.8.20

- Fix ipv6 error

- Fix android udp direct error

- Add ipv6 switch

- Add access all selected button

- Remove android low version splash

## v0.8.19

- Update version

- Add allowBypass

- Fix Android only pick .text file issues

## v0.8.18

- Fix search issues

## v0.8.17

- Fix LoadBalance, Relay load error

- Fix build.yml4

- Fix build.yml3

- Fix build.yml2

- Fix build.yml

- Add search function at access control

- Fix the issues with the profile add button to cover the edit button

- Adapt LoadBalance and Relay

- Add arm

- Fix android notification icon error

## v0.8.16

- Add one-click update all profiles
- Add expire show

## v0.8.15

- Temp remove tun mode

- Remove macos in workflow

- Change go version

## v0.8.14

- Update Version

- Fix tun unable to open

## v0.8.13

- Optimize delay test2

- Optimize delay test

- Add check ip

- add check ip request

## v0.8.12

- Fix the problem that the download of remote resources failed after GeodataMode was turned on, which caused the
  application to flash back.

- Fix edit profile error

- Fix quickStart change proxy error

- Fix core version

## v0.8.10

- Fix core version

## v0.8.9

- Update file_picker

- Add resources page

- Optimize more detail

- Add access selected sorted

- Fix notification duplicate creation issue

- Fix AccessControl click issue

## v0.8.7

- Fix Workflow

- Fix Linux unable to open

- Update README.md 3

- Create LICENSE
- Update README.md 2

- Update README.md

- Optimize workFlow

## v0.8.6

- optimize checkUpdate

## v0.8.5

- Fix submit error

## v0.8.4

- add WebDAV

- add Auto check updates

- Optimize more details

- optimize delayTest

## v0.8.2

- upgrade flutter version

## v0.8.1

- Update kernel
- Add import profile via QR code image

## v0.8.0

- Add compatibility mode and adapt clash scheme.

## v0.7.14

- update Version

- Reconstruction application proxy logic

## v0.7.13

- Fix Tab destroy error

## v0.7.12

- Optimize repeat healthcheck

## v0.7.11

- Optimize Direct mode ui

## v0.7.10

- Optimize Healthcheck

- Remove proxies position animation, improve performance
- Add Telegram Link

- Update healthcheck policy

- New Check URLTest

- Fix the problem of invalid auto-selection

## v0.7.8

- New Async UpdateConfig

- add changeProfileDebounce

- Update Workflow

- Fix ChangeProfile block

- Fix Release Message Error

## v0.7.7

- Update Selector 2

## v0.7.6

- Update Version

- Fix Proxies Select Error

## v0.7.5

- Fix the problem that the proxy group is empty in global mode.

- Fix the problem that the proxy group is empty in global mode.

## v0.7.4

- Add ProxyProvider2

## v0.7.3

- Add ProxyProvider

- Update Version

- Update ProxyGroup Sort

- Fix Android quickStart VpnService some problems

## v0.7.1

- Update version

- Set Android notification low importance

- Fix the issue that VpnService can't be closed correctly in special cases

- Fix the problem that TileService is not destroyed correctly in some cases

- Adjust tab animation defaults

- Add Telegram in README_zh_CN.md

- Add Telegram

## v0.7.0

- update mobile_scanner

- Initial commit