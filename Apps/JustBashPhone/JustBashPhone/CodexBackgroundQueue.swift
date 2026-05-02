import BackgroundTasks
import CodexCore
import Foundation

enum CodexBackgroundJobStatus: String, Codable, Sendable {
    case pending
    case submitted
    case running
    case completed
    case failed
    case cancelled
}

struct CodexBackgroundJob: Codable, Identifiable, Hashable, Sendable {
    var id: String
    var responseID: String?
    var prompt: String
    var model: String
    var status: CodexBackgroundJobStatus
    var responseStatus: String?
    var outputText: String
    var errorMessage: String?
    var createdAt: Date
    var updatedAt: Date

    var displayID: String {
        String(id.prefix(8))
    }
}

actor CodexBackgroundQueue {
    static let shared = CodexBackgroundQueue()
    static let backgroundTaskIdentifier = "com.mweinbach.JustBashPhone.codex-background"

    private var isLoaded = false
    private var jobs: [CodexBackgroundJob] = []

    func enqueue(prompt: String, model: String? = nil) async throws -> CodexBackgroundJob {
        try loadIfNeeded()
        let selectedModel = normalizedModel(model)
        var job = CodexBackgroundJob(
            id: UUID().uuidString,
            responseID: nil,
            prompt: prompt,
            model: selectedModel,
            status: .pending,
            responseStatus: nil,
            outputText: "",
            errorMessage: nil,
            createdAt: Date(),
            updatedAt: Date()
        )
        jobs.insert(job, at: 0)
        try save()

        do {
            job = try await submit(job)
            upsert(job)
            try save()
            if !job.status.isTerminal {
                CodexBackgroundScheduler.scheduleRefresh()
            }
            return job
        } catch {
            job.status = .failed
            job.errorMessage = String(describing: error)
            job.updatedAt = Date()
            upsert(job)
            try save()
            throw error
        }
    }

    func list() async throws -> [CodexBackgroundJob] {
        try loadIfNeeded()
        return jobs
    }

    func hasPendingJobs() async throws -> Bool {
        try loadIfNeeded()
        return jobs.contains { !$0.status.isTerminal }
    }

    @discardableResult
    func refreshPendingJobs() async throws -> [CodexBackgroundJob] {
        try await refreshJobs(matching: nil)
    }

    @discardableResult
    func refreshJob(idPrefix: String) async throws -> CodexBackgroundJob {
        let refreshed = try await refreshJobs(matching: idPrefix)
        guard let job = refreshed.first(where: { $0.matches(idPrefix) }) else {
            throw CodexCoreError.invalidState("No background job matches \(idPrefix)")
        }
        return job
    }

    @discardableResult
    func cancelJob(idPrefix: String) async throws -> CodexBackgroundJob {
        try loadIfNeeded()
        guard var job = jobs.first(where: { $0.matches(idPrefix) }) else {
            throw CodexCoreError.invalidState("No background job matches \(idPrefix)")
        }
        if job.status.isTerminal {
            return job
        }
        guard let responseID = job.responseID else {
            job.status = .cancelled
            job.updatedAt = Date()
            upsert(job)
            try save()
            return job
        }
        let client = try await makeResponsesClient()
        let snapshot = try await client.cancelResponse(id: responseID)
        job.apply(snapshot)
        if job.status != .cancelled {
            job.status = .cancelled
        }
        upsert(job)
        try save()
        return job
    }

    private func refreshJobs(matching idPrefix: String?) async throws -> [CodexBackgroundJob] {
        try loadIfNeeded()
        let refreshable = jobs.filter { job in
            guard idPrefix.map(job.matches) ?? true else { return false }
            return !job.status.isTerminal || idPrefix != nil
        }
        guard !refreshable.isEmpty else {
            return jobs
        }

        let client = try await makeResponsesClient()
        for var job in refreshable {
            if job.responseID == nil {
                do {
                    job = try await submit(job)
                } catch {
                    job.status = .failed
                    job.errorMessage = String(describing: error)
                    job.updatedAt = Date()
                }
                upsert(job)
                continue
            }

            do {
                let snapshot = try await client.retrieveResponse(id: job.responseID!)
                job.apply(snapshot)
            } catch {
                job.errorMessage = String(describing: error)
                job.updatedAt = Date()
            }
            upsert(job)
        }
        try save()
        if jobs.contains(where: { !$0.status.isTerminal }) {
            CodexBackgroundScheduler.scheduleRefresh()
        }
        return jobs
    }

    private func submit(_ job: CodexBackgroundJob) async throws -> CodexBackgroundJob {
        let client = try await makeResponsesClient()
        let request = ResponsesRequest(
            model: job.model,
            instructions: """
            You are Codex running as a durable background job for Just Bash on iOS.
            The app may be suspended while this response is processing. Do not assume local JustBash tools are available during the server-side background run. Produce the best text result you can, and when workspace changes are required, return shell commands, patch text, or clear next steps that can be applied when the app wakes.
            """,
            input: [ResponseInputBuilder.userMessage(job.prompt)],
            tools: [],
            stream: false,
            background: true,
            store: true,
            metadata: [
                "source": .string("just-bash-phone-background"),
                "background_job_id": .string(job.id)
            ],
            parallelToolCalls: false
        )
        var updated = job
        let snapshot = try await client.createBackgroundResponse(request)
        updated.apply(snapshot)
        return updated
    }

    private func makeResponsesClient() async throws -> OpenAIResponsesClient {
        let key = CodexPhoneSettings.loadAPIKey().trimmingCharacters(in: .whitespacesAndNewlines)
        let selection = try await CodexPhoneSettings.makeProvider(apiKeyFallback: key)
        guard let client = selection.responsesClient else {
            throw CodexCoreError.invalidState("Current Codex provider does not support Responses background jobs")
        }
        return client
    }

    private func normalizedModel(_ model: String?) -> String {
        let trimmed = model?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return trimmed.isEmpty ? CodexPhoneSettings.defaultModel : trimmed
    }

    private func upsert(_ job: CodexBackgroundJob) {
        if let index = jobs.firstIndex(where: { $0.id == job.id }) {
            jobs[index] = job
        } else {
            jobs.insert(job, at: 0)
        }
        jobs.sort { $0.createdAt > $1.createdAt }
    }

    private func loadIfNeeded() throws {
        guard !isLoaded else { return }
        let url = Self.storeURL()
        if FileManager.default.fileExists(atPath: url.path) {
            let data = try Data(contentsOf: url)
            jobs = try Self.decoder.decode([CodexBackgroundJob].self, from: data)
        }
        isLoaded = true
    }

    private func save() throws {
        let url = Self.storeURL()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try Self.encoder.encode(jobs)
        try data.write(to: url, options: [.atomic])
    }

    private static func storeURL() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        return base
            .appendingPathComponent("JustBashPhone", isDirectory: true)
            .appendingPathComponent("CodexBackgroundJobs.json")
    }

    private static var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }

    private static var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

enum CodexBackgroundScheduler {
    static func register() {
        BGTaskScheduler.shared.register(
            forTaskWithIdentifier: CodexBackgroundQueue.backgroundTaskIdentifier,
            using: nil
        ) { task in
            handle(task)
        }
    }

    static func scheduleRefresh(after interval: TimeInterval = 5 * 60) {
        let request = BGProcessingTaskRequest(identifier: CodexBackgroundQueue.backgroundTaskIdentifier)
        request.requiresNetworkConnectivity = true
        request.requiresExternalPower = false
        request.earliestBeginDate = Date(timeIntervalSinceNow: interval)
        try? BGTaskScheduler.shared.submit(request)
    }

    private static func handle(_ task: BGTask) {
        let completion = BackgroundTaskCompletion(task: task)
        let worker = Task {
            do {
                try await CodexBackgroundQueue.shared.refreshPendingJobs()
                completion.setCompleted(success: true)
            } catch {
                completion.setCompleted(success: false)
            }
        }
        task.expirationHandler = {
            worker.cancel()
        }
    }
}

private struct BackgroundTaskCompletion: @unchecked Sendable {
    let task: BGTask

    func setCompleted(success: Bool) {
        task.setTaskCompleted(success: success)
    }
}

private extension CodexBackgroundJobStatus {
    var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled:
            return true
        case .pending, .submitted, .running:
            return false
        }
    }
}

private extension CodexBackgroundJob {
    func matches(_ prefix: String) -> Bool {
        id.hasPrefix(prefix) || displayID == prefix || responseID?.hasPrefix(prefix) == true
    }

    mutating func apply(_ snapshot: OpenAIResponseSnapshot) {
        responseID = snapshot.id ?? responseID
        responseStatus = snapshot.status
        outputText = snapshot.outputText
        errorMessage = snapshot.errorMessage
        status = CodexBackgroundJobStatus(snapshotStatus: snapshot.status)
        updatedAt = Date()
    }
}

private extension CodexBackgroundJobStatus {
    init(snapshotStatus: String?) {
        switch snapshotStatus?.lowercased() {
        case "queued":
            self = .submitted
        case "in_progress":
            self = .running
        case "completed":
            self = .completed
        case "failed", "incomplete", "expired":
            self = .failed
        case "cancelled", "canceled":
            self = .cancelled
        default:
            self = .submitted
        }
    }
}
