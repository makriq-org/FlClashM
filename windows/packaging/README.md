# Windows package

Windows x64 is distributed as an unsigned Inno Setup installer. The release
pipeline verifies its own Ed25519-signed update catalog and SHA-256 package
digest; it does not use Authenticode, suppress SmartScreen, remove Mark of the
Web, or change Windows security settings.

The installer is the only elevated component. It installs the
`app.flclashm.client.helper` service, while `FlClashM.exe` remains an ordinary
interactive-user process. Uninstall keeps user data unless the user explicitly
chooses its removal.
