import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunnerError: Error { case executableMissing(URL), timedOut, failed(ProcessResult) }

public struct ProcessRunner: Sendable {
    public var outputLimit: Int
    public init(outputLimit: Int = 64 * 1024) { self.outputLimit = outputLimit }

    public func run(executable: URL, arguments: [String] = [], environment: [String: String] = [:], cwd: URL? = nil) throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProcessRunnerError.executableMissing(executable) }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }; process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe(); let err = Pipe(); process.standardOutput = out; process.standardError = err
        try process.run(); process.waitUntilExit()
        let stdout = String(data: out.fileHandleForReading.readDataToEndOfFile().prefix(outputLimit), encoding: .utf8) ?? ""
        let stderr = String(data: err.fileHandleForReading.readDataToEndOfFile().prefix(outputLimit), encoding: .utf8) ?? ""
        let result = ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        if process.terminationStatus != 0 { throw ProcessRunnerError.failed(result) }
        return result
    }
}
