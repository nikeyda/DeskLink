#if os(iOS) && !targetEnvironment(macCatalyst)
import BackgroundTasks
import os
import UIKit

@MainActor
protocol VNCFileTransferBackgroundRuntime {
    func updateProgress(_ fraction: Double?)
    func finish(success: Bool)
}

typealias VNCFileTransferBackgroundRuntimeFactory = @MainActor (
    VNCFileTransfer, @escaping @MainActor () -> Void
) -> (any VNCFileTransferBackgroundRuntime)?

/// Holds system runtime for a transfer the user already started over the live session.
@available(iOS 26.0, *)
@MainActor
final class VNCFileTransferBackgroundTask: VNCFileTransferBackgroundRuntime {
    private static let prefix = Bundle.main.bundleIdentifier.map { $0 + ".file-transfer." }
    private static let logger = Logger(subsystem: "rootshellVNC", category: "FileTransferBackground")
    private static let permittedIdentifiers = Bundle.main.object(forInfoDictionaryKey: "BGTaskSchedulerPermittedIdentifiers") as? [String]

    private let identifier: String
    private let cancelTransfer: @MainActor () -> Void
    private var task: BGContinuedProcessingTask?
    private var percent: Int64 = 0
    private var finished = false

    init?(transfer: VNCFileTransfer, cancel: @escaping @MainActor () -> Void) {
        guard UIApplication.shared.applicationState != .background, let prefix = Self.prefix,
              Self.permittedIdentifiers?.contains(prefix + "*") == true else { return nil }
        identifier = prefix + transfer.id.uuidString
        cancelTransfer = cancel

        let scheduler = BGTaskScheduler.shared
        let registered = scheduler.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
            guard let self, !finished, let task = task as? BGContinuedProcessingTask else {
                task.setTaskCompleted(success: false)
                return
            }
            receive(task)
        }
        guard registered else {
            Self.logger.notice("Background file transfer registration declined")
            return nil
        }

        let title = String(localized: "File Transfers", bundle: .module)
        let subtitle = switch transfer.direction {
        case .download: String(localized: "Downloading from the Mac", bundle: .module)
        case .upload: String(localized: "Uploading to the Mac", bundle: .module)
        }
        let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: subtitle)
        if #available(iOS 27.0, *) {
            Task.detached { [self] in
                BGTaskScheduler.shared.submitTaskRequest(request) { @Sendable error in
                    Task { @MainActor in
                        if let error { self.submissionFailed(error) }
                        else if self.finished { BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: self.identifier) }
                    }
                }
            }
        } else {
            do { try scheduler.submit(request) }
            catch {
                submissionFailed(error)
                return nil
            }
        }
    }

    func updateProgress(_ fraction: Double?) {
        guard !finished, let fraction else { return }
        // Leave the last percent for the Mac's confirmation or publishing to Files.
        let next = min(99, Int64(fraction * 100))
        guard next > percent else { return }
        percent = next
        task?.progress.completedUnitCount = percent
    }

    func finish(success: Bool) {
        guard !finished else { return }
        finished = true
        if let task {
            self.task = nil
            task.expirationHandler = nil
            if success { task.progress.completedUnitCount = task.progress.totalUnitCount }
            task.setTaskCompleted(success: success)
            let backgrounded = UIApplication.shared.applicationState == .background
            Self.logger.info("Continued transfer finished: success=\(success, privacy: .public) background=\(backgrounded, privacy: .public)")
        } else {
            BGTaskScheduler.shared.cancel(taskRequestWithIdentifier: identifier)
        }
    }

    private func submissionFailed(_ error: Error) {
        finished = true
        let code = (error as NSError).code
        Self.logger.notice("Background runtime unavailable (\(code, privacy: .public))")
    }

    private func receive(_ task: BGContinuedProcessingTask) {
        self.task = task
        Self.logger.info("Continued transfer started")
        task.progress.totalUnitCount = 100
        task.progress.completedUnitCount = percent
        task.expirationHandler = { @Sendable [weak self] in
            Task { @MainActor in
                guard let self, !self.finished else { return }
                self.cancelTransfer()
                self.finish(success: false)
            }
        }
    }
}
#endif
