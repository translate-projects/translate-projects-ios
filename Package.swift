// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "translate-projects-ios",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "translate-projects-ios", targets: ["translate-projects-ios"]),
        .plugin(name: "TranslateProjects", targets: ["TranslateProjects"]),
    ],
    targets: [
        .target(name: "TranslateProjectsKit"),
        .executableTarget(name: "translate-projects-ios", dependencies: ["TranslateProjectsKit"]),
        .plugin(
            name: "TranslateProjects",
            capability: .command(
                intent: .custom(verb: "translate", description: "Translate Localizable.xcstrings with Translate Projects"),
                permissions: [
                    .writeToPackageDirectory(reason: "Writes the translations into the String Catalog"),
                    .allowNetworkConnections(scope: .all(ports: [443]), reason: "Calls the Translate Projects API"),
                ]
            ),
            dependencies: ["translate-projects-ios"]
        ),
        .testTarget(name: "TranslateProjectsKitTests", dependencies: ["TranslateProjectsKit"]),
    ]
)
