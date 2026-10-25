//
//  MouseButtonCaptureTextField.swift
//  Mac Mouse Fix
//
//  Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
//

import Cocoa
import ReactiveSwift
import ReactiveCocoa

/// Capture field for the "Mouse Modifiers" section on the Scrolling tab.
///
/// Behaves like `ModCaptureTextField`, but captures a mouse button instead of keyboard modifier flags.
/// The value is the 1-based `MFMouseButtonNumber`; `0` means "not assigned" and displays as "-".
@IBDesignable class MouseButtonCaptureTextField: CoolNSTextField, BindingSource, BindingTargetProvider {

    /// BindingSource / BindingTargetProvider

    typealias Value = UInt
    typealias Error = Never

    var bindingTarget: BindingTarget<UInt> { BindingTarget(lifetime: self.reactive.lifetime) { [weak self] in self?.value = $0 } }
    var producer: SignalProducer<UInt, Never> { _signal.producer.prefix(value: value) }
    var signal: Signal<UInt, Never> { _signal }

    /// Storage

    private var _value: UInt = 0
    private let (_signal, _observer) = Signal<UInt, Never>.pipe()

    var value: UInt {
        get { _value }
        set {
            guard newValue != _value else { return }
            _value = newValue
            _observer.send(value: newValue)
            updateAppearance()
        }
    }

    /// Set by `awakeFromNib`

    private var localEventMonitor: Any? = nil

    override func awakeFromNib() {

        super.awakeFromNib()

        self.delegate = nil
        self.wantsLayer = true
        self.bezelStyle = .roundedBezel
        self.alignment = .center
        self.lineBreakMode = .byTruncatingTail
        self.focusRingType = .none
        self.isEditable = true
        self.isSelectable = true

        updateAppearance()
    }

    /// IBActions

    @IBAction func clear(_ sender: Any?) {
        self.value = 0
    }

    /// First responder

    override func coolDidBecomeFirstResponder() {

        updateAppearance()

        /// Hide the insertion point while capturing
        (self.currentEditor() as? NSTextView)?.insertionPointColor = .clear

        /// Let the helper pass clicks through while we're recording, otherwise an already-assigned
        /// button (right click by default) would be swallowed before we could see it. This also stops
        /// `ButtonInputReceiver`, so MB3+ buttons that already have an action can still be re-assigned.
        MFMessagePort.sendMessage("enableMouseModifierCapture", withPayload: nil, waitForReply: true)

        self.localEventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.rightMouseDown, .otherMouseDown, .leftMouseDown]) { [weak self] event in

            guard let self = self else { return event }

            if event.type == .leftMouseDown {

                /// Click outside the field ends capture
                if let superview = self.superview {
                    let locationInSuperview = superview.convert(event.locationInWindow, from: nil)
                    if self.hitTest(locationInSuperview) == nil {
                        self.window?.makeFirstResponder(nil)
                    }
                }
                return event
            }

            /// Right or other mouse button -> capture it
            let button = event.buttonNumber + 1
            guard button >= Int(kMFMouseButtonNumberRight.rawValue),
                  button <= Int(kMFMaxButtonNumber) else {
                return event
            }

            self.value = UInt(button)
            self.window?.makeFirstResponder(nil)

            /// Swallow the event so it doesn't reach the system (e.g. no context menu)
            return nil
        }
    }

    override func coolDidResignFirstResponder() {

        updateAppearance()

        MFMessagePort.sendMessage("disableMouseModifierCapture", withPayload: nil, waitForReply: false)

        if let monitor = self.localEventMonitor {
            NSEvent.removeMonitor(monitor)
            self.localEventMonitor = nil
        }
    }

    /// Appearance

    private func updateAppearance() {

        let string = MouseButtonCaptureTextField.string(for: _value)

        self.stringValue = string
        self.textColor = (_value == 0) ? .placeholderTextColor : .controlTextColor

        if self.isCoolFirstResponder {
            self.currentEditor()?.selectAll(nil)
        } else {
            self.currentEditor()?.selectedRange = NSRange(location: 0, length: 0)
        }
    }

    static func string(for button: UInt) -> String {

        guard button > 0 else { return "-" }

        return UIStrings.getButtonString(
            MFMouseButtonNumber(rawValue: UInt32(button)),
            context: kMFButtonStringUsageContextActionTableTriggerSubstring
        ) ?? "-"
    }
}
