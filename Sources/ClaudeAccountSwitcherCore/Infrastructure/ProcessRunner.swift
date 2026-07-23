import Foundation

public struct ProcessResult: Sendable, Equatable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
}

public enum ProcessRunnerError: Error { case executableMissing(URL), timedOut, failed(ProcessResult) }

public struct ProcessRunner: Sendable {
    public var outputLimit: Int
    /// Tempo máximo (em segundos) para o processo terminar; `nil` = sem limite.
    public var timeout: TimeInterval?

    public init(outputLimit: Int = 64 * 1024, timeout: TimeInterval? = nil) {
        self.outputLimit = outputLimit
        self.timeout = timeout
    }

    public func run(executable: URL, arguments: [String] = [], environment: [String: String] = [:], cwd: URL? = nil, timeout: TimeInterval? = nil) throws -> ProcessResult {
        let timeout = timeout ?? self.timeout
        guard FileManager.default.isExecutableFile(atPath: executable.path) else { throw ProcessRunnerError.executableMissing(executable) }
        let process = Process(); process.executableURL = executable; process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        environment.forEach { env[$0.key] = $0.value }; process.environment = env
        process.currentDirectoryURL = cwd
        let out = Pipe(); let err = Pipe(); process.standardOutput = out; process.standardError = err

        // Drena stdout/stderr concorrentemente durante a execução. Ler só após o exit
        // deadlockaria se o filho enchesse o buffer de pipe (>64KB) antes de terminar.
        let outCollector = PipeCollector(handle: out.fileHandleForReading)
        let errCollector = PipeCollector(handle: err.fileHandleForReading)
        outCollector.start(); errCollector.start()

        try process.run()

        if let timeout {
            // waitUntilExit() não tem variante com timeout; espera em background e
            // dá join com deadline. Se estourar, mata o processo (SIGTERM → SIGKILL).
            let done = DispatchSemaphore(value: 0)
            let waiter = Thread { process.waitUntilExit(); done.signal() }
            waiter.stackSize = 1 << 20
            waiter.start()
            if done.wait(timeout: .now() + timeout) == .timedOut {
                process.terminate()
                if done.wait(timeout: .now() + 2) == .timedOut {
                    kill(process.processIdentifier, SIGKILL)
                    done.wait()
                }
                // Fecha os pipes para destravar os leitores antes de descartá-los.
                outCollector.finish(); errCollector.finish()
                throw ProcessRunnerError.timedOut
            }
        } else {
            process.waitUntilExit()
        }

        let stdout = decodeTruncated(outCollector.finish(), limit: outputLimit)
        let stderr = decodeTruncated(errCollector.finish(), limit: outputLimit)
        let result = ProcessResult(exitCode: process.terminationStatus, stdout: stdout, stderr: stderr)
        if process.terminationStatus != 0 { throw ProcessRunnerError.failed(result) }
        return result
    }
}

/// Trunca em `limit` bytes respeitando a fronteira de caracteres UTF-8: recua até
/// obter uma sequência válida, evitando que um corte no meio de um code point vire "".
private func decodeTruncated(_ data: Data, limit: Int) -> String {
    var slice = data.prefix(limit)
    if slice.count == data.count { return String(decoding: slice, as: UTF8.self) }
    // Recua no máximo 3 bytes (comprimento máximo restante de um code point UTF-8).
    for _ in 0..<4 {
        if let text = String(data: slice, encoding: .utf8) { return text }
        guard !slice.isEmpty else { break }
        slice = slice.dropLast()
    }
    return String(decoding: slice, as: UTF8.self)
}

/// Lê um `FileHandle` de pipe em uma thread dedicada até EOF, acumulando os bytes.
/// `finish()` aguarda o término da leitura e devolve o buffer completo.
private final class PipeCollector: @unchecked Sendable {
    private let handle: FileHandle
    private let lock = NSLock()
    private var buffer = Data()
    private let done = DispatchSemaphore(value: 0)
    private var thread: Thread?

    init(handle: FileHandle) { self.handle = handle }

    func start() {
        let thread = Thread { [handle, lock, done] in
            while true {
                let chunk = handle.availableData
                if chunk.isEmpty { break }
                lock.lock(); self.buffer.append(chunk); lock.unlock()
            }
            done.signal()
        }
        thread.stackSize = 1 << 20
        self.thread = thread
        thread.start()
    }

    /// Aguarda EOF e retorna todos os bytes lidos.
    @discardableResult
    func finish() -> Data {
        try? handle.close()
        done.wait()
        lock.lock(); defer { lock.unlock() }
        return buffer
    }
}
