import Foundation

public enum WorkflowJournalEventKind: String, Codable, Equatable, Sendable {
    case runStarted
    case stateChanged
    case stepPreparing
    case stepPrepared
    case stepStarted
    case stepSucceeded
    case stepFailed
    case compensationStarted
    case compensationSucceeded
    case compensationFailed
    case runFinished
}

/// Journal entries are intentionally self-contained and Codable so a durable
/// implementation can append them without exposing root-owned snapshots.
public struct WorkflowJournalEvent: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let sequence: UInt64
    public let runID: WorkflowRunID
    public let workflowID: WorkflowID
    public let kind: WorkflowJournalEventKind
    public let status: WorkflowRunStatus
    public let stepID: WorkflowStepID?
    public let recoveryHandle: WorkflowRecoveryHandle?
    public let errorDescription: String?
    public let timestamp: Date

    public init(
        id: UUID = UUID(),
        sequence: UInt64 = 0,
        runID: WorkflowRunID,
        workflowID: WorkflowID,
        kind: WorkflowJournalEventKind,
        status: WorkflowRunStatus,
        stepID: WorkflowStepID? = nil,
        recoveryHandle: WorkflowRecoveryHandle? = nil,
        errorDescription: String? = nil,
        timestamp: Date = Date()
    ) {
        self.id = id
        self.sequence = sequence
        self.runID = runID
        self.workflowID = workflowID
        self.kind = kind
        self.status = status
        self.stepID = stepID
        self.recoveryHandle = recoveryHandle
        self.errorDescription = errorDescription
        self.timestamp = timestamp
    }

    fileprivate func assigning(sequence: UInt64) -> WorkflowJournalEvent {
        WorkflowJournalEvent(
            id: id,
            sequence: sequence,
            runID: runID,
            workflowID: workflowID,
            kind: kind,
            status: status,
            stepID: stepID,
            recoveryHandle: recoveryHandle,
            errorDescription: errorDescription,
            timestamp: timestamp
        )
    }
}

public enum WorkflowJournalError: Error, LocalizedError, Equatable, Sendable {
    case unavailable(String)
    case corrupted(String)

    public var errorDescription: String? {
        switch self {
        case .unavailable(let message):
            return "Workflow journal unavailable: \(message)"
        case .corrupted(let message):
            return "Workflow journal is corrupted: \(message)"
        }
    }
}

/// A durable implementation can persist each Codable event and reconstruct
/// active runs from the last event.  The engine never assumes a concrete file,
/// database, or root-owned storage implementation.
public protocol WorkflowJournal: Sendable {
    func append(_ event: WorkflowJournalEvent) async throws
    func events(for runID: WorkflowRunID) async throws -> [WorkflowJournalEvent]
    func incompleteRunIDs() async throws -> [WorkflowRunID]
}

/// Atomic, user-owned journal used by the App composition root. The complete
/// document is replaced on each step boundary; phase-one workflows are short,
/// so this favors crash consistency and simple recovery over append throughput.
public actor FileWorkflowJournal: WorkflowJournal {
    private struct Document: Codable {
        static let currentSchemaVersion = 1

        let schemaVersion: Int
        let events: [WorkflowJournalEvent]
    }

    public static let maximumFileBytes = 16 * 1_024 * 1_024

    private let url: URL
    private let fileManager: FileManager
    private var eventsByRun: [WorkflowRunID: [WorkflowJournalEvent]] = [:]
    private var allStoredEvents: [WorkflowJournalEvent] = []
    private var nextSequence: UInt64 = 1

    public init(url: URL, fileManager: FileManager = .default) throws {
        self.url = url.standardizedFileURL
        self.fileManager = fileManager

        guard fileManager.fileExists(atPath: self.url.path) else { return }
        let attributes = try fileManager.attributesOfItem(atPath: self.url.path)
        if let size = attributes[.size] as? NSNumber,
           size.intValue > Self.maximumFileBytes {
            throw WorkflowJournalError.corrupted("file exceeds the size limit")
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: Data(contentsOf: self.url))
        } catch {
            throw WorkflowJournalError.corrupted(error.localizedDescription)
        }
        guard document.schemaVersion == Document.currentSchemaVersion else {
            throw WorkflowJournalError.corrupted("unsupported schema version")
        }

        var previousSequence: UInt64 = 0
        var identifiers = Set<UUID>()
        for event in document.events {
            guard event.sequence > previousSequence,
                  identifiers.insert(event.id).inserted else {
                throw WorkflowJournalError.corrupted("event ordering or identity is invalid")
            }
            previousSequence = event.sequence
            eventsByRun[event.runID, default: []].append(event)
        }
        allStoredEvents = document.events
        nextSequence = previousSequence == UInt64.max ? UInt64.max : previousSequence + 1
    }

    public func append(_ event: WorkflowJournalEvent) throws {
        guard nextSequence < UInt64.max else {
            throw WorkflowJournalError.unavailable("sequence space exhausted")
        }
        let stored = event.assigning(sequence: nextSequence)
        let nextEvents = allStoredEvents + [stored]
        try persist(nextEvents)
        allStoredEvents = nextEvents
        eventsByRun[event.runID, default: []].append(stored)
        nextSequence += 1
    }

    public func events(for runID: WorkflowRunID) -> [WorkflowJournalEvent] {
        eventsByRun[runID, default: []]
    }

    public func incompleteRunIDs() -> [WorkflowRunID] {
        eventsByRun.compactMap { runID, events in
            guard let last = events.last else { return nil }
            return last.status.isTerminal ? nil : runID
        }.sorted { $0.uuidString < $1.uuidString }
    }

    public func allEvents() -> [WorkflowJournalEvent] {
        allStoredEvents
    }

    private func persist(_ events: [WorkflowJournalEvent]) throws {
        let document = Document(schemaVersion: Document.currentSchemaVersion, events: events)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data: Data
        do {
            data = try encoder.encode(document)
        } catch {
            throw WorkflowJournalError.unavailable(error.localizedDescription)
        }
        guard data.count <= Self.maximumFileBytes else {
            throw WorkflowJournalError.unavailable("file would exceed the size limit")
        }

        do {
            try fileManager.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true,
                attributes: [.posixPermissions: 0o700]
            )
            try data.write(to: url, options: .atomic)
            try fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        } catch {
            throw WorkflowJournalError.unavailable(error.localizedDescription)
        }
    }
}

public actor InMemoryWorkflowJournal: WorkflowJournal {
    private var eventsByRun: [WorkflowRunID: [WorkflowJournalEvent]] = [:]
    private var nextSequence: UInt64 = 1

    public init() {}

    public func append(_ event: WorkflowJournalEvent) async throws {
        let stored = event.assigning(sequence: nextSequence)
        nextSequence += 1
        eventsByRun[event.runID, default: []].append(stored)
    }

    public func events(for runID: WorkflowRunID) async throws -> [WorkflowJournalEvent] {
        eventsByRun[runID, default: []]
    }

    public func incompleteRunIDs() async throws -> [WorkflowRunID] {
        eventsByRun.compactMap { runID, events in
            guard let last = events.last else { return nil }
            return last.status.isTerminal ? nil : runID
        }.sorted { $0.uuidString < $1.uuidString }
    }

    public func allEvents() -> [WorkflowJournalEvent] {
        eventsByRun.values.flatMap { $0 }.sorted { $0.sequence < $1.sequence }
    }

    public func removeAll() {
        eventsByRun.removeAll()
        nextSequence = 1
    }
}
