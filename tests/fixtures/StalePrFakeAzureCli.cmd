@echo off
node.exe "%~dp0StalePrFakeAzureCli.mjs" %*
exit /b %ERRORLEVEL%
