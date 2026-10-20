// swift-tools-version: 5.9
import PackageDescription
let package=Package(name:"WiFiSentinel",platforms:[.macOS(.v13)],products:[.executable(name:"WiFiSentinel",targets:["WiFiSentinel"])],targets:[.target(name:"RecoveryCore"),.executableTarget(name:"WiFiSentinel",dependencies:["RecoveryCore"])])
