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

(for-each
 (lambda (specification)
   (assert (member specification recovery)
           (string-append "recovery floor lost " specification)))
 '("curl" "git" "fish" "emacs" "emacs-exwm" "bluez" "ncurses"
   "xset" "xrandr" "xwallpaper" "picom"))

(for-each
 (lambda (specification)
   (assert (member specification home)
           (string-append "Home ownership lost " specification)))
 '("emacs" "emacs-use-package" "emacs-geiser" "emacs-sly"
   "guile" "sbcl" "python-lsp-server" "lua-language-server"
   "ungoogled-chromium" "ranger" "shellcheck"))

(for-each
 (lambda (specification)
   (assert (not (member specification home))
           (string-append "optional dialect leaked into Home: " specification)))
 '("clojure" "clojure-tools" "leiningen" "openjdk" "racket"
   "emacs-cider" "emacs-racket-mode"))

(assert (equal? (sk:intersection recovery home) '("emacs"))
        "Emacs must be the sole deliberate System/Home package duplicate")

(format #t "guix-package-ownership-check: PASS (recovery=~a home=~a)~%"
        (length recovery) (length home))
