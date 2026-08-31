;;; Racket editor packages whose runtime ownership differs from upstream Guix.

(define-module (sk emacs)
  #:use-module (gnu packages)
  #:use-module (gnu packages emacs)
  #:use-module (gnu packages emacs-xyz)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:export (emacs/graft-safe
            emacs-racket-mode/runtime-detached
            sk:package-for-specification))

;; A graft can rewrite Emacs's wrapper and native-lisp tree while its portable
;; dump retains the ungrafted executable directory.  Preserve the normal
;; invocation name, but pass its full graftable path so the dump finds the
;; matching native-lisp tree.
(define-public emacs/graft-safe
  (package/inherit emacs-next
    (name "emacs")
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-next)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'restore-emacs-pdmp 'preserve-grafted-exec-directory
              (lambda* (#:key outputs #:allow-other-keys)
                (let ((bin (string-append (assoc-ref outputs "out") "/bin")))
                  (for-each
                   (lambda (program)
                     (substitute* program
                       (("exec -a \"\\$\\{0##\\*/\\}\"")
                        (string-append
                         "exec -a \"" bin "/${0##*/}\""))))
                   (find-files
                    bin
                    "^emacs(-[0-9]+(\\.[0-9]+)*)?$")))))))))))

(define-public (sk:package-for-specification specification)
  (if (string=? specification "emacs")
      emacs/graft-safe
      (specification->package specification)))

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
