#!/bin/bash
set -euo pipefail
# Creates a fresh fixture for Structure, Dependencies and Legacy; never changes an existing repository.
temporary="${TMPDIR:-/tmp}"
demo_root="$(mktemp -d "${temporary%/}/GitScope-legacy-demo.XXXXXX")"
export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL=/dev/null
commit() { # commit <ISO date> <author name> <author email> <message>
    export GIT_AUTHOR_DATE="$1" GIT_COMMITTER_DATE="$1" GIT_AUTHOR_NAME="$2" GIT_AUTHOR_EMAIL="$3" GIT_COMMITTER_NAME="$2" GIT_COMMITTER_EMAIL="$3"
    git -C "$demo_root" add -A
    git -C "$demo_root" -c core.hooksPath=/dev/null commit -qm "$4"
}
package() { # package <tools version> <Alamofire requirement> [extra dependency line]
    cat > "$demo_root/Package.swift" <<EOF
// swift-tools-version:$1
import PackageDescription
let package = Package(name: "Shop", platforms: [.iOS(.v13)], dependencies: [
    .package(url: "https://github.com/Alamofire/Alamofire.git", $2),${3:-}
], targets: [
    .target(name: "App", dependencies: ["Alamofire"]),
    .target(name: "Payments"),
    .testTarget(name: "AppTests", dependencies: ["App"])
])
EOF
}
git -C "$demo_root" init -q -b main
mkdir -p "$demo_root/Sources/App" "$demo_root/Sources/Payments/Legacy" "$demo_root/Tests/AppTests"

package 5.3 'from: "4.9.0"' '
    .package(url: "https://github.com/onevcat/Kingfisher.git", from: "6.0.0"),'
printf 'import UIKit\nimport Alamofire\n\nfinal class HelpScreen {\n    let web = UIWebView()\n    func load() { AF.request("https://example.test/help") }\n}\n' > "$demo_root/Sources/App/HelpScreen.swift"
printf 'import UIKit\nimport Kingfisher\n\nfunc avatar(_ view: UIImageView, _ url: URL) { view.kf.setImage(with: url) }\n' > "$demo_root/Sources/App/Avatar.swift"
printf 'import Foundation\n\nstruct Card { let number: String }\n' > "$demo_root/Sources/Payments/Card.swift"
printf 'import XCTest\n@testable import App\n\nfinal class AppTests: XCTestCase { func testExample() {} }\n' > "$demo_root/Tests/AppTests/AppTests.swift"
commit "2021-03-10T12:00:00Z" "Ada Lovelace" "ada@example.test" "Create shop app"

printf 'import Foundation\n\n// TODO: remove after the Payments v2 migration\n@available(*, deprecated, message: "Use PaymentsClient")\nfinal class LegacyGateway { func charge(_ card: Card) {} }\n' > "$demo_root/Sources/Payments/Legacy/LegacyGateway.swift"
commit "2022-06-01T12:00:00Z" "Grace Hopper" "grace@example.test" "Add payment gateway"

package 5.9 'from: "5.8.0"'
printf 'import WebKit\n\nfinal class OnboardingScreen {\n    let web = WKWebView()\n}\n' > "$demo_root/Sources/App/OnboardingScreen.swift"
commit "2023-09-15T12:00:00Z" "Ada Lovelace" "ada@example.test" "Upgrade to Alamofire 5, drop Kingfisher, start WKWebView migration"

printf 'import UIKit\nimport Alamofire\n\nfinal class HelpScreen {\n    let web = UIWebView()\n    let title = "Help"\n    func load() { AF.request("https://example.test/help") }\n}\n' > "$demo_root/Sources/App/HelpScreen.swift"
commit "2024-11-20T12:00:00Z" "Grace Hopper" "grace@example.test" "Add help title"

printf 'import UIKit\nimport Alamofire\n\nfinal class HelpScreen {\n    let web = UIWebView()\n    let title = "Help center"\n    func load() { AF.request("https://example.test/help") }\n}\n' > "$demo_root/Sources/App/HelpScreen.swift"
printf 'v20.11.0\n' > "$demo_root/.nvmrc"
commit "2026-02-03T12:00:00Z" "Grace Hopper" "grace@example.test" "Rename help title, pin Node for tooling"

printf '\nSelect this repository in GitScope:\n%s\n' "$demo_root"
