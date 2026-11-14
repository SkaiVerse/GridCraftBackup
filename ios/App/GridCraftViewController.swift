import UIKit
import UniformTypeIdentifiers

/// Writes a line to GridCraft-log.txt (visible in Files: On My iPad > GridCraft).
func gcLog(_ message: String) {
    guard let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first else { return }
    let url = docs.appendingPathComponent("GridCraft-log.txt")
    let line = "[swift] \(message)\n"
    if let handle = try? FileHandle(forWritingTo: url) {
        handle.seekToEndOfFile()
        handle.write(Data(line.utf8))
        try? handle.close()
    } else {
        try? line.write(to: url, atomically: true, encoding: .utf8)
    }
}

/// Owns the drawing view and everything that needs Apple's own screens: Files, alerts, printing.
final class GridCraftViewController: UIViewController, UIDocumentPickerDelegate {

    private let metal = MetalView()
    private enum Mode { case open, save, picture }
    private var mode: Mode = .open
    /// Files opened from Files, kept so Save can offer to replace the original.
    private var opened: [String: URL] = [:]

    override var prefersStatusBarHidden: Bool { true }
    override var prefersHomeIndicatorAutoHidden: Bool { true }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = UIColor(red: 0.11, green: 0.11, blue: 0.12, alpha: 1)

        metal.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(metal)
        let guide = view.safeAreaLayoutGuide
        NSLayoutConstraint.activate([
            metal.topAnchor.constraint(equalTo: guide.topAnchor),
            metal.bottomAnchor.constraint(equalTo: guide.bottomAnchor),
            metal.leadingAnchor.constraint(equalTo: guide.leadingAnchor),
            metal.trailingAnchor.constraint(equalTo: guide.trailingAnchor)
        ])

        metal.onOpenFiles = { [weak self] in self?.pick(.open) }
        metal.onPickPicture = { [weak self] in self?.pick(.picture) }
        metal.onSave = { [weak self] name, data in self?.handleSave(name: name, data: data) }
        metal.onOpenURL = { url in
            guard let u = URL(string: url), let scheme = u.scheme?.lowercased(),
                  ["http", "https", "mailto"].contains(scheme) else { return }
            UIApplication.shared.open(u)
        }
        metal.onCopyText = { UIPasteboard.general.string = $0 }
        metal.onCopyHTML = { html, text in
            UIPasteboard.general.setItems([["public.html": html, "public.utf8-plain-text": text]])
        }
        metal.onPasteText = { UIPasteboard.general.string }
        metal.onPasteHTML = {
            if let s = UIPasteboard.general.value(forPasteboardType: "public.html") as? String { return s }
            if let d = UIPasteboard.general.data(forPasteboardType: "public.html") { return String(data: d, encoding: .utf8) }
            return nil
        }
        metal.onPrint = { [weak self] data in self?.printPDF(data) }

        let nc = NotificationCenter.default
        nc.addObserver(forName: UIApplication.willResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.saveState()
            self?.metal.setFocused(false)
        }
        nc.addObserver(forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.metal.setFocused(true)
        }
    }

    // MARK: Files

    private func pick(_ m: Mode) {
        gcLog("pick requested: \(m); already presenting: \(presentedViewController != nil)")
        guard presentedViewController == nil else { return }
        mode = m
        let types: [UTType] = (m == .picture) ? [.image] : [.item]
        let picker = UIDocumentPickerViewController(forOpeningContentTypes: types, asCopy: false)
        picker.allowsMultipleSelection = (m == .open)
        picker.delegate = self
        metal.suspendFocus = true
        present(picker, animated: true) { gcLog("picker is on screen") }
    }

    func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
        gcLog("picker returned \(urls.count) item(s) in mode \(mode)")
        metal.suspendFocus = false
        switch mode {
        case .open:
            for url in urls { read(url, keepAccess: true) { name, data in self.metal.deliverOpened(name: name, data: data) } }
        case .picture:
            for url in urls { read(url, keepAccess: false) { name, data in self.metal.deliverPicture(name: name, data: data) } }
        case .save:
            if let u = urls.first { opened[u.lastPathComponent] = u }
            metal.saveResult(ok: true)
        }
    }

    func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
        gcLog("picker cancelled in mode \(mode)")
        metal.suspendFocus = false
        if mode == .save { metal.saveResult(ok: false) }
    }

    private func read(_ url: URL, keepAccess: Bool, deliver: (String, Data) -> Void) {
        let scoped = url.startAccessingSecurityScopedResource()
        gcLog("reading \(url.lastPathComponent), security scope granted: \(scoped)")
        var data: Data?
        var readError: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: url, options: [], error: &coordError) { readURL in
            do { data = try Data(contentsOf: readURL) } catch { readError = error }
        }
        if scoped && !keepAccess { url.stopAccessingSecurityScopedResource() }
        if let data = data {
            gcLog("read \(data.count) bytes from \(url.lastPathComponent)")
            if keepAccess { opened[url.lastPathComponent] = url }
            deliver(url.lastPathComponent, data)
        } else {
            let why = (readError ?? coordError)?.localizedDescription ?? "It could not be read."
            gcLog("read failed: \(why)")
            message("Couldn’t open the file", why)
        }
    }

    // MARK: Saving

    private func handleSave(name: String, data: Data) {
        gcLog("save requested: \(name), \(data.count) bytes")
        guard presentedViewController == nil else { metal.saveResult(ok: false); return }
        let safe = name.replacingOccurrences(of: "/", with: "_")
        if let original = opened[safe] {
            let alert = UIAlertController(title: "Save “\(safe)”",
                                          message: "You opened this file from Files. What would you like to do?",
                                          preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "Replace Original", style: .default) { _ in
                self.metal.suspendFocus = false
                self.overwrite(original, with: data)
            })
            alert.addAction(UIAlertAction(title: "Save as New Copy…", style: .default) { _ in
                self.export(name: safe, data: data)
            })
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in
                self.metal.suspendFocus = false
                self.metal.saveResult(ok: false)
            })
            metal.suspendFocus = true
            present(alert, animated: true)
        } else {
            export(name: safe, data: data)
        }
    }

    private func export(name: String, data: Data) {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let file = folder.appendingPathComponent(name)
            try data.write(to: file)
            mode = .save
            let picker = UIDocumentPickerViewController(forExporting: [file], asCopy: true)
            picker.delegate = self
            metal.suspendFocus = true
            present(picker, animated: true)
        } catch {
            metal.suspendFocus = false
            metal.saveResult(ok: false)
            message("Couldn’t prepare the file", error.localizedDescription)
        }
    }

    private func overwrite(_ url: URL, with data: Data) {
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        var coordError: NSError?
        var writeError: Error?
        NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &coordError) { writeURL in
            do { try data.write(to: writeURL) } catch { writeError = error }
        }
        if let e = (coordError as Error?) ?? writeError {
            metal.saveResult(ok: false)
            message("Couldn’t save", e.localizedDescription)
        } else {
            metal.saveResult(ok: true)
        }
    }

    // MARK: Printing and messages

    private func printPDF(_ data: Data) {
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.outputType = .general
        info.jobName = "GridCraft"
        controller.printInfo = info
        controller.printingItem = data
        controller.present(from: metal.bounds, in: metal, animated: true, completionHandler: nil)
    }

    private func message(_ title: String, _ text: String) {
        guard presentedViewController == nil else { return }
        let a = UIAlertController(title: title, message: text, preferredStyle: .alert)
        a.addAction(UIAlertAction(title: "OK", style: .default))
        present(a, animated: true)
    }
}
