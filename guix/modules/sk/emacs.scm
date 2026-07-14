;;; Racket editor packages whose runtime ownership differs from upstream Guix.

(define-module (sk emacs)
  #:use-module (gnu packages emacs-xyz)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (emacs-racket-mode/runtime-detached))

;; Guix's emacs-racket-mode package replaces the upstream "racket" default
;; with the absolute store path of its native Racket input.  That is useful for
;; a standalone package, but it would retain the complete Racket distribution
;; in Guix Home and let editor processes bypass the project manifest.  Keep the
;; native input for the upstream test suite, then restore the relocatable
;; command before the Emacs build compiles and installs racket-custom.el.
(define-public emacs-racket-mode/runtime-detached
  (package/inherit emacs-racket-mode
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-racket-mode)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'configure 'restore-unqualified-racket-program
              (lambda _
                (emacs-substitute-variables "racket-custom.el"
                  ("racket-program" "racket"))))))))))
