import Foundation

/// Recognised dependency, build and toolchain manifests. Parsing is deliberately textual and
/// conservative: it never executes a manifest and only reports what is literally declared.
public enum ManifestFormat: String, Codable, Sendable, CaseIterable {
    case swiftPackage, swiftResolved, xcodeProject, podfile, podfileLock, cartfile, cartfileResolved
    case packageJSON, requirements, pyproject, goMod, cargo, gemfile
    case gradle, gradleWrapper, versionCatalog, maven, csproj, globalJSON
    case dockerfile, toolVersions, rustToolchainTOML, versionFile

    /// Formats whose folder is treated as a module root.
    public var marksModule: Bool {
        switch self {
        case .swiftPackage, .xcodeProject, .podfile, .cartfile, .packageJSON, .pyproject, .goMod, .cargo, .gemfile, .gradle, .maven, .csproj: return true
        default: return false
        }
    }
    public var moduleKind: String {
        switch self {
        case .swiftPackage: return "SwiftPM package"
        case .xcodeProject: return "Xcode project"
        case .podfile: return "CocoaPods app"
        case .cartfile: return "Carthage app"
        case .packageJSON: return "npm package"
        case .pyproject: return "Python project"
        case .goMod: return "Go module"
        case .cargo: return "Cargo crate"
        case .gemfile: return "Ruby bundle"
        case .gradle: return "Gradle project"
        case .maven: return "Maven project"
        case .csproj: return ".NET project"
        default: return "Project"
        }
    }
}

public enum ManifestCatalog {
    /// Third-party trees that are never analysed as the repository's own manifests or code.
    public static let vendoredComponents: Set<String> = ["node_modules", "Pods", ".build", "DerivedData", "Carthage", ".venv", "venv", "site-packages", "bower_components"]
    static let versionFiles: [String: String] = [
        ".nvmrc": "Node.js", ".node-version": "Node.js", ".python-version": "Python", ".ruby-version": "Ruby",
        ".swift-version": "Swift", ".xcode-version": "Xcode", ".java-version": "Java", "rust-toolchain": "Rust"
    ]
    /// Git pathspecs that select every candidate manifest in one `git log` call.
    public static let pathspecs: [String] = {
        let names = ["Package.swift", "Package.resolved", "project.pbxproj", "Podfile", "Podfile.lock", "Cartfile", "Cartfile.resolved",
                     "package.json", "requirements*.txt", "pyproject.toml", "go.mod", "Cargo.toml", "Gemfile", "build.gradle", "build.gradle.kts",
                     "gradle-wrapper.properties", "libs.versions.toml", "pom.xml", "*.csproj", "global.json", "Dockerfile", ".tool-versions",
                     "rust-toolchain.toml"] + versionFiles.keys.sorted()
        return names.map { ":(glob)**/" + $0 }
    }()
    public static func isVendored(_ path: String) -> Bool {
        path.split(separator: "/").dropLast().contains { vendoredComponents.contains(String($0)) }
    }
    public static func format(for path: String) -> ManifestFormat? {
        if isVendored(path) { return nil }
        let name = RepoPath.name(path)
        switch name {
        case "Package.swift": return .swiftPackage
        case "Package.resolved": return .swiftResolved
        case "project.pbxproj": return RepoPath.parent(path).hasSuffix(".xcodeproj") ? .xcodeProject : nil
        case "Podfile": return .podfile
        case "Podfile.lock": return .podfileLock
        case "Cartfile": return .cartfile
        case "Cartfile.resolved": return .cartfileResolved
        case "package.json": return .packageJSON
        case "pyproject.toml": return .pyproject
        case "go.mod": return .goMod
        case "Cargo.toml": return .cargo
        case "Gemfile": return .gemfile
        case "build.gradle", "build.gradle.kts": return .gradle
        case "gradle-wrapper.properties": return .gradleWrapper
        case "libs.versions.toml": return .versionCatalog
        case "pom.xml": return .maven
        case "global.json": return .globalJSON
        case "Dockerfile": return .dockerfile
        case ".tool-versions": return .toolVersions
        case "rust-toolchain.toml": return .rustToolchainTOML
        default: break
        }
        if versionFiles[name] != nil { return .versionFile }
        if name.hasPrefix("requirements") && name.hasSuffix(".txt") { return .requirements }
        if name.hasSuffix(".csproj") { return .csproj }
        return nil
    }
    /// The folder a module manifest describes. An Xcode project describes the folder containing `X.xcodeproj`.
    public static func moduleRoot(for path: String, format: ManifestFormat) -> String {
        var folder = RepoPath.parent(path)
        if format == .xcodeProject { folder = RepoPath.parent(folder) }
        return folder
    }
}

public struct ManifestParser {
    public init() {}

    public func parse(_ text: String, path: String) -> [DependencyDeclaration] {
        guard let format = ManifestCatalog.format(for: path) else { return [] }
        let raw: [DependencyDeclaration]
        switch format {
        case .swiftPackage: raw = swiftPackage(text)
        case .swiftResolved: raw = swiftResolved(text)
        case .xcodeProject: raw = xcodeProject(text)
        case .podfile: raw = podfile(text)
        case .podfileLock: raw = podfileLock(text)
        case .cartfile, .cartfileResolved: raw = cartfile(text)
        case .packageJSON: raw = packageJSON(text)
        case .requirements: raw = requirements(text)
        case .pyproject: raw = pyproject(text)
        case .goMod: raw = goMod(text)
        case .cargo: raw = cargo(text)
        case .gemfile: raw = gemfile(text)
        case .gradle: raw = gradle(text)
        case .gradleWrapper: raw = gradleWrapper(text)
        case .versionCatalog: raw = versionCatalog(text)
        case .maven: raw = maven(text)
        case .csproj: raw = csproj(text)
        case .globalJSON: raw = globalJSON(text)
        case .dockerfile: raw = dockerfile(text)
        case .toolVersions: raw = toolVersions(text)
        case .rustToolchainTOML: raw = captures(#"(?m)^\s*channel\s*=\s*"([^"]+)""#, text).map { tool("Rust", $0[0], "rustup") }
        case .versionFile:
            let value = text.split(whereSeparator: \.isNewline).map { $0.trimmingCharacters(in: .whitespaces) }.first { !$0.isEmpty && !$0.hasPrefix("#") } ?? ""
            raw = value.isEmpty ? [] : [tool(ManifestCatalog.versionFiles[RepoPath.name(path)] ?? "Toolchain", value, "Version file")]
        }
        return Self.merge(raw)
    }

    /// One declaration per identity. Repeated declarations (several targets or build configurations) keep every distinct version.
    static func merge(_ declarations: [DependencyDeclaration]) -> [DependencyDeclaration] {
        var order: [String] = []
        var grouped: [String: [DependencyDeclaration]] = [:]
        for declaration in declarations where !declaration.name.isEmpty {
            if grouped[declaration.key] == nil { order.append(declaration.key) }
            grouped[declaration.key, default: []].append(declaration)
        }
        return order.map { key in
            let group = grouped[key]!
            var seen = Set<String>()
            let versions = group.map(\.version).filter { !$0.isEmpty && seen.insert($0).inserted }
            return DependencyDeclaration(name: group[0].name, version: versions.sorted().joined(separator: ", "), kind: group[0].kind, ecosystem: group[0].ecosystem)
        }.sorted { $0.key < $1.key }
    }

    // MARK: Swift and Apple

    func swiftPackage(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        if let tools = captures(#"//\s*swift-tools-version\s*:\s*([0-9][0-9.]*)"#, text).first { result.append(tool("Swift tools version", tools[0], "SwiftPM")) }
        for call in balancedCalls(prefix: ".package(", in: text) {
            guard let location = captures(#"(?:url|id)\s*:\s*"([^"]+)""#, call).first?[0] else { continue }
            let name = repositoryName(location)
            result.append(library(name, swiftRequirement(call), "SwiftPM"))
        }
        for platform in captures(#"\.(macOS|iOS|tvOS|watchOS|visionOS|macCatalyst|driverKit)\s*\(\s*(?:\.v([0-9_]+)|"([0-9.]+)")"#, text) {
            let version = platform[1].isEmpty ? platform[2] : platform[1].replacingOccurrences(of: "_", with: ".")
            result.append(tool(platform[0] + " deployment target", version, "SwiftPM"))
        }
        return result
    }
    private func swiftRequirement(_ call: String) -> String {
        if let range = captures(#""([^"]+)"\s*(\.\.<|\.\.\.)\s*"([^"]+)""#, call).first { return range[0] + range[1] + range[2] }
        for (label, display) in [("exact", "exact "), ("upToNextMinor\\s*\\(\\s*from", "upToNextMinor "), ("upToNextMajor\\s*\\(\\s*from", "from "), ("from", "from "),
                                 ("branch", "branch "), ("revision", "revision ")] {
            if let value = captures(label + #"\s*:\s*"([^"]+)""#, call).first?[0] {
                return display + (label == "revision" ? String(value.prefix(12)) : value)
            }
        }
        if let legacy = captures(#"majorVersion\s*:\s*(\d+)"#, call).first?[0] { return "from " + legacy + ".0.0" }
        return ""
    }
    func swiftResolved(_ text: String) -> [DependencyDeclaration] {
        guard let json = jsonObject(text) else { return [] }
        let pins = ((json["object"] as? [String: Any])?["pins"] ?? json["pins"]) as? [[String: Any]] ?? []
        return pins.compactMap { pin in
            let location = (pin["location"] ?? pin["repositoryURL"]) as? String
            guard let name = location.map(repositoryName) ?? (pin["identity"] ?? pin["package"]) as? String else { return nil }
            let state = pin["state"] as? [String: Any] ?? [:]
            let version = (state["version"] as? String) ?? (state["branch"] as? String).map { "branch " + $0 } ?? (state["revision"] as? String).map { "revision " + String($0.prefix(12)) } ?? ""
            return library(name, version, "SwiftPM")
        }
    }
    func xcodeProject(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        for value in captures(#"SWIFT_VERSION\s*=\s*"?([0-9][0-9.]*)"?;"#, text) { result.append(tool("Swift language version", value[0], "Xcode")) }
        let platforms = ["IPHONEOS": "iOS", "MACOSX": "macOS", "TVOS": "tvOS", "WATCHOS": "watchOS", "XROS": "visionOS"]
        for value in captures(#"(IPHONEOS|MACOSX|TVOS|WATCHOS|XROS)_DEPLOYMENT_TARGET\s*=\s*"?([0-9][0-9.]*)"?;"#, text) {
            result.append(tool(platforms[value[0]]! + " deployment target", value[1], "Xcode"))
        }
        if let upgrade = captures(#"LastUpgradeCheck\s*=\s*(\d{4});"#, text).first?[0], let number = Int(upgrade) {
            result.append(tool("Xcode (last upgrade check)", "\(number / 100).\(number % 100 / 10)", "Xcode"))
        }
        for package in captures(#"repositoryURL\s*=\s*"([^"]+)";\s*requirement\s*=\s*\{([^}]*)\}"#, text) {
            let requirement = package[1]
            let version = captures(#"(?:minimumVersion|version)\s*=\s*"?([^";\s]+)"?;"#, requirement).first.map { $0[0] }
                ?? captures(#"branch\s*=\s*"?([^";]+)"?;"#, requirement).first.map { "branch " + $0[0] } ?? ""
            result.append(library(repositoryName(package[0]), version, "SwiftPM"))
        }
        return result
    }
    func podfile(_ text: String) -> [DependencyDeclaration] {
        var result = captures(#"(?m)^\s*pod\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?"#, text).map { library($0[0], $0[1], "CocoaPods") }
        for platform in captures(#"(?m)^\s*platform\s+:(\w+)(?:\s*,\s*['"]([^'"]+)['"])?"#, text) {
            result.append(tool(platform[0] + " deployment target", platform[1], "CocoaPods"))
        }
        return result
    }
    func podfileLock(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        var inPods = false
        for line in text.components(separatedBy: .newlines) {
            if !line.hasPrefix(" ") && !line.isEmpty { inPods = line.hasPrefix("PODS:") }
            if inPods, let pod = captures(#"^  - "?([^ "(]+) \(([^)]+)\)"#, line).first { result.append(library(pod[0], pod[1], "CocoaPods")) }
        }
        if let version = captures(#"(?m)^COCOAPODS: ([^\s]+)"#, text).first?[0] { result.append(tool("CocoaPods", version, "CocoaPods")) }
        return result
    }
    func cartfile(_ text: String) -> [DependencyDeclaration] {
        captures(#"(?m)^\s*(?:github|git|binary)\s+"([^"]+)"\s*([^#\n]*)"#, text).map {
            library(repositoryName($0[0]), $0[1].trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "\"", with: ""), "Carthage")
        }
    }

    // MARK: JavaScript, Python, Go, Rust, Ruby

    func packageJSON(_ text: String) -> [DependencyDeclaration] {
        guard let json = jsonObject(text) else { return [] }
        var result: [DependencyDeclaration] = []
        for section in ["dependencies", "devDependencies", "peerDependencies", "optionalDependencies"] {
            for (name, value) in (json[section] as? [String: Any] ?? [:]) {
                result.append(DependencyDeclaration(name: name, version: value as? String ?? "", kind: Self.classify(name, development: section == "devDependencies"), ecosystem: "npm"))
            }
        }
        for (name, value) in (json["engines"] as? [String: Any] ?? [:]) { result.append(tool(name == "node" ? "Node.js" : name, value as? String ?? "", "npm")) }
        if let manager = json["packageManager"] as? String, let at = manager.lastIndex(of: "@"), at != manager.startIndex {
            result.append(tool(String(manager[..<at]), String(manager[manager.index(after: at)...]).components(separatedBy: "+")[0], "npm"))
        }
        return result
    }
    func requirements(_ text: String) -> [DependencyDeclaration] {
        text.components(separatedBy: .newlines).compactMap { line in
            let content = line.components(separatedBy: "#")[0].trimmingCharacters(in: .whitespaces)
            guard !content.isEmpty, !content.hasPrefix("-"), let requirement = pythonRequirement(content) else { return nil }
            return requirement
        }
    }
    private func pythonRequirement(_ text: String) -> DependencyDeclaration? {
        guard let match = captures(#"^\s*([A-Za-z0-9][A-Za-z0-9._-]*)\s*(?:\[[^\]]*\])?\s*([<>=!~][^;]*)?"#, text).first else { return nil }
        return DependencyDeclaration(name: match[0], version: match[1].trimmingCharacters(in: .whitespaces), kind: Self.classify(match[0]), ecosystem: "pip")
    }
    func pyproject(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        let toml = TOMLLines(text)
        for entry in toml.entries {
            switch (entry.section, entry.key) {
            case ("project", "requires-python"): result.append(tool("Python", entry.stringValue, "pip"))
            case ("project", "dependencies"), ("build-system", "requires"):
                for item in entry.arrayValues { if let requirement = pythonRequirement(item) {
                    result.append(entry.section == "build-system" ? tool(requirement.name, requirement.version, "pip") : requirement)
                } }
            default:
                if entry.section == "project.optional-dependencies" {
                    result += entry.arrayValues.compactMap(pythonRequirement)
                } else if entry.section.hasPrefix("tool.poetry") && entry.section.hasSuffix("dependencies") {
                    if entry.key == "python" { result.append(tool("Python", entry.stringValue, "pip")) }
                    else { result.append(DependencyDeclaration(name: entry.key, version: entry.tableValue("version") ?? entry.stringValue, kind: Self.classify(entry.key), ecosystem: "pip")) }
                }
            }
        }
        return result
    }
    func goMod(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        if let version = captures(#"(?m)^go\s+([0-9][0-9.]*)"#, text).first?[0] { result.append(tool("Go", version, "Go modules")) }
        if let version = captures(#"(?m)^toolchain\s+go([0-9][0-9.]*)"#, text).first?[0] { result.append(tool("Go toolchain", version, "Go modules")) }
        var inBlock = false
        for line in text.components(separatedBy: .newlines) {
            let content = line.components(separatedBy: "//")[0].trimmingCharacters(in: .whitespaces)
            if content.hasPrefix("require (") || content == "require(" { inBlock = true; continue }
            if inBlock && content.hasPrefix(")") { inBlock = false; continue }
            let fields = content.split(separator: " ").map(String.init)
            if inBlock, fields.count >= 2 { result.append(library(fields[0], fields[1], "Go modules")) }
            else if fields.count >= 3, fields[0] == "require" { result.append(library(fields[1], fields[2], "Go modules")) }
        }
        return result
    }
    func cargo(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        for entry in TOMLLines(text).entries {
            if entry.section == "package" && entry.key == "rust-version" { result.append(tool("Rust", entry.stringValue, "Cargo")) }
            let section = entry.section.split(separator: ".").last.map(String.init) ?? ""
            if ["dependencies", "dev-dependencies", "build-dependencies"].contains(section) {
                let version = entry.tableValue("version") ?? entry.tableValue("git").map { "git " + $0 } ?? entry.tableValue("path").map { "path " + $0 } ?? entry.stringValue
                result.append(DependencyDeclaration(name: entry.key, version: version, kind: section == "build-dependencies" ? .tool : Self.classify(entry.key), ecosystem: "Cargo"))
            }
        }
        return result
    }
    func gemfile(_ text: String) -> [DependencyDeclaration] {
        var result = captures(#"(?m)^\s*gem\s+['"]([^'"]+)['"](?:\s*,\s*['"]([^'"]+)['"])?"#, text).map {
            DependencyDeclaration(name: $0[0], version: $0[1], kind: Self.classify($0[0]), ecosystem: "RubyGems")
        }
        if let ruby = captures(#"(?m)^\s*ruby\s+['"]([^'"]+)['"]"#, text).first?[0] { result.append(tool("Ruby", ruby, "RubyGems")) }
        return result
    }

    // MARK: JVM and .NET

    func gradle(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        let configurations = "implementation|api|compileOnly|runtimeOnly|testImplementation|androidTestImplementation|debugImplementation|releaseImplementation|kapt|ksp|annotationProcessor|classpath|compile|testCompile"
        for match in captures(#"\b("# + configurations + #")\s*\(?\s*(?:platform\s*\(\s*)?['"]([^:'"\s]+):([^:'"\s]+):([^'"\s]+)['"]"#, text) {
            let name = match[1] + ":" + match[2]
            result.append(DependencyDeclaration(name: name, version: match[3], kind: match[0] == "classpath" ? .tool : Self.classify(name), ecosystem: "Gradle"))
        }
        for plugin in captures(#"\bid\s*\(?\s*['"]([^'"]+)['"]\s*\)?\s*version\s*\(?\s*['"]([^'"]+)['"]"#, text) { result.append(tool(plugin[0], plugin[1], "Gradle plugin")) }
        for plugin in captures(#"\bkotlin\s*\(\s*"([^"]+)"\s*\)\s*version\s*"([^"]+)""#, text) { result.append(tool("org.jetbrains.kotlin." + plugin[0], plugin[1], "Gradle plugin")) }
        for sdk in captures(#"\b(compileSdk|targetSdk|minSdk)(?:Version)?\s*[=(]?\s*(\d+)"#, text) { result.append(tool("Android " + sdk[0], sdk[1], "Gradle")) }
        for java in captures(#"JavaVersion\.VERSION_([0-9_]+)"#, text) { result.append(tool("Java", java[0].replacingOccurrences(of: "_", with: "."), "Gradle")) }
        for java in captures(#"jvmToolchain\s*\(\s*(\d+)"#, text) { result.append(tool("Java", java[0], "Gradle")) }
        return result
    }
    func gradleWrapper(_ text: String) -> [DependencyDeclaration] {
        captures(#"distributionUrl=.*gradle-([0-9][^-/]*(?:-rc-\d+)?)-(?:bin|all)\.zip"#, text).map { tool("Gradle", $0[0], "Gradle wrapper") }
    }
    func versionCatalog(_ text: String) -> [DependencyDeclaration] {
        let entries = TOMLLines(text).entries
        var versions: [String: String] = [:]
        for entry in entries where entry.section == "versions" { versions[entry.key] = entry.stringValue }
        var result: [DependencyDeclaration] = []
        for entry in entries where entry.section == "libraries" || entry.section == "plugins" {
            let version = entry.tableValue("version.ref").flatMap { versions[$0] } ?? entry.tableValue("version") ?? ""
            if entry.section == "plugins" {
                result.append(tool(entry.tableValue("id") ?? entry.key, version, "Gradle plugin"))
            } else {
                let module = entry.tableValue("module") ?? [entry.tableValue("group"), entry.tableValue("name")].compactMap { $0 }.joined(separator: ":")
                let parts = entry.stringValue.split(separator: ":").map(String.init)
                let name = module.isEmpty ? (parts.count >= 2 ? parts[0] + ":" + parts[1] : entry.key) : module
                let resolved = version.isEmpty && parts.count == 3 ? parts[2] : version
                result.append(DependencyDeclaration(name: name, version: resolved, kind: Self.classify(name), ecosystem: "Gradle"))
            }
        }
        return result
    }
    func maven(_ text: String) -> [DependencyDeclaration] {
        var properties: [String: String] = [:]
        if let block = captures(#"(?s)<properties>(.*?)</properties>"#, text).first?[0] {
            for property in captures(#"<([A-Za-z0-9_.-]+)>([^<]*)</\1>"#, block) { properties[property[0]] = property[1].trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        func resolve(_ value: String) -> String {
            guard value.hasPrefix("${"), value.hasSuffix("}") else { return value }
            return properties[String(value.dropFirst(2).dropLast())] ?? value
        }
        func tag(_ name: String, _ block: String) -> String { captures("<" + name + #">\s*([^<]*?)\s*</"# + name + ">", block).first?[0] ?? "" }
        var result: [DependencyDeclaration] = []
        let body = text.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: "", options: .regularExpression)
        if let parent = captures(#"(?s)<parent>(.*?)</parent>"#, body).first?[0] {
            let name = tag("groupId", parent) + ":" + tag("artifactId", parent)
            result.append(DependencyDeclaration(name: name, version: resolve(tag("version", parent)), kind: Self.classify(name), ecosystem: "Maven"))
        }
        for block in captures(#"(?s)<dependency>(.*?)</dependency>"#, body).map({ $0[0] }) {
            let name = tag("groupId", block) + ":" + tag("artifactId", block)
            result.append(DependencyDeclaration(name: name, version: resolve(tag("version", block)), kind: Self.classify(name), ecosystem: "Maven"))
        }
        for block in captures(#"(?s)<plugin>(.*?)</plugin>"#, body).map({ $0[0] }) {
            let group = tag("groupId", block)
            result.append(tool((group.isEmpty ? "org.apache.maven.plugins" : group) + ":" + tag("artifactId", block), resolve(tag("version", block)), "Maven plugin"))
        }
        for key in ["java.version", "maven.compiler.release", "maven.compiler.source"] where properties[key] != nil {
            result.append(tool("Java", properties[key]!, "Maven")); break
        }
        return result
    }
    func csproj(_ text: String) -> [DependencyDeclaration] {
        var result: [DependencyDeclaration] = []
        for element in captures(#"<PackageReference\b([^>]*)>"#, text) {
            let attributes = element[0]
            guard let name = captures(#"Include\s*=\s*"([^"]+)""#, attributes).first?[0] else { continue }
            let version = captures(#"Version\s*=\s*"([^"]+)""#, attributes).first?[0] ?? ""
            result.append(DependencyDeclaration(name: name, version: version, kind: Self.classify(name), ecosystem: "NuGet"))
        }
        for framework in captures(#"<TargetFrameworks?>([^<]+)</TargetFrameworks?>"#, text) { result.append(tool(".NET target framework", framework[0].replacingOccurrences(of: ";", with: ", "), "MSBuild")) }
        if let sdk = captures(#"<Project\s+Sdk\s*=\s*"([^"/]+)/([^"]+)""#, text).first { result.append(tool(sdk[0], sdk[1], "MSBuild")) }
        return result
    }
    func globalJSON(_ text: String) -> [DependencyDeclaration] {
        guard let sdk = (jsonObject(text)?["sdk"] as? [String: Any])?["version"] as? String else { return [] }
        return [tool(".NET SDK", sdk, "global.json")]
    }

    // MARK: Images and generic tool files

    func dockerfile(_ text: String) -> [DependencyDeclaration] {
        var stages = Set<String>()
        var result: [DependencyDeclaration] = []
        for match in captures(#"(?im)^\s*FROM\s+(?:--platform=\S+\s+)?(\S+)(?:\s+AS\s+(\S+))?"#, text) {
            let reference = match[0]
            let isStage = reference == "scratch" || stages.contains(reference.lowercased())
            if !match[1].isEmpty { stages.insert(match[1].lowercased()) }
            if isStage { continue }
            var image = reference, tag = "latest"
            if let at = image.firstIndex(of: "@") { tag = String(image[image.index(after: at)...].prefix(19)); image = String(image[..<at]) }
            else if let colon = image.lastIndex(of: ":"), !image[colon...].contains("/") { tag = String(image[image.index(after: colon)...]); image = String(image[..<colon]) }
            result.append(tool("Image " + image, tag, "Docker"))
        }
        return result
    }
    func toolVersions(_ text: String) -> [DependencyDeclaration] {
        text.components(separatedBy: .newlines).compactMap { line in
            let fields = line.components(separatedBy: "#")[0].split(separator: " ").map(String.init)
            return fields.count >= 2 ? tool(fields[0], fields[1], "asdf") : nil
        }
    }

    // MARK: Helpers

    private func tool(_ name: String, _ version: String, _ ecosystem: String) -> DependencyDeclaration {
        DependencyDeclaration(name: name, version: version.trimmingCharacters(in: .whitespaces), kind: .tool, ecosystem: ecosystem)
    }
    private func library(_ name: String, _ version: String, _ ecosystem: String) -> DependencyDeclaration {
        DependencyDeclaration(name: name, version: version.trimmingCharacters(in: .whitespaces), kind: Self.classify(name), ecosystem: ecosystem)
    }
    /// Recognises a small set of well-known frameworks and build tools; everything else is a library.
    static func classify(_ name: String, development: Bool = false) -> DependencyKind {
        let lower = name.lowercased()
        let short = lower.split(separator: ":").last.map(String.init) ?? lower
        let frameworks: Set<String> = ["react", "vue", "@angular/core", "svelte", "next", "nuxt", "express", "@nestjs/core", "fastify", "django", "flask", "fastapi",
                                       "rails", "sinatra", "vapor", "swift-composable-architecture", "rxswift", "spring-boot-starter-parent", "spring-boot-starter",
                                       "spring-boot-starter-web", "github.com/gin-gonic/gin", "github.com/labstack/echo/v4", "actix-web", "rocket", "axum",
                                       "microsoft.aspnetcore.app", "flutter", "electron", "ktor-server-core", "quarkus-core"]
        let tools: Set<String> = ["typescript", "webpack", "vite", "rollup", "esbuild", "parcel", "@babel/core", "eslint", "prettier", "jest", "vitest", "mocha",
                                  "swiftlint", "swiftformat", "r.swift", "swiftgen", "sourcery", "fastlane", "cocoapods", "setuptools", "wheel", "poetry-core",
                                  "hatchling", "black", "ruff", "mypy", "pytest", "rubocop", "rake", "cc"]
        if frameworks.contains(lower) || frameworks.contains(short) || lower.hasPrefix("org.springframework.boot:spring-boot-starter") { return .framework }
        if tools.contains(lower) || tools.contains(short) || lower.hasPrefix("@types/") || lower.hasPrefix("eslint-") || lower.hasPrefix("@typescript-eslint/") { return .tool }
        return development ? .tool : .library
    }
    /// "https://github.com/Alamofire/Alamofire.git" → "Alamofire"; registry IDs keep their last component.
    func repositoryName(_ location: String) -> String {
        var trimmed = location.trimmingCharacters(in: CharacterSet(charactersIn: "/ "))
        if trimmed.hasSuffix(".git") { trimmed.removeLast(4) }
        let separators: Set<Character> = trimmed.contains("/") ? ["/", ":"] : ["."]
        return trimmed.split(whereSeparator: { separators.contains($0) }).last.map(String.init) ?? trimmed
    }
    private func jsonObject(_ text: String) -> [String: Any]? {
        (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
    }
    /// Every match of `pattern`, as an array of capture groups (an empty string for groups that did not participate).
    func captures(_ pattern: String, _ text: String) -> [[String]] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let source = text as NSString
        return expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { match in
            (1..<max(1, match.numberOfRanges)).map { index in
                let range = match.range(at: index)
                return range.location == NSNotFound ? "" : source.substring(with: range)
            }
        }
    }
    /// Arguments of calls such as `.package(...)`, honouring nested parentheses and string literals.
    func balancedCalls(prefix: String, in text: String) -> [String] {
        var result: [String] = []
        var searchStart = text.startIndex
        while let found = text.range(of: prefix, range: searchStart..<text.endIndex) {
            var depth = 1, index = found.upperBound, inString = false, previous: Character = " "
            while index < text.endIndex && depth > 0 {
                let character = text[index]
                if character == "\"" && previous != "\\" { inString.toggle() }
                else if !inString && character == "(" { depth += 1 }
                else if !inString && character == ")" { depth -= 1 }
                previous = character
                index = text.index(after: index)
            }
            if depth == 0 { result.append(String(text[found.upperBound..<text.index(before: index)])) }
            searchStart = index
        }
        return result
    }
}

/// A line-oriented reader for the subset of TOML used by dependency tables.
/// It understands sections, string values, inline tables and (multi-line) arrays of strings.
struct TOMLLines {
    struct Entry {
        let section: String
        let key: String
        let raw: String
        var stringValue: String { Self.strings(raw).first ?? raw.trimmingCharacters(in: .whitespaces) }
        var arrayValues: [String] { raw.hasPrefix("[") ? Self.strings(raw) : [] }
        func tableValue(_ name: String) -> String? {
            guard raw.hasPrefix("{") else { return nil }
            let escaped = NSRegularExpression.escapedPattern(for: name)
            return ManifestParser().captures(#"(?:^|[{,\s])"# + escaped + #"\s*=\s*"([^"]*)""#, raw).first?[0]
        }
        static func strings(_ text: String) -> [String] {
            ManifestParser().captures(#""((?:[^"\\]|\\.)*)"|'([^']*)'"#, text).map { $0[0].isEmpty ? $0[1] : $0[0] }
        }
    }
    let entries: [Entry]
    init(_ text: String) {
        var entries: [Entry] = []
        var section = ""
        var pendingKey: String?
        var pending = ""
        for rawLine in text.components(separatedBy: .newlines) {
            let line = Self.stripComment(rawLine).trimmingCharacters(in: .whitespaces)
            if let key = pendingKey {
                pending += " " + line
                if Self.balanced(pending) { entries.append(Entry(section: section, key: key, raw: pending)); pendingKey = nil; pending = "" }
                continue
            }
            if line.hasPrefix("[") && !line.contains("=") {
                section = line.trimmingCharacters(in: CharacterSet(charactersIn: "[] ")).replacingOccurrences(of: "\"", with: "")
                continue
            }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let key = line[..<equals].trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            let value = line[line.index(after: equals)...].trimmingCharacters(in: .whitespaces)
            if Self.balanced(value) { entries.append(Entry(section: section, key: key, raw: value)) }
            else { pendingKey = key; pending = value }
        }
        self.entries = entries
    }
    private static func balanced(_ text: String) -> Bool {
        var depth = 0, inString = false, quote: Character = "\""
        for character in text {
            if inString { if character == quote { inString = false } ; continue }
            if character == "\"" || character == "'" { inString = true; quote = character }
            else if character == "[" || character == "{" { depth += 1 }
            else if character == "]" || character == "}" { depth -= 1 }
        }
        return depth <= 0
    }
    private static func stripComment(_ line: String) -> String {
        var inString = false, quote: Character = "\""
        for (offset, character) in line.enumerated() {
            if inString { if character == quote { inString = false }; continue }
            if character == "\"" || character == "'" { inString = true; quote = character }
            else if character == "#" { return String(line.prefix(offset)) }
        }
        return line
    }
}

/// Numeric version comparison over the first dotted number in a requirement string.
public enum VersionOrdering {
    public static func components(_ text: String) -> [Int]? {
        guard let range = text.range(of: #"\d+(?:\.\d+)*"#, options: .regularExpression) else { return nil }
        return text[range].split(separator: ".").compactMap { Int($0) }
    }
    public static func compare(_ left: String, _ right: String) -> ComparisonResult? {
        guard let a = components(left), let b = components(right) else { return nil }
        for index in 0..<max(a.count, b.count) {
            let x = index < a.count ? a[index] : 0, y = index < b.count ? b[index] : 0
            if x != y { return x < y ? .orderedAscending : .orderedDescending }
        }
        return .orderedSame
    }
    /// A different major version, or a different minor version while the major version is zero.
    public static func isMajorChange(_ left: String, _ right: String) -> Bool {
        guard let a = components(left), let b = components(right), let majorA = a.first, let majorB = b.first else { return false }
        if majorA != majorB { return true }
        return majorA == 0 && (a.count > 1 ? a[1] : 0) != (b.count > 1 ? b[1] : 0)
    }
}
