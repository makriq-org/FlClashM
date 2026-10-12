# Windows package

Windows x64 is distributed as an unsigned Inno Setup installer. The release
pipeline verifies its own Ed25519-signed update catalog and SHA-256 package
digest; it does not use Authenticode, suppress SmartScreen, remove Mark of the
Web, or change Windows security settings.

The installer is the only elevated component. It installs the
`app.flclashm.client.helper` service, while `FlClashM.exe` remains an ordinary
interactive-user process. Uninstall keeps user data unless the user explicitly
chooses its removal.

The helper accepts requests only from the installed GUI at the fixed
`%ProgramFiles%\FlClashM` location. Setup rejects custom `/DIR` values and
older installations elsewhere; those must be removed before installing this
version.

An in-app update starts the installer through UAC while the current network
runtime stays active. Once elevation succeeds, the GUI runs its normal network
cleanup and exits. Setup waits for both the GUI and its same-user proxy
watchdog to finish before replacing files. Manual install and uninstall refuse
to proceed while either process is still running. Setup keeps a temporary copy
of the entire previous application directory and restores it together with the
helper service if installation fails. The final install status is written to
`HKLM\Software\FlClashM\InstallResult`; each user records their own
receipt after reading it. Windows mihomo updates are delivered only in the full
application package.
