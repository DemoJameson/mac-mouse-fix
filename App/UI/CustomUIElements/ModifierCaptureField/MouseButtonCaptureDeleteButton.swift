//
//  MouseButtonCaptureDeleteButton.swift
//  Mac Mouse Fix
//
//  Licensed under the MMF License (https://github.com/noah-nuebling/mac-mouse-fix/blob/master/License)
//

import Cocoa
import ReactiveSwift

/// Companion to `MouseButtonCaptureTextField`, mirrors `ModCaptureDeleteButton`.
@IBDesignable class MouseButtonCaptureDeleteButton: NSButton {

    @IBOutlet var parentTextField: MouseButtonCaptureTextField?

    override func awakeFromNib() {

        guard let parentTextField = parentTextField else { return }

        parentTextField.producer.startWithValues { button in
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.1
                context.timingFunction = .init(name: .default)
                self.animator().alphaValue = (button == 0) ? 0 : 1
            }
        }
    }

    override func mouseDown(with event: NSEvent) {
        parentTextField?.clear(self)
    }
}
