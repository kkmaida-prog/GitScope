// swift-tools-version: 5.9
import PackageDescription
let package = Package(name: "GitScope", platforms: [.macOS(.v14)], products: [.library(name: "GitScopeCore", targets: ["GitScopeCore"]), .executable(name: "GitScope", targets: ["GitScope"])], targets: [.target(name: "GitScopeCore", linkerSettings: [.linkedLibrary("sqlite3")]), .executableTarget(name: "GitScope", dependencies: ["GitScopeCore"]), .testTarget(name: "GitScopeCoreTests", dependencies: ["GitScopeCore"])])
