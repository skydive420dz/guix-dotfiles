;;; Deterministic semantic-theme validation and target rendering.

(define-module (sk theme)
  #:use-module (ice-9 format)
  #:use-module (ice-9 match)
  #:use-module (srfi srfi-1)
  #:export (%sk-theme-error-key
            %sk-theme-schema-version
            %sk-theme-targets
            sk:read-theme
            sk:theme-validation-errors
            sk:theme-asset-errors
            sk:theme-contrast-ratio
            sk:render-theme
            sk:render-all))

(define %sk-theme-error-key 'sk-theme-invalid)
(define %sk-theme-schema-version 2)
(define %sk-theme-targets '(emacs kitty fish gtk3 gtk4 x-session))

(define %top-level-keys
  '(schema-version
    kind
    provenance
    roles
    ansi
    typography
    desktop
    calibrations
    assets
    contrast
    fish
    targets))

(define %provenance-keys
  '(palette-authority
    theme
    palette-source
    modus-version
    theme-source-sha256
    core-source-sha256
    guix-revision
    emacs-version
    mapping-version))

(define %role-keys
  '(canvas
    surface
    surface-raised
    text
    text-muted
    text-disabled
    accent
    on-accent
    selection
    on-selection
    focus
    success
    warning
    error
    border
    shadow
    cursor
    on-cursor))

(define %ansi-keys
  '(black red green yellow blue magenta cyan white
    bright-black bright-red bright-green bright-yellow
    bright-blue bright-magenta bright-cyan bright-white))

(define %accepted-production-roles
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

(define %accepted-production-ansi
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

(define %typography-keys
  '(fixed-family ui-family ui-size-pt fallback-families))

(define %desktop-keys
  '(color-scheme
    gtk3-theme
    gtk4-theme
    icon-theme
    cursor-theme
    cursor-size-px
    logical-dpi
    integer-scale
    scale-ownership
    gtk4-test-application))

(define %calibration-keys
  '(emacs-face-height-tenths-pt
    kitty-font-size-pt
    picom-emacs-opacity-percent
    kitty-background-opacity-ratio
    kitty-cursor-trail-role))

(define %asset-keys '(wallpaper))
(define %wallpaper-keys '(path fit))

(define %contrast-keys
  '(primary-text-min
    secondary-text-min
    ui-component-min
    transparent-hand-test-required?))

(define %fish-keys '(prompt syntax pager))

(define %fish-prompt-keys
  '(path path-background git-branch git-status success error))

(define %fish-syntax-keys
  '(normal
    command
    keyword
    quote
    redirection
    end
    error
    param
    valid-path
    option
    comment
    selection
    operator
    escape
    autosuggestion
    cancel
    search-match
    history-current
    host
    host-remote
    status
    cwd
    cwd-root
    user
    background
    statement-terminator))

(define %fish-pager-keys
  '(progress
    background
    prefix
    completion
    description
    secondary-background
    secondary-prefix
    secondary-completion
    secondary-description
    selected-background
    selected-prefix
    selected-completion
    selected-description))

(define %fish-style-keys '(foreground background attributes))
(define %fish-attributes '(bold dim italics underline reverse))

(define %required-contrast-pairs
  '((text canvas primary-text-min)
    (text surface primary-text-min)
    (text surface-raised primary-text-min)
    (text-muted canvas secondary-text-min)
    (text-muted surface secondary-text-min)
    (text-disabled canvas secondary-text-min)
    (accent canvas secondary-text-min)
    (on-accent accent secondary-text-min)
    (on-selection selection secondary-text-min)
    (success canvas secondary-text-min)
    (warning canvas secondary-text-min)
    (error canvas secondary-text-min)
    (focus canvas ui-component-min)
    (border canvas ui-component-min)
    (cursor canvas ui-component-min)
    (on-cursor cursor ui-component-min)))

(define %ansi-on-canvas-keys
  ;; ANSI black and bright-black are the exact Modus dark/dim endpoints, not
  ;; semantic UI text or component roles.  The remaining 14 terminal
  ;; foregrounds must clear the component floor against the default canvas.
  '(red green yellow blue magenta cyan white
    bright-red bright-green bright-yellow
    bright-blue bright-magenta bright-cyan bright-white))

(define %fish-variable-map
  '((normal . "fish_color_normal")
    (command . "fish_color_command")
    (keyword . "fish_color_keyword")
    (quote . "fish_color_quote")
    (redirection . "fish_color_redirection")
    (end . "fish_color_end")
    (error . "fish_color_error")
    (param . "fish_color_param")
    (valid-path . "fish_color_valid_path")
    (option . "fish_color_option")
    (comment . "fish_color_comment")
    (selection . "fish_color_selection")
    (operator . "fish_color_operator")
    (escape . "fish_color_escape")
    (autosuggestion . "fish_color_autosuggestion")
    (cancel . "fish_color_cancel")
    (search-match . "fish_color_search_match")
    (history-current . "fish_color_history_current")
    (host . "fish_color_host")
    (host-remote . "fish_color_host_remote")
    (status . "fish_color_status")
    (cwd . "fish_color_cwd")
    (cwd-root . "fish_color_cwd_root")
    (user . "fish_color_user")
    (background . "fish_color_background")
    (statement-terminator . "fish_color_statement_terminator")))

(define %fish-pager-variable-map
  '((progress . "fish_pager_color_progress")
    (background . "fish_pager_color_background")
    (prefix . "fish_pager_color_prefix")
    (completion . "fish_pager_color_completion")
    (description . "fish_pager_color_description")
    (secondary-background . "fish_pager_color_secondary_background")
    (secondary-prefix . "fish_pager_color_secondary_prefix")
    (secondary-completion . "fish_pager_color_secondary_completion")
    (secondary-description . "fish_pager_color_secondary_description")
    (selected-background . "fish_pager_color_selected_background")
    (selected-prefix . "fish_pager_color_selected_prefix")
    (selected-completion . "fish_pager_color_selected_completion")
    (selected-description . "fish_pager_color_selected_description")))

(define (make-error code path detail)
  `((code . ,code)
    (path . ,path)
    (detail . ,detail)))

(define (pair-graph-reused? value)
  (let ((seen '()))
    (define (walk item)
      (and (pair? item)
           (if (memq item seen)
               #t
               (begin
                 (set! seen (cons item seen))
                 (or (walk (car item))
                     (walk (cdr item)))))))
    (walk value)))

(define (object-entry? entry)
  (and (pair? entry) (symbol? (car entry))))

(define (object-ready? object expected)
  (and (list? object)
       (every object-entry? object)
       (every (lambda (key)
                (= 1 (count (lambda (entry) (eq? key (car entry)))
                            object)))
              expected)))

(define (object-ref object key)
  (let ((entry (and (list? object) (assq key object))))
    (and entry (cdr entry))))

(define (duplicate-values values)
  (delete-duplicates
   (filter (lambda (value)
             (> (count (lambda (candidate)
                         (equal? candidate value))
                       values)
                1))
           values)
   equal?))

(define (validate-object! add-error object expected path)
  (if (not (list? object))
      (add-error 'wrong-type path "expected an association list")
      (let ((bad-entries (filter (lambda (entry)
                                   (not (object-entry? entry)))
                                 object)))
        (for-each
         (lambda (entry)
           (add-error 'invalid-entry path
                      "object entries must begin with a symbol key"))
         bad-entries)
        (when (null? bad-entries)
          (let ((keys (map car object)))
            (for-each
             (lambda (key)
               (add-error 'duplicate-key (append path (list key))
                          "key occurs more than once"))
             (duplicate-values keys))
            (for-each
             (lambda (key)
               (unless (memq key keys)
                 (add-error 'missing-key (append path (list key))
                            "required key is absent")))
             expected)
            (for-each
             (lambda (key)
               (unless (memq key expected)
                 (add-error 'unknown-key (append path (list key))
                            "key is not part of this schema")))
             keys))))))

(define (ascii-digit? character)
  (let ((code (char->integer character)))
    (<= (char->integer #\0) code (char->integer #\9))))

(define (ascii-letter? character)
  (let ((code (char->integer character)))
    (or (<= (char->integer #\A) code (char->integer #\Z))
        (<= (char->integer #\a) code (char->integer #\z)))))

(define (ascii-lower-hex-character? character)
  (or (ascii-digit? character)
      (memv character '(#\a #\b #\c #\d #\e #\f))))

(define (canonical-color? value)
  (and (string? value)
       (= (string-length value) 7)
       (char=? (string-ref value 0) #\#)
       (every ascii-lower-hex-character?
              (string->list (substring value 1)))))

(define (lower-hex-string? value length)
  (and (string? value)
       (= (string-length value) length)
       (every ascii-lower-hex-character? (string->list value))))

(define (control-character? character)
  (let ((code (char->integer character)))
    (or (< code 32) (= code 127))))

(define (safe-description? value)
  (and (string? value)
       (<= 1 (string-length value) 200)
       (not (any control-character? (string->list value)))
       (not (string-prefix? "/" value))
       (not (string-contains value "://"))
       (not (string-contains value "/home/"))
       (not (string-contains value "/gnu/store/"))))

(define (safe-name-character? character)
  (or (ascii-letter? character)
      (ascii-digit? character)
      (memv character '(#\space #\- #\_ #\. #\+))))

(define (safe-name? value)
  (and (string? value)
       (<= 1 (string-length value) 128)
       (every safe-name-character? (string->list value))))

(define (safe-path-character? character)
  (or (ascii-letter? character)
      (ascii-digit? character)
      (memv character '(#\/ #\- #\_ #\.))))

(define (split-path path)
  (let loop ((start 0) (parts '()))
    (let ((separator (string-index path #\/ start)))
      (if separator
          (loop (+ separator 1)
                (cons (substring path start separator) parts))
          (reverse (cons (substring path start) parts))))))

(define (safe-relative-path? value)
  (and (string? value)
       (> (string-length value) 0)
       (not (char=? (string-ref value 0) #\/))
       (not (char=? (string-ref value 0) #\~))
       (not (string-index value #\\))
       (not (string-contains value "://"))
       (every safe-path-character? (string->list value))
       (every (lambda (component)
                (and (> (string-length component) 0)
                     (not (member component '("." "..")))))
              (split-path value))))

(define (finite-real? value)
  (and (real? value)
       (= value value)
       (< (abs value) 1.0e308)))

(define (number-in-range? value minimum maximum)
  (and (finite-real? value)
       (<= minimum value maximum)))

(define (renderable-decimal? value)
  (and (finite-real? value)
       (or (integer? value) (inexact? value))))

(define (integer-in-range? value minimum maximum)
  (and (integer? value)
       (exact? value)
       (<= minimum value maximum)))

(define (all-unique? values)
  (= (length values) (length (delete-duplicates values equal?))))

(define (validate-string-list! add-error value path)
  (if (not (and (list? value) (not (null? value))))
      (add-error 'wrong-type path "expected a nonempty list")
      (begin
        (unless (all-unique? value)
          (add-error 'duplicate-value path "list values must be unique"))
        (for-each
         (lambda (item)
           (unless (safe-name? item)
             (add-error 'invalid-name path
                        "name contains unsupported characters")))
         value))))

(define (validate-color-object! add-error object expected path)
  (validate-object! add-error object expected path)
  (when (object-ready? object expected)
    (for-each
     (lambda (key)
       (unless (canonical-color? (object-ref object key))
         (add-error 'invalid-color (append path (list key))
                    "expected lowercase #rrggbb")))
     expected)))

(define (validate-style! add-error style path)
  (validate-object! add-error style %fish-style-keys path)
  (when (object-ready? style %fish-style-keys)
    (let ((foreground (object-ref style 'foreground))
          (background (object-ref style 'background))
          (attributes (object-ref style 'attributes)))
      (for-each
       (lambda (entry)
         (let ((key (car entry)) (value (cdr entry)))
           (unless (or (eq? value 'none) (memq value %role-keys))
             (add-error 'unknown-role (append path (list key))
                        "Fish color reference is not a semantic role"))))
       `((foreground . ,foreground) (background . ,background)))
      (when (and (eq? foreground 'none) (eq? background 'none)
                 (null? attributes))
        (add-error 'empty-style path "Fish style has no effect"))
      (if (not (list? attributes))
          (add-error 'wrong-type (append path '(attributes))
                     "attributes must be a list")
          (begin
            (unless (all-unique? attributes)
              (add-error 'duplicate-value (append path '(attributes))
                         "Fish attributes must be unique"))
            (for-each
             (lambda (attribute)
               (unless (memq attribute %fish-attributes)
                 (add-error 'unknown-enum
                            (append path (list 'attributes attribute))
                            "unsupported Fish attribute")))
             attributes))))))

(define (validate-style-group! add-error group expected path)
  (validate-object! add-error group expected path)
  (when (object-ready? group expected)
    (for-each
     (lambda (key)
       (validate-style! add-error (object-ref group key)
                        (append path (list key))))
     expected)))

(define (foreground-minimum-key role)
  (cond
   ((eq? role 'text) 'primary-text-min)
   ((memq role
          '(text-muted
            text-disabled
            accent
            on-accent
            on-selection
            success
            warning
            error))
    'secondary-text-min)
   (else 'ui-component-min)))

(define (validate-adapter-contrast!
         add-error roles ansi contrast fish calibrations)
  (let ((thresholds
         `((primary-text-min
            . ,(object-ref contrast 'primary-text-min))
           (secondary-text-min
            . ,(object-ref contrast 'secondary-text-min))
           (ui-component-min
            . ,(object-ref contrast 'ui-component-min)))))
    (define (check-pair! path foreground background minimum-key)
      (let ((foreground-color (object-ref roles foreground))
            (background-color (object-ref roles background))
            (minimum (object-ref thresholds minimum-key)))
        (when (and (canonical-color? foreground-color)
                   (canonical-color? background-color)
                   (finite-real? minimum))
          (let ((ratio
                 (sk:theme-contrast-ratio
                  foreground-color background-color)))
            (when (< ratio minimum)
              (add-error
               'contrast-below-floor
               path
               (format #f "ratio ~,6f is below ~a"
                       ratio minimum)))))))

    (when (and (object-ready? roles %role-keys)
               (every canonical-color?
                      (map (lambda (key) (object-ref roles key))
                           %role-keys))
               (every finite-real? (map cdr thresholds)))
      ;; Kitty renders this configurable trail role directly on the canvas.
      (when (object-ready? calibrations %calibration-keys)
        (let ((trail-role
               (object-ref calibrations 'kitty-cursor-trail-role)))
          (when (memq trail-role %role-keys)
            (check-pair!
             '(contrast kitty cursor-trail canvas)
             trail-role 'canvas 'ui-component-min))))

      ;; Fish styles without an explicit background render on the terminal
      ;; canvas.  Validate the actual role mapping, not merely the existence
      ;; of each palette color.
      (when (object-ready? fish %fish-keys)
        (for-each
         (match-lambda
           ((group-name expected)
            (let ((group (object-ref fish group-name)))
              (when (object-ready? group expected)
                (for-each
                 (lambda (key)
                   (let ((style (object-ref group key)))
                     (when (object-ready? style %fish-style-keys)
                       (let ((foreground
                              (object-ref style 'foreground))
                             (background
                              (object-ref style 'background)))
                         (when (memq foreground %role-keys)
                           (check-pair!
                            (list 'contrast 'fish group-name key)
                            foreground
                            (if (memq background %role-keys)
                                background
                                'canvas)
                            (foreground-minimum-key foreground)))))))
                 expected)))))
         `((prompt ,%fish-prompt-keys)
           (syntax ,%fish-syntax-keys)
           (pager ,%fish-pager-keys))))

      ;; The exact Modus black/bright-black endpoints are intentionally
      ;; excluded above; every other ANSI foreground must remain
      ;; distinguishable from the configured canvas.
      (when (and
             (object-ready? ansi %ansi-keys)
             (every canonical-color?
                    (map (lambda (key) (object-ref ansi key))
                         %ansi-keys)))
        (for-each
         (lambda (key)
           (let ((ratio
                  (sk:theme-contrast-ratio
                   (object-ref ansi key)
                   (object-ref roles 'canvas)))
                 (minimum
                  (object-ref thresholds 'ui-component-min)))
             (when (< ratio minimum)
               (add-error
                'contrast-below-floor
                (list 'contrast 'ansi key 'canvas)
                (format #f "ratio ~,6f is below ~a"
                        ratio minimum)))))
         %ansi-on-canvas-keys)))))

(define (validate-accepted-production-identities!
         add-error
         kind
         provenance
         roles
         ansi
         typography
         desktop
         calibrations
         assets)
  (define (expect path actual expected)
    (unless (equal? actual expected)
      (add-error 'invalid-production-identity path
                 (format #f "expected accepted value ~s" expected))))
  (cond
   ((eq? kind 'fixture)
    (when (object-ready? provenance %provenance-keys)
      (expect '(provenance palette-source)
              (object-ref provenance 'palette-source)
              "synthetic fixture only")
      (expect '(provenance modus-version)
              (object-ref provenance 'modus-version)
              "fixture-0")
      (expect '(provenance theme-source-sha256)
              (object-ref provenance 'theme-source-sha256)
              "0000000000000000000000000000000000000000000000000000000000000000")
      (expect '(provenance core-source-sha256)
              (object-ref provenance 'core-source-sha256)
              "0000000000000000000000000000000000000000000000000000000000000000")
      (expect '(provenance guix-revision)
              (object-ref provenance 'guix-revision)
              "0000000000000000000000000000000000000000")
      (expect '(provenance emacs-version)
              (object-ref provenance 'emacs-version)
              "fixture-0")
      (expect '(provenance mapping-version)
              (object-ref provenance 'mapping-version)
              1)))
   ((eq? kind 'production)
    (when (object-ready? provenance %provenance-keys)
      (expect '(provenance palette-source)
              (object-ref provenance 'palette-source)
              "GNU Emacs 30.2 etc/themes/modus-vivendi-tinted-theme.el")
      (expect '(provenance modus-version)
              (object-ref provenance 'modus-version)
              "4.4.0")
      (expect '(provenance theme-source-sha256)
              (object-ref provenance 'theme-source-sha256)
              "4ecca25fc420989fc8520a3717135a60c068f9bc1e575f4a42e1fe5826f0e3dd")
      (expect '(provenance core-source-sha256)
              (object-ref provenance 'core-source-sha256)
              "26dc9f44271008ce27c63a97b21835b0ebe1a374660f0ac96b5f931ece23b97a")
      (expect '(provenance emacs-version)
              (object-ref provenance 'emacs-version)
              "30.2")
      (expect '(provenance guix-revision)
              (object-ref provenance 'guix-revision)
              "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
      (expect '(provenance mapping-version)
              (object-ref provenance 'mapping-version)
              1))
    (when (object-ready? roles %role-keys)
      (for-each
       (match-lambda
         ((key . expected)
          (expect (list 'roles key)
                  (object-ref roles key)
                  expected)))
       %accepted-production-roles))
    (when (object-ready? ansi %ansi-keys)
      (for-each
       (match-lambda
         ((key . expected)
          (expect (list 'ansi key)
                  (object-ref ansi key)
                  expected)))
       %accepted-production-ansi))
    (when (object-ready? typography %typography-keys)
      (expect '(typography fixed-family)
              (object-ref typography 'fixed-family)
              "JetBrainsMono Nerd Font Mono")
      (expect '(typography ui-family)
              (object-ref typography 'ui-family)
              "JetBrainsMono Nerd Font")
      (let ((ui-size (object-ref typography 'ui-size-pt)))
        (unless (and (number? ui-size)
                     (exact? ui-size)
                     (= ui-size 11))
          (add-error
           'invalid-production-identity
           '(typography ui-size-pt)
           "expected accepted exact value 11")))
      (expect '(typography fallback-families)
              (object-ref typography 'fallback-families)
              '("Symbols Nerd Font Mono"
                "Noto Color Emoji"
                "Font Awesome"
                "Material Icons")))
    (when (object-ready? desktop %desktop-keys)
      (for-each
       (match-lambda
         ((key expected)
          (expect (list 'desktop key)
                  (object-ref desktop key)
                  expected)))
       '((color-scheme dark)
         (gtk3-theme "Adwaita-dark")
         (gtk4-theme "Adwaita")
         (icon-theme "Papirus-Dark")
         (cursor-theme "Bibata-Modern-Ice")
         (cursor-size-px 32)
         (logical-dpi 96)
         (integer-scale 1)
         (scale-ownership inherit-verified)
         (gtk4-test-application "gtk4-widget-factory"))))
    (when (object-ready? calibrations %calibration-keys)
      (for-each
       (match-lambda
         ((key expected)
          (expect (list 'calibrations key)
                  (object-ref calibrations key)
                  expected)))
       '((emacs-face-height-tenths-pt 120)
         (kitty-font-size-pt 14.0)
         (picom-emacs-opacity-percent 85)
         (kitty-background-opacity-ratio 0.0)
         (kitty-cursor-trail-role focus))))
    (when (object-ready? assets %asset-keys)
      (let ((wallpaper (object-ref assets 'wallpaper)))
        (when (object-ready? wallpaper %wallpaper-keys)
          (expect '(assets wallpaper path)
                  (object-ref wallpaper 'path)
                  "assets/wallpapers/waifu-cyberpunk.png")
          (expect '(assets wallpaper fit)
                  (object-ref wallpaper 'fit)
                  'zoom)))))))

(define (hex-channel color offset)
  (string->number (substring color offset (+ offset 2)) 16))

(define (linear-channel value)
  (let ((channel (/ value 255.0)))
    (if (<= channel 0.04045)
        (/ channel 12.92)
        (expt (/ (+ channel 0.055) 1.055) 2.4))))

(define (relative-luminance color)
  (+ (* 0.2126 (linear-channel (hex-channel color 1)))
     (* 0.7152 (linear-channel (hex-channel color 3)))
     (* 0.0722 (linear-channel (hex-channel color 5)))))

(define (sk:theme-contrast-ratio foreground background)
  "Return the WCAG contrast ratio between two canonical RGB strings."
  (unless (and (canonical-color? foreground)
               (canonical-color? background))
    (throw %sk-theme-error-key
           (list (make-error 'invalid-color '(contrast)
                             "contrast inputs must be lowercase #rrggbb"))))
  (let* ((first (relative-luminance foreground))
         (second (relative-luminance background))
         (lighter (max first second))
         (darker (min first second)))
    (/ (+ lighter 0.05) (+ darker 0.05))))

(define (sk:theme-validation-errors theme)
  "Return deterministic validation errors for THEME, or the empty list."
  (if (pair-graph-reused? theme)
      (list (make-error 'shared-or-cyclic-datum '()
                        "shared or cyclic pairs are forbidden"))
      (let ((errors '()))
        (define (add-error code path detail)
          (set! errors (cons (make-error code path detail) errors)))
        (validate-object! add-error theme %top-level-keys '())
        (when (object-ready? theme %top-level-keys)
          (let ((schema-version (object-ref theme 'schema-version))
                (kind (object-ref theme 'kind))
                (provenance (object-ref theme 'provenance))
                (roles (object-ref theme 'roles))
                (ansi (object-ref theme 'ansi))
                (typography (object-ref theme 'typography))
                (desktop (object-ref theme 'desktop))
                (calibrations (object-ref theme 'calibrations))
                (assets (object-ref theme 'assets))
                (contrast (object-ref theme 'contrast))
                (fish (object-ref theme 'fish))
                (targets (object-ref theme 'targets)))
            (unless (equal? schema-version %sk-theme-schema-version)
              (add-error 'unsupported-schema '(schema-version)
                         (format #f "schema version must equal ~a"
                                 %sk-theme-schema-version)))
            (unless (memq kind '(fixture production))
              (add-error 'unknown-enum '(kind)
                         "kind must be fixture or production"))

            (validate-object! add-error provenance %provenance-keys
                              '(provenance))
            (when (object-ready? provenance %provenance-keys)
              (unless (eq? (object-ref provenance 'palette-authority)
                           'frozen-modus-subset)
                (add-error 'unknown-enum
                           '(provenance palette-authority)
                           "palette authority must be frozen-modus-subset"))
              (unless (eq? (object-ref provenance 'theme)
                           'modus-vivendi-tinted)
                (add-error 'unknown-enum '(provenance theme)
                           "theme must be modus-vivendi-tinted"))
              (unless (safe-description?
                       (object-ref provenance 'palette-source))
                (add-error 'invalid-string '(provenance palette-source)
                           "palette source is unsafe"))
              (unless (safe-name? (object-ref provenance 'modus-version))
                (add-error 'invalid-name '(provenance modus-version)
                           "Modus version is unsafe"))
              (unless (lower-hex-string?
                       (object-ref provenance 'theme-source-sha256) 64)
                (add-error
                 'invalid-hash
                 '(provenance theme-source-sha256)
                 "theme source SHA-256 must be 64 lowercase hex digits"))
              (unless (lower-hex-string?
                       (object-ref provenance 'core-source-sha256) 64)
                (add-error
                 'invalid-hash
                 '(provenance core-source-sha256)
                 "core source SHA-256 must be 64 lowercase hex digits"))
              (unless (lower-hex-string?
                       (object-ref provenance 'guix-revision) 40)
                (add-error 'invalid-revision '(provenance guix-revision)
                           "Guix revision must be 40 lowercase hex digits"))
              (unless (safe-name? (object-ref provenance 'emacs-version))
                (add-error 'invalid-name '(provenance emacs-version)
                           "Emacs version is unsafe"))
              (unless (integer-in-range?
                       (object-ref provenance 'mapping-version) 1 999)
                (add-error 'out-of-range '(provenance mapping-version)
                           "mapping version must be an integer from 1 to 999")))

            (validate-color-object! add-error roles %role-keys '(roles))
            (validate-color-object! add-error ansi %ansi-keys '(ansi))

            (validate-object! add-error typography %typography-keys
                              '(typography))
            (when (object-ready? typography %typography-keys)
              (for-each
               (lambda (key)
                 (unless (safe-name? (object-ref typography key))
                   (add-error 'invalid-name (list 'typography key)
                              "font family contains unsupported characters")))
               '(fixed-family ui-family))
              (unless (and
                       (renderable-decimal?
                        (object-ref typography 'ui-size-pt))
                       (number-in-range?
                        (object-ref typography 'ui-size-pt) 6 72))
                (add-error 'out-of-range '(typography ui-size-pt)
                           "UI point size must be a decimal in [6,72]"))
              (validate-string-list!
               add-error
               (object-ref typography 'fallback-families)
               '(typography fallback-families)))

            (validate-object! add-error desktop %desktop-keys '(desktop))
            (when (object-ready? desktop %desktop-keys)
              (unless (eq? (object-ref desktop 'color-scheme) 'dark)
                (add-error 'unknown-enum '(desktop color-scheme)
                           "only the accepted dark scheme is supported"))
              (for-each
               (lambda (key)
                 (unless (safe-name? (object-ref desktop key))
                   (add-error 'invalid-name (list 'desktop key)
                              "desktop identity contains unsupported characters")))
               '(gtk3-theme
                 gtk4-theme
                 icon-theme
                 cursor-theme
                 gtk4-test-application))
              (unless (integer-in-range?
                       (object-ref desktop 'cursor-size-px) 8 128)
                (add-error 'out-of-range '(desktop cursor-size-px)
                           "cursor size must be an integer in [8,128]"))
              (unless (integer-in-range?
                       (object-ref desktop 'logical-dpi) 72 240)
                (add-error 'out-of-range '(desktop logical-dpi)
                           "logical DPI must be an integer in [72,240]"))
              (unless (integer-in-range?
                       (object-ref desktop 'integer-scale) 1 4)
                (add-error 'out-of-range '(desktop integer-scale)
                           "integer scale must be in [1,4]"))
              (unless (eq? (object-ref desktop 'scale-ownership)
                           'inherit-verified)
                (add-error 'unknown-enum '(desktop scale-ownership)
                           "scale ownership must be inherit-verified")))

            (validate-object! add-error calibrations %calibration-keys
                              '(calibrations))
            (when (object-ready? calibrations %calibration-keys)
              (unless (integer-in-range?
                       (object-ref calibrations
                                   'emacs-face-height-tenths-pt)
                       60 400)
                (add-error
                 'out-of-range
                 '(calibrations emacs-face-height-tenths-pt)
                 "Emacs face height must be an integer in [60,400]"))
              (unless (and
                       (renderable-decimal?
                        (object-ref calibrations 'kitty-font-size-pt))
                       (number-in-range?
                        (object-ref calibrations 'kitty-font-size-pt)
                        6 72))
                (add-error 'out-of-range
                           '(calibrations kitty-font-size-pt)
                           "Kitty point size must be a decimal in [6,72]"))
              (unless (integer-in-range?
                       (object-ref calibrations
                                   'picom-emacs-opacity-percent)
                       0 100)
                (add-error
                 'out-of-range
                 '(calibrations picom-emacs-opacity-percent)
                 "Picom opacity must be an integer percent"))
              (unless (and
                       (renderable-decimal?
                        (object-ref
                         calibrations
                         'kitty-background-opacity-ratio))
                       (number-in-range?
                        (object-ref
                         calibrations
                         'kitty-background-opacity-ratio)
                        0 1))
                (add-error
                 'out-of-range
                 '(calibrations kitty-background-opacity-ratio)
                 "Kitty opacity must be a decimal ratio in [0,1]"))
              (unless (memq (object-ref calibrations
                                        'kitty-cursor-trail-role)
                            %role-keys)
                (add-error
                 'unknown-role
                 '(calibrations kitty-cursor-trail-role)
                 "Kitty cursor trail must reference a semantic role")))

            (validate-object! add-error assets %asset-keys '(assets))
            (when (object-ready? assets %asset-keys)
              (let ((wallpaper (object-ref assets 'wallpaper)))
                (validate-object! add-error wallpaper %wallpaper-keys
                                  '(assets wallpaper))
                (when (object-ready? wallpaper %wallpaper-keys)
                  (unless (safe-relative-path?
                           (object-ref wallpaper 'path))
                    (add-error 'unsafe-path '(assets wallpaper path)
                               "wallpaper path must be normalized and relative"))
                  (unless (eq? (object-ref wallpaper 'fit) 'zoom)
                    (add-error 'unknown-enum '(assets wallpaper fit)
                               "only the accepted zoom fit is supported")))))

            (validate-object! add-error contrast %contrast-keys '(contrast))
            (when (object-ready? contrast %contrast-keys)
              (let ((thresholds
                     `((primary-text-min
                        . ,(object-ref contrast 'primary-text-min))
                       (secondary-text-min
                        . ,(object-ref contrast 'secondary-text-min))
                       (ui-component-min
                        . ,(object-ref contrast 'ui-component-min)))))
                (unless (and
                         (number? (object-ref contrast 'primary-text-min))
                         (= (object-ref contrast 'primary-text-min) 7))
                  (add-error 'invalid-policy '(contrast primary-text-min)
                             "accepted primary contrast floor is 7"))
                (unless (and
                         (number? (object-ref contrast
                                              'secondary-text-min))
                         (= (object-ref contrast
                                        'secondary-text-min)
                            9/2))
                  (add-error 'invalid-policy '(contrast secondary-text-min)
                             "accepted secondary contrast floor is 9/2"))
                (unless (and
                         (number? (object-ref contrast 'ui-component-min))
                         (= (object-ref contrast 'ui-component-min) 3))
                  (add-error 'invalid-policy '(contrast ui-component-min)
                             "accepted component contrast floor is 3"))
                (unless (boolean?
                         (object-ref contrast
                                     'transparent-hand-test-required?))
                  (add-error
                   'wrong-type
                   '(contrast transparent-hand-test-required?)
                   "transparent hand-test policy must be boolean"))
                (when (and (object-ready? roles %role-keys)
                           (every canonical-color?
                                  (map (lambda (key)
                                         (object-ref roles key))
                                       %role-keys))
                           (every finite-real? (map cdr thresholds)))
                  (for-each
                   (match-lambda
                     ((foreground background minimum-key)
                      (let ((ratio
                             (sk:theme-contrast-ratio
                              (object-ref roles foreground)
                              (object-ref roles background)))
                            (minimum (object-ref thresholds minimum-key)))
                        (when (< ratio minimum)
                          (add-error
                           'contrast-below-floor
                           (list 'contrast foreground background)
                           (format #f "ratio ~,6f is below ~a"
                                   ratio minimum))))))
                   %required-contrast-pairs))
                (when (and (object-ready? calibrations %calibration-keys)
                           (finite-real?
                            (object-ref
                             calibrations
                             'picom-emacs-opacity-percent))
                           (finite-real?
                            (object-ref
                             calibrations
                             'kitty-background-opacity-ratio))
                           (or (< (object-ref
                                   calibrations
                                   'picom-emacs-opacity-percent)
                                  100)
                               (< (object-ref
                                   calibrations
                                   'kitty-background-opacity-ratio)
                                  1))
                           (not (eq? (object-ref
                                      contrast
                                      'transparent-hand-test-required?)
                                     #t)))
                  (add-error
                   'missing-hand-test
                   '(contrast transparent-hand-test-required?)
                   "nonopaque targets require a real-display hand test"))))

            (validate-object! add-error fish %fish-keys '(fish))
            (when (object-ready? fish %fish-keys)
              (validate-style-group! add-error
                                     (object-ref fish 'prompt)
                                     %fish-prompt-keys
                                     '(fish prompt))
              (validate-style-group! add-error
                                     (object-ref fish 'syntax)
                                     %fish-syntax-keys
                                     '(fish syntax))
              (validate-style-group! add-error
                                     (object-ref fish 'pager)
                                     %fish-pager-keys
                                     '(fish pager)))

            (when (and (object-ready? roles %role-keys)
                       (object-ready? ansi %ansi-keys)
                       (object-ready? contrast %contrast-keys)
                       (object-ready? fish %fish-keys))
              (validate-adapter-contrast!
               add-error roles ansi contrast fish calibrations))

            (unless (equal? targets %sk-theme-targets)
              (add-error 'invalid-target-set '(targets)
                         "target list must be the exact six-target order"))

            (validate-accepted-production-identities!
             add-error
             kind
             provenance
             roles
             ansi
             typography
             desktop
             calibrations
             assets)))
        (reverse errors))))

(define (raise-if-invalid theme)
  (let ((errors (sk:theme-validation-errors theme)))
    (unless (null? errors)
      (throw %sk-theme-error-key errors)))
  theme)

(define (read-error code detail)
  (throw %sk-theme-error-key
         (list (make-error code '(reader) detail))))

(define (sk:read-theme port)
  "Read one inert quoted theme datum from PORT and require EOF."
  (let ((form
         (catch #t
           (lambda () (read port))
           (lambda _ (read-error 'read-error "invalid Scheme datum")))))
    (unless (and (list? form)
                 (= (length form) 2)
                 (eq? (car form) 'quote))
      (read-error 'not-inert
                  "theme source must contain one quoted datum"))
    (let ((trailing
           (catch #t
             (lambda () (read port))
             (lambda _ (read-error 'read-error
                                   "invalid trailing Scheme datum")))))
      (unless (eof-object? trailing)
        (read-error 'trailing-datum
                    "theme source must contain exactly one datum")))
    (cadr form)))

(define (sk:theme-asset-errors theme repository-root)
  "Return validation and explicit-root wallpaper errors for THEME."
  (let ((errors (sk:theme-validation-errors theme)))
    (if (not (null? errors))
        errors
        (catch #t
          (lambda ()
            (let* ((root (canonicalize-path repository-root))
                   (wallpaper (object-ref (object-ref theme 'assets)
                                          'wallpaper))
                   (relative (object-ref wallpaper 'path))
                   (candidate (string-append root "/" relative))
                   (resolved (canonicalize-path candidate))
                   (root-prefix (string-append root "/")))
              (cond
               ((not (string-prefix? root-prefix resolved))
                (list (make-error 'asset-outside-root
                                  '(assets wallpaper path)
                                  "resolved wallpaper escapes the explicit root")))
               ((not (eq? (stat:type (stat resolved)) 'regular))
                (list (make-error 'asset-not-regular
                                  '(assets wallpaper path)
                                  "wallpaper must resolve to a regular file")))
               (else '()))))
          (lambda _
            (list (make-error 'asset-unavailable
                              '(assets wallpaper path)
                              "root or wallpaper cannot be resolved")))))))

(define (header-lines theme comment-prefix)
  (let* ((kind (object-ref theme 'kind))
         (provenance (object-ref theme 'provenance))
         (palette-source (object-ref provenance 'palette-source)))
    (append
     (if (eq? kind 'fixture)
         (list (string-append comment-prefix
                              " SYNTHETIC FIXTURE - DO NOT INSTALL"))
         (list (string-append comment-prefix
                              " Generated by (sk theme); do not edit.")))
     (list (format #f "~a schema=~a palette=~a"
                   comment-prefix
                   %sk-theme-schema-version
                   palette-source)))))

(define (emacs-header-lines theme)
  (let* ((kind (object-ref theme 'kind))
         (provenance (object-ref theme 'provenance))
         (palette-source (object-ref provenance 'palette-source)))
    (list
     (if (eq? kind 'fixture)
         ";;; sk-theme-generated.el --- SYNTHETIC FIXTURE - DO NOT INSTALL -*- lexical-binding: t; -*-"
         ";;; sk-theme-generated.el --- Generated theme adapter -*- lexical-binding: t; -*-")
     (format #f ";;; schema=~a palette=~a"
             %sk-theme-schema-version palette-source))))

(define (lines->text lines)
  (string-append (string-join lines "\n") "\n"))

(define (role theme name)
  (object-ref (object-ref theme 'roles) name))

(define (ansi theme name)
  (object-ref (object-ref theme 'ansi) name))

(define (typography theme name)
  (object-ref (object-ref theme 'typography) name))

(define (desktop theme name)
  (object-ref (object-ref theme 'desktop) name))

(define (calibration theme name)
  (object-ref (object-ref theme 'calibrations) name))

(define (wallpaper theme name)
  (object-ref (object-ref (object-ref theme 'assets) 'wallpaper) name))

(define (elisp-string value)
  (format #f "~s" value))

(define (elisp-palette-line key value)
  (format #f "    (~a ~a)" key (elisp-string value)))

(define (render-emacs theme)
  (let* ((fallbacks (typography theme 'fallback-families))
         (ui-height
          (inexact->exact (round (* 10 (typography theme 'ui-size-pt)))))
         (palette-lines
          `((bg-main . ,(role theme 'canvas))
            (bg-dim . ,(role theme 'surface))
            (bg-active . ,(role theme 'surface-raised))
            (fg-main . ,(role theme 'text))
            (fg-alt . ,(role theme 'text-muted))
            (fg-dim . ,(role theme 'text-disabled))
            (border . ,(role theme 'border))
            (bg-region . ,(role theme 'selection))
            (fg-region . ,(role theme 'on-selection))
            (cursor . ,(role theme 'cursor))
            (err . ,(role theme 'error))
            (warning . ,(role theme 'warning))
            (info . ,(role theme 'success))
            (bg-term-black . ,(ansi theme 'black))
            (fg-term-black . ,(ansi theme 'black))
            (bg-term-red . ,(ansi theme 'red))
            (fg-term-red . ,(ansi theme 'red))
            (bg-term-green . ,(ansi theme 'green))
            (fg-term-green . ,(ansi theme 'green))
            (bg-term-yellow . ,(ansi theme 'yellow))
            (fg-term-yellow . ,(ansi theme 'yellow))
            (bg-term-blue . ,(ansi theme 'blue))
            (fg-term-blue . ,(ansi theme 'blue))
            (bg-term-magenta . ,(ansi theme 'magenta))
            (fg-term-magenta . ,(ansi theme 'magenta))
            (bg-term-cyan . ,(ansi theme 'cyan))
            (fg-term-cyan . ,(ansi theme 'cyan))
            (bg-term-white . ,(ansi theme 'white))
            (fg-term-white . ,(ansi theme 'white))
            (bg-term-black-bright . ,(ansi theme 'bright-black))
            (fg-term-black-bright . ,(ansi theme 'bright-black))
            (bg-term-red-bright . ,(ansi theme 'bright-red))
            (fg-term-red-bright . ,(ansi theme 'bright-red))
            (bg-term-green-bright . ,(ansi theme 'bright-green))
            (fg-term-green-bright . ,(ansi theme 'bright-green))
            (bg-term-yellow-bright . ,(ansi theme 'bright-yellow))
            (fg-term-yellow-bright . ,(ansi theme 'bright-yellow))
            (bg-term-blue-bright . ,(ansi theme 'bright-blue))
            (fg-term-blue-bright . ,(ansi theme 'bright-blue))
            (bg-term-magenta-bright . ,(ansi theme 'bright-magenta))
            (fg-term-magenta-bright . ,(ansi theme 'bright-magenta))
            (bg-term-cyan-bright . ,(ansi theme 'bright-cyan))
            (fg-term-cyan-bright . ,(ansi theme 'bright-cyan))
            (bg-term-white-bright . ,(ansi theme 'bright-white))
            (fg-term-white-bright . ,(ansi theme 'bright-white)))))
    (lines->text
     (append
      (emacs-header-lines theme)
      (list ""
            "(setq modus-themes-variable-pitch-ui t"
            "      modus-vivendi-tinted-palette-overrides"
            "      '(")
      (map (lambda (entry)
             (elisp-palette-line (car entry) (cdr entry)))
           palette-lines)
      (list "        ))"
            ""
            "(mapc #'disable-theme custom-enabled-themes)"
            "(load-theme 'modus-vivendi-tinted t)"
            (format #f "(set-face-attribute 'default nil :family ~a :height ~a)"
                    (elisp-string (typography theme 'fixed-family))
                    (calibration theme 'emacs-face-height-tenths-pt))
            (format #f "(set-face-attribute 'fixed-pitch nil :family ~a :height ~a)"
                    (elisp-string (typography theme 'fixed-family))
                    (calibration theme 'emacs-face-height-tenths-pt))
            (format #f "(set-face-attribute 'variable-pitch nil :family ~a :height ~a)"
                    (elisp-string (typography theme 'ui-family))
                    ui-height)
            ""
            "(when (display-graphic-p)"
            "  (dolist (family"
            "           '(")
      (map (lambda (family)
             (string-append "             " (elisp-string family)))
           fallbacks)
      (list "             ))"
            "    (when (find-font (font-spec :name family))"
            "      (set-fontset-font t 'symbol family nil 'append))))"
            ""
            "(provide 'sk-theme-generated)"
            ";;; sk-theme-generated.el ends here")))))

(define %kitty-ansi-options
  '((black . "color0")
    (red . "color1")
    (green . "color2")
    (yellow . "color3")
    (blue . "color4")
    (magenta . "color5")
    (cyan . "color6")
    (white . "color7")
    (bright-black . "color8")
    (bright-red . "color9")
    (bright-green . "color10")
    (bright-yellow . "color11")
    (bright-blue . "color12")
    (bright-magenta . "color13")
    (bright-cyan . "color14")
    (bright-white . "color15")))

(define (render-kitty theme)
  (lines->text
   (append
    (header-lines theme "#")
    (list
     "scrollback_lines 10000"
     (format #f "foreground ~a" (role theme 'text))
     (format #f "background ~a" (role theme 'canvas))
     (format #f "background_opacity ~a"
             (calibration theme 'kitty-background-opacity-ratio))
     (format #f "selection_foreground ~a" (role theme 'on-selection))
     (format #f "selection_background ~a" (role theme 'selection))
     (format #f "cursor ~a" (role theme 'cursor))
     (format #f "cursor_text_color ~a" (role theme 'on-cursor))
     (format #f "url_color ~a" (role theme 'accent))
     (format #f "active_tab_foreground ~a" (role theme 'on-accent))
     (format #f "active_tab_background ~a" (role theme 'accent))
     (format #f "inactive_tab_foreground ~a" (role theme 'text-muted))
     (format #f "inactive_tab_background ~a" (role theme 'surface))
     (format #f "tab_bar_background ~a" (role theme 'shadow))
     "tab_bar_style powerline"
     "tab_powerline_style round"
     "cursor_trail 10"
     "cursor_trail_decay 0.2 0.6"
     (format #f "cursor_trail_color ~a"
             (role theme
                   (calibration theme 'kitty-cursor-trail-role)))
     "repaint_delay 10"
     "shell_integration enabled"
     "allow_remote_control no"
     "window_padding_width 10"
     (format #f "font_family ~a" (typography theme 'fixed-family))
     (format #f "font_size ~a"
             (calibration theme 'kitty-font-size-pt)))
    (map (lambda (entry)
           (format #f "~a ~a" (cdr entry) (ansi theme (car entry))))
         %kitty-ansi-options))))

(define (color-without-hash color)
  (substring color 1))

(define (fish-style-values theme style)
  (let ((foreground (object-ref style 'foreground))
        (background (object-ref style 'background))
        (attributes (object-ref style 'attributes)))
    (append
     (if (eq? foreground 'none)
         '()
         (list (color-without-hash (role theme foreground))))
     (if (eq? background 'none)
         '()
         (list (string-append "--background="
                              (color-without-hash
                               (role theme background)))))
     (filter-map
      (lambda (attribute)
        (and (memq attribute attributes)
             (string-append "--" (symbol->string attribute))))
      %fish-attributes))))

(define (fish-set-line theme variable style)
  (format #f "set -g -- ~a ~{~a~^ ~}"
          variable
          (map (lambda (value) (format #f "'~a'" value))
               (fish-style-values theme style))))

(define (fish-prompt-color-line theme variable style)
  (let ((values (fish-style-values theme style)))
    (format #f "set -g -- ~a ~{~a~^ ~}"
            variable
            (map (lambda (value) (format #f "'~a'" value)) values))))

(define (render-fish theme)
  (let* ((fish (object-ref theme 'fish))
         (prompt (object-ref fish 'prompt))
         (syntax (object-ref fish 'syntax))
         (pager (object-ref fish 'pager)))
    (lines->text
     (append
      (header-lines theme "#")
      (list "# Generated Fish syntax, pager, and prompt color adapter.")
      (map
       (lambda (entry)
         (fish-set-line theme (cdr entry)
                        (object-ref syntax (car entry))))
       %fish-variable-map)
      (map
       (lambda (entry)
         (fish-set-line theme (cdr entry)
                        (object-ref pager (car entry))))
       %fish-pager-variable-map)
      (list
       (fish-prompt-color-line theme "__sk_theme_prompt_path"
                               (object-ref prompt 'path))
       (fish-prompt-color-line theme "__sk_theme_prompt_path_background"
                               (object-ref prompt 'path-background))
       (fish-prompt-color-line theme "__sk_theme_prompt_git_branch"
                               (object-ref prompt 'git-branch))
       (fish-prompt-color-line theme "__sk_theme_prompt_git_status"
                               (object-ref prompt 'git-status))
       (fish-prompt-color-line theme "__sk_theme_prompt_success"
                               (object-ref prompt 'success))
       (fish-prompt-color-line theme "__sk_theme_prompt_error"
                               (object-ref prompt 'error))
       ""
       "function fish_prompt"
       "    set -l last_status $status"
       "    set -l branch (__sk_git_branch)"
       "    set -l git_status (__sk_git_status)"
       ""
       "    set_color normal"
       "    set_color $__sk_theme_prompt_path_background $__sk_theme_prompt_path"
       "    echo -n ' '(__sk_prompt_pwd)' '"
       "    set_color normal"
       ""
       "    if test -n \"$branch\""
       "        echo -n ' '"
       "        set_color $__sk_theme_prompt_git_branch"
       "        echo -n '󰊢 '$branch' '"
       "        set_color $__sk_theme_prompt_git_status"
       "        echo -n $git_status' '"
       "        set_color normal"
       "    end"
       ""
       "    echo"
       ""
       "    if test $last_status -eq 0"
       "        set_color $__sk_theme_prompt_success"
       "    else"
       "        set_color $__sk_theme_prompt_error"
       "    end"
       "    echo -n '❯ '"
       "    set_color normal"
       "end"
       ""
       "function fish_right_prompt"
       "end")))))

(define (font-setting theme)
  (format #f "~a ~a"
          (typography theme 'ui-family)
          (typography theme 'ui-size-pt)))

(define (render-gtk theme version)
  (let ((gtk-theme (if (= version 3)
                       (desktop theme 'gtk3-theme)
                       (desktop theme 'gtk4-theme))))
    (lines->text
     (append
      (header-lines theme "#")
      (list
       (format #f
               "# GTK ~a policy: logical-dpi=~a scale=~a ownership=~a"
               version
               (desktop theme 'logical-dpi)
               (desktop theme 'integer-scale)
               (desktop theme 'scale-ownership)))
      (if (= version 4)
          (list
           (format #f "# acceptance-application=~a"
                   (desktop theme 'gtk4-test-application))
           "# gtk-interface-color-scheme requires GTK 4.20 or newer.")
          '())
      (list
       "# Scaling is verified externally; this file emits no scale override."
       "[Settings]"
       (format #f "gtk-theme-name=~a" gtk-theme)
       (format #f "gtk-icon-theme-name=~a"
               (desktop theme 'icon-theme))
       (format #f "gtk-font-name=~a" (font-setting theme))
       (format #f "gtk-cursor-theme-name=~a"
               (desktop theme 'cursor-theme))
       (format #f "gtk-cursor-theme-size=~a"
               (desktop theme 'cursor-size-px)))
      (if (= version 3)
          (list "gtk-application-prefer-dark-theme=true")
          (list "gtk-interface-color-scheme=dark"))))))

(define (shell-quoted value)
  ;; Every caller supplies a value already restricted to conservative ASCII
  ;; without apostrophes.  Keep the quoting explicit at the target boundary.
  (format #f "'~a'" value))

(define (render-x-session theme)
  (lines->text
   (append
    (header-lines theme "#")
    (list
     "# Same-shell data only: starts no process and emits no toolkit scale override."
     (format #f "SK_THEME_LOGICAL_DPI=~a"
             (shell-quoted (number->string
                            (desktop theme 'logical-dpi))))
     (format #f "SK_THEME_INTEGER_SCALE=~a"
             (shell-quoted (number->string
                            (desktop theme 'integer-scale))))
     (format #f "SK_THEME_SCALE_OWNERSHIP=~a"
             (shell-quoted
              (symbol->string (desktop theme 'scale-ownership))))
     (format #f "SK_THEME_WALLPAPER=~a"
             (shell-quoted (wallpaper theme 'path)))
     (format #f "SK_THEME_WALLPAPER_FIT=~a"
             (shell-quoted
              (symbol->string (wallpaper theme 'fit))))
     (format #f "SK_THEME_PICOM_EMACS_OPACITY_PERCENT=~a"
             (shell-quoted
              (number->string
               (calibration theme 'picom-emacs-opacity-percent))))
     "SK_THEME_PICOM_CONFIG='/dev/null'"
     "SK_THEME_PICOM_BACKEND='glx'"
     "SK_THEME_PICOM_VSYNC='true'"
     (format #f "XCURSOR_THEME=~a"
             (shell-quoted (desktop theme 'cursor-theme)))
     (format #f "XCURSOR_SIZE=~a"
             (shell-quoted
              (number->string (desktop theme 'cursor-size-px))))
     "export XCURSOR_THEME XCURSOR_SIZE"))))

(define (render-dispatch theme target)
  (case target
    ((emacs) (render-emacs theme))
    ((kitty) (render-kitty theme))
    ((fish) (render-fish theme))
    ((gtk3) (render-gtk theme 3))
    ((gtk4) (render-gtk theme 4))
    ((x-session) (render-x-session theme))
    (else
     (throw %sk-theme-error-key
            (list (make-error 'unknown-target '(render target)
                              "renderer target is not allowed"))))))

(define (sk:render-theme theme target)
  "Validate THEME and return TARGET's deterministic native text."
  (raise-if-invalid theme)
  (unless (memq target %sk-theme-targets)
    (throw %sk-theme-error-key
           (list (make-error 'unknown-target (list 'render target)
                             "renderer target is not allowed"))))
  (render-dispatch theme target))

(define (sk:render-all theme)
  "Validate THEME and return the six target strings in canonical order."
  (raise-if-invalid theme)
  (map (lambda (target)
         (cons target (render-dispatch theme target)))
       %sk-theme-targets))
