import Foundation

/// Runs a child process to completion, collecting stdout and stderr. Terminates it after `timeout`.
public enum ProcessRunner {
    public struct Output: Sendable {
        public var status: Int32
        public var stdout: String
        public var stderr: String
    }

    public static func run(executable: URL, arguments: [String], environment: [String: String]? = nil, timeout: TimeInterval) async throws -> Output {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Output, Error>) in
            let process = Process()
            process.executableURL = executable
            process.arguments = arguments
            process.environment = environment
            let out = Pipe(), err = Pipe()
            process.standardOutput = out
            process.standardError = err
            let outBox = DataBox(), errBox = DataBox()
            out.fileHandleForReading.readabilityHandler = { h in outBox.append(h.availableData) }
            err.fileHandleForReading.readabilityHandler = { h in errBox.append(h.availableData) }
            process.terminationHandler = { p in
                out.fileHandleForReading.readabilityHandler = nil
                err.fileHandleForReading.readabilityHandler = nil
                outBox.append(out.fileHandleForReading.readDataToEndOfFile())
                errBox.append(err.fileHandleForReading.readDataToEndOfFile())
                cont.resume(returning: Output(
                    status: p.terminationStatus,
                    stdout: String(decoding: outBox.data, as: UTF8.self),
                    stderr: String(decoding: errBox.data, as: UTF8.self)
                ))
            }
            do {
                try process.run()
            } catch {
                cont.resume(throwing: BackupImportError("Couldn't run \(executable.lastPathComponent): \(error.localizedDescription)"))
                return
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + timeout) { if process.isRunning { process.terminate() } }
        }
    }
}

private final class DataBox: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    func append(_ d: Data) { lock.lock(); buffer.append(d); lock.unlock() }
    var data: Data { lock.lock(); defer { lock.unlock() }; return buffer }
}
