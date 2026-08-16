import Foundation
import PackagePlugin

/// Compiles Core Image Metal kernels (`Metal/*.metal`) into `.cikernel` resources.
/// When the Metal toolchain is unavailable (Command Line Tools only), the kernel
/// source is stored verbatim and compiled by CIKernelLoader at runtime.
@main
struct MetalCIKernelPlugin: BuildToolPlugin {
    func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command] {
        let metalDir = context.package.directoryURL.appending(path: "Metal")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: metalDir.path()))?
            .filter { $0.hasSuffix(".metal") } ?? []

        return names.map { file in
            let stem = (file as NSString).deletingPathExtension
            let metal = metalDir.appending(path: file)
            let air = context.pluginWorkDirectoryURL.appending(path: "\(stem).air")
            let cikernel = context.pluginWorkDirectoryURL.appending(path: "\(stem).cikernel")
            return .buildCommand(
                displayName: "Compile CI kernel \(file)",
                executable: URL(filePath: "/bin/sh"),
                arguments: [
                    "-c",
                    "if xcrun -f metal >/dev/null 2>&1; then " +
                    "xcrun metal -c -fcikernel '\(metal.path())' -o '\(air.path())' && " +
                    "xcrun metallib -cikernel '\(air.path())' -o '\(cikernel.path())'; " +
                    "else " +
                    "cp '\(metal.path())' '\(cikernel.path())'; " +
                    "fi",
                ],
                inputFiles: [metal],
                outputFiles: [cikernel])
        }
    }
}
