#!/bin/bash

# abort script if any command fails
set -e

release=""
ptb=""

BUILD_DIR="source/build"
SOURCE_DIR="source"

if [ -n "$GITHUB_REPOSITORY" ] ; then
  BUILD_DIR=$BUILD_FOLDER
  SOURCE_DIR=$GITHUB_WORKSPACE
fi

# find out if we do a release build
while getopts ":pr:" option; do
  if [ "${option}" = "r" ]; then
    release="${OPTARG}"
    version="${OPTARG}"
    shift $((OPTIND-1))
  elif [ "${option}" = "p" ]; then
    ptb="yep"
    shift $((OPTIND-1))
  else
    echo "Unknown option -${option}"
    exit 1
  fi
done
if [ -z "${release}" ]; then
  version="${1}"
fi

# setup linuxdeployqt binary if not found
if [ "$(getconf LONG_BIT)" = "64" ]; then
  if [[ ! -e linuxdeployqt.AppImage ]]; then
      # download prepackaged linuxdeployqt. Doesn't seem to have a "latest" url yet
      echo "linuxdeployqt not found - downloading one."
      wget --quiet -O linuxdeployqt.AppImage https://github.com/probonopd/linuxdeployqt/releases/download/continuous/linuxdeployqt-continuous-x86_64.AppImage
      chmod +x linuxdeployqt.AppImage
  fi
else
  echo "32bit Linux is currently not supported by the AppImage."
  exit 2
fi

# clean up the build/ folder
rm -rf build/
mkdir build

# delete previous appimage as well since we need to regenerate it twice
rm -f Mudlet*.AppImage

# move the binary up to the build folder (they differ between qmake and cmake,
# so we use find to find the binary
find "$BUILD_DIR"/ -iname mudlet -type f -exec cp '{}' build/ \;

if [ "$WITH_SENTRY" = "ON" ]; then
  cp -v "$BUILD_DIR/src/MudletCrashReporter" build/
  cp -v "$BUILD_DIR/src/crashpad_handler" build/
fi

# get mudlet-lua in there as well so linuxdeployqt bundles it
cp -rf "$SOURCE_DIR"/src/mudlet-lua build/
# copy Lua translations
# only copy if folder exists
mkdir -p build/translations/lua
[ -d "$SOURCE_DIR"/translations/lua ] && cp -rf "$SOURCE_DIR"/translations/lua build/translations/
# and the dictionary files in case the user system doesn't have them (at a known
# place)
cp "$SOURCE_DIR"/src/*.dic build/
cp "$SOURCE_DIR"/src/*.aff build/
# and the .desktop file so linuxdeployqt can pilfer it for info
cp "$SOURCE_DIR"/mudlet{.desktop,.png,.svg} build/


cp -r "$SOURCE_DIR"/3rdparty/lcf build/

# now copy Lua modules we need in
# this should be improved not to be hardcoded
mkdir -p build/lib/luasql
mkdir -p build/lib/brimworks

cp "$SOURCE_DIR"/3rdparty/discord/rpc/lib/libdiscord-rpc.so build/lib/

for lib in lfs rex_pcre2 luasql/sqlite3 brimworks/zip lua-utf8 lpeg yajl
do
  found=0
  for path in $(luarocks path --lr-cpath | tr ";" "\n")
  do
    changed_path=${path/\?/${lib}};
    if [ -e "${changed_path}" ]; then
      cp -rL "${changed_path}" build/lib/${lib}.so
      found=1
    fi
  done
  if [ "${found}" -ne "1" ]; then
    echo "Missing dependency ${lib}, aborting."
    exit 1
  fi
done

# extract linuxdeployqt since some environments (like travis) don't allow FUSE
./linuxdeployqt.AppImage --appimage-extract

# a hack to get the Chinese input text plugin for Qt from the Ubuntu package
# into the Qt for /opt package directory
if [ -n "${QTDIR}" ]; then
  sudo cp /usr/lib/x86_64-linux-gnu/qt5/plugins/platforminputcontexts/libfcitxplatforminputcontextplugin.so \
          "${QTDIR}/plugins/platforminputcontexts/libfcitxplatforminputcontextplugin.so" || exit
fi

echo "Generating AppImage"
./squashfs-root/AppRun ./build/mudlet -appimage \
  -executable=build/lib/rex_pcre2.so \
  -executable=build/lib/zip.so \
  -executable=build/lib/luasql/sqlite3.so \
  -executable=build/lib/yajl.so \
  -executable=build/lib/lpeg.so \
  -extra-plugins=texttospeech/libqttexttospeech_flite.so,texttospeech/libqttexttospeech_speechd.so,platforminputcontexts/libcomposeplatforminputcontextplugin.so,platforminputcontexts/libibusplatforminputcontextplugin.so,platforminputcontexts/libfcitxplatforminputcontextplugin.so


# Workaround for qtkeychain password storage issue #6730
# Extract the AppImage, remove bundled libglib, then repackage it
# This is necessary because the bundled libglib-2.0.so.0 library in the AppImage
# conflicts with qtkeychain's ability to access the system's secure storage.
# Solution based on Nextcloud Desktop's approach:
# https://github.com/nextcloud/desktop/blob/master/admin/linux/build-appimage.sh
echo "Applying libglib workaround for password storage (#6730)..."
rm -rf squashfs-root/
TEMP_APPIMAGE=$(ls Mudlet*.AppImage)
chmod +x "${TEMP_APPIMAGE}"
./"${TEMP_APPIMAGE}" --appimage-extract
rm ./"${TEMP_APPIMAGE}"

# Remove the bundled libraries that cause keychain issues
# Check both common library locations (usr/lib and lib)
for lib in libglib-2.0.so.0 libgthread-2.0.so.0; do
  for libpath in ./squashfs-root/usr/lib ./squashfs-root/lib; do
    if [ -f "${libpath}/${lib}" ]; then
      echo "Removing bundled ${lib} from ${libpath}..."
      rm "${libpath}/${lib}"
    fi
  done
done

# Download appimagetool for repackaging
if [ ! -e appimagetool-x86_64.AppImage ]; then
  echo "Downloading appimagetool..."
  wget --quiet -O appimagetool-x86_64.AppImage https://github.com/AppImage/AppImageKit/releases/download/continuous/appimagetool-x86_64.AppImage
  chmod +x appimagetool-x86_64.AppImage
fi

# Repackage the AppImage without libglib
# GitHub Actions supports FUSE, so we can run appimagetool directly
# Use the original filename that was saved earlier
./appimagetool-x86_64.AppImage -n squashfs-root "${TEMP_APPIMAGE}"

# clean up extracted appimage
rm -rf squashfs-root/


if [ -z "${release}" ]; then
  output_name="Mudlet-${version}"
else
  if [ -z "${ptb}" ]; then
    output_name="Mudlet"
  else
    output_name="Mudlet PTB"
  fi
fi

echo "output_name: ${output_name}"
mv Mudlet*.AppImage "$output_name.AppImage"
