!define APPNAME "tiecook2"
!define VERSION "1.0.0"

Name "${APPNAME}"
OutFile "tiecook2-setup.exe"
InstallDir "$LOCALAPPDATA\Programs\${APPNAME}"
RequestExecutionLevel user

Page directory
Page instfiles
UninstPage uninstConfirm
UninstPage instfiles

Section "Install"
  SetOutPath "$INSTDIR"
  File "tiecook2.exe"
  File "libssl-1_1-x64.dll"
  File "libcrypto-1_1-x64.dll"
  File "libssp-0.dll"
  File "config.example"

  CreateDirectory "$APPDATA\${APPNAME}"
  IfFileExists "$APPDATA\${APPNAME}\config.ini" ConfigExists 0
    CopyFiles "$INSTDIR\config.example" "$APPDATA\${APPNAME}\config.ini"
  ConfigExists:

  CreateDirectory "$SMPROGRAMS\${APPNAME}"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\tiecook2.lnk" "$INSTDIR\tiecook2.exe"
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Edit Config.lnk" "notepad.exe" '"$APPDATA\${APPNAME}\config.ini"'
  CreateShortcut "$SMPROGRAMS\${APPNAME}\Uninstall.lnk" "$INSTDIR\uninstall.exe"

  WriteUninstaller "$INSTDIR\uninstall.exe"
SectionEnd

Section "Uninstall"
  Delete "$INSTDIR\tiecook2.exe"
  Delete "$INSTDIR\libssl-1_1-x64.dll"
  Delete "$INSTDIR\libcrypto-1_1-x64.dll"
  Delete "$INSTDIR\libssp-0.dll"
  Delete "$INSTDIR\config.example"
  Delete "$INSTDIR\uninstall.exe"
  RMDir "$INSTDIR"

  Delete "$SMPROGRAMS\${APPNAME}\tiecook2.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\Edit Config.lnk"
  Delete "$SMPROGRAMS\${APPNAME}\Uninstall.lnk"
  RMDir "$SMPROGRAMS\${APPNAME}"

  ; the user's config.ini and recipe library are left in place on uninstall
SectionEnd
