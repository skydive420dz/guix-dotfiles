(use-modules (ice-9 textual-ports)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 2)
  (error "expected repository path" arguments))

(define repo (canonicalize-path (cadr arguments)))
(primitive-load (string-append repo "/guix/package-ownership.scm"))

(define (assert condition message)
  (unless condition (error message)))

(define recovery
  (module-ref (current-module) '%guixpc-recovery-package-specifications))
(define home
  (module-ref (current-module) '%guixpc-home-package-specifications))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define system-source
  (read-file (string-append repo "/guix/systems/guixpc.scm")))
(define home-source
  (read-file (string-append repo "/guix/home/guixpc.scm")))

(assert
 (equal? recovery
         '("curl" "git" "fish" "emacs" "emacs-exwm" "bluez" "ncurses"
           "ripgrep" "vim" "xset" "xwallpaper" "picom" "xrandr"))
 "reviewed 13-package recovery floor changed")

(assert (= (length home) 78)
        "reviewed Home ownership list must contain exactly 78 packages")

(for-each
 (lambda (specification)
   (assert (member specification home)
           (string-append "Home ownership lost " specification)))
 '("fish-foreign-env" "emacs" "emacs-use-package" "emacs-geiser" "emacs-sly"
   "emacs-puni" "emacs-eshell-syntax-highlighting" "emacs-yasnippet"
   "emacs-package-lint"
   "guile" "sbcl" "python-lsp-server" "lua-language-server"
   "ungoogled-chromium" "ranger" "shellcheck"))

(for-each
 (lambda (specification)
   (assert (not (member specification home))
           (string-append "optional dialect leaked into Home: " specification)))
 '("clojure" "clojure-tools" "leiningen" "openjdk" "racket"
   "emacs-cider" "emacs-racket-mode"))

(assert (equal? (sk:intersection recovery home) '("emacs"))
        "Emacs must be the sole overlap in the explicit ownership lists")

(assert
 (string-contains system-source
                  "(map specification->package %guixpc-recovery-package-specifications)")
 "System declaration lacks the reviewed recovery-list wiring")
(assert
 (string-contains system-source "(list kitty-latest)")
 "System declaration lacks the Kitty recovery-floor wiring")
(assert
 (string-contains home-source
                  "(map specification->package %guixpc-home-package-specifications)")
 "Home declaration lacks the reviewed Home-list wiring")

(for-each
 (lambda (specification)
   (assert
    (not (string-contains system-source
                          (string-append "\"" specification "\"")))
    (string-append "Home-only package leaked into System source: "
                   specification)))
 '("ungoogled-chromium" "ranger" "emacs-use-package" "emacs-geiser"
   "emacs-sly" "emacs-puni" "emacs-eshell-syntax-highlighting"
   "emacs-package-lint"
   "sbcl" "python-lsp-server" "lua-language-server"
   "gcc-toolchain" "gdb" "shellcheck"))

(format #t "guix-package-ownership-check: PASS (recovery=~a home=~a)~%"
        (length recovery) (length home))
