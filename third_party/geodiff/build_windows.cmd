@echo off
rem geodiff.dll（Windows x64）を焼く。ホスト VM のテスト（flutter test）で使う。
rem 依存: Visual Studio（cl/lib）と Android SDK 同梱の cmake/ninja。
rem 出力: third_party\geodiff\windows\geodiff.dll（sqlite3 は静的に同梱）
rem 使い方: third_party\geodiff\build_windows.cmd [作業dir]
setlocal
rem 取得物は中身を固定する（版を上げるときは URL と SHA を組で書き換える。build_android.sh と揃える）
set GEODIFF_TAG=2.3.1
set GEODIFF_SHA=f32842c79effd1be5b74140d295a1b0bb9ee521c
set SQLITE_ZIP=https://sqlite.org/2026/sqlite-amalgamation-3530400.zip
set SQLITE_SHA256=1e71ddf93849c6a6ecf58b827c0692073d2dd7ee40196158068f7b29f422e87d
set LIBGPKG_URL=https://github.com/benstadin/libgpkg/archive/0822c5cba7e1ac2c2806e445e5f5dd2f0d0a18b4.tar.gz
set LIBGPKG_SHA256=2039f928724c57d7e8ba2983532346506cde48437e764efa243fbc6ba24fd1ba
set REPO=%~dp0..\..
if "%~1"=="" (set W=%REPO%\build\geodiff-win) else (set W=%~1)
if not exist "%W%" mkdir "%W%"
set SDK=%LOCALAPPDATA%\Android\Sdk
set CM=%SDK%\cmake\3.22.1\bin\cmake.exe
set NJ=%SDK%\cmake\3.22.1\bin\ninja.exe

for /f "usebackq delims=" %%i in (`"%ProgramFiles(x86)%\Microsoft Visual Studio\Installer\vswhere.exe" -latest -property installationPath`) do set VS=%%i
call "%VS%\VC\Auxiliary\Build\vcvars64.bat" >nul || exit /b 1
cd /d "%W%"

if not exist sqlite.zip curl -fsSL -o sqlite.zip %SQLITE_ZIP% || exit /b 1
call :verify sqlite.zip %SQLITE_SHA256% || exit /b 1
for /f "delims=" %%d in ('tar tf sqlite.zip ^| findstr /r "^[^/]*/$"') do set SQL_DIR=%%d
set SQL_DIR=%SQL_DIR:/=%
if not exist "%SQL_DIR%" tar xf sqlite.zip || exit /b 1

if not exist sqlite-x64 mkdir sqlite-x64
cd sqlite-x64
cl /nologo /O2 /MD /c ..\%SQL_DIR%\sqlite3.c /DSQLITE_ENABLE_SESSION /DSQLITE_ENABLE_PREUPDATE_HOOK /DSQLITE_ENABLE_RTREE /DSQLITE_ENABLE_COLUMN_METADATA /DSQLITE_ENABLE_FTS5 /DSQLITE_THREADSAFE=1 /DSQLITE_DEFAULT_MEMSTATUS=0 || exit /b 1
lib /nologo /out:sqlite3.lib sqlite3.obj || exit /b 1
cd ..

if not exist geodiff (
  git init -q geodiff || exit /b 1
  git -C geodiff fetch -q --depth 1 https://github.com/MerginMaps/geodiff.git %GEODIFF_SHA% || exit /b 1
  git -C geodiff checkout -q FETCH_HEAD || exit /b 1
)
for /f %%h in ('git -C geodiff rev-parse HEAD') do set GOT_SHA=%%h
if not "%GOT_SHA%"=="%GEODIFF_SHA%" (echo geodiff が %GEODIFF_SHA% ではない。作業dirの geodiff を消して焼き直す & exit /b 1)
if not exist build-x64 mkdir build-x64
cd build-x64
rem libgpkg は geodiff の CMake が取りにいく。先に落として照合しておくと CMake は取得を飛ばす
if not exist libgpkg.tar.gz curl -fsSL -o libgpkg.tar.gz %LIBGPKG_URL% || exit /b 1
call :verify libgpkg.tar.gz %LIBGPKG_SHA256% || exit /b 1
"%CM%" -G Ninja -DCMAKE_MAKE_PROGRAM="%NJ%" -DCMAKE_BUILD_TYPE=Release -DCMAKE_C_COMPILER=cl -DCMAKE_CXX_COMPILER=cl ^
  -DBUILD_SHARED=ON -DBUILD_STATIC=OFF -DBUILD_TOOLS=OFF -DENABLE_TESTS=OFF -DWITH_POSTGRESQL=OFF -DPEDANTIC=OFF ^
  -DSQLite3_INCLUDE_DIR="%W%\%SQL_DIR%" -DSQLite3_LIBRARY="%W%\sqlite-x64\sqlite3.lib" ^
  "%W%\geodiff\geodiff" >nul || exit /b 1
"%NJ%" || exit /b 1
cd ..

if not exist "%REPO%\third_party\geodiff\windows" mkdir "%REPO%\third_party\geodiff\windows"
copy /y build-x64\geodiff.dll "%REPO%\third_party\geodiff\windows\geodiff.dll" >nul
echo == 出力: %REPO%\third_party\geodiff\windows\geodiff.dll
exit /b 0

rem %1 のファイルが SHA-256 %2 でなければ消して失敗を返す
:verify
set GOT=
for /f "skip=1 delims=" %%h in ('certutil -hashfile "%~1" SHA256') do if not defined GOT set GOT=%%h
set GOT=%GOT: =%
if /i "%GOT%"=="%~2" exit /b 0
echo SHA-256 不一致: %~1 (got %GOT%, want %~2)
del /q "%~1"
exit /b 1
