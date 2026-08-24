import Foundation

public enum CrossOverThreadName: String, Equatable, Sendable {
    case noelleMain = "Noelle Main"
    case unityGfxDeviceWorker = "UnityGfxDeviceWorker"
    case unityMultiRenderingThread = "UnityMultiRenderingThread"
}

/// Events intentionally expose only normalized, bounded values. Raw trace
/// lines are never retained or returned, so command lines and session tokens
/// cannot leak through the parser result.
public enum CrossOverTraceEvent: Equatable, Sendable {
    case genshinProcessStarted(pid: Int32)
    case threadNamed(pid: Int32, name: CrossOverThreadName)
    case mhypBaseMapped(pid: Int32, lowerBound: UInt64, upperBound: UInt64)
    case mhypBaseAccessViolation(pid: Int32, code: UInt32, address: UInt64)
    case processExited(pid: Int32)
    case lineLimitExceeded
    case logLimitExceeded
}

/// A streaming parser for the timestamp/pid Wine trace format emitted by
/// cxstart. A caller may supply the PID belonging to the current launch, or
/// leave it nil and let the parser discover YuanShen launches from the
/// CreateProcess trace. All other process IDs are ignored before any event is
/// emitted.
public struct CrossOverTraceParser: Sendable {
    public struct Limits: Equatable, Sendable {
        public let maximumLogBytes: Int
        public let maximumLineBytes: Int

        public init(
            maximumLogBytes: Int = 32 * 1024 * 1024,
            maximumLineBytes: Int = 256 * 1024
        ) {
            self.maximumLogBytes = max(1, maximumLogBytes)
            self.maximumLineBytes = max(1, maximumLineBytes)
        }
    }

    public private(set) var targetPID: Int32?
    public let limits: Limits
    public private(set) var bytesConsumed = 0

    private var pendingLine = Data()
    private var pendingLineExceededLimit = false
    private var didEmitLogLimit = false
    private var processHasExited = false
    private var mhypBaseRanges: [ClosedRange<UInt64>] = []
    private var mhypBaseLowerBounds: Set<UInt64> = []
    private var pendingMHYPAccessViolation: (code: UInt32, address: UInt64)?
    private var pendingYuanShenLaunches: [ProcessThread] = []
    private var pendingYuanShenCreations: [ProcessThread] = []

    public init(targetPID: Int32? = nil, limits: Limits = Limits()) throws {
        if let targetPID, targetPID <= 0 {
            throw CrossOverTraceParserError.invalidPID
        }
        self.targetPID = targetPID
        self.limits = limits
    }

    /// Starts a fresh process instance. Clearing the module ranges is
    /// important when the operating system reuses the same numeric PID.
    public mutating func reset(targetPID: Int32? = nil) throws {
        if let targetPID, targetPID <= 0 {
            throw CrossOverTraceParserError.invalidPID
        }
        self.targetPID = targetPID
        bytesConsumed = 0
        pendingLine.removeAll(keepingCapacity: false)
        pendingLineExceededLimit = false
        didEmitLogLimit = false
        processHasExited = false
        mhypBaseRanges.removeAll(keepingCapacity: false)
        mhypBaseLowerBounds.removeAll(keepingCapacity: false)
        pendingMHYPAccessViolation = nil
        pendingYuanShenLaunches.removeAll(keepingCapacity: false)
        pendingYuanShenCreations.removeAll(keepingCapacity: false)
    }

    public mutating func append(_ chunk: Data) -> [CrossOverTraceEvent] {
        guard !chunk.isEmpty, !didEmitLogLimit else { return [] }

        let remainingCapacity = limits.maximumLogBytes - bytesConsumed
        guard remainingCapacity > 0 else {
            didEmitLogLimit = true
            return [.logLimitExceeded]
        }

        let count = min(remainingCapacity, chunk.count)
        var events: [CrossOverTraceEvent] = []
        events.reserveCapacity(2)

        for byte in chunk.prefix(count) {
            if byte == 0x0a { // LF; CR is removed below.
                if pendingLine.last == 0x0d {
                    pendingLine.removeLast()
                }
                if pendingLineExceededLimit {
                    events.append(.lineLimitExceeded)
                } else if let event = parse(line: pendingLine) {
                    events.append(event)
                }
                pendingLine.removeAll(keepingCapacity: true)
                pendingLineExceededLimit = false
            } else if pendingLineExceededLimit {
                continue
            } else if pendingLine.count < limits.maximumLineBytes {
                pendingLine.append(byte)
            } else {
                // Drop the remainder of an oversized line without retaining
                // it. Parsing resumes at the next LF boundary.
                pendingLineExceededLimit = true
                pendingLine.removeAll(keepingCapacity: false)
            }
        }
        bytesConsumed += count

        if count < chunk.count {
            didEmitLogLimit = true
            events.append(.logLimitExceeded)
        }
        return events
    }

    public mutating func append(_ chunk: String) -> [CrossOverTraceEvent] {
        append(Data(chunk.utf8))
    }

    /// Parses a final unterminated line when the trace source closes. A line
    /// split across normal chunks is not parsed until its LF arrives, so this
    /// method is the only operation that accepts an EOF-terminated line.
    public mutating func finish() -> [CrossOverTraceEvent] {
        guard !didEmitLogLimit, !pendingLine.isEmpty else { return [] }
        defer {
            pendingLine.removeAll(keepingCapacity: false)
            pendingLineExceededLimit = false
        }
        if pendingLineExceededLimit {
            return [.lineLimitExceeded]
        }
        return parse(line: pendingLine).map { [$0] } ?? []
    }

    private struct ProcessThread: Equatable, Sendable {
        let pid: Int32
        let tid: Int32
    }

    private mutating func parse(line: Data) -> CrossOverTraceEvent? {
        guard let line = String(data: line, encoding: .utf8) else { return nil }
        let fields = line.split(separator: ":", maxSplits: 5, omittingEmptySubsequences: false)
        guard fields.count == 6,
              let pidValue = UInt32(fields[1], radix: 16),
              let tidValue = UInt32(fields[2], radix: 16),
              pidValue <= UInt32(Int32.max),
              tidValue <= UInt32(Int32.max) else {
            return nil
        }

        let processThread = ProcessThread(pid: Int32(pidValue), tid: Int32(tidValue))
        let channel = fields[4].lowercased()
        let message = String(fields[5])

        // The first process line contains the full command line, including
        // sensitive launcher/session arguments. We only retain the fact that
        // a YuanShen launch is pending, never the line itself.
        if channel == "process" {
            if message.localizedCaseInsensitiveContains("CreateProcessInternalW app") &&
                message.localizedCaseInsensitiveContains("YuanShen.exe") {
                if !pendingYuanShenLaunches.contains(processThread) {
                    pendingYuanShenLaunches.append(processThread)
                    pendingYuanShenLaunches = Array(pendingYuanShenLaunches.suffix(8))
                }
            }

            if message.localizedCaseInsensitiveContains("NtCreateUserProcess") &&
                message.localizedCaseInsensitiveContains("YuanShen.exe"),
               let launchIndex = pendingYuanShenLaunches.firstIndex(of: processThread) {
                pendingYuanShenLaunches.remove(at: launchIndex)
                if let pid = hexadecimalPID(after: "pid", in: message) {
                    return activateProcess(pid: pid)
                }
                pendingYuanShenCreations.append(processThread)
                pendingYuanShenCreations = Array(pendingYuanShenCreations.suffix(8))
            }

            if message.localizedCaseInsensitiveContains("CreateProcessInternalW started process"),
               let launchIndex = pendingYuanShenCreations.firstIndex(of: processThread),
               let pid = hexadecimalPID(after: "pid", in: message) {
                pendingYuanShenCreations.remove(at: launchIndex)
                return activateProcess(pid: pid)
            }
        }

        // Wine can emit the child process's module mapping before the
        // launcher prints "started process pid ...". Once a YuanShen create
        // request is pending, this is an equally strong PID binding and lets
        // us retain MHYPBase's range for the early failure path. A dedicated
        // cxstart trace may also begin inside YuanShen itself and contain no
        // parent CreateProcess event; in that case the executable's own
        // module mapping is the first process-scoped identity signal.
        if channel == "module",
           message.localizedCaseInsensitiveContains("YuanShen.exe"),
           (targetPID == nil || pendingYuanShenCreations.contains(where: { $0.pid != processThread.pid })),
           let event = activateProcess(pid: Int32(pidValue)) {
            return event
        }

        guard let targetPID,
              Int32(pidValue) == targetPID,
              !processHasExited else {
            return nil
        }

        switch channel {
        case "threadname":
            guard let name = normalizedThreadName(in: message) else { return nil }
            return .threadNamed(pid: targetPID, name: name)

        case "module":
            if let range = mhypBaseRange(in: message) {
                mhypBaseRanges.append(range)
                mhypBaseLowerBounds.insert(range.lowerBound)
                return .mhypBaseMapped(pid: targetPID, lowerBound: range.lowerBound, upperBound: range.upperBound)
            }
            if let base = mhypBaseLoadBase(in: message) {
                mhypBaseLowerBounds.insert(base)
            }
            if message.localizedCaseInsensitiveContains("LdrShutdownProcess") {
                processHasExited = true
                return .processExited(pid: targetPID)
            }

        case "loaddll":
            if let base = mhypBaseLoadBase(in: message) {
                mhypBaseLowerBounds.insert(base)
            }

        case "process":
            let lowercased = message.lowercased()
            if lowercased.contains("ntterminateprocess") ||
                lowercased.contains("exitprocess") ||
                lowercased.contains("terminateprocess") {
                processHasExited = true
                return .processExited(pid: targetPID)
            }

        case "seh":
            guard message.localizedCaseInsensitiveContains("dispatch_exception") else {
                return nil
            }
            pendingMHYPAccessViolation = nil
            guard let codeValue = hexadecimalValue(after: "code=", in: message),
                  codeValue <= UInt64(UInt32.max),
                  let code = UInt32(exactly: codeValue),
                  code == 0xc0000005,
                  let address = hexadecimalValue(after: "addr=", in: message) else {
                return nil
            }
            if mhypBaseRanges.contains(where: { $0.contains(address) }) {
                return .mhypBaseAccessViolation(pid: targetPID, code: code, address: address)
            }
            pendingMHYPAccessViolation = (code, address)

        case "unwind":
            guard let pending = pendingMHYPAccessViolation,
                  message.localizedCaseInsensitiveContains("RtlVirtualUnwind"),
                  let base = hexadecimalValue(after: "base ", in: message),
                  mhypBaseLowerBounds.contains(base) else {
                return nil
            }
            pendingMHYPAccessViolation = nil
            return .mhypBaseAccessViolation(pid: targetPID, code: pending.code, address: pending.address)

        default:
            break
        }
        return nil
    }

    private mutating func activateProcess(pid: Int32) -> CrossOverTraceEvent? {
        guard pid > 0 else { return nil }
        if targetPID == pid, !processHasExited {
            return nil
        }
        targetPID = pid
        processHasExited = false
        mhypBaseRanges.removeAll(keepingCapacity: false)
        mhypBaseLowerBounds.removeAll(keepingCapacity: false)
        pendingMHYPAccessViolation = nil
        return .genshinProcessStarted(pid: pid)
    }

    private func normalizedThreadName(in message: String) -> CrossOverThreadName? {
        guard let start = message.range(of: "L\"")?.upperBound,
              let end = message[start...].firstIndex(of: "\"") else {
            return nil
        }
        return CrossOverThreadName(rawValue: String(message[start..<end]))
    }

    private func mhypBaseRange(in message: String) -> ClosedRange<UInt64>? {
        guard message.localizedCaseInsensitiveContains("mapping PE file"),
              message.localizedCaseInsensitiveContains("MHYPBase.dll"),
              let marker = message.range(of: " at 0x", options: .caseInsensitive)?.upperBound else {
            return nil
        }

        let rangeText = message[marker...].prefix { character in
            character.isHexDigit || character == "x" || character == "X" || character == "-"
        }
        let pieces = rangeText.split(separator: "-")
        guard pieces.count == 2,
              let lower = parseHexToken(pieces[0]),
              let upper = parseHexToken(pieces[1]),
              lower <= upper else {
            return nil
        }
        return lower...upper
    }

    private func mhypBaseLoadBase(in message: String) -> UInt64? {
        guard message.localizedCaseInsensitiveContains("MHYPBase.dll") else { return nil }
        if let base = hexadecimalValue(after: " at 0x", in: message) {
            return base
        }
        return hexadecimalValue(after: " at ", in: message)
    }

    private func parseHexToken(_ token: Substring) -> UInt64? {
        var value = String(token)
        if value.lowercased().hasPrefix("0x") {
            value.removeFirst(2)
        }
        return UInt64(value, radix: 16)
    }

    private func hexadecimalValue(after marker: String, in message: String) -> UInt64? {
        guard let start = message.range(of: marker, options: .caseInsensitive)?.upperBound else {
            return nil
        }
        let token = message[start...].prefix { $0.isHexDigit }
        guard !token.isEmpty else { return nil }
        return UInt64(token, radix: 16)
    }

    private func hexadecimalPID(after marker: String, in message: String) -> Int32? {
        guard let value = hexadecimalValue(after: "\(marker) ", in: message),
              value <= UInt64(Int32.max) else {
            return nil
        }
        return Int32(exactly: value)
    }
}

public enum CrossOverTraceParserError: Error, Equatable, Sendable {
    case invalidPID
}
