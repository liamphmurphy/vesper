import AppKit
import VesperCore
import WebKit

/// Liquid Glass container that refreshes its hairline border when the window appearance changes.
@MainActor
private final class FindBarGlassView: NSVisualEffectView {
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        material = .popover
        blendingMode = .withinWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 10
        layer?.masksToBounds = true
        layer?.borderWidth = 0.5
        updateBorderColor()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateBorderColor()
    }

    private func updateBorderColor() {
        let resolved = effectiveAppearance
        resolved.performAsCurrentDrawingAppearance {
            self.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.35).cgColor
        }
    }
}

/// Floating top-right Liquid Glass find bar backed by `WKWebView.find(_:configuration:)`.
@MainActor
final class FindBarViewController: NSViewController, NSTextFieldDelegate {
    /// The web view or native screen to search.
    weak var target: (any FindTarget)?
    var onDismiss: (() -> Void)?

    var isVisible: Bool { isViewLoaded && !view.isHidden }
    var hasQuery: Bool { FindLogic.shouldSearch(query: queryField.stringValue) }

    private let glass = FindBarGlassView(frame: .zero)
    private let searchIcon = NSImageView()
    private let queryField = NSTextField()
    private let statusLabel = NSTextField(labelWithString: "")
    private let caseButton = NSButton()
    private let prevButton = NSButton()
    private let nextButton = NSButton()
    private let closeButton = NSButton()

    private var caseSensitive = false
    private var searchGeneration = 0
    private var debounceTask: Task<Void, Never>?

    override func loadView() {
        let shadowHost = NSView()
        shadowHost.wantsLayer = true
        shadowHost.shadow = NSShadow()
        shadowHost.layer?.shadowColor = NSColor.black.withAlphaComponent(0.24).cgColor
        shadowHost.layer?.shadowOpacity = 1
        shadowHost.layer?.shadowRadius = 14
        shadowHost.layer?.shadowOffset = NSSize(width: 0, height: -4)

        searchIcon.image = NSImage(systemSymbolName: "magnifyingglass", accessibilityDescription: nil)
        searchIcon.contentTintColor = .secondaryLabelColor
        searchIcon.setContentHuggingPriority(.required, for: .horizontal)

        queryField.isBordered = false
        queryField.drawsBackground = false
        queryField.focusRingType = .none
        queryField.usesSingleLineMode = true
        queryField.lineBreakMode = .byTruncatingHead
        queryField.font = .systemFont(ofSize: 13)
        queryField.placeholderString = "Find in page…"
        queryField.delegate = self

        statusLabel.font = .systemFont(ofSize: 11, weight: .medium)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.isHidden = true
        statusLabel.setContentHuggingPriority(.required, for: .horizontal)

        caseButton.title = "Aa"
        caseButton.setButtonType(.toggle)
        caseButton.bezelStyle = .accessoryBarAction
        caseButton.controlSize = .small
        caseButton.font = .systemFont(ofSize: 11, weight: .medium)
        caseButton.toolTip = "Match Case"
        caseButton.target = self
        caseButton.action = #selector(toggleCaseSensitive)
        caseButton.setContentHuggingPriority(.required, for: .horizontal)

        configureIconButton(prevButton, symbol: "chevron.up", description: "Previous match", tip: "Previous match (⇧⌘G)", action: #selector(findPreviousTapped))
        configureIconButton(nextButton, symbol: "chevron.down", description: "Next match", tip: "Next match (⌘G)", action: #selector(findNextTapped))
        configureIconButton(closeButton, symbol: "xmark", description: "Close find bar", tip: "Close find bar (Esc)", action: #selector(closeTapped))

        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            divider.widthAnchor.constraint(equalToConstant: 1),
            divider.heightAnchor.constraint(equalToConstant: 16),
        ])

        let stack = NSStackView(views: [searchIcon, queryField, statusLabel, caseButton, prevButton, nextButton, divider, closeButton])
        stack.orientation = .horizontal
        stack.alignment = .centerY
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 8)
        stack.translatesAutoresizingMaskIntoConstraints = false

        glass.translatesAutoresizingMaskIntoConstraints = false
        glass.addSubview(stack)
        shadowHost.addSubview(glass)

        NSLayoutConstraint.activate([
            queryField.widthAnchor.constraint(equalToConstant: 190),
            stack.leadingAnchor.constraint(equalTo: glass.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: glass.trailingAnchor),
            stack.topAnchor.constraint(equalTo: glass.topAnchor),
            stack.bottomAnchor.constraint(equalTo: glass.bottomAnchor),
            glass.leadingAnchor.constraint(equalTo: shadowHost.leadingAnchor),
            glass.trailingAnchor.constraint(equalTo: shadowHost.trailingAnchor),
            glass.topAnchor.constraint(equalTo: shadowHost.topAnchor),
            glass.bottomAnchor.constraint(equalTo: shadowHost.bottomAnchor),
        ])

        updateButtonStates()
        view = shadowHost
    }

    private func configureIconButton(_ button: NSButton, symbol: String, description: String, tip: String, action: Selector) {
        button.image = NSImage(systemSymbolName: symbol, accessibilityDescription: description)
        button.imagePosition = .imageOnly
        button.isBordered = false
        button.controlSize = .small
        button.toolTip = tip
        button.target = self
        button.action = action
        button.setContentHuggingPriority(.required, for: .horizontal)
    }

    func present(initialQuery: String? = nil) {
        _ = view
        if let initialQuery {
            queryField.stringValue = initialQuery
        }
        view.isHidden = false
        updateButtonStates()
        view.window?.makeFirstResponder(queryField)
        queryField.selectText(nil)
        if hasQuery {
            runSearch(backwards: false)
        } else {
            applyStatus(hasResult: false, matchFound: false)
        }
    }

    func findNext() {
        guard isVisible, hasQuery else {
            present()
            return
        }
        runSearch(backwards: false)
    }

    func findPrevious() {
        guard isVisible, hasQuery else {
            present()
            return
        }
        runSearch(backwards: true)
    }

    func dismiss(restoreFocus: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        searchGeneration += 1
        target?.clearFind()
        applyStatus(hasResult: false, matchFound: false)
        if isViewLoaded {
            view.isHidden = true
        }
        if restoreFocus {
            onDismiss?()
        }
    }

    func teardown() {
        debounceTask?.cancel()
        debounceTask = nil
        target = nil
    }

    // MARK: Actions & NSTextFieldDelegate

    @objc private func toggleCaseSensitive() {
        caseSensitive = caseButton.state == .on
        if hasQuery {
            runSearch(backwards: false)
        }
    }

    @objc private func findNextTapped() { findNext() }
    @objc private func findPreviousTapped() { findPrevious() }
    @objc private func closeTapped() { dismiss(restoreFocus: true) }

    func controlTextDidChange(_ obj: Notification) {
        updateButtonStates()
        debounceTask?.cancel()
        let query = queryField.stringValue
        guard FindLogic.shouldSearch(query: query) else {
            searchGeneration += 1
            target?.clearFind()
            applyStatus(hasResult: false, matchFound: false)
            return
        }
        debounceTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(80))
            guard !Task.isCancelled else { return }
            self?.runSearch(backwards: false)
        }
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        if commandSelector == #selector(NSResponder.insertNewline(_:)) {
            if NSApp.currentEvent?.modifierFlags.contains(.shift) == true {
                findPrevious()
            } else {
                findNext()
            }
            return true
        }
        if commandSelector == #selector(NSResponder.cancelOperation(_:)) {
            dismiss(restoreFocus: true)
            return true
        }
        return false
    }

    // MARK: Find

    private func runSearch(backwards: Bool) {
        debounceTask?.cancel()
        debounceTask = nil
        let query = queryField.stringValue
        guard FindLogic.shouldSearch(query: query), let target else {
            target?.clearFind()
            applyStatus(hasResult: false, matchFound: false)
            return
        }
        searchGeneration += 1
        let generation = searchGeneration
        let matchCase = caseSensitive
        Task { @MainActor [weak self, weak target] in
            guard let target else { return }
            let found = await target.find(query, backwards: backwards, caseSensitive: matchCase)
            guard let self, self.searchGeneration == generation, self.target === target, self.isVisible else { return }
            self.applyStatus(hasResult: true, matchFound: found)
        }
    }

    private func updateButtonStates() {
        let enabled = hasQuery
        prevButton.isEnabled = enabled
        nextButton.isEnabled = enabled
    }

    private func applyStatus(hasResult: Bool, matchFound: Bool) {
        if let text = FindLogic.statusText(query: queryField.stringValue, hasResult: hasResult, matchFound: matchFound) {
            statusLabel.stringValue = text
            statusLabel.textColor = .systemRed
            statusLabel.isHidden = false
        } else {
            statusLabel.stringValue = ""
            statusLabel.isHidden = true
        }
    }
}
