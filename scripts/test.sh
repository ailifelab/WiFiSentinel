#!/bin/zsh
set -eu
PROJECT="${0:A:h:h}"
cd "$PROJECT"
CACHE="${WIFISENTINEL_MODULE_CACHE:-$PROJECT/.build/modules}"
mkdir -p .build/tests
export WIFISENTINEL_OFFLINE_ENV_FIXTURE=offline-child-inherited-value
swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Tests/CoreTests.swift -o .build/tests/CoreTests
.build/tests/CoreTests
for SUITE in PolicyTests CycleTests; do
  swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
    -module-cache-path "$CACHE" "Tests/$SUITE.swift" -o ".build/tests/$SUITE"
  ".build/tests/$SUITE"
done
swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Sources/WiFiSentinel/LocalIPC.swift Tests/OfflineCycleFixture.swift -o .build/tests/OfflineCycleFixture
swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Tests/IPCRecoveryTests.swift -o .build/tests/IPCRecoveryTests
.build/tests/IPCRecoveryTests
swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Sources/WiFiSentinel/LocalIPC.swift Sources/WiFiSentinel/Store.swift Sources/WiFiSentinel/SnapshotWriter.swift Sources/WiFiSentinel/WebPulse.swift Sources/WiFiSentinel/NativeBackend.swift Sources/WiFiSentinel/KnownNetworkAdapter.swift Tests/AdapterTests.swift -o .build/tests/AdapterTests
.build/tests/AdapterTests

swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Sources/WiFiSentinel/Store.swift Sources/WiFiSentinel/SnapshotWriter.swift Tests/StorageTests.swift -o .build/tests/StorageTests
.build/tests/StorageTests

swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
  -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Sources/WiFiSentinel/LocalIPC.swift Sources/WiFiSentinel/Store.swift Sources/WiFiSentinel/SnapshotWriter.swift Sources/WiFiSentinel/WebPulse.swift Sources/WiFiSentinel/NativeBackend.swift Sources/WiFiSentinel/KnownNetworkAdapter.swift Tests/KnownNetworkTests.swift -o .build/tests/KnownNetworkTests
.build/tests/KnownNetworkTests

swiftc -swift-version 5 -parse-as-library -I .build/rewrite5-exit0 -L .build/rewrite5-exit0 -lRecoveryCore \
 -module-cache-path "$CACHE" Sources/WiFiSentinel/BoundedProcess.swift Sources/WiFiSentinel/LocalIPC.swift Sources/WiFiSentinel/Store.swift Sources/WiFiSentinel/SnapshotWriter.swift Sources/WiFiSentinel/WebPulse.swift Sources/WiFiSentinel/NativeBackend.swift Sources/WiFiSentinel/KnownNetworkAdapter.swift Sources/WiFiSentinel/LocationAccess.swift Sources/WiFiSentinel/KnownNetworkSession.swift Tests/LocationFlowTests.swift -o .build/tests/LocationFlowTests
.build/tests/LocationFlowTests
