import SwiftUI
import UIKit
import UniformTypeIdentifiers

// Wraps UIDocumentPickerViewController directly. asCopy is false so iOS does not pre-copy the
// whole selection; the app copies files one at a time itself.
struct DocumentPicker: UIViewControllerRepresentable {
    var folder: Bool
    var multiple: Bool = true
    var onPick: ([URL]) -> Void
    var onDone: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick, onDone: onDone) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let types: [UTType] = folder ? [.folder] : [.item]
        let vc = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        vc.allowsMultipleSelection = multiple
        vc.delegate = context.coordinator
        return vc
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onPick: ([URL]) -> Void
        let onDone: () -> Void
        init(onPick: @escaping ([URL]) -> Void, onDone: @escaping () -> Void) {
            self.onPick = onPick
            self.onDone = onDone
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            onPick(urls)
            onDone()
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            onDone()
        }
    }
}
