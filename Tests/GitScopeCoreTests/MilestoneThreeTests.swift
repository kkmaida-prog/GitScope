import XCTest
@testable import GitScopeCore

final class MilestoneThreeTests: XCTestCase {
    private let parser = ManifestParser()
    private func declarations(_ text: String, _ path: String) -> [String: DependencyDeclaration] {
        Dictionary(parser.parse(text, path: path).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
    }

    // MARK: Manifests

    func testSwiftAndAppleManifests() throws {
        let package = """
        // swift-tools-version:5.9
        import PackageDescription
        let package = Package(name: "App", platforms: [.macOS(.v14), .iOS("16.4")],
            dependencies: [
                .package(url: "https://github.com/Alamofire/Alamofire.git", .upToNextMajor(from: "5.8.0")),
                .package(url: "https://github.com/apple/swift-collections", exact: "1.0.4"),
                .package(url: "git@github.com:pointfreeco/swift-composable-architecture.git", "1.0.0"..<"2.0.0"),
                .package(url: "https://example.com/tools/Lint.git", branch: "main"),
                .package(path: "../Local")
            ])
        """
        let swift = declarations(package, "Package.swift")
        XCTAssertEqual(swift["Swift tools version"]?.version, "5.9")
        XCTAssertEqual(swift["Swift tools version"]?.kind, .tool)
        XCTAssertEqual(swift["Alamofire"]?.version, "from 5.8.0")
        XCTAssertEqual(swift["swift-collections"]?.version, "exact 1.0.4")
        XCTAssertEqual(swift["swift-composable-architecture"]?.version, "1.0.0..<2.0.0")
        XCTAssertEqual(swift["swift-composable-architecture"]?.kind, .framework)
        XCTAssertEqual(swift["Lint"]?.version, "branch main")
        XCTAssertEqual(swift["macOS deployment target"]?.version, "14")
        XCTAssertEqual(swift["iOS deployment target"]?.version, "16.4")
        XCTAssertNil(swift["Local"])

        let resolved = #"{"pins":[{"identity":"alamofire","kind":"remoteSourceControl","location":"https://github.com/Alamofire/Alamofire.git","state":{"revision":"abc","version":"5.8.1"}}],"version":2}"#
        XCTAssertEqual(declarations(resolved, "Package.resolved")["Alamofire"]?.version, "5.8.1")
        let legacyResolved = #"{"object":{"pins":[{"package":"Kingfisher","repositoryURL":"https://github.com/onevcat/Kingfisher","state":{"branch":null,"revision":"r","version":"6.3.1"}}]},"version":1}"#
        XCTAssertEqual(declarations(legacyResolved, "Package.resolved")["Kingfisher"]?.version, "6.3.1")

        let project = """
        LastUpgradeCheck = 1500;
        SWIFT_VERSION = 5.0;
        SWIFT_VERSION = 6.0;
        IPHONEOS_DEPLOYMENT_TARGET = 15.0;
        repositoryURL = "https://github.com/onevcat/Kingfisher";
        requirement = {
            kind = upToNextMajorVersion;
            minimumVersion = 7.0.0;
        };
        """
        let xcode = declarations(project, "App.xcodeproj/project.pbxproj")
        XCTAssertEqual(xcode["Swift language version"]?.version, "5.0, 6.0")
        XCTAssertEqual(xcode["iOS deployment target"]?.version, "15.0")
        XCTAssertEqual(xcode["Xcode (last upgrade check)"]?.version, "15.0")
        XCTAssertEqual(xcode["Kingfisher"]?.version, "7.0.0")
        XCTAssertTrue(parser.parse(project, path: "docs/project.pbxproj").isEmpty)

        let lock = "PODS:\n  - Alamofire (4.9.1)\n  - Firebase/Core (8.0.0):\n    - FirebaseAnalytics (= 8.0.0)\n\nCOCOAPODS: 1.11.3\n"
        let pods = declarations(lock, "Podfile.lock")
        XCTAssertEqual(pods["Alamofire"]?.version, "4.9.1")
        XCTAssertEqual(pods["Firebase/Core"]?.version, "8.0.0")
        XCTAssertNil(pods["FirebaseAnalytics"])
        XCTAssertEqual(pods["CocoaPods"]?.kind, .tool)
        let podfile = declarations("platform :ios, '13.0'\npod 'SnapKit', '~> 5.0'\n", "Podfile")
        XCTAssertEqual(podfile["SnapKit"]?.version, "~> 5.0")
        XCTAssertEqual(podfile["ios deployment target"]?.version, "13.0")
        XCTAssertEqual(declarations("github \"ReactiveX/RxSwift\" ~> 6.0\n", "Cartfile")["RxSwift"]?.version, "~> 6.0")
    }

    func testOtherEcosystemManifests() {
        let npm = declarations(#"{"dependencies":{"react":"^18.2.0","lodash":"4.17.21"},"devDependencies":{"typescript":"~5.3.0","left-pad":"1.0.0"},"engines":{"node":">=18"},"packageManager":"pnpm@8.6.0+sha.1"}"#, "web/package.json")
        XCTAssertEqual(npm["react"]?.kind, .framework)
        XCTAssertEqual(npm["lodash"]?.kind, .library)
        XCTAssertEqual(npm["typescript"]?.kind, .tool)
        XCTAssertEqual(npm["left-pad"]?.kind, .tool) // development dependency
        XCTAssertEqual(npm["Node.js"]?.version, ">=18")
        XCTAssertEqual(npm["pnpm"]?.version, "8.6.0")
        let pip = declarations("# comment\nDjango==4.2.1\nrequests[socks] >= 2.0 ; python_version > '3'\n-r base.txt\n", "requirements-dev.txt")
        XCTAssertEqual(pip["Django"]?.version, "==4.2.1")
        XCTAssertEqual(pip["Django"]?.kind, .framework)
        XCTAssertEqual(pip["requests"]?.version, ">= 2.0")
        let pyproject = declarations("[project]\nrequires-python = \">=3.10\"\ndependencies = [\n  \"httpx>=0.25\",\n  \"pydantic~=2.0\",\n]\n[build-system]\nrequires = [\"hatchling\"]\n[tool.poetry.dependencies]\npython = \"^3.11\"\nflask = { version = \"^3.0\", optional = true }\n", "pyproject.toml")
        XCTAssertEqual(pyproject["httpx"]?.version, ">=0.25")
        XCTAssertEqual(pyproject["pydantic"]?.version, "~=2.0")
        XCTAssertEqual(pyproject["hatchling"]?.kind, .tool)
        XCTAssertEqual(pyproject["flask"]?.version, "^3.0")
        XCTAssertEqual(pyproject["Python"]?.version, ">=3.10, ^3.11")
        let go = declarations("module example.com/app\n\ngo 1.21\ntoolchain go1.22.1\nrequire github.com/pkg/errors v0.9.1\nrequire (\n\tgithub.com/gin-gonic/gin v1.9.1 // indirect\n)\n", "go.mod")
        XCTAssertEqual(go["Go"]?.version, "1.21"); XCTAssertEqual(go["Go toolchain"]?.version, "1.22.1")
        XCTAssertEqual(go["github.com/pkg/errors"]?.version, "v0.9.1"); XCTAssertEqual(go["github.com/gin-gonic/gin"]?.kind, .framework)
        let cargo = declarations("[package]\nrust-version = \"1.70\"\n[dependencies]\nserde = { version = \"1.0\", features = [\"derive\"] }\ntokio = \"1.32\"\n[build-dependencies]\ncc = \"1.0\"\n", "Cargo.toml")
        XCTAssertEqual(cargo["serde"]?.version, "1.0"); XCTAssertEqual(cargo["tokio"]?.version, "1.32")
        XCTAssertEqual(cargo["cc"]?.kind, .tool); XCTAssertEqual(cargo["Rust"]?.version, "1.70")
        XCTAssertEqual(declarations("ruby '3.2.2'\ngem 'rails', '~> 7.1'\n", "Gemfile")["rails"]?.kind, .framework)
        let gradle = declarations("plugins { id 'org.jetbrains.kotlin.android' version '1.9.0' }\nandroid { compileSdk 34 }\ndependencies {\n implementation \"com.squareup.retrofit2:retrofit:2.9.0\"\n testImplementation(\"junit:junit:4.13.2\")\n}\n", "app/build.gradle")
        XCTAssertEqual(gradle["com.squareup.retrofit2:retrofit"]?.version, "2.9.0")
        XCTAssertEqual(gradle["junit:junit"]?.version, "4.13.2")
        XCTAssertEqual(gradle["org.jetbrains.kotlin.android"]?.kind, .tool)
        XCTAssertEqual(gradle["Android compileSdk"]?.version, "34")
        XCTAssertEqual(declarations("distributionUrl=https\\://services.gradle.org/distributions/gradle-8.4-bin.zip\n", "gradle/wrapper/gradle-wrapper.properties")["Gradle"]?.version, "8.4")
        let catalog = declarations("[versions]\nokhttp = \"4.12.0\"\n[libraries]\nokhttp = { module = \"com.squareup.okhttp3:okhttp\", version.ref = \"okhttp\" }\n[plugins]\nandroid-app = { id = \"com.android.application\", version = \"8.2.0\" }\n", "gradle/libs.versions.toml")
        XCTAssertEqual(catalog["com.squareup.okhttp3:okhttp"]?.version, "4.12.0")
        XCTAssertEqual(catalog["com.android.application"]?.version, "8.2.0")
        let pom = declarations("<project><properties><java.version>17</java.version><guava.version>32.1.0-jre</guava.version></properties><parent><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-parent</artifactId><version>3.1.0</version></parent><dependencies><dependency><artifactId>guava</artifactId><groupId>com.google.guava</groupId><version>${guava.version}</version></dependency></dependencies><build><plugins><plugin><artifactId>maven-surefire-plugin</artifactId><version>3.0.0</version></plugin></plugins></build></project>", "pom.xml")
        XCTAssertEqual(pom["com.google.guava:guava"]?.version, "32.1.0-jre")
        XCTAssertEqual(pom["org.springframework.boot:spring-boot-starter-parent"]?.kind, .framework)
        XCTAssertEqual(pom["org.apache.maven.plugins:maven-surefire-plugin"]?.kind, .tool)
        XCTAssertEqual(pom["Java"]?.version, "17")
        let csproj = declarations("<Project Sdk=\"Microsoft.NET.Sdk\"><PropertyGroup><TargetFramework>net8.0</TargetFramework></PropertyGroup><ItemGroup><PackageReference Version=\"13.0.3\" Include=\"Newtonsoft.Json\" /></ItemGroup></Project>", "src/Api/Api.csproj")
        XCTAssertEqual(csproj["Newtonsoft.Json"]?.version, "13.0.3")
        XCTAssertEqual(csproj[".NET target framework"]?.version, "net8.0")
        let docker = declarations("FROM node:20-alpine AS build\nFROM build AS test\nFROM --platform=linux/amd64 nginx\nFROM scratch\n", "Dockerfile")
        XCTAssertEqual(docker["Image node"]?.version, "20-alpine"); XCTAssertEqual(docker["Image nginx"]?.version, "latest")
        XCTAssertNil(docker["Image build"]); XCTAssertNil(docker["Image scratch"])
        XCTAssertEqual(declarations("v20.10.0\n", ".nvmrc")["Node.js"]?.version, "v20.10.0")
        XCTAssertEqual(declarations("nodejs 20.1.0\nruby 3.2.0 # pinned\n", ".tool-versions")["ruby"]?.version, "3.2.0")
        XCTAssertNil(ManifestCatalog.format(for: "node_modules/react/package.json"))
        XCTAssertNil(ManifestCatalog.format(for: "README.md"))
    }

    func testVersionOrderingAndMajorChanges() {
        XCTAssertEqual(VersionOrdering.compare("from 4.9.0", "5.6.0"), .orderedAscending)
        XCTAssertEqual(VersionOrdering.compare("^2.10", "2.9.5"), .orderedDescending)
        XCTAssertEqual(VersionOrdering.compare("1.0", "1.0.0"), .orderedSame)
        XCTAssertNil(VersionOrdering.compare("branch main", "1.0"))
        XCTAssertTrue(VersionOrdering.isMajorChange("4.9.1", "5.0.0"))
        XCTAssertTrue(VersionOrdering.isMajorChange("0.9.0", "0.10.0"))
        XCTAssertFalse(VersionOrdering.isMajorChange("5.1.0", "5.8.1"))
    }

    // MARK: Pure analysis

    private func date(_ year: Int, _ month: Int = 1) -> Date {
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar.date(from: DateComponents(year: year, month: month, day: 15))!
    }
    private func change(_ path: String, _ added: Int = 1) -> FileChange { FileChange(path: path, additions: added, deletions: 0) }
    private func swiftPM(_ name: String, _ version: String) -> DependencyDeclaration { DependencyDeclaration(name: name, version: version, kind: .library, ecosystem: "SwiftPM") }
    private func revision(_ commit: String, _ year: Int, _ items: [DependencyDeclaration], previous: [DependencyDeclaration]?, path: String = "Package.swift") -> ManifestRevision {
        ManifestRevision(commit: commit, date: date(year), path: path, deleted: false, declarations: items, previous: previous)
    }

    /// Package at the root with two Swift targets, history 2019–2024, a dependency upgrade and a removal.
    private func fixtureSnapshot() -> RepositorySnapshot {
        let commits = [
            Commit(id: "c5", author: "Bob", email: "bob@example.test", date: date(2024), subject: "Tweak old view", changes: [change("Sources/App/Old.swift", 3)]),
            Commit(id: "c4", author: "Ada", email: "ada@example.test", date: date(2023, 6), subject: "Move manifest", changes: [change("Package.swift"), change("Sources/App/New.swift", 10)]),
            Commit(id: "c3", author: "Ada", email: "ada@example.test", date: date(2023), subject: "Upgrade Alamofire, drop Kingfisher", changes: [change("Package.swift", 2), change("Sources/App/Net.swift", 4)]),
            Commit(id: "c2", author: "Ada", email: "ada@example.test", date: date(2021), subject: "Add images", changes: [change("Sources/App/Images.swift", 5), change("Sources/Legacy/Bridge.swift", 2)]),
            Commit(id: "c1", author: "Ada", email: "ada@example.test", date: date(2019), subject: "Create", changes: [change("Package.swift"), change("Sources/App/Old.swift", 20), change("Sources/App/Net.swift", 8), change("README.md")])
        ]
        let first = [swiftPM("Alamofire", "from 4.9.0"), swiftPM("Kingfisher", "from 6.0.0"), DependencyDeclaration(name: "Swift tools version", version: "5.3", kind: .tool, ecosystem: "SwiftPM")]
        let second = [swiftPM("Alamofire", "from 5.6.0"), DependencyDeclaration(name: "Swift tools version", version: "5.9", kind: .tool, ecosystem: "SwiftPM")]
        // Re-declaring a dependency with different name casing is not a change.
        let third = [swiftPM("alamofire", "from 5.6.0"), DependencyDeclaration(name: "Swift tools version", version: "5.9", kind: .tool, ecosystem: "SwiftPM")]
        // Listed out of date order on purpose: events come from parent comparisons, not from ordering.
        let manifests = [revision("c4", 2023, third, previous: second), revision("c1", 2019, first, previous: nil), revision("c3", 2023, second, previous: first)]
        let sizes = ["Package.swift": 300, "Sources/App/Old.swift": 900, "Sources/App/New.swift": 400, "Sources/App/Net.swift": 200,
                     "Sources/App/Images.swift": 100, "Sources/Legacy/Bridge.swift": 50, "README.md": 10, "Tests/AppTests/AppTests.swift": 70]
        return RepositorySnapshot(root: URL(fileURLWithPath: "/tmp/Demo"), head: "head", shallow: false, commits: commits, fileSizes: sizes, manifests: manifests, currentManifests: ["Package.swift": third])
    }
    private func fixtureScan() -> CodeScan {
        let rules = LegacyRules.builtIn
        return CodeScan(head: "head", rules: rules,
                        matches: [RuleMatch(ruleID: "apple.uiwebview", location: CodeLine(path: "Sources/App/Old.swift", line: 7, text: "let web = UIWebView()"))],
                        imports: [ImportReference(module: "Alamofire", location: CodeLine(path: "Sources/App/Old.swift", line: 2, text: "import Alamofire")),
                                  ImportReference(module: "Alamofire", location: CodeLine(path: "Sources/App/Net.swift", line: 1, text: "import Alamofire")),
                                  ImportReference(module: "Kingfisher", location: CodeLine(path: "Sources/App/Images.swift", line: 1, text: "import Kingfisher")),
                                  ImportReference(module: "Foundation", location: CodeLine(path: "Sources/App/New.swift", line: 1, text: "import Foundation"))],
                        migrationStarts: ["apple.uiwebview": MigrationStart(ruleID: "apple.uiwebview", commit: "c4", date: date(2023, 6))], warnings: [])
    }

    func testDependencyHistoryTransitionsAndRemainingUsages() throws {
        let metrics = AnalysisEngine().compute(fixtureSnapshot(), scan: fixtureScan())
        let insights = metrics.dependencies
        let alamofire = try XCTUnwrap(insights.summaries.first { $0.name.lowercased() == "alamofire" })
        XCTAssertTrue(alamofire.isCurrent)
        XCTAssertEqual(alamofire.currentVersion, "from 5.6.0")
        XCTAssertEqual(alamofire.changes.map(\.change), [.added, .upgraded])
        XCTAssertTrue(alamofire.changes[1].isMajor)
        XCTAssertEqual(alamofire.distinctVersions, ["from 4.9.0", "from 5.6.0"])
        XCTAssertEqual(alamofire.usages.map(\.path), ["Sources/App/Net.swift", "Sources/App/Old.swift"])
        // Net.swift changed in the upgrade commit; Old.swift changed later, so neither is stale.
        XCTAssertTrue(alamofire.staleUsages.isEmpty)
        let kingfisher = try XCTUnwrap(insights.summaries.first { $0.name == "Kingfisher" })
        XCTAssertFalse(kingfisher.isCurrent)
        XCTAssertEqual(kingfisher.currentVersion, "removed")
        XCTAssertEqual(kingfisher.staleUsages.map(\.path), ["Sources/App/Images.swift"])
        XCTAssertEqual(insights.summaries.first { $0.name == "Swift tools version" }?.changes.map(\.change), [.added, .upgraded])
        XCTAssertNil(insights.transitions.first { $0.commit == "c4" }, "a re-declared dependency is not a change")
        let upgrade = try XCTUnwrap(insights.transitions.first { $0.commit == "c3" })
        XCTAssertEqual(Set(upgrade.changes.map(\.name)), ["Alamofire", "Kingfisher", "Swift tools version"])
        XCTAssertEqual(upgrade.changedModules, ["App", "Demo"])
        XCTAssertEqual(upgrade.remainingUsages.map(\.path), ["Sources/App/Images.swift"])
        XCTAssertEqual(insights.transitions.map(\.commit), ["c3", "c1"])
        var options = AnalysisOptions(); options.since = date(2022)
        let filtered = AnalysisEngine().compute(fixtureSnapshot(), options: options, scan: fixtureScan()).dependencies
        XCTAssertEqual(filtered.transitions.map(\.commit), ["c3"])
        XCTAssertEqual(filtered.summaries.first { $0.name == "Kingfisher" }?.referenceChange?.commit, "c3")
    }

    func testInterleavedBranchesDoNotCreateFlipFlopEvents() throws {
        // Two branches edit the same manifest on interleaved dates; each change is compared with its own parent.
        let base = [swiftPM("Lib", "1.0.0")]
        let manifests = [
            revision("main1", 2020, [swiftPM("Lib", "2.0.0")], previous: base),
            revision("side1", 2021, [swiftPM("Lib", "1.1.0")], previous: base),
            revision("main2", 2022, [swiftPM("Lib", "2.1.0")], previous: [swiftPM("Lib", "2.0.0")]),
            revision("root", 2019, base, previous: nil)
        ]
        let commits = ["main2", "side1", "main1", "root"].enumerated().map { offset, id in
            Commit(id: id, author: "Ada", email: "ada@example.test", date: date(2022 - offset), subject: id, changes: [change("Package.swift")])
        }
        let snapshot = RepositorySnapshot(root: URL(fileURLWithPath: "/tmp/Branches"), head: "h", shallow: false, commits: commits, fileSizes: ["Package.swift": 1],
                                          manifests: manifests, currentManifests: ["Package.swift": [swiftPM("Lib", "2.1.0")]])
        let lib = try XCTUnwrap(AnalysisEngine().compute(snapshot).dependencies.summaries.first)
        XCTAssertEqual(lib.changes.map(\.commit), ["root", "main1", "side1", "main2"])
        XCTAssertEqual(lib.changes.map(\.change), [.added, .upgraded, .upgraded, .upgraded])
        XCTAssertEqual(lib.changes[2].from, "1.0.0")
        XCTAssertEqual(lib.currentVersion, "2.1.0")
    }

    func testFolderAndModuleSummaries() throws {
        let metrics = AnalysisEngine().compute(fixtureSnapshot(), scan: fixtureScan())
        let structure = metrics.structure
        let root = try XCTUnwrap(structure.root)
        XCTAssertEqual(root.name, "Demo"); XCTAssertEqual(root.commits, 5); XCTAssertEqual(root.currentFiles, 8)
        XCTAssertEqual(root.subfolders, ["Sources", "Tests"])
        XCTAssertEqual(root.files, ["Package.swift", "README.md"])
        let app = try XCTUnwrap(structure.folders["Sources/App"])
        XCTAssertEqual(app.parent, "Sources")
        XCTAssertEqual(app.commits, 5)
        XCTAssertEqual(app.churn, 3 + 10 + 4 + 5 + 20 + 8)
        XCTAssertEqual(app.leader?.email, "ada@example.test")
        XCTAssertEqual(app.leader?.commits, 4)
        XCTAssertEqual(app.leader?.share ?? 0, 0.8, accuracy: 0.0001)
        XCTAssertEqual(app.recentCommits.first?.id, "c5")
        XCTAssertEqual(app.lastChange, date(2024))
        XCTAssertEqual(structure.folders["Sources/Legacy"]?.findings, 1)
        XCTAssertGreaterThanOrEqual(app.findings, 3)
        let names = Set(structure.modules.map(\.name))
        XCTAssertEqual(names, ["Demo", "App", "Legacy", "AppTests"])
        let package = try XCTUnwrap(structure.modules.first { $0.name == "Demo" })
        XCTAssertEqual(package.kinds, ["SwiftPM package"])
        XCTAssertEqual(package.currentFiles, 2) // Package.swift and README.md
        XCTAssertEqual(Set(package.dependencies.map(\.name)), ["alamofire", "Swift tools version"])
        XCTAssertEqual(structure.modules.first { $0.name == "AppTests" }?.kinds, ["Swift test target"])
        XCTAssertEqual(structure.modules.first { $0.name == "App" }?.commits, 5)
        let index = ModuleIndex(currentPaths: ["web/package.json", "web/src/a.ts", "App.xcodeproj/project.pbxproj", "Main.swift"], repositoryName: "Repo")
        XCTAssertEqual(index.module(for: "web/src/a.ts").name, "web")
        XCTAssertEqual(index.module(for: "Main.swift").kinds, ["Xcode project"])
    }

    func testLegacyFindingsCarryConcreteSignals() throws {
        let now = date(2025)
        let raw = fixtureSnapshot()
        let index = ModuleIndex(currentPaths: Array(raw.fileSizes.keys), repositoryName: "Demo")
        let history = DependencyAnalysis.FileHistory(raw.commits)
        let dependencies = DependencyAnalysis().compute(raw, options: AnalysisOptions(), index: index, scan: fixtureScan(), history: history)
        let legacy = LegacyAnalysis().compute(raw: raw, filtered: raw, options: AnalysisOptions(), scan: fixtureScan(), dependencies: dependencies, index: index, history: history, now: now)
        XCTAssertTrue(legacy.scanned)
        let web = try XCTUnwrap(legacy.findings.first { $0.primary.kind == .deprecatedAPI })
        XCTAssertEqual(web.path, "Sources/App/Old.swift"); XCTAssertEqual(web.line, 7)
        XCTAssertTrue(web.primary.detail.contains("UIWebView")); XCTAssertTrue(web.primary.detail.contains("WKWebView"))
        let churn = try XCTUnwrap(web.signals.first { $0.kind == .changingAfterMigration })
        XCTAssertTrue(churn.detail.contains("1 eligible commit"))
        XCTAssertTrue(web.signals.contains { $0.kind == .fileAge }, "Old.swift is among the oldest files")
        XCTAssertEqual(web.module, "App")
        XCTAssertEqual(web.commits.map(\.id), ["c5", "c1"])
        let removed = try XCTUnwrap(legacy.findings.first { $0.primary.kind == .removedDependency })
        XCTAssertEqual(removed.path, "Sources/App/Images.swift"); XCTAssertEqual(removed.line, 1)
        XCTAssertTrue(removed.primary.detail.contains("Kingfisher")); XCTAssertTrue(removed.primary.detail.contains("c3"))
        XCTAssertFalse(removed.signals.contains { $0.kind == .changingAfterMigration })
        XCTAssertEqual(Set(legacy.findings.filter { $0.primary.kind == .legacyPath }.map(\.path)), ["Sources/Legacy/Bridge.swift", "Sources/App/Old.swift"])
        XCTAssertEqual(legacy.findings.first?.id, web.id, "deprecated API that keeps changing ranks first")
        XCTAssertFalse(legacy.findings.contains { $0.path == "Sources/App/New.swift" && $0.signals.contains { $0.kind == .fileAge } })
        // Shared path filters also scope findings.
        var options = AnalysisOptions(); options.excludedPatterns = ["Sources/App/*"]
        let scoped = LegacyAnalysis().compute(raw: raw, filtered: options.apply(to: raw), options: options, scan: fixtureScan(), dependencies: dependencies, index: index, history: history, now: now)
        XCTAssertEqual(scoped.findings.map(\.path), ["Sources/Legacy/Bridge.swift"])
        // Without a scan, only path signals are available and a warning explains why.
        let unscanned = AnalysisEngine().compute(raw)
        XCTAssertFalse(unscanned.legacy.scanned)
        XCTAssertEqual(Set(unscanned.legacy.findings.map(\.primary.kind)), [.legacyPath])
        XCTAssertTrue(AnalysisEngine().compute(raw, scan: CodeScan(head: "other", rules: [], matches: [], imports: [], migrationStarts: [:], warnings: [])).legacy.findings.allSatisfy { $0.primary.kind == .legacyPath })
    }

    func testRuleMatchingIgnoresStringsAndComments() throws {
        let rule = try XCTUnwrap(LegacyRules.builtIn.first { $0.id == "apple.uiwebview" })
        let expression = try NSRegularExpression(pattern: rule.pattern)
        func check(_ text: String, _ path: String = "a.swift", _ category: LegacyRuleCategory = .deprecatedAPI) -> Bool {
            CodebaseScanner.matches(expression, line: CodeLine(path: path, line: 1, text: text), category: category)
        }
        XCTAssertTrue(check("let view = UIWebView(frame: .zero)"))
        XCTAssertTrue(check("let label = \"web\"; let view = UIWebView()"))
        XCTAssertFalse(check("// UIWebView was replaced"))
        XCTAssertFalse(check("print(\"UIWebView\")"))
        XCTAssertFalse(check("let view = WKWebView() // not UIWebView"))
        XCTAssertFalse(check("let view: UIWebViewer"))
        let marker = try XCTUnwrap(LegacyRules.builtIn.first { $0.id == "marker.legacy" })
        let markerExpression = try NSRegularExpression(pattern: marker.pattern, options: [.caseInsensitive])
        XCTAssertTrue(CodebaseScanner.matches(markerExpression, line: CodeLine(path: "a.py", line: 1, text: "# TODO: remove after migration to v2"), category: .legacyMarker))
        XCTAssertTrue(CodebaseScanner.matches(markerExpression, line: CodeLine(path: "a.swift", line: 1, text: "// Legacy bridge for iOS 12"), category: .legacyMarker))
        XCTAssertFalse(CodebaseScanner.matches(markerExpression, line: CodeLine(path: "a.swift", line: 1, text: "let title = \"TODO: legacy\""), category: .legacyMarker))
        let custom = LegacyRule.custom(old: "OldClient(", replacement: "NewClient(", extensions: [".SWIFT"])
        XCTAssertTrue(custom.applies(to: "x/y.swift")); XCTAssertFalse(custom.applies(to: "x/y.kt"))
        XCTAssertEqual(custom.replacementKeyword, "NewClient(")
        XCTAssertNoThrow(try NSRegularExpression(pattern: custom.pattern))
        for builtIn in LegacyRules.builtIn { XCTAssertNoThrow(try NSRegularExpression(pattern: builtIn.pattern), builtIn.id) }
        XCTAssertEqual(CodebaseScanner.importedModules(in: CodeLine(path: "a.swift", line: 1, text: "@testable import struct Alamofire.Session")), ["Alamofire"])
        XCTAssertEqual(CodebaseScanner.importedModules(in: CodeLine(path: "a.ts", line: 1, text: "import { x } from '@scope/pkg/sub'")), ["@scope/pkg/sub"])
        XCTAssertEqual(CodebaseScanner.importedModules(in: CodeLine(path: "a.ts", line: 1, text: "import y from './local'")), [])
        XCTAssertEqual(CodebaseScanner.importedModules(in: CodeLine(path: "a.py", line: 1, text: "from yaml.loader import SafeLoader")), ["yaml.loader"])
    }

    // MARK: Real Git

    func testRealGitManifestHistoryScanAndLineContext() throws {
        let fixture = try DatedFixture(); defer { fixture.remove() }
        try fixture.commit("2021-03-01T10:00:00Z", "Create app", files: [
            "Package.swift": "// swift-tools-version:5.5\nimport PackageDescription\nlet package = Package(name: \"Demo\", dependencies: [\n  .package(url: \"https://github.com/Alamofire/Alamofire.git\", from: \"4.9.0\"),\n  .package(url: \"https://github.com/onevcat/Kingfisher.git\", from: \"6.0.0\")\n])\n",
            "Sources/App/Old.swift": "import Alamofire\nimport UIKit\nlet web = UIWebView()\n",
            "Sources/App/Images.swift": "import Kingfisher\n"
        ])
        try fixture.commit("2023-05-01T10:00:00Z", "Upgrade networking", files: [
            "Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Demo\", dependencies: [\n  .package(url: \"https://github.com/Alamofire/Alamofire.git\", from: \"5.6.0\")\n])\n",
            "Sources/App/New.swift": "import WebKit\nlet web = WKWebView()\n"
        ])
        try fixture.commit("2024-02-01T10:00:00Z", "Tweak old screen", files: ["Sources/App/Old.swift": "import Alamofire\nimport UIKit\nlet web = UIWebView()\nlet title = \"Old\"\n"])
        let before = try fixture.git(["status", "--porcelain=v1"])
        let service = GitRepositoryService(cacheURL: fixture.directory.appendingPathComponent("cache.sqlite"))
        let snapshot = try service.load(fixture.repository)
        XCTAssertNil(snapshot.manifestWarning)
        XCTAssertEqual(snapshot.manifests.map(\.path), ["Package.swift", "Package.swift"])
        XCTAssertEqual(snapshot.manifests.first { $0.date.timeIntervalSince1970 < 1_650_000_000 }?.declarations.count, 3)
        XCTAssertEqual(try service.load(fixture.repository).manifests, snapshot.manifests, "cache keeps manifest history")

        let scan = try CodebaseScanner().load(snapshot, rules: LegacyRuleSettings().effectiveRules)
        XCTAssertTrue(scan.warnings.isEmpty, scan.warnings.joined())
        XCTAssertEqual(scan.matches.filter { $0.ruleID == "apple.uiwebview" }.map(\.location), [CodeLine(path: "Sources/App/Old.swift", line: 3, text: "let web = UIWebView()")])
        let start = try XCTUnwrap(scan.migrationStarts["apple.uiwebview"])
        XCTAssertEqual(start.date.timeIntervalSince1970, 1_682_935_200)
        XCTAssertEqual(Set(scan.imports.map(\.module)), ["Alamofire", "UIKit", "Kingfisher", "WebKit", "PackageDescription"])

        let metrics = AnalysisEngine().compute(snapshot, scan: scan)
        let alamofire = try XCTUnwrap(metrics.dependencies.summaries.first { $0.name == "Alamofire" })
        XCTAssertEqual(alamofire.changes.map(\.change), [.added, .upgraded])
        XCTAssertEqual(metrics.dependencies.transitions.count, 2)
        let findings = metrics.legacy.findings
        let web = try XCTUnwrap(findings.first { $0.primary.kind == .deprecatedAPI })
        XCTAssertTrue(web.signals.contains { $0.kind == .changingAfterMigration })
        XCTAssertTrue(findings.contains { $0.primary.kind == .removedDependency && $0.path == "Sources/App/Images.swift" })

        let context = try CodebaseScanner().context(root: snapshot.root, head: snapshot.head, path: "Sources/App/Old.swift", line: 3, radius: 1)
        XCTAssertEqual(context.lines.map(\.line), [2, 3, 4])
        XCTAssertEqual(context.lines[1].text, "let web = UIWebView()")
        XCTAssertEqual(context.blame?.summary, "Create app", "the matched line was written by the first commit")
        XCTAssertEqual(context.blame?.email, "fixture@example.test")

        try fixture.commit("2024-06-01T10:00:00Z", "Pin Alamofire", files: ["Package.swift": "// swift-tools-version:5.9\nimport PackageDescription\nlet package = Package(name: \"Demo\", dependencies: [\n  .package(url: \"https://github.com/Alamofire/Alamofire.git\", exact: \"5.8.1\")\n])\n"])
        let incremental = try service.load(fixture.repository)
        XCTAssertEqual(incremental.importMode, .incremental)
        let full = try GitRepositoryService().load(fixture.repository)
        XCTAssertEqual(Set(incremental.manifests.map { $0.commit + $0.path }), Set(full.manifests.map { $0.commit + $0.path }))
        XCTAssertEqual(incremental.manifests.count, 3)
        XCTAssertEqual(try fixture.git(["status", "--porcelain=v1"]), before)
    }
}

/// A disposable repository whose commits carry explicit UTC dates.
private final class DatedFixture {
    let directory: URL
    let repository: URL
    init() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        repository = directory.appendingPathComponent("Demo")
        try FileManager.default.createDirectory(at: repository, withIntermediateDirectories: true)
        try git(["init", "-b", "main"])
    }
    func remove() { try? FileManager.default.removeItem(at: directory) }
    @discardableResult func git(_ args: [String], date: String? = nil) throws -> String {
        let process = Process(); process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-c", "core.hooksPath=/dev/null", "-C", repository.path] + args
        var environment = ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_AUTHOR_NAME": "Fixture", "GIT_AUTHOR_EMAIL": "fixture@example.test",
                           "GIT_COMMITTER_NAME": "Fixture", "GIT_COMMITTER_EMAIL": "fixture@example.test"]
        if let date { environment["GIT_AUTHOR_DATE"] = date; environment["GIT_COMMITTER_DATE"] = date }
        process.environment = environment
        let pipe = Pipe(); process.standardOutput = pipe; process.standardError = FileHandle.nullDevice
        try process.run(); let data = pipe.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GitError.failed("Fixture command failed: \(args)") }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .newlines)
    }
    /// Writes each file (nil values are ignored) and commits everything with the given date.
    func commit(_ date: String, _ message: String, files: [String: String?]) throws {
        for (path, contents) in files {
            guard let contents else { continue }
            let url = repository.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        try git(["add", "."]); try git(["commit", "-m", message], date: date)
    }
}
