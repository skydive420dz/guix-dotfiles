;; Package ownership shared by the guixpc System and Home declarations.
;;
;; Home generation 37 accepted the 77-package user/editor base.  The
;; structural-editing slice added Puni and Eshell syntax highlighting as
;; packages 76 and 77 after generation 36's 75-package baseline.  The
;; System list guarantees a tty shell, Kitty, and `emacs -Q'; normal configured
;; EXWM still consumes the accepted base Home services and editor profile.
;; Optional dialect environments live in guix/manifests and must not be added
;; to either list merely for convenience.  Emacs is the sole overlap between
;; the explicit lists below.  The realized profiles also deliberately overlap
;; on Fish (Home's Fish service) and Guile (System's %base-packages).

(define %guixpc-recovery-package-specifications
  '("curl"
    "git"
    "fish"
    "emacs"
    "emacs-exwm"
    "bluez"
    "ncurses"
    "ripgrep"
    "vim"
    "xset"
    "xwallpaper"
    "picom"
    "xrandr"))

(define %guixpc-home-desktop-package-specifications
  '("fish-foreign-env"
    "fastfetch-minimal"
    "btop"
    "fzf"
    "blueman"
    "bzmenu"
    "pipemixer"
    "pamixer"
    "ranger"
    "ungoogled-chromium"
    "xdg-utils"
    "file"
    "bat"
    "chafa"
    "mediainfo"
    "ffmpegthumbnailer"
    "poppler"
    "atool"
    "unzip"
    "odt2txt"
    "font-iosevka-term"
    "font-nerd-symbols"
    "font-google-noto-emoji"
    "font-nerd-jetbrains-mono"))

(define %guixpc-home-emacs-package-specifications
  '("emacs"
    "emacs-desktop-environment"
    "emacs-rainbow-delimiters"
    "emacs-visual-fill-column"
    "emacs-lsp-mode"
    "emacs-company"
    "emacs-flycheck"
    "emacs-lsp-ui"
    "emacs-lsp-ivy"
    "emacs-vterm"
    "emacs-eshell-syntax-highlighting"
    "emacs-lsp-treemacs"
    "emacs-yasnippet"
    "emacs-puni"
    "emacs-geiser"
    "emacs-geiser-guile"
    "emacs-sly"
    "emacs-lua-mode"
    "emacs-json-mode"
    "emacs-org"
    "emacs-org-bullets"
    "emacs-evil"
    "emacs-projectile"
    "emacs-counsel-projectile"
    "emacs-evil-collection"
    "emacs-magit"
    "emacs-helpful"
    "emacs-general"
    "emacs-use-package"
    "emacs-which-key"
    "emacs-ivy-rich"
    "emacs-counsel"
    "emacs-diminish"
    "emacs-ivy"
    "emacs-doom-modeline"
    "emacs-all-the-icons"
    "emacs-all-the-icons-dired"
    "emacs-all-the-icons-ibuffer"))

(define %guixpc-home-development-package-specifications
  '("jq"
    "guile"
    "sbcl"
    "lua"
    "lua-language-server"
    "python"
    "python-lsp-server"
    "ruff"
    "shellcheck"
    "shfmt"
    "clang"
    "gcc-toolchain"
    "make"
    "gdb"
    "pkg-config"))

(define %guixpc-home-package-specifications
  (append %guixpc-home-desktop-package-specifications
          %guixpc-home-emacs-package-specifications
          %guixpc-home-development-package-specifications))

(define (sk:duplicates items)
  (let loop ((remaining items) (seen '()) (duplicates '()))
    (if (null? remaining)
        (reverse duplicates)
        (let ((item (car remaining)))
          (loop (cdr remaining)
                (cons item seen)
                (if (and (member item seen)
                         (not (member item duplicates)))
                    (cons item duplicates)
                    duplicates))))))

(define (sk:intersection left right)
  (let loop ((remaining left) (matches '()))
    (if (null? remaining)
        (reverse matches)
        (loop (cdr remaining)
              (if (member (car remaining) right)
                  (cons (car remaining) matches)
                  matches)))))

(let ((recovery-duplicates
       (sk:duplicates %guixpc-recovery-package-specifications))
      (home-duplicates
       (sk:duplicates %guixpc-home-package-specifications))
      (overlap
       (sk:intersection %guixpc-recovery-package-specifications
                        %guixpc-home-package-specifications)))
  (unless (null? recovery-duplicates)
    (error "duplicate guixpc recovery package specifications"
           recovery-duplicates))
  (unless (null? home-duplicates)
    (error "duplicate guixpc Home package specifications" home-duplicates))
  ;; The normal session selects Home Emacs through PATH and its coherent
  ;; site-lisp profile.  System deliberately retains the same Emacs package as
  ;; a tty/EXWM recovery executable, so this is the sole approved overlap in
  ;; these two explicit specification lists.  The full build gate separately
  ;; checks the expected implicit Fish and Guile profile overlap.
  (unless (equal? overlap '("emacs"))
    (error "unexpected guixpc System/Home package ownership overlap" overlap)))
