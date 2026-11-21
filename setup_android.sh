#!/usr/bin/env bash
# Genera android/ y aplica la configuración de SONA (media session, permisos).
# Uso (desde la raíz del proyecto): bash tool/setup_android.sh
set -euo pipefail

# flutter create no debe pisar nuestros archivos
mkdir -p /tmp/sona_bak && cp -r pubspec.yaml lib /tmp/sona_bak/
flutter create --platforms=android,windows,linux --org app.sona --project-name sona .
cp /tmp/sona_bak/pubspec.yaml pubspec.yaml
rm -rf lib && cp -r /tmp/sona_bak/lib lib
rm -rf test

# Iconos de bandeja de relleno (solo se usan en escritorio) si no existen
mkdir -p assets/tray
python3 - <<'EOF'
import base64, os
png = base64.b64decode("iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")
for n in ("tray.png", "tray.ico"):
    p = os.path.join("assets/tray", n)
    if not os.path.exists(p):
        open(p, "wb").write(png)
EOF

# MainActivity con AudioServiceActivity
KT_DIR=android/app/src/main/kotlin/app/sona/sona
mkdir -p "$KT_DIR"
cat > "$KT_DIR/MainActivity.kt" <<'EOF'
package app.sona.sona

import com.ryanheise.audioservice.AudioServiceActivity

class MainActivity : AudioServiceActivity()
EOF

# Manifest: permisos + servicio + receptor de botones multimedia
python3 - <<'EOF'
import re
p = "android/app/src/main/AndroidManifest.xml"
s = open(p, encoding="utf-8").read()
if "READ_MEDIA_AUDIO" not in s:
    perms = """
    <uses-permission android:name="android.permission.READ_MEDIA_AUDIO"/>
    <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" android:maxSdkVersion="32"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE"/>
    <uses-permission android:name="android.permission.FOREGROUND_SERVICE_MEDIA_PLAYBACK"/>
    <uses-permission android:name="android.permission.WAKE_LOCK"/>
"""
    s = s.replace("<application", perms + "    <application", 1)
    comps = """
        <service android:name="com.ryanheise.audioservice.AudioService"
            android:foregroundServiceType="mediaPlayback" android:exported="true">
            <intent-filter><action android:name="android.media.browse.MediaBrowserService"/></intent-filter>
        </service>
        <receiver android:name="com.ryanheise.audioservice.MediaButtonReceiver" android:exported="true">
            <intent-filter><action android:name="android.intent.action.MEDIA_BUTTON"/></intent-filter>
        </receiver>
    """
    s = s.replace("</application>", comps + "</application>", 1)
    open(p, "w", encoding="utf-8").write(s)
EOF

echo "Listo. Ahora: flutter pub get && flutter build apk --release"
