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
(define home-specifications
  (module-ref (current-module) '%guixpc-home-package-specifications))
(define home-output-specifications
  (module-ref
   (current-module)
   '%guixpc-home-output-package-specifications))
(define home-output-names
  (module-ref (current-module) '%guixpc-home-output-package-names))
(define home-explicit
  (module-ref (current-module) '%guixpc-home-explicit-package-names))
(define home
  (module-ref (current-module) '%guixpc-home-package-names))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define system-source
  (read-file (string-append repo "/guix/systems/guixpc.scm")))
(define home-source
  (read-file (string-append repo "/guix/home/guixpc.scm")))
(define emacs-module-source
  (read-file (string-append repo "/guix/modules/sk/emacs.scm")))
(define desktop-integration-source
  (read-file
   (string-append repo "/guix/modules/sk/desktop-integration.scm")))

(assert
 (equal? recovery
         '("curl" "git" "fish" "emacs" "emacs-exwm" "bluez" "ncurses"
           "ripgrep" "vim" "xset" "xwallpaper" "picom" "xrandr"))
 "reviewed 13-package recovery floor changed")

(assert (= (length home-specifications) 92)
        "reviewed Home specification list must contain exactly 92 packages")
(assert (equal? home-output-specifications '("gtk:out" "gtk:bin"))
        "reviewed Home output specifications changed")
(assert (equal? home-output-names '("gtk"))
        "reviewed Home output package names changed")
(assert (equal? home-explicit '("emacs-racket-mode"))
        "reviewed explicit Home package names changed")
(assert (= (length home) 94)
        "reviewed Home ownership must contain exactly 94 unique package names")
(assert (= (+ (length home-specifications)
              (length home-output-specifications)
              (length home-explicit))
           95)
        "reviewed Home declaration must contain exactly 95 selections")
(assert
 (equal? home
         (append home-specifications home-output-names home-explicit))
 "Home ownership names do not match normal, output, and explicit selections")

(for-each
 (lambda (specification)
   (assert (member specification home)
           (string-append "Home ownership lost " specification)))
 '("fish-foreign-env" "emacs" "emacs-use-package" "emacs-geiser" "emacs-sly"
   "emacs-puni" "emacs-eshell-syntax-highlighting" "emacs-yasnippet"
   "emacs-package-lint" "emacs-clojure-mode" "cljfmt" "clj-kondo"
   "emacs-racket-mode" "emacs-fennel-mode"
   "guile" "sbcl" "python-lsp-server" "lua-language-server"
   "ungoogled-chromium" "ranger" "shellcheck" "dunst" "polkit-gnome"
   "maim" "xclip"
   "font-awesome" "font-google-material-design-icons"
   "papirus-icon-theme" "bibata-cursor-theme" "hicolor-icon-theme"
   "gst-plugins-base" "gst-plugins-good" "gtk"))

(for-each
 (lambda (specification)
   (assert (not (member specification home))
           (string-append "optional dialect leaked into Home: " specification)))
 '("babashka" "clojure" "clojure-tools" "clojure-lsp" "gradle"
   "leiningen" "maven" "openjdk" "racket" "racket-minimal"
   "fennel" "fnlfmt" "fennel-ls"
   "emacs-cider" "emacs-flycheck-clj-kondo"))

(assert (equal? (sk:intersection recovery home) '("emacs"))
        "Emacs must be the sole overlap in the explicit ownership lists")

(assert
 (string-contains system-source
                  "(map specification->package %guixpc-recovery-package-specifications)")
 "System declaration lacks the reviewed recovery-list wiring")
(assert
 (string-contains
  system-source
  (string-append
   "(list kitty-latest\n"
   "            (list kitty-latest \"terminfo\"))"))
 "System declaration must retain Kitty's default output and add terminfo")
(assert
 (string-contains home-source
                  "(map specification->package %guixpc-home-package-specifications)")
 "Home declaration lacks the reviewed Home-list wiring")
(assert (string-contains home-source "(sk emacs)")
        "Home declaration lacks the local Emacs package module")
(assert (string-contains home-source "(sk desktop-integration)")
        "Home declaration lacks the desktop-integration module")
(assert
 (string-contains home-source
                  "(list emacs-racket-mode/runtime-detached)")
 "Home declaration lacks the runtime-detached Racket Mode object")
(assert
 (string-contains
  home-source
 (string-append
   "(append\n"
   "   (map specification->package %guixpc-home-package-specifications)\n"
   "   (specifications->packages\n"
   "    %guixpc-home-output-package-specifications)\n"
   "   %guixpc-home-explicit-packages)"))
 "Home declaration does not append its explicit package objects")

(assert
 (string-contains emacs-module-source
                  "(package/inherit emacs-racket-mode")
 "Racket Mode variant no longer inherits the pinned Guix package")
(assert
 (string-contains emacs-module-source
                  "(add-after 'configure 'restore-unqualified-racket-program")
 "Racket Mode variant no longer restores the command after configuration")
(assert
 (string-contains emacs-module-source
                  "(\"racket-program\" \"racket\")")
 "Racket Mode variant no longer restores the unqualified runtime command")
(assert (not (string-contains emacs-module-source "/gnu/store/"))
        "Racket Mode variant embeds a literal store path")

(for-each
 (lambda (text)
   (assert (string-contains desktop-integration-source text)
           (string-append "desktop integration lost: " text)))
 '("home-xdg-mime-applications-service-type"
   "emacsclient.desktop"
   "emacsclient-mail.desktop"
   "chromium.desktop"
   "home-x11-service-type"
   "polkit-gnome-authentication-agent-1"
   "(requirement '(dbus x11-display))"))

(for-each
 (lambda (specification)
   (assert
    (not (string-contains system-source
                          (string-append "\"" specification "\"")))
    (string-append "non-System package leaked into System source: "
                   specification)))
 '("ungoogled-chromium" "ranger" "emacs-use-package" "emacs-geiser"
   "dunst" "polkit-gnome" "maim" "xclip"
   "emacs-sly" "emacs-puni" "emacs-eshell-syntax-highlighting"
   "emacs-package-lint" "emacs-clojure-mode" "cljfmt" "clj-kondo"
   "emacs-fennel-mode"
   "sbcl" "python-lsp-server" "lua-language-server"
   "gcc-toolchain" "gdb" "shellcheck" "babashka" "clojure"
   "clojure-tools" "clojure-lsp" "gradle" "leiningen" "maven"
   "openjdk" "racket" "racket-minimal" "emacs-racket-mode"
   "fennel" "fnlfmt" "fennel-ls"))

(format #t
        "guix-package-ownership-check: PASS (recovery=~a home=~a explicit=~a)~%"
        (length recovery) (length home) (length home-explicit))
