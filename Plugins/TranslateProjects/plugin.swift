import Foundation
import PackagePlugin

/** `swift package translate` in a package, or right-click the project → Translate Projects in Xcode. */
@main
struct TranslateProjects: CommandPlugin {
    func performCommand(context: PluginContext, arguments: [String]) async throws {
        try run(context.tool(named: "translate-projects-ios").path.string, directory: context.package.directory.string, arguments)
    }
}

func run(_ tool: String, directory: String, _ arguments: [String]) throws {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: tool)
    process.arguments = ["--directory", directory] + arguments
    try process.run()
    process.waitUntilExit()
    if process.terminationStatus != 0 { Diagnostics.error("Translate Projects failed, see the log above") }
}

#if canImport(XcodeProjectPlugin)
import XcodeProjectPlugin

extension TranslateProjects: XcodeCommandPlugin {
    func performCommand(context: XcodePluginContext, arguments: [String]) throws {
        try run(context.tool(named: "translate-projects-ios").path.string, directory: context.xcodeProject.directory.string, arguments)
    }
}
#endif
