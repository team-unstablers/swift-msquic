import PackagePlugin
import Foundation

@main
struct PrebuiltLibraryInjector: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let packageRoot = context.package.directory
        let workDirectory = context.pluginWorkDirectory

        let distDir = packageRoot.appending("dist")
        let distLib = distDir.appending("ios").appending("lib").appending("libmsquic.a")
        // let stageStamp = artifactDir.appending("libmsquic.stamp")
        let destination = workDirectory.appending("libmsquic.a")

        let copy = Command.buildCommand(
            displayName: "Stage msquic static library",
            executable: Path("/bin/cp"),
            arguments: [distLib, destination],
            inputFiles: [distLib],
            outputFiles: [destination]
        )

        return [copy]
    }
}


