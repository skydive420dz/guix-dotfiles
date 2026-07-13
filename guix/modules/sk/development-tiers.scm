(define-module (sk development-tiers)
  #:use-module (gnu packages)
  #:use-module (guix profiles)
  #:export (%sk-development-base-specifications
            %sk-core-lisp-specifications
            %sk-jvm-lisp-specifications
            %sk-racket-specifications
            %sk-development-tier-registry
            sk:development-manifest))

;; These are project-shell conveniences, not workstation ownership.  Keeping
;; the list small makes each dialect environment independently reviewable.
(define %sk-development-base-specifications
  '("git"
    "make"
    "pkg-config"
    "ripgrep"))

(define %sk-core-lisp-specifications
  (append %sk-development-base-specifications
          '("guile"
            "guile-readline"
            "guile-colorized"
            "sbcl")))

;; clojure-tools already embeds Clojure and wraps the pinned OpenJDK.  Adding a
;; second Clojure, JDK, or Leiningen would make runtime selection ambiguous.
(define %sk-jvm-lisp-specifications
  (append %sk-development-base-specifications
          '("clojure-tools")))

;; Full Racket supplies raco, RackUnit, documentation, and the GUI/runtime
;; closure expected by the later editor-integration slice.
(define %sk-racket-specifications
  (append %sk-development-base-specifications
          '("racket")))

(define %sk-development-tier-registry
  `((core-lisp . ,%sk-core-lisp-specifications)
    (jvm-lisp . ,%sk-jvm-lisp-specifications)
    (racket . ,%sk-racket-specifications)))

(define (sk:development-manifest tier)
  (let ((entry (assq tier %sk-development-tier-registry)))
    (unless entry
      (error "unknown development tier" tier))
    (specifications->manifest (cdr entry))))
