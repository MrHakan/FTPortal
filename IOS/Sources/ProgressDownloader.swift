import Foundation

private final class ProgressDownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destination: URL
    let transferId: String
    var continuation: CheckedContinuation<HTTPURLResponse, Error>?
    var session: URLSession?
    var task: URLSessionDownloadTask?
    private var moveError: Error?
    private var moved = false

    init(destination: URL, transferId: String) {
        self.destination = destination
        self.transferId = transferId
    }

    func cancel() {
        task?.cancel()
        session?.invalidateAndCancel()
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didWriteData bytesWritten: Int64, totalBytesWritten: Int64, totalBytesExpectedToWrite: Int64) {
        TransferCenter.shared.update(id: transferId, bytes: totalBytesWritten)
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask, didFinishDownloadingTo location: URL) {
        do {
            try? FileManager.default.removeItem(at: destination)
            try FileManager.default.moveItem(at: location, to: destination)
            moved = true
        } catch {
            moveError = error
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        defer {
            self.session?.finishTasksAndInvalidate()
            self.session = nil
            continuation = nil
        }
        if let error {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: error)
            return
        }
        if let moveError {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: moveError)
            return
        }
        guard moved, let response = task.response as? HTTPURLResponse else {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: NSError(domain: "FTPortal.Download", code: 1, userInfo: [NSLocalizedDescriptionKey: "Transfer ended without a valid response."]))
            return
        }
        guard (200..<300).contains(response.statusCode) else {
            try? FileManager.default.removeItem(at: destination)
            continuation?.resume(throwing: NSError(domain: "FTPortal.Download", code: response.statusCode, userInfo: [NSLocalizedDescriptionKey: "Peer returned HTTP \(response.statusCode)."]))
            return
        }
        continuation?.resume(returning: response)
    }
}

enum ProgressDownloader {
    static func download(request: URLRequest, to destination: URL, transferId: String) async throws -> HTTPURLResponse {
        let delegate = ProgressDownloadDelegate(destination: destination, transferId: transferId)
        return try await withTaskCancellationHandler(operation: {
            try await withCheckedThrowingContinuation { continuation in
                delegate.continuation = continuation
                let configuration = URLSessionConfiguration.ephemeral
                configuration.timeoutIntervalForRequest = 60
                configuration.timeoutIntervalForResource = 3600
                let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
                delegate.session = session
                let task = session.downloadTask(with: request)
                delegate.task = task
                task.resume()
            }
        }, onCancel: {
            delegate.cancel()
        })
    }
}
