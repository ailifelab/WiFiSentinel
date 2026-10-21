#!/bin/zsh
set -eu
PROJECT="${0:A:h:h}"
cd "$PROJECT"
NATIVE="$PROJECT/.build/rewrite5-exit0"
APP="$PROJECT/build/candidates/rewrite5-exit0/WiFiSentinel.app"
CACHE="${WIFISENTINEL_MODULE_CACHE:-$PROJECT/.build/modules}"
mkdir -p "$NATIVE" "$CACHE" "$APP/Contents/MacOS" "$APP/Contents/Resources"
TARGET="$(uname -m)-apple-macosx13.0"
swiftc -swift-version 5 -target "$TARGET" -O -parse-as-library -enable-testing -emit-library -static -emit-module \
  -module-name RecoveryCore -module-cache-path "$CACHE" Sources/RecoveryCore/*.swift -o "$NATIVE/libRecoveryCore.a"
swiftc -swift-version 5 -target "$TARGET" -O -parse-as-library -I "$NATIVE" -L "$NATIVE" -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/*.swift -o "$APP/Contents/MacOS/WiFiSentinel"
cp Info.plist "$APP/Contents/Info.plist"
WIFISENTINEL_CANDIDATE_PATH="$APP" python3 - <<'PY'
from pathlib import Path
import hashlib,json,datetime,os,plistlib,subprocess
r=Path.cwd();app=Path(os.environ['WIFISENTINEL_CANDIDATE_PATH']);assert app.resolve() != (r/'build/WiFiSentinel.app').resolve();files=[r/'Info.plist',r/'Package.swift']+sorted((r/'Sources').rglob('*.swift'))
m={str(p.relative_to(r)):hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
info=plistlib.loads((r/'Info.plist').read_bytes());git=subprocess.run(['git','rev-parse','HEAD'],text=True,capture_output=True);commit=git.stdout.strip() if git.returncode==0 else None
v={'createdUTC':datetime.datetime.now(datetime.timezone.utc).isoformat(),'version':info['CFBundleShortVersionString'],'rewriteBuild':info['CFBundleVersion'],'sourceCommit':commit,'sourceTreeDirty':bool(subprocess.check_output(['git','status','--porcelain'],text=True).strip()) if commit else None,'architecture':os.uname().machine,'minimumSystemVersion':info['LSMinimumSystemVersion'],'recordStage':'compiler output before distribution signing','sourceSHA256':m,'binarySHA256BeforeSigning':hashlib.sha256((app/'Contents/MacOS/WiFiSentinel').read_bytes()).hexdigest(),'codesignInvokedByBuildScript':False,'notarizationPerformedByBuildScript':False,'distributionPerformedByBuildScript':False,'note':'Compiler may embed an initial ad hoc signature. Final signature identity and binary hash are recorded outside the sealed bundle after signing; no notarization or distribution is implied.'}
(app/'Contents/Resources/BuildInfo.json').write_text(json.dumps(v,indent=2)+'\n')
print(json.dumps(v,indent=2))
PY
