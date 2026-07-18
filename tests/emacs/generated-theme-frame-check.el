;;; generated-theme-frame-check.el --- Generated frame-font behavior -*- lexical-binding: t; -*-

;;; Commentary:

;; Run after a rendered generated-theme adapter.  Five fake graphical frames
;; model the initial frame plus EXWM's four additional workspace frames.

;;; Code:

(require 'cl-lib)

(unless (fboundp 'sk/theme-setup-symbol-fonts)
  (error "generated theme lacks its symbol-font frame helper"))

(let ((frames '(sk/check-frame-1
                sk/check-frame-2
                sk/check-frame-3
                sk/check-frame-4
                sk/check-frame-5))
      (markers nil)
      (fontset-calls nil))
  (cl-letf (((symbol-function 'frame-live-p)
             (lambda (frame)
               (memq frame frames)))
            ((symbol-function 'display-graphic-p)
             (lambda (&optional frame)
               (memq frame frames)))
            ((symbol-function 'frame-parameter)
             (lambda (frame parameter)
               (cdr (assoc (cons frame parameter) markers #'equal))))
            ((symbol-function 'set-frame-parameter)
             (lambda (frame parameter value)
               (push (cons (cons frame parameter) value) markers)
               value))
            ((symbol-function 'find-font)
             (lambda (_font-spec &optional frame)
               (and (memq frame frames) t)))
            ((symbol-function 'set-fontset-font)
             (lambda (fontset target font-spec &optional frame add)
               (push (list fontset target font-spec frame add)
                     fontset-calls))))
    (dolist (frame frames)
      (sk/theme-setup-symbol-fonts frame))
    (let ((first-call-count (length fontset-calls)))
      (unless (> first-call-count 0)
        (error "symbol-font helper made no frame-specific calls"))
      (dolist (call fontset-calls)
        (unless (and (null (nth 0 call))
                     (eq (nth 1 call) 'symbol)
                     (memq (nth 3 call) frames)
                     (eq (nth 4 call) 'append))
          (error "invalid frame-specific fontset call: %S" call)))
      (dolist (frame frames)
        (unless (and (cdr
                      (assoc
                       (cons frame 'sk-theme-symbol-fonts-configured)
                       markers
                       #'equal))
                     (cl-find frame fontset-calls
                              :key (lambda (call) (nth 3 call))
                              :test #'eq))
          (error "symbol-font helper did not configure %S" frame)))
      (dolist (frame frames)
        (sk/theme-setup-symbol-fonts frame))
      (unless (= first-call-count (length fontset-calls))
        (error "symbol-font helper is not idempotent")))))

(provide 'generated-theme-frame-check)

;;; generated-theme-frame-check.el ends here
