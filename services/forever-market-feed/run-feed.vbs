' Runs run-feed.cmd without a console window (no focus steal while playing).
Set shell = CreateObject("WScript.Shell")
dir = CreateObject("Scripting.FileSystemObject").GetParentFolderName(WScript.ScriptFullName)
shell.Run """" & dir & "\run-feed.cmd""", 0, True
