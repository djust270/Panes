import AppKit
import ExplorerCore
import UniformTypeIdentifiers

/// Drags a remote item out as a file promise: wherever it's dropped (Finder, another app, a
/// local folder in this app), the item is downloaded there, with the usual progress window.
final class RemoteFilePromise: NSFilePromiseProvider {
    convenience init(item: FileItem, window: NSWindow?) {
        let path = RemotePath(url: item.url)
        let type: UTType = item.isFolder ? .folder : item.typeIdentifier.flatMap(UTType.init) ?? .data
        let delegate = RemoteFilePromiseDelegate(path: path, window: window)
        self.init(fileType: type.identifier, delegate: delegate)
        // The provider holds its delegate weakly; this keeps it for as long as the drag needs it.
        userInfo = delegate
    }
}

private final class RemoteFilePromiseDelegate: NSObject, NSFilePromiseProviderDelegate {
    private let path: RemotePath?
    private weak var window: NSWindow?

    init(path: RemotePath?, window: NSWindow?) {
        self.path = path
        self.window = window
    }

    func filePromiseProvider(_ filePromiseProvider: NSFilePromiseProvider, fileNameForType fileType: String) -> String {
        path?.name ?? "Untitled"
    }

    func filePromiseProvider(
        _ filePromiseProvider: NSFilePromiseProvider,
        writePromiseTo url: URL,
        completionHandler: @escaping (Error?) -> Void
    ) {
        guard let path else { return completionHandler(CocoaError(.fileNoSuchFile)) }
        let complete = UncheckedSendable(completionHandler)
        let folder = url.deletingLastPathComponent()
        let window = UncheckedSendable(window)
        Task { @MainActor in
            let result = await RemoteCenter.download([path], into: folder, from: window.value)
            if let failure = result?.failures.first {
                complete.value(RemoteTransferFailure(message: failure.message))
            } else if result == nil || result?.wasCancelled == true {
                complete.value(CocoaError(.userCancelled))
            } else {
                complete.value(nil)
            }
        }
    }
}

private struct RemoteTransferFailure: LocalizedError {
    let message: String
    var errorDescription: String? { message }
}

/// Carries a completion handler AppKit calls back on its own terms across a `Task`.
private struct UncheckedSendable<Value>: @unchecked Sendable {
    let value: Value
    init(_ value: Value) { self.value = value }
}
