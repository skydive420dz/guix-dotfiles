(use-modules (ice-9 format)
             (ice-9 textual-ports)
             (sk theme)
             (srfi srfi-1)
             (srfi srfi-13))

(define arguments (command-line))
(unless (= (length arguments) 3)
  (format (current-error-port)
          "usage: guile ~a REPOSITORY TEMP-DIRECTORY~%"
          (car arguments))
  (exit 64))

(define %repo (canonicalize-path (list-ref arguments 1)))
(define %temporary (canonicalize-path (list-ref arguments 2)))
(define %fixture-path
  (string-append %repo "/fixtures/theme/valid/tokens.scm"))
(define %production-path
  (string-append %repo "/theme/tokens.scm"))
(define %asset-root
  (string-append %repo "/fixtures/theme/root"))
(define %expected-root
  (string-append %repo "/fixtures/theme/expected"))
(define %production-expected-root
  (string-append %repo "/fixtures/theme/expected-production"))
(define %rendered-root
  (string-append %temporary "/rendered"))
(define %production-rendered-root
  (string-append %temporary "/rendered-production"))

(define %checks 0)
(define %failures 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition
    (set! %failures (+ %failures 1))
    (format (current-error-port) "FAIL: ~a~%" label)))

(define (check-equal actual expected label)
  (check (equal? actual expected) label))

(define (check-close actual expected tolerance label)
  (check (<= (abs (- actual expected)) tolerance) label))

(define (read-file path)
  (call-with-input-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")
      (get-string-all port))))

(define (write-file path contents)
  (call-with-output-file path
    (lambda (port)
      (set-port-encoding! port "UTF-8")
      (display contents port))))

(define (mkdir-if-missing path)
  (unless (file-exists? path)
    (mkdir path)))

(define (load-theme path)
  (call-with-input-file path sk:read-theme))

(define %theme (load-theme %fixture-path))
(define %production-theme (load-theme %production-path))

(define (error-code error)
  (assq-ref error 'code))

(define (validation-codes theme)
  (map error-code (sk:theme-validation-errors theme)))

(define (asset-error-codes theme root)
  (map error-code (sk:theme-asset-errors theme root)))

(define (has-code? theme code)
  (memq code (validation-codes theme)))

(define (alist-replace object key value)
  (map (lambda (entry)
         (if (eq? (car entry) key)
             (cons key value)
             entry))
       object))

(define (alist-delete object key)
  (filter (lambda (entry) (not (eq? (car entry) key))) object))

(define (mutate-group theme key procedure)
  (alist-replace theme key (procedure (assq-ref theme key))))

(define (mutate-nested theme outer inner procedure)
  (mutate-group
   theme outer
   (lambda (object)
     (alist-replace object inner
                    (procedure (assq-ref object inner))))))

(define (style foreground background attributes)
  `((foreground . ,foreground)
    (background . ,background)
    (attributes . ,attributes)))

(define (alist-object? value)
  (and (list? value)
       (every (lambda (entry)
                (and (pair? entry) (symbol? (car entry))))
              value)))

(define (permute-objects value)
  (cond
   ((alist-object? value)
    (reverse
     (map (lambda (entry)
            (cons (car entry) (permute-objects (cdr entry))))
          value)))
   ((list? value) (map permute-objects value))
   (else value)))

(define (throws-theme-error? thunk)
  (catch %sk-theme-error-key
    (lambda () (thunk) #f)
    (lambda _ #t)))

(define (count-substring text needle)
  (let loop ((start 0) (count 0))
    (let ((index (string-contains text needle start)))
      (if index
          (loop (+ index (string-length needle)) (+ count 1))
          count))))

(define (exactly-one-trailing-newline? text)
  (let ((length (string-length text)))
    (and (> length 1)
         (char=? (string-ref text (- length 1)) #\newline)
         (not (char=? (string-ref text (- length 2)) #\newline)))))

(define (line-count text expected)
  (count (lambda (line) (string=? line expected))
         (string-split text #\newline)))

(define (line-prefix-count text prefix)
  (count (lambda (line) (string-prefix? prefix line))
         (string-split text #\newline)))

(define (theme-role theme key)
  (assq-ref (assq-ref theme 'roles) key))

(define (fixture-role key)
  (theme-role %theme key))

(define (production-role key)
  (theme-role %production-theme key))

(define (fixture-role-without-hash key)
  (substring (fixture-role key) 1))

(define (production-role-without-hash key)
  (substring (production-role key) 1))

(define (gtk-settings-entries text)
  ;; This is an intentionally small structural parser for the generated
  ;; GKeyFile subset.  Native GTK property/runtime verification belongs to
  ;; P3.3/P3.4, when a candidate profile and real display are in scope.
  (let loop ((lines (string-split text #\newline))
             (sections 0)
             (entries '())
             (valid? #t))
    (if (null? lines)
        (and valid? (= sections 1) (reverse entries))
        (let ((line (car lines)))
          (cond
           ((or (string-null? line)
                (string-prefix? "#" line))
            (loop (cdr lines) sections entries valid?))
           ((string=? line "[Settings]")
            (loop (cdr lines) (+ sections 1) entries valid?))
           (else
            (let ((separator (string-index line #\=)))
              (if (and (= sections 1)
                       separator
                       (> separator 0)
                       (< separator (- (string-length line) 1))
                       (not (string-index line #\= (+ separator 1))))
                  (loop
                   (cdr lines)
                   sections
                   (cons (cons (substring line 0 separator)
                               (substring line (+ separator 1)))
                         entries)
                   valid?)
                  (loop (cdr lines) sections entries #f)))))))))

(define %expected-paths
  '((emacs . "emacs.el")
    (kitty . "kitty.conf")
    (fish . "fish.fish")
    (gtk3 . "gtk3.ini")
    (gtk4 . "gtk4.ini")
    (dunst . "dunstrc")
    (x-session . "x-session.sh")))

(define %expected-production-provenance
  '((palette-authority . frozen-modus-subset)
    (theme . modus-vivendi-tinted)
    (palette-source
     . "GNU Emacs 30.2 etc/themes/modus-vivendi-tinted-theme.el")
    (modus-version . "4.4.0")
    (theme-source-sha256
     . "4ecca25fc420989fc8520a3717135a60c068f9bc1e575f4a42e1fe5826f0e3dd")
    (core-source-sha256
     . "26dc9f44271008ce27c63a97b21835b0ebe1a374660f0ac96b5f931ece23b97a")
    (guix-revision . "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
    (emacs-version . "30.2")
    (mapping-version . 1)))

(define %expected-production-roles
  '((canvas . "#0d0e1c")
    (surface . "#1d2235")
    (surface-raised . "#4a4f69")
    (text . "#ffffff")
    (text-muted . "#c6daff")
    (text-disabled . "#989898")
    (accent . "#2fafff")
    (on-accent . "#0d0e1c")
    (selection . "#555a66")
    (on-selection . "#ffffff")
    (focus . "#79a8ff")
    (success . "#6ae4b9")
    (warning . "#fec43f")
    (error . "#ff5f59")
    (border . "#61647a")
    (shadow . "#000000")
    (cursor . "#ff66ff")
    (on-cursor . "#0d0e1c")))

(define %expected-production-ansi
  '((black . "#000000")
    (red . "#ff5f59")
    (green . "#44bc44")
    (yellow . "#d0bc00")
    (blue . "#2fafff")
    (magenta . "#feacd0")
    (cyan . "#00d3d0")
    (white . "#a6a6a6")
    (bright-black . "#595959")
    (bright-red . "#ff6b55")
    (bright-green . "#00c06f")
    (bright-yellow . "#fec43f")
    (bright-blue . "#79a8ff")
    (bright-magenta . "#b6a0ff")
    (bright-cyan . "#6ae4b9")
    (bright-white . "#ffffff")))

(define %expected-production-typography
  '((fixed-family . "JetBrainsMono Nerd Font Mono")
    (ui-family . "JetBrainsMono Nerd Font")
    (ui-size-pt . 11)
    (fallback-families
     "Symbols Nerd Font Mono"
     "Noto Color Emoji"
     "Font Awesome"
     "Material Icons")))

(define %expected-production-desktop
  '((color-scheme . dark)
    (gtk3-theme . "Adwaita")
    (gtk4-theme . "Adwaita")
    (icon-theme . "Papirus-Dark")
    (cursor-theme . "Bibata-Modern-Ice")
    (cursor-size-px . 32)
    (logical-dpi . 96)
    (integer-scale . 1)
    (scale-ownership . inherit-verified)
    (gtk4-test-application . "gtk4-widget-factory")))

(define %expected-production-calibrations
  '((emacs-face-height-tenths-pt . 120)
    (kitty-font-size-pt . 14.0)
    (picom-emacs-opacity-percent . 85)
    (kitty-background-opacity-ratio . 0.0)
    (kitty-cursor-trail-role . focus)))

(define %expected-production-assets
  '((wallpaper
     (path . "assets/wallpapers/waifu-cyberpunk.png")
     (fit . zoom))))

(define %outputs (sk:render-all %theme))
(define %permuted-outputs (sk:render-all (permute-objects %theme)))
(define %production-outputs (sk:render-all %production-theme))
(define %permuted-production-outputs
  (sk:render-all (permute-objects %production-theme)))

(check (null? (sk:theme-validation-errors %theme))
       "synthetic fixture failed validation")
(check-equal (assq-ref %theme 'schema-version) 2
             "synthetic fixture is not schema v2")
(check (null? (sk:theme-asset-errors %theme %asset-root))
       "synthetic fixture asset failed explicit-root validation")
(check-equal (map car %outputs) %sk-theme-targets
             "rendered target order drifted")
(check-equal %outputs %permuted-outputs
             "key-permuted theme changed rendered bytes")
(check-equal %outputs (sk:render-all %theme)
             "second render changed bytes")
(check-close (sk:theme-contrast-ratio "#000000" "#ffffff")
             21.0 0.000001
             "black/white WCAG contrast is not 21")

(mkdir-if-missing %rendered-root)
(for-each
 (lambda (entry)
   (let* ((target (car entry))
          (text (cdr entry))
          (filename (assq-ref %expected-paths target))
          (expected
           (read-file (string-append %expected-root "/" filename)))
          (rendered-path
           (string-append %rendered-root "/" filename)))
     (check-equal text expected
                  (format #f "~a output differs from golden" target))
     (check (exactly-one-trailing-newline? text)
            (format #f "~a output lacks one canonical final newline" target))
     (check (string-prefix?
             (if (eq? target 'emacs)
                 ";;; sk-theme-generated.el --- SYNTHETIC FIXTURE - DO NOT INSTALL"
                 "# SYNTHETIC FIXTURE")
             text)
            (format #f "~a fixture lacks non-installable header" target))
     (write-file rendered-path text)))
 %outputs)

;; Emacs uses semicolon comments, unlike the other six adapters.
(check (string-prefix?
        ";;; sk-theme-generated.el --- SYNTHETIC FIXTURE - DO NOT INSTALL"
                       (assq-ref %outputs 'emacs))
       "Emacs fixture lacks non-installable header")
(check (string-prefix?
        ";;; sk-theme-generated.el --- SYNTHETIC FIXTURE - DO NOT INSTALL -*- lexical-binding: t; -*-\n"
        (assq-ref %outputs 'emacs))
       "Emacs lexical-binding cookie is not on the first line")

(let ((combined (string-concatenate (map cdr %outputs))))
  (for-each
   (lambda (forbidden)
     (check (not (string-contains combined forbidden))
            (string-append "rendered output contains forbidden text: "
                           forbidden)))
   '("/home/"
     "/gnu/store/"
     "$HOME"
     "GTK_THEME"
     "GDK_SCALE"
     "GDK_DPI_SCALE"
     "QT_QPA"
     "qt5"
     "qt6"))
  (for-each
   (lambda (entry)
     (check (string-contains combined (cdr entry))
            (format #f "semantic role is not consumed: ~a" (car entry))))
   (assq-ref %theme 'roles)))

;; Assert semantic projections at their exact target keys.  Merely finding a
;; color somewhere in the aggregate output can hide a role-mapping swap when
;; two accepted roles happen to share a value.
(for-each
 (lambda (projection)
   (let ((target (list-ref projection 0))
         (line (list-ref projection 1))
         (label (list-ref projection 2)))
     (check (= 1 (line-count (assq-ref %outputs target) line))
            label)))
 `((emacs
    ,(format #f "    (bg-active ~s)"
             (fixture-role 'surface-raised))
    "Emacs raised-surface role is mapped incorrectly")
   (emacs
    ,(format #f "    (fg-dim ~s)"
             (fixture-role 'text-disabled))
    "Emacs disabled-text role is mapped incorrectly")
   (emacs
    ,(format #f "    (border ~s)"
             (fixture-role 'border))
    "Emacs border role is mapped incorrectly")
   (emacs
    ,(format #f "    (err ~s)"
             (fixture-role 'error))
    "Emacs error role is mapped incorrectly")
   (kitty
    ,(format #f "background ~a" (fixture-role 'canvas))
    "Kitty canvas role is mapped incorrectly")
   (kitty
    ,(format #f "inactive_tab_background ~a"
             (fixture-role 'surface))
    "Kitty surface role is mapped incorrectly")
   (kitty
    ,(format #f "active_tab_background ~a"
             (fixture-role 'accent))
    "Kitty accent role is mapped incorrectly")
   (kitty
    ,(format #f "active_tab_foreground ~a"
             (fixture-role 'on-accent))
    "Kitty on-accent role is mapped incorrectly")
   (kitty
    ,(format #f "selection_background ~a"
             (fixture-role 'selection))
    "Kitty selection role is mapped incorrectly")
   (kitty
    ,(format #f "selection_foreground ~a"
             (fixture-role 'on-selection))
    "Kitty on-selection role is mapped incorrectly")
   (kitty
    ,(format #f "cursor ~a" (fixture-role 'cursor))
    "Kitty cursor role is mapped incorrectly")
   (kitty
    ,(format #f "cursor_text_color ~a"
             (fixture-role 'on-cursor))
    "Kitty on-cursor role is mapped incorrectly")
   (kitty
    ,(format #f "cursor_trail_color ~a"
             (fixture-role 'focus))
    "Kitty focus role is mapped incorrectly")
   (kitty
    ,(format #f "tab_bar_background ~a"
             (fixture-role 'shadow))
    "Kitty shadow role is mapped incorrectly")
   (dunst
    ,(format #f "    background = \"~a\"" (fixture-role 'surface))
    "Dunst surface role is mapped incorrectly")
   (dunst
    ,(format #f "    foreground = \"~a\"" (fixture-role 'text))
    "Dunst text role is mapped incorrectly")
   (dunst
    ,(format #f "    highlight = \"~a\"" (fixture-role 'accent))
    "Dunst accent role is mapped incorrectly")
   (fish
    ,(format #f "set -g -- fish_color_command '~a'"
             (fixture-role-without-hash 'success))
    "Fish command success role is mapped incorrectly")
   (fish
    ,(format #f "set -g -- fish_color_quote '~a'"
             (fixture-role-without-hash 'warning))
    "Fish quote warning role is mapped incorrectly")
   (fish
    ,(format #f "set -g -- fish_color_error '~a'"
             (fixture-role-without-hash 'error))
    "Fish error role is mapped incorrectly")
   (fish
    ,(format #f "set -g -- fish_color_autosuggestion '~a'"
             (fixture-role-without-hash 'text-disabled))
    "Fish autosuggestion disabled-text role is mapped incorrectly")
   (fish
    ,(format
      #f
      "set -g -- __sk_theme_prompt_path_background '--background=~a'"
      (fixture-role-without-hash 'surface-raised))
    "Fish prompt raised-surface role is mapped incorrectly")))

(let ((kitty (assq-ref %outputs 'kitty)))
  (check (= 1 (line-count kitty "allow_remote_control no"))
         "Kitty remote-control denial is not unique")
  (check (= 1 (line-prefix-count kitty "allow_remote_control "))
         "Kitty emits more than one remote-control directive")
  (check (= 1 (line-count kitty "copy_on_select no"))
         "Kitty selection-to-clipboard policy is not explicit")
  (check (= 1
            (line-count
             kitty
             "clipboard_control write-clipboard write-primary read-clipboard-ask read-primary-ask"))
         "Kitty terminal clipboard policy is not explicit")
  (for-each
   (lambda (forbidden)
     (check (not (string-contains kitty forbidden))
            (string-append "Kitty output contains forbidden surface: "
                           forbidden)))
   '("\nallow_remote_control yes"
     "\nlisten_on "
     "\nremote_control_password "
     "\ninclude "
     "\nglobinclude "
     "\nenvinclude "
     "\ngeninclude "))
  (let loop ((index 0))
    (when (< index 16)
      (check (= 1
                (count-substring kitty
                                 (format #f "\ncolor~a " index)))
             (format #f "Kitty color~a is missing or duplicated" index))
      (loop (+ index 1)))))

(let ((fish (assq-ref %outputs 'fish)))
  (for-each
   (lambda (variable)
     (check (= 1 (count-substring
                  fish
                  (string-append "set -g -- " variable " ")))
            (string-append "Fish variable missing or duplicated: "
                           variable)))
   '("fish_color_normal"
     "fish_color_command"
     "fish_color_keyword"
     "fish_color_quote"
     "fish_color_redirection"
     "fish_color_end"
     "fish_color_error"
     "fish_color_param"
     "fish_color_valid_path"
     "fish_color_option"
     "fish_color_comment"
     "fish_color_selection"
     "fish_color_operator"
     "fish_color_escape"
     "fish_color_autosuggestion"
     "fish_color_cancel"
     "fish_color_search_match"
     "fish_color_history_current"
     "fish_color_host"
     "fish_color_host_remote"
     "fish_color_status"
     "fish_color_cwd"
     "fish_color_cwd_root"
     "fish_color_user"
     "fish_color_background"
     "fish_color_statement_terminator"
     "fish_pager_color_progress"
     "fish_pager_color_background"
     "fish_pager_color_prefix"
     "fish_pager_color_completion"
     "fish_pager_color_description"
     "fish_pager_color_secondary_background"
     "fish_pager_color_secondary_prefix"
     "fish_pager_color_secondary_completion"
     "fish_pager_color_secondary_description"
     "fish_pager_color_selected_background"
     "fish_pager_color_selected_prefix"
     "fish_pager_color_selected_completion"
     "fish_pager_color_selected_description")))

(for-each
 (lambda (case)
   (let* ((target (car case))
          (expected-keys (cdr case))
          (text (assq-ref %outputs target))
          (entries (gtk-settings-entries text)))
     (check entries
            (format #f "~a is not a valid generated GKeyFile subset"
                    target))
     (when entries
       (check-equal
        (map car entries)
        expected-keys
        (format #f "~a setting key/order set drifted" target))
       (check (= (length entries)
                 (length (delete-duplicates
                          (map car entries) string=?)))
              (format #f "~a contains duplicate setting keys" target)))
     (check (not (string-contains text "gtk.css"))
            (format #f "~a unexpectedly emits CSS" target))
     (check (not (string-contains text "gtk-xft-dpi"))
            (format #f "~a unexpectedly forces DPI" target))))
 `((gtk3
    . ("gtk-theme-name"
       "gtk-icon-theme-name"
       "gtk-font-name"
       "gtk-cursor-theme-name"
       "gtk-cursor-theme-size"
       "gtk-application-prefer-dark-theme"))
   (gtk4
    . ("gtk-theme-name"
       "gtk-icon-theme-name"
       "gtk-font-name"
       "gtk-cursor-theme-name"
       "gtk-cursor-theme-size"
       "gtk-interface-color-scheme"))))

(check (string-contains (assq-ref %outputs 'gtk4)
                        "# acceptance-application=gtk4-widget-factory\n")
       "GTK 4 output does not record its accepted fixture test surface")
(check (= 1 (line-count (assq-ref %outputs 'gtk4)
                        "gtk-interface-color-scheme=dark"))
       "GTK 4 does not emit the supported dark interface scheme")
(check (not (string-contains (assq-ref %outputs 'gtk4)
                             "gtk-application-prefer-dark-theme"))
       "GTK 4 emits the deprecated prefer-dark setting")
(check (= 1 (line-count (assq-ref %outputs 'gtk3)
                        "gtk-application-prefer-dark-theme=true"))
       "GTK 3 does not emit its accepted dark-theme preference")

(for-each
 (lambda (outputs label)
   (let ((emacs (assq-ref outputs 'emacs)))
     (for-each
      (lambda (line description)
        (check (= 1 (line-count emacs line))
               (string-append label " Emacs " description)))
      '("(defun sk/theme-setup-symbol-fonts (frame)"
        "(add-hook 'after-make-frame-functions"
        "          #'sk/theme-setup-symbol-fonts)"
        "(dolist (frame (frame-list))"
        "      (when (find-font (font-spec :name family) frame)"
        "        (set-fontset-font nil 'symbol family frame 'append)))"
        "     frame 'sk-theme-symbol-fonts-configured t)))")
      '("symbol helper is not unique"
        "frame hook is not unique"
        "frame hook target is not unique"
        "existing-frame application is not unique"
        "font lookup is not frame-specific"
        "fontset application is not frame-specific"
        "per-frame idempotence marker is not unique"))
     (check (not (string-contains emacs "(when (display-graphic-p)"))
            (string-append
             label
             " Emacs retains the pre-frame one-shot graphic guard"))))
 (list %outputs %production-outputs)
 '("fixture" "production"))

;; Production data is frozen, validated, and rendered offline.  These checks
;; do not imply Home wiring, a Guix build, activation, or live consumption.
(check (null? (sk:theme-validation-errors %production-theme))
       "production theme failed validation")
(check-equal (assq-ref %production-theme 'schema-version) 2
             "production theme is not schema v2")
(check (null? (sk:theme-asset-errors %production-theme %repo))
       "production theme asset failed explicit-repository validation")
(check-equal (assq-ref %production-theme 'kind) 'production
             "canonical production theme has the wrong kind")
(check-equal (assq-ref %production-theme 'provenance)
             %expected-production-provenance
             "production provenance drifted")
(check-equal (assq-ref %production-theme 'roles)
             %expected-production-roles
             "frozen production semantic roles drifted")
(check-equal (assq-ref %production-theme 'ansi)
             %expected-production-ansi
             "frozen production ANSI palette drifted")
(check-equal (assq-ref %production-theme 'typography)
             %expected-production-typography
             "accepted production typography drifted")
(check-equal (assq-ref %production-theme 'desktop)
             %expected-production-desktop
             "accepted production desktop policy drifted")
(check-equal (assq-ref %production-theme 'calibrations)
             %expected-production-calibrations
             "accepted production calibrations drifted")
(check-equal (assq-ref %production-theme 'assets)
             %expected-production-assets
             "accepted production asset policy drifted")
(check-equal (map car %production-outputs) %sk-theme-targets
             "production rendered target order drifted")
(check-equal %production-outputs %permuted-production-outputs
             "key-permuted production theme changed rendered bytes")
(check-equal %production-outputs (sk:render-all %production-theme)
             "second production render changed bytes")

;; Modus ANSI black and bright-black are exact terminal endpoints, not
;; semantic UI text/component roles.  Keep this reviewed exception explicit.
(check (< (sk:theme-contrast-ratio
           (assq-ref (assq-ref %production-theme 'ansi) 'bright-black)
           (production-role 'canvas))
          3)
       "production bright-black no longer exercises its reviewed exception")

(mkdir-if-missing %production-rendered-root)
(for-each
 (lambda (entry)
   (let* ((target (car entry))
          (text (cdr entry))
          (filename (assq-ref %expected-paths target))
          (expected
           (read-file
            (string-append %production-expected-root "/" filename)))
          (rendered-path
           (string-append %production-rendered-root "/" filename)))
     (check-equal
      text expected
      (format #f "production ~a output differs from golden" target))
     (check (exactly-one-trailing-newline? text)
            (format #f
                    "production ~a output lacks one canonical final newline"
                    target))
     (check
      (string-prefix?
       (if (eq? target 'emacs)
           ";;; sk-theme-generated.el --- Generated theme adapter -*- lexical-binding: t; -*-"
           "# Generated by (sk theme); do not edit.")
       text)
      (format #f "production ~a output has the wrong header" target))
     (write-file rendered-path text)))
 %production-outputs)

(let ((combined
       (string-concatenate (map cdr %production-outputs))))
  (for-each
   (lambda (forbidden)
     (check (not (string-contains combined forbidden))
            (string-append
             "production output contains forbidden text: "
             forbidden)))
   '("SYNTHETIC FIXTURE"
     "/home/"
     "/gnu/store/"
     "$HOME"
     "GTK_THEME"
     "GDK_SCALE"
     "GDK_DPI_SCALE"
     "QT_QPA"
     "qt5"
     "qt6")))

(for-each
 (lambda (projection)
   (let ((target (list-ref projection 0))
         (line (list-ref projection 1))
         (label (list-ref projection 2)))
     (check (= 1
               (line-count
                (assq-ref %production-outputs target)
                line))
            label)))
 `((emacs
    "    (bg-main \"#0d0e1c\")"
    "production Emacs canvas drifted")
   (emacs
    "    (info \"#6ae4b9\")"
    "production Emacs info/success mapping drifted")
   (emacs
    "(set-face-attribute 'default nil :family \"JetBrainsMono Nerd Font Mono\" :height 120)"
    "production Emacs fixed face drifted")
   (emacs
    "(set-face-attribute 'variable-pitch nil :family \"JetBrainsMono Nerd Font\" :height 110)"
    "production Emacs UI face drifted")
   (kitty
    "background #0d0e1c"
    "production Kitty canvas drifted")
   (kitty
    "font_family JetBrainsMono Nerd Font Mono"
    "production Kitty font family drifted")
   (kitty
    "font_size 14.0"
    "production Kitty font size drifted")
   (kitty
    "background_opacity 0.0"
    "production Kitty opacity drifted")
   (fish
    ,(format #f "set -g -- fish_color_command '~a'"
             (production-role-without-hash 'success))
    "production Fish command role drifted")
   (fish
    ,(format #f "set -g -- fish_color_autosuggestion '~a'"
             (production-role-without-hash 'text-disabled))
    "production Fish autosuggestion role drifted")
   (gtk3
    "gtk-theme-name=Adwaita"
    "production GTK 3 base drifted")
   (gtk3
    "gtk-font-name=JetBrainsMono Nerd Font 11"
    "production GTK 3 font drifted")
   (gtk4
    "gtk-theme-name=Adwaita"
    "production GTK 4 base drifted")
   (gtk4
    "gtk-interface-color-scheme=dark"
    "production GTK 4 color scheme drifted")
   (gtk4
    "gtk-icon-theme-name=Papirus-Dark"
    "production icon theme drifted")
   (gtk4
    "gtk-cursor-theme-name=Bibata-Modern-Ice"
    "production cursor theme drifted")
   (dunst
    "    background = \"#1d2235\""
    "production Dunst surface drifted")
   (dunst
    "    frame_color = \"#ff5f59\""
    "production Dunst critical frame drifted")
   (dunst
    "    icon_theme = \"Papirus-Dark\""
    "production Dunst icon theme drifted")
   (x-session
    "SK_THEME_WALLPAPER='assets/wallpapers/waifu-cyberpunk.png'"
    "production wallpaper path drifted")
   (x-session
    "SK_THEME_PICOM_EMACS_OPACITY_PERCENT='85'"
    "production Picom opacity drifted")
   (x-session
    "XCURSOR_SIZE='32'"
    "production cursor size drifted")))

(let ((kitty (assq-ref %production-outputs 'kitty)))
  (check (= 1 (line-count kitty "allow_remote_control no"))
         "production Kitty remote-control denial is not unique")
  (check (= 1 (line-prefix-count kitty "allow_remote_control "))
         "production Kitty emits multiple remote-control directives")
  (check (= 1 (line-count kitty "copy_on_select no"))
         "production Kitty selection-to-clipboard policy is not explicit")
  (check (= 1
            (line-count
             kitty
             "clipboard_control write-clipboard write-primary read-clipboard-ask read-primary-ask"))
         "production Kitty terminal clipboard policy is not explicit")
  (for-each
   (lambda (forbidden)
     (check (not (string-contains kitty forbidden))
            (string-append
             "production Kitty output contains forbidden surface: "
             forbidden)))
   '("\nallow_remote_control yes"
     "\nlisten_on "
     "\nremote_control_password "
     "\ninclude "
     "\nglobinclude "
     "\nenvinclude "
     "\ngeninclude ")))

(for-each
 (lambda (case)
   (let* ((target (car case))
          (expected-keys (cdr case))
          (text (assq-ref %production-outputs target))
          (entries (gtk-settings-entries text)))
     (check entries
            (format #f
                    "production ~a is not a valid generated GKeyFile subset"
                    target))
     (when entries
       (check-equal
        (map car entries)
        expected-keys
        (format #f "production ~a setting key/order set drifted"
                target)))))
 `((gtk3
    . ("gtk-theme-name"
       "gtk-icon-theme-name"
       "gtk-font-name"
       "gtk-cursor-theme-name"
       "gtk-cursor-theme-size"
       "gtk-application-prefer-dark-theme"))
   (gtk4
    . ("gtk-theme-name"
       "gtk-icon-theme-name"
       "gtk-font-name"
       "gtk-cursor-theme-name"
       "gtk-cursor-theme-size"
       "gtk-interface-color-scheme"))))

;; Reader safety: one quoted datum and EOF are mandatory.
(check (equal? (sk:read-theme (open-input-string "'((sample . 1))"))
               '((sample . 1)))
       "safe reader rejected one inert quoted datum")
(check (throws-theme-error?
        (lambda ()
          (sk:read-theme (open-input-string "(display \"active\")"))))
       "safe reader accepted executable Scheme")
(check (throws-theme-error?
        (lambda ()
          (sk:read-theme (open-input-string "'() '()"))))
       "safe reader accepted a trailing datum")

;; Exact schema and recursive duplicate/unknown controls.
(check (has-code? (alist-delete %theme 'roles) 'missing-key)
       "missing top-level key passed")
(check (has-code? (append %theme '((surprise . #t))) 'unknown-key)
       "unknown top-level key passed")
(check (has-code? (alist-replace %theme 'schema-version 1)
                  'unsupported-schema)
       "schema v1 passed the schema v2 validator")
(let ((masquerade (alist-replace %theme 'kind 'production)))
  (check (has-code? masquerade 'invalid-production-identity)
         "synthetic fixture identities passed as production")
  (check (throws-theme-error? (lambda () (sk:render-all masquerade)))
         "invalid production masquerade rendered"))
(check
 (has-code?
  (mutate-group
   %theme 'provenance
   (lambda (provenance)
     (alist-replace provenance 'mapping-version 2)))
  'invalid-production-identity)
 "unreviewed synthetic fixture identity passed")

;; Production identities are an exact, reviewed contract.  Generic range and
;; contrast validation must not permit a plausible but unaccepted value.
(check
 (has-code?
  (mutate-group
   %production-theme 'typography
   (lambda (typography)
     (alist-replace typography 'ui-size-pt 12)))
  'invalid-production-identity)
 "unaccepted production UI point size 12 passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'typography
   (lambda (typography)
     (alist-replace typography 'ui-size-pt 11.0)))
 'invalid-production-identity)
 "inexact production UI point size 11.0 passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'desktop
   (lambda (desktop)
     (alist-replace desktop 'gtk3-theme "Adwaita-dark")))
  'invalid-production-identity)
 "known GTK 3 light-fallback alias passed as production")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace provenance 'modus-version "4.4.1")))
  'invalid-production-identity)
 "unreviewed production Modus version passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace
      provenance
      'theme-source-sha256
      "26dc9f44271008ce27c63a97b21835b0ebe1a374660f0ac96b5f931ece23b97a")))
 'invalid-production-identity)
 "wrong but well-formed production theme source hash passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace
      provenance
      'core-source-sha256
      "4ecca25fc420989fc8520a3717135a60c068f9bc1e575f4a42e1fe5826f0e3dd")))
  'invalid-production-identity)
 "wrong but well-formed production core source hash passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace provenance 'theme-source-sha256 "ABCDEF")))
  'invalid-hash)
 "malformed production theme source hash passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace
      provenance
      'core-source-sha256
      "26DC9F44271008CE27C63A97B21835B0EBE1A374660F0AC96B5F931ECE23B97A")))
  'invalid-hash)
 "uppercase production core source hash passed")
(check
 (has-code?
  (mutate-group
   %production-theme 'provenance
   (lambda (provenance)
     (alist-replace
      provenance
      'guix-revision
      "b8391f2d7451c2463ba253ffa9872fa6f27485d7")))
  'invalid-production-identity)
 "unreviewed production Guix revision passed")
(let* ((mutated
        (mutate-group
         %production-theme 'roles
         (lambda (roles)
           (alist-replace roles 'focus "#00bcff"))))
       (codes (validation-codes mutated)))
  (check (memq 'invalid-production-identity codes)
         "contrast-passing production role mutation passed")
  (check (not (memq 'contrast-below-floor codes))
         "production role pinning test does not clear contrast"))
(let* ((mutated
        (mutate-group
         %production-theme 'ansi
         (lambda (ansi)
           (alist-replace ansi 'bright-red "#ff8787"))))
       (codes (validation-codes mutated)))
  (check (memq 'invalid-production-identity codes)
         "contrast-passing production ANSI mutation passed")
  (check (not (memq 'contrast-below-floor codes))
         "production ANSI pinning test does not clear contrast"))
(check
 (has-code?
  (mutate-group
   %theme 'roles
   (lambda (roles)
     (cons (cons 'canvas "#101010") roles)))
  'duplicate-key)
 "duplicate nested role passed")
(check
 (has-code?
  (mutate-group
   %theme 'roles
   (lambda (roles)
     (alist-replace roles 'canvas "#ABCDEF")))
  'invalid-color)
 "uppercase color passed")
(check
 (has-code?
  (mutate-group
   %theme 'ansi
   (lambda (ansi) (alist-delete ansi 'bright-white)))
  'missing-key)
 "incomplete ANSI palette passed")
(check
 (has-code?
  (mutate-group
   %theme 'ansi
   (lambda (ansi)
     (alist-replace ansi 'red "#ABCDEF")))
  'invalid-color)
 "malformed complete ANSI palette threw or passed")

;; Numeric units and opacity types/ranges remain distinct.
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'kitty-background-opacity-ratio
                    50)))
  'out-of-range)
 "Kitty ratio accepted a percent")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'picom-emacs-opacity-percent
                    0.5)))
  'out-of-range)
 "Picom percent accepted a ratio")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'picom-emacs-opacity-percent
                    0)))
  'out-of-range)
 "Picom accepted an invisible final desktop")
(check
 (has-code?
  (mutate-group
   %theme 'contrast
   (lambda (contrast)
     (alist-replace contrast 'primary-text-min "7")))
  'invalid-policy)
 "nonnumeric contrast policy crashed or passed")
(check
 (has-code?
  (mutate-group
   %theme 'contrast
   (lambda (contrast)
     (alist-replace contrast 'primary-text-min 7+1i)))
  'invalid-policy)
 "complex contrast policy crashed or passed")
(check
 (has-code?
  (mutate-group
   %theme 'typography
   (lambda (typography)
     (alist-replace typography 'ui-size-pt 13/2)))
  'out-of-range)
 "rational UI point size passed native-decimal validation")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations 'kitty-font-size-pt 29/2)))
  'out-of-range)
 "rational Kitty point size passed native-decimal validation")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'kitty-background-opacity-ratio
                    1/2)))
  'out-of-range)
 "rational Kitty opacity passed native-decimal validation")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'picom-emacs-opacity-percent
                    85+1i)))
  'out-of-range)
 "complex Picom opacity crashed or passed")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'kitty-background-opacity-ratio
                    0.5+1i)))
  'out-of-range)
 "complex Kitty opacity crashed or passed")
(check
 (has-code?
  (mutate-group
   %theme 'desktop
   (lambda (desktop)
     (alist-replace desktop 'cursor-size-px 24.0)))
  'out-of-range)
 "inexact cursor-size integer passed")
(check
 (has-code?
  (mutate-group
   %theme 'calibrations
   (lambda (calibrations)
     (alist-replace calibrations
                    'emacs-face-height-tenths-pt
                    130.0)))
  'out-of-range)
 "inexact Emacs face-height integer passed")

;; Path, identity, target, and Fish reference controls.
(check
 (has-code?
  (mutate-nested
   %theme 'assets 'wallpaper
   (lambda (wallpaper)
     (alist-replace wallpaper 'path "../escape.png")))
 'unsafe-path)
 "parent-relative wallpaper passed")
(let ((missing-theme
       (mutate-nested
        %theme 'assets 'wallpaper
        (lambda (wallpaper)
          (alist-replace wallpaper
                         'path
                         "assets/missing-wallpaper.png")))))
  (check (memq 'asset-unavailable
               (asset-error-codes missing-theme %asset-root))
         "explicit asset-root validation accepted a missing asset"))
(check
 (has-code?
  (mutate-group
   %theme 'typography
   (lambda (typography)
     (alist-replace typography 'ui-family "bad\nfamily")))
  'invalid-name)
 "control character in font family passed")
(check
 (has-code?
  (alist-replace %theme 'targets
                 '(emacs kitty fish gtk3 gtk4 dunst qt))
  'invalid-target-set)
 "Qt target passed")
(check
 (has-code?
  (alist-replace %theme 'targets
                 '(kitty emacs fish gtk3 gtk4 dunst x-session))
  'invalid-target-set)
 "reordered target list passed")
(check
 (has-code?
  (mutate-nested
   %theme 'fish 'syntax
   (lambda (syntax)
     (cons (cons 'unknown
                 (style 'text 'none '()))
           syntax)))
  'unknown-key)
 "unknown Fish variable mapping passed")
(check
 (has-code?
  (mutate-nested
   %theme 'fish 'syntax
   (lambda (syntax)
     (alist-replace syntax 'keyword
                    (style 'accent 'none '(bold bold)))))
  'duplicate-value)
 "duplicate Fish attribute passed")
(check
 (has-code?
  (mutate-nested
   %theme 'fish 'syntax
   (lambda (syntax)
     (alist-replace syntax 'keyword
                    (style 'unlisted-role 'none '()))))
  'unknown-role)
 "unknown Fish semantic role passed")

;; Contrast failures are never rounded into passing values.
(check
 (has-code?
  (mutate-group
   %theme 'roles
   (lambda (roles)
     (alist-replace roles 'text "#777777")))
  'contrast-below-floor)
 "sub-floor primary text contrast passed")
(check
 (has-code?
  (mutate-nested
   %theme 'fish 'syntax
   (lambda (syntax)
     (alist-replace syntax 'command
                    (style 'canvas 'none '()))))
  'contrast-below-floor)
 "Fish renderer mapping accepted invisible canvas-on-canvas text")
(check
 (has-code?
  (mutate-group
   %theme 'ansi
   (lambda (ansi)
     (alist-replace ansi 'red (fixture-role 'canvas))))
  'contrast-below-floor)
 "ANSI renderer mapping accepted invisible red-on-canvas output")
(check
 (has-code?
  (mutate-group
   %theme 'contrast
   (lambda (contrast)
     (alist-replace contrast
                    'transparent-hand-test-required?
                    #f)))
  'missing-hand-test)
 "transparent targets passed without a hand-test requirement")

;; Shared and cyclic pair graphs are rejected before recursive traversal.
(let ((cycle (cons 'cycle '())))
  (set-cdr! cycle cycle)
  (check (memq 'shared-or-cyclic-datum
               (validation-codes cycle))
         "cyclic datum was not rejected"))
(let* ((shared (list (cons 'value 1)))
       (datum (list (cons 'left shared)
                    (cons 'right shared))))
  (check (memq 'shared-or-cyclic-datum
               (validation-codes datum))
         "shared pair graph was not rejected"))

(check
 (throws-theme-error? (lambda () (sk:render-theme %theme 'qt6)))
 "unknown renderer target did not raise")
(check
 (throws-theme-error?
  (lambda ()
    (sk:render-all (alist-delete %theme 'roles))))
 "renderer returned partial output for invalid data")

;; Explicit filesystem boundary: missing, directory, and symlink escape.
(check (memq 'asset-unavailable
             (asset-error-codes
              %theme
              (string-append %temporary "/missing-root")))
       "missing asset root passed")

(define %directory-root (string-append %temporary "/directory-root"))
(mkdir-if-missing %directory-root)
(mkdir-if-missing (string-append %directory-root "/assets"))
(mkdir-if-missing (string-append %directory-root
                                 "/assets/wallpaper.png"))
(check (memq 'asset-not-regular
             (asset-error-codes %theme %directory-root))
       "directory wallpaper passed")

(define %escape-root (string-append %temporary "/escape-root"))
(define %outside-root (string-append %temporary "/outside"))
(mkdir-if-missing %escape-root)
(mkdir-if-missing (string-append %escape-root "/assets"))
(mkdir-if-missing %outside-root)
(write-file (string-append %outside-root "/wallpaper.png") "outside\n")
(symlink (string-append %outside-root "/wallpaper.png")
         (string-append %escape-root "/assets/wallpaper.png"))
(check (memq 'asset-outside-root
             (asset-error-codes %theme %escape-root))
       "symlink-escaped wallpaper passed")

(if (zero? %failures)
    (begin
      (format #t "theme-check: PASS (~a checks)~%" %checks)
      (exit 0))
    (begin
      (format (current-error-port)
              "theme-check: FAIL (~a failures across ~a checks)~%"
              %failures %checks)
      (exit 1)))
