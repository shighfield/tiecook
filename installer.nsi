!define APPNAME "tiecook"
!define VERSION "1.0.0"

Name "${APPNAME}"
OutFile "tiecook-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
RequestExecutionLevel user

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File "tiecook.exe"
  File "libssl-1_1-x64.dll"
  File "libcrypto-1_1-x64.dll"
  File "libssp-0.dll"
  File "config.example"

  CreateDirectory "$APPDATA\tiecook"
  IfFileExists "$APPDATA\tiecook\config" ConfigExists 0
    CopyFiles "$INSTDIR\config.example" "$APPDATA\tiecook\config"
  ConfigExists:

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\tiecook.lnk" "$INSTDIR\tiecook.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Edit Config.lnk" "notepad.exe" '"$APPDATA\tiecook\config"'
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall.lnk" "$INSTDIR\uninstall.exe"

  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\tiecook.exe"
  Delete "$INSTDIR\libssl-1_1-x64.dll"
  Delete "$INSTDIR\libcrypto-1_1-x64.dll"
  Delete "$INSTDIR\libssp-0.dll"
  Delete "$INSTDIR\config.example"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\${APPNAME}\tiecook.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\Edit Config.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\Uninstall.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"

  ; config file (real token) is left in place on uninstall, not deleted
SectionEnd
