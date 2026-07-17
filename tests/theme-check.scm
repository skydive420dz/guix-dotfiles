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
(define %asset-root
  (string-append %repo "/fixtures/theme/root"))
(define %expected-root
  (string-append %repo "/fixtures/theme/expected"))
(define %rendered-root
  (string-append %temporary "/rendered"))

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

(define (fixture-role key)
  (assq-ref (assq-ref %theme 'roles) key))

(define (fixture-role-without-hash key)
  (substring (fixture-role key) 1))

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
    (x-session . "x-session.sh")))

(define %outputs (sk:render-all %theme))
(define %permuted-outputs (sk:render-all (permute-objects %theme)))

(check (null? (sk:theme-validation-errors %theme))
       "synthetic fixture failed validation")
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

;; Emacs uses semicolon comments, unlike the other five adapters.
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
(let ((masquerade (alist-replace %theme 'kind 'production)))
  (check (has-code? masquerade 'invalid-production-identity)
         "synthetic fixture identities passed as production")
  (check (has-code? masquerade 'production-not-ready)
         "production bypassed the unresolved GTK/UI size gate")
  (check (throws-theme-error? (lambda () (sk:render-all masquerade)))
         "production rendered while its decision gate is closed"))
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
                 '(emacs kitty fish gtk3 gtk4 qt))
  'invalid-target-set)
 "Qt target passed")
(check
 (has-code?
  (alist-replace %theme 'targets
                 '(kitty emacs fish gtk3 gtk4 x-session))
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
