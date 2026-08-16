import CoreImage
import Foundation

/// Loads Core Image kernels from `.cikernel` resources: compiled `.metallib`
/// bytes when the Metal toolchain was available at build time, otherwise kernel
/// source compiled on first use.
enum CIKernelLoader {
    private static let metallibMagic = Data("MTLB".utf8)

    private static func data(_ lib: String) -> Data? {
        BundledResource.url("\(lib).cikernel").flatMap { try? Data(contentsOf: $0) }
    }

    static func kernel(_ lib: String, _ function: String) -> CIKernel? {
        kernel(named: function, in: data(lib))
    }

    static func colorKernel(_ lib: String, _ function: String) -> CIColorKernel? {
        kernel(named: function, in: data(lib)) as? CIColorKernel
    }

    private static func kernel(named function: String, in data: Data?) -> CIKernel? {
        guard let data else { return nil }
        if data.prefix(4) == metallibMagic {
            return try? CIKernel(functionName: function, fromMetalLibraryData: data)
        }
        guard let source = String(data: data, encoding: .utf8) else { return nil }
        let ciSource = source
            .split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.hasPrefix("#include") }
            .joined(separator: "\n")
        guard let kernels = try? CIKernel.kernels(withMetalString: ciSource) else { return nil }
        return kernels.first { $0.name == function }
    }
}
