;;; Racket editor packages whose runtime ownership differs from upstream Guix.

(define-module (sk emacs)
  #:use-module (gnu packages)
  #:use-module (gnu packages emacs)
  #:use-module (gnu packages emacs-xyz)
  #:use-module (guix build-system)
  #:use-module (guix build-system emacs)
  #:use-module (guix gexp)
  #:use-module (guix packages)
  #:use-module (guix utils)
  #:use-module (ice-9 match)
  #:export (emacs/graft-safe
            emacs-racket-mode/runtime-detached
            sk:package-for-specification))

;; Emacs 31 source-loads package files to discover autoload macros.  Restrict
;; that choice to the target file, and keep relative load names from adding
;; nil to `load-path'.  Rebinding `load-suffixes' also forces dependencies to
;; source Guix's compressed jka-compr recursively.
(define (emacs-with-scoped-loaddefs-source package)
  (package/inherit package
    (arguments
     (substitute-keyword-arguments
         (package-arguments package)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'scope-loaddefs-source-loading
              (lambda _
                (substitute* "lisp/emacs-lisp/loaddefs-gen.el"
                  (("[(]cons [(]file-name-directory file[)] load-path[)]")
                   (string-append
                    "(cons (or (file-name-directory file) default-directory) "
                    "load-path)"))
                  (("[(]let [(][(]load-suffixes '[(]\"[.]el\"[)][)][)]")
                   "(progn")
                  (("[(]load file[)]")
                   "(load (concat file \".el\") nil nil t)"))))))))))

(define emacs-next-minimal/loaddefs-safe
  (emacs-with-scoped-loaddefs-source emacs-next-minimal))

(define emacs-next/loaddefs-safe
  (emacs-with-scoped-loaddefs-source emacs-next))

;; A graft can rewrite Emacs's wrapper and native-lisp tree while its portable
;; dump retains the ungrafted executable directory.  Preserve the normal
;; invocation name, but pass its full graftable path so the dump finds the
;; matching native-lisp tree.
(define-public emacs/graft-safe
  (package/inherit emacs-next/loaddefs-safe
    (name "emacs")
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-next/loaddefs-safe)
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

;; The pinned Evil predates Emacs 31's removal of the private buffer list
;; created by `define-globalized-minor-mode'.  Initialize Evil's guard, and
;; keep zero-length match markers advancing with inserted replacement text.
(define emacs-evil/emacs31-safe-source
  (package/inherit emacs-evil
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-evil)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'initialize-evil-mode-buffers
              (lambda _
                (substitute* "evil-core.el"
                  (("[(]defvar evil-mode-buffers[)]")
                   "(defvar evil-mode-buffers nil)"))
                (substitute* "evil-commands.el"
                  (("[(]setq zero-length-match [(]= match-beg match-end[)][)]")
                   (string-append
                    "(setq zero-length-match (= match-beg match-end))\n"
                    "                  (when zero-length-match\n"
                    "                    (set-marker-insertion-type match-end t))")))))))))))

;; Interactive Emacs ignores SIGPIPE, but Guix builders restore its default
;; action.  Match the runtime policy so Flycheck's truncated-stdin specs can
;; exercise EPIPE handling without terminating batch Emacs.
(define emacs-flycheck/emacs31-safe-source
  (package/inherit emacs-flycheck
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-flycheck)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-before 'check 'ignore-sigpipe-like-interactive-emacs
              (lambda _
                (sigaction SIGPIPE SIG_IGN)))))))))

;; Org's current Imenu tree includes both a branch and an explicit marker leaf
;; for parent headlines.  Once Treemacs normalizes both to the same tag path,
;; retain only one copy; older Org trees remain unchanged.
(define emacs-treemacs/emacs31-safe-source
  (package/inherit emacs-treemacs
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-treemacs)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'deduplicate-org-parent-tags
              (lambda _
                (substitute* "src/elisp/treemacs-tag-follow-mode.el"
                  (("[(]sort flat-index compare-func[)]")
                   (string-append
                    "(sort (if org? (delete-dups flat-index) flat-index) "
                    "compare-func)")))))))))))

;; SLY ships its autoload declarations without a lexical-binding cookie.
;; Declare its existing dynamic dialect so Emacs 31 does not warn.
(define emacs-sly/emacs31-safe-source
  (package/inherit emacs-sly
    (arguments
     (substitute-keyword-arguments
         (package-arguments emacs-sly)
       ((#:phases phases)
        #~(modify-phases #$phases
            (add-after 'unpack 'declare-autoload-lexical-binding
              (lambda _
                (substitute* "sly-autoloads.el"
                  (("-\\*- no-byte-compile: t -\\*-")
                   "-*- no-byte-compile: t; lexical-binding: nil -*-"))))))))))

;; Emacs Lisp bytecode is not forward-compatible across every Emacs macro
;; change.  Rewrite both explicit and implicit compiler inputs so the complete
;; package closure is built by the same Emacs major as the runtime.
(define %emacs-next-compiler-replacements
  `((,emacs-minimal . ,emacs-next-minimal/loaddefs-safe)
    (,emacs-no-x . ,emacs/graft-safe)
    (,emacs . ,emacs/graft-safe)))

(define %emacs-next-compiler-input-rewriting
  (package-input-rewriting
   %emacs-next-compiler-replacements
   #:deep? #t))

(define emacs-evil/emacs31-safe
  (%emacs-next-compiler-input-rewriting emacs-evil/emacs31-safe-source))

(define emacs-flycheck/emacs31-safe
  (%emacs-next-compiler-input-rewriting emacs-flycheck/emacs31-safe-source))

(define emacs-treemacs/emacs31-safe
  (%emacs-next-compiler-input-rewriting emacs-treemacs/emacs31-safe-source))

(define emacs-sly/emacs31-safe
  (%emacs-next-compiler-input-rewriting emacs-sly/emacs31-safe-source))

(define %emacs-next-package-input-rewriting
  (package-input-rewriting
   `((,emacs-evil . ,emacs-evil/emacs31-safe)
     (,emacs-flycheck . ,emacs-flycheck/emacs31-safe)
     (,emacs-treemacs . ,emacs-treemacs/emacs31-safe)
     (,emacs-sly . ,emacs-sly/emacs31-safe)
     ,@%emacs-next-compiler-replacements)
   #:deep? #t))

(define (package-with-emacs-next package)
  (let* ((package (%emacs-next-package-input-rewriting package))
         (version (package-version emacs/graft-safe))
         (source (package-source emacs/graft-safe)))
    (for-each
     (lambda (dependency)
       (when (eq? (build-system-name (package-build-system dependency))
                  'emacs)
         (match (assoc "emacs"
                       (bag-build-inputs (package->bag dependency)))
           ((_ (? package? compiler) . _)
            (unless (and (string=? (package-version compiler) version)
                         (equal? (package-source compiler) source))
              (error "Emacs compiler/runtime provenance mismatch"
                     (package-name dependency)
                     (package-name compiler)
                     (package-version compiler)
                     version)))
           (_
            (error "Emacs package lacks a compiler input"
                   (package-name dependency))))))
     (package-closure (list package)))
    package))

(define-public (sk:package-for-specification specification)
  (let ((package
         (if (string=? specification "emacs")
             emacs/graft-safe
             (specification->package specification))))
    (if (eq? (build-system-name (package-build-system package)) 'emacs)
        (package-with-emacs-next package)
        package)))

;; Guix's emacs-racket-mode package replaces the upstream "racket" default
;; with the absolute store path of its native Racket input.  That is useful for
;; a standalone package, but it would retain the complete Racket distribution
;; in Guix Home and let editor processes bypass the project manifest.  Keep the
;; native input for the upstream test suite, then restore the relocatable
;; command before the Emacs build compiles and installs racket-custom.el.
(define-public emacs-racket-mode/runtime-detached
  (package-with-emacs-next
   (package/inherit emacs-racket-mode
     (arguments
      (substitute-keyword-arguments
          (package-arguments emacs-racket-mode)
        ((#:phases phases)
         #~(modify-phases #$phases
             (add-before 'check 'allow-racket-integration-test-time
               (lambda _
                 (emacs-substitute-variables "test/racket-tests.el"
                   ("racket-tests/timeout" 60))))
             (add-after 'configure 'restore-unqualified-racket-program
               (lambda _
                 (emacs-substitute-variables "racket-custom.el"
                   ("racket-program" "racket")))))))))))
