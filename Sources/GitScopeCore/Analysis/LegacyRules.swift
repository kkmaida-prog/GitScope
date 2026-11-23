import Foundation

/// Built-in legacy signals. Each rule names one concrete, documented deprecation or an explicit marker,
/// so every finding can say exactly why it was reported. Users can disable rules or add literal ones.
public enum LegacyRules {
    static let apple = ["swift", "m", "mm", "h"]
    static let javaScript = ["js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte"]
    /// Extensions scanned for rules and imports. Documentation and data files are not scanned.
    public static let sourceExtensions = ["swift", "m", "mm", "h", "c", "cc", "cpp", "hpp", "js", "jsx", "ts", "tsx", "mjs", "cjs", "vue", "svelte",
                                          "py", "rb", "go", "rs", "java", "kt", "kts", "scala", "groovy", "gradle", "cs", "php", "dart"]

    public static let builtIn: [LegacyRule] = [
        rule("apple.uiwebview", "UIWebView", ["UIWebView"], #"\bUIWebView\b"#, "WKWebView", "WKWebView", apple,
             "Deprecated in iOS 12; the App Store no longer accepts new apps that use it."),
        rule("apple.uialertview", "UIAlertView", ["UIAlertView"], #"\bUIAlertView\b"#, "UIAlertController", "UIAlertController", apple, "Deprecated in iOS 9."),
        rule("apple.uiactionsheet", "UIActionSheet", ["UIActionSheet"], #"\bUIActionSheet\b"#, "UIAlertController", "UIAlertController", apple, "Deprecated in iOS 8.3."),
        rule("apple.nsurlconnection", "NSURLConnection", ["NSURLConnection"], #"\bNSURLConnection\b"#, "URLSession", "URLSession", apple, "Deprecated in iOS 9 and macOS 10.11."),
        rule("apple.openurl", "UIApplication openURL(_:)", [".openURL("], #"\.openURL\("#, "open(_:options:completionHandler:)", nil, ["swift"], "Deprecated in iOS 10."),
        rule("apple.keywindow", "UIApplication keyWindow", [".keyWindow"], #"UIApplication\.shared\.keyWindow\b"#, "the window of a UIWindowScene", nil, ["swift"],
             "Deprecated in iOS 13 for apps that support multiple scenes."),
        rule("apple.appmain", "@UIApplicationMain / @NSApplicationMain", ["@UIApplicationMain", "@NSApplicationMain"], #"@(UI|NS)ApplicationMain\b"#, "@main", "@main", ["swift"],
             "Deprecated by Swift Evolution SE-0383."),
        rule("apple.navigationview", "SwiftUI NavigationView", ["NavigationView"], #"\bNavigationView\s*[\{(]"#, "NavigationStack or NavigationSplitView", "NavigationStack", ["swift"],
             "Deprecated; NavigationStack and NavigationSplitView replace it (iOS 16, macOS 13)."),
        rule("apple.navigationbartitle", "SwiftUI navigationBarTitle(_:)", [".navigationBarTitle("], #"\.navigationBarTitle\("#, "navigationTitle(_:)", ".navigationTitle(", ["swift"],
             "Deprecated; use navigationTitle(_:)."),
        rule("apple.edgesignoringsafearea", "SwiftUI edgesIgnoringSafeArea(_:)", [".edgesIgnoringSafeArea("], #"\.edgesIgnoringSafeArea\("#, "ignoresSafeArea(_:edges:)", ".ignoresSafeArea(", ["swift"],
             "Deprecated; use ignoresSafeArea(_:edges:)."),
        rule("apple.accentcolor", "SwiftUI accentColor(_:)", [".accentColor("], #"\.accentColor\("#, "tint(_:)", ".tint(", ["swift"], "Deprecated; use tint(_:)."),
        rule("apple.imagecontext", "UIGraphicsBeginImageContext", ["UIGraphicsBeginImageContext"], #"\bUIGraphicsBeginImageContext(WithOptions)?\b"#, "UIGraphicsImageRenderer",
             "UIGraphicsImageRenderer", apple, "Deprecated in iOS 17; use UIGraphicsImageRenderer."),
        rule("react.unsafelifecycle", "Legacy React lifecycle method", ["componentWillMount", "componentWillReceiveProps", "componentWillUpdate"],
             #"(?<!UNSAFE_)\b(componentWillMount|componentWillReceiveProps|componentWillUpdate)\b"#, "hooks or componentDidMount/getDerivedStateFromProps", nil, javaScript,
             "Legacy since React 16.3; only UNSAFE_ names remain supported."),
        rule("react.domrender", "ReactDOM.render", ["ReactDOM.render(", "ReactDOM.hydrate("], #"\bReactDOM\.(render|hydrate)\("#, "createRoot / hydrateRoot", "createRoot(", javaScript,
             "Deprecated in React 18 and removed in React 19."),
        rule("node.buffer", "new Buffer()", ["new Buffer("], #"\bnew Buffer\("#, "Buffer.from / Buffer.alloc", "Buffer.from(", javaScript, "Deprecated by Node.js (DEP0005)."),
        rule("python.imp", "imp module", ["import imp", "from imp "], #"^\s*(import imp\b|from imp import)"#, "importlib", "importlib", ["py"], "Removed in Python 3.12."),
        rule("python.distutils", "distutils", ["distutils"], #"^\s*(import|from)\s+distutils\b"#, "setuptools / packaging", nil, ["py"], "Removed in Python 3.12."),
        rule("python.utcnow", "datetime.utcnow()", [".utcnow("], #"\.utcnow\(\)"#, "datetime.now(timezone.utc)", "timezone.utc", ["py"], "Deprecated in Python 3.12."),
        rule("go.ioutil", "io/ioutil", ["io/ioutil", "ioutil."], #""io/ioutil"|\bioutil\.\w+\("#, "io and os functions", nil, ["go"], "Deprecated since Go 1.16."),
        rule("android.asynctask", "AsyncTask", ["AsyncTask"], #"\bAsyncTask\b"#, "coroutines or java.util.concurrent", nil, ["java", "kt"], "Deprecated in Android API 30."),
        rule("dotnet.webclient", "WebClient", ["WebClient"], #"\bnew WebClient\(|\bWebClient\s+\w+\s*="#, "HttpClient", "HttpClient", ["cs"], "Obsolete since .NET 6 (SYSLIB0014)."),
        LegacyRule(id: "marker.deprecated", title: "Deprecated declaration in this repository", category: .deprecationMarker,
                   keywords: ["deprecated", "Deprecated", "DEPRECATED", "Obsolete"],
                   pattern: #"@available\([^)]*\bdeprecated\b|@Deprecated\b|\[Obsolete\b|@deprecated\b|DeprecationWarning|API_DEPRECATED|DEPRECATED_ATTRIBUTE|__attribute__\(\(deprecated|#\[deprecated"#,
                   note: "The code itself is marked as deprecated, so callers should be migrating away from it.", builtIn: true),
        LegacyRule(id: "marker.legacy", title: "Legacy or migration comment", category: .legacyMarker,
                   keywords: ["TODO", "FIXME", "HACK", "XXX", "legacy", "Legacy", "LEGACY"],
                   pattern: #"\b(TODO|FIXME|HACK|XXX)\b.*\b(legacy|deprecat\w*|migrat\w*|obsolete|old api|remove (after|when|once))|(//|#|/\*|^\s*\*|--)\s*.*\blegacy\b"#,
                   caseInsensitive: true, note: "A comment explicitly calls this code legacy or describes an unfinished migration.", builtIn: true)
    ]

    private static func rule(_ id: String, _ title: String, _ keywords: [String], _ pattern: String, _ replacement: String?, _ replacementKeyword: String?,
                             _ extensions: [String], _ note: String) -> LegacyRule {
        LegacyRule(id: id, title: title, category: .deprecatedAPI, keywords: keywords, pattern: pattern, replacement: replacement,
                   replacementKeyword: replacementKeyword, extensions: extensions, note: note, builtIn: true)
    }
}
