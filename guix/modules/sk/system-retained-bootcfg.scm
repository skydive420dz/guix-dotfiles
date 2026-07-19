;;; Configuration-aware, stage-only GRUB construction for reviewed System links.

(define-module (sk system-retained-bootcfg)
  #:use-module (gcrypt hash)
  #:use-module (gnu bootloader)
  #:use-module (gnu bootloader grub)
  #:use-module (gnu system)
  #:use-module (gnu system keyboard)
  #:use-module (guix base16)
  #:use-module (guix derivations)
  #:use-module (guix gexp)
  #:use-module (guix monads)
  #:use-module (guix store)
  #:use-module (ice-9 format)
  #:use-module (ice-9 regex)
  #:use-module (ice-9 textual-ports)
  #:use-module (srfi srfi-1)
  #:export (sk:assert-stage-spec
            sk:bootcfg-configuration-tuple
            sk:build-retained-bootcfg
            sk:file-sha256
            sk:make-retained-bootcfg
            sk:project-retained-grub
            sk:read-stage-spec
            sk:record-values
            sk:retained-generations
            sk:single-record
            sk:symlink-points-to-link?
            sk:validate-bootloader-configuration
            sk:validate-retained-grub))

(define %schema "p5.2b-retained-bootcfg-stage/v1")
(define %fixed-repository-inputs
  '(("implementation-module"
     . "guix/modules/sk/system-retained-bootcfg.scm")
    ("implementation-driver"
     . "scripts/guix-system-retained-bootcfg.scm")
    ("implementation-launcher"
     . "scripts/guix-system-retained-bootcfg")
    ("evaluation-input"
     . "guix/package-ownership.scm")))
(define %old-submenu-open
  "submenu \"GNU system, old configurations...\" {\n")
(define %old-submenu-close
  "}\n\nif [ \"${grub_platform}\" == efi ]; then")
(define %single-record-fields
  '(("schema" . 2)
    ("mode" . 2)
    ("authorization" . 2)
    ("status" . 2)
    ("timezone" . 2)
    ("guix-revision" . 2)
    ("base-checkpoint" . 2)
    ("implementation-module" . 3)
    ("implementation-driver" . 3)
    ("implementation-launcher" . 3)
    ("evaluation-input" . 3)
    ("channels" . 3)
    ("review-input" . 3)
    ("os-source" . 3)
    ("profile" . 2)
    ("current" . 6)
    ("booted" . 3)
    ("home-profile" . 6)
    ("pull-profile" . 6)
    ("candidate-generations" . 2)
    ("system-link-count" . 2)
    ("pins" . 3)
    ("installed-grub" . 3)
    ("bootcfg" . 3)
    ("bootloader" . 2)
    ("targets" . 2)
    ("default-entry" . 2)
    ("timeout" . 2)
    ("resolution" . 3)
    ("gfxmodes" . 5)
    ("keyboard" . 5)
    ("theme-image" . 2)
    ("theme-color-normal" . 3)
    ("theme-color-highlight" . 3)
    ("terminal-outputs" . 2)
    ("terminal-inputs" . 2)
    ("serial" . 3)
    ("device-tree-support" . 2)
    ("extra-initrd" . 2)
    ("static-menu-count" . 2)))

(define (fail format-string . arguments)
  (throw 'sk-retained-bootcfg
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply fail format-string arguments)))

(define (safe-field? value)
  (and (string? value)
       (not (string-null? value))
       (not (string-index value #\nul))
       (not (string-index value #\newline))
       (not (string-index value #\return))))

(define (read-lines file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((line (get-line port))
                 (result '()))
        (if (eof-object? line)
            (reverse result)
            (loop (get-line port) (cons line result)))))))

(define (split-tab line)
  (string-split line #\tab))

(define (sk:read-stage-spec file)
  "Read FILE as a strict, tab-separated stage specification."
  (ensure (and (string? file) (absolute-file-name? file))
          "stage specification path is not absolute: ~s" file)
  (ensure (eq? 'regular (stat:type (stat file)))
          "stage specification is not a regular file: ~a" file)
  (let ((records
         (map (lambda (line)
                (ensure (and (not (string-null? line))
                             (not (string-prefix? "#" line)))
                        "blank and comment lines are forbidden in the stage specification")
                (let ((fields (split-tab line)))
                  (ensure (every safe-field? fields)
                          "unsafe stage-specification field in: ~s" line)
                  fields))
              (read-lines file))))
    (ensure (pair? records) "stage specification is empty")
    records))

(define (sk:record-values records key)
  "Return all records in RECORDS whose first field equals KEY."
  (filter (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          records))

(define* (sk:single-record records key #:optional field-count)
  "Return the sole KEY record, optionally requiring FIELD-COUNT fields."
  (let ((matches (sk:record-values records key)))
    (ensure (= (length matches) 1)
            "stage specification requires exactly one ~a record" key)
    (let ((record (car matches)))
      (when field-count
        (ensure (= (length record) field-count)
                "~a record requires exactly ~a fields"
                key field-count))
      record)))

(define (decimal-string->number value label)
  (let ((number (string->number value 10)))
    (ensure (and number
                 (integer? number)
                 (>= number 0)
                 (string=? value (number->string number)))
            "invalid ~a decimal: ~s" label value)
    number))

(define (hex-sha256? value)
  (and (= (string-length value) 64)
       (every (lambda (character)
                (or (char-numeric? character)
                    (and (char>=? character #\a)
                         (char<=? character #\f))))
              (string->list value))))

(define (generation-list value)
  (let ((parts (string-split value #\,)))
    (ensure (pair? parts) "generation list is empty")
    (let ((numbers
           (map (lambda (part)
                  (decimal-string->number part "generation"))
                parts)))
      (ensure (= (length numbers) (length (delete-duplicates numbers)))
              "generation list contains duplicates")
      numbers)))

(define (retained-record<? left right)
  (> (decimal-string->number (list-ref left 1) "retained generation")
     (decimal-string->number (list-ref right 1) "retained generation")))

(define (sk:retained-generations records)
  "Return retained generations from RECORDS, newest first."
  (map (lambda (record)
         (ensure (= (length record) 6)
                 "retained record requires exactly six fields")
         (decimal-string->number (list-ref record 1)
                                 "retained generation"))
       (sort (sk:record-values records "retained") retained-record<?)))

(define (sk:assert-stage-spec records)
  "Validate the closed stage-only protocol in RECORDS."
  (for-each
   (lambda (record)
     (ensure (or (assoc (car record) %single-record-fields)
                 (string=? (car record) "retained"))
             "unknown stage-specification record: ~a" (car record)))
   records)
  (for-each
   (lambda (field)
     (sk:single-record records (car field) (cdr field)))
   %single-record-fields)
  (ensure (string=? (cadr (sk:single-record records "schema" 2))
                    %schema)
          "unsupported stage specification schema")
  (ensure (string=? (cadr (sk:single-record records "mode" 2))
                    "STAGE-ONLY")
          "stage specification mode must be STAGE-ONLY")
  (ensure (string=? (cadr (sk:single-record records "authorization" 2))
                    "NOT-GRANTED")
          "stage specification authorization must be NOT-GRANTED")
  (ensure (string=? (cadr (sk:single-record records "status" 2))
                    "REVIEW-ONLY")
          "stage specification status must be REVIEW-ONLY")
  (ensure (string=? (cadr (sk:single-record records "timezone" 2))
                    "America/New_York")
          "stage specification timezone changed")
  (ensure (string=? (cadr (sk:single-record records "theme-image" 2))
                    "PRESENT")
          "stage specification theme-image policy changed")
  (ensure (member (cadr
                   (sk:single-record records "device-tree-support" 2))
                  '("TRUE" "FALSE"))
          "invalid device-tree-support policy")
  (for-each
   (lambda (pair)
     (let ((value (cadr (sk:single-record records (car pair) 2))))
       (ensure (and (= (string-length value) (cdr pair))
                    (every (lambda (character)
                             (or (char-numeric? character)
                                 (and (char>=? character #\a)
                                      (char<=? character #\f))))
                           (string->list value)))
               "invalid ~a hexadecimal identifier" (car pair))))
   '(("guix-revision" . 40)
     ("base-checkpoint" . 40)))
  (for-each
   (lambda (binding)
     (let ((record (sk:single-record records (car binding) 3)))
       (ensure (string=? (list-ref record 1) (cdr binding))
               "~a path must be ~a" (car binding) (cdr binding))
       (ensure (hex-sha256? (list-ref record 2))
               "invalid SHA256 in ~a record" (car binding))))
   %fixed-repository-inputs)
  (let ((source (sk:single-record records "os-source" 3))
        (channels (sk:single-record records "channels" 3))
        (review (sk:single-record records "review-input" 3))
        (current (sk:single-record records "current" 6))
        (booted (sk:single-record records "booted" 3))
        (pins (sk:single-record records "pins" 3))
        (grub (sk:single-record records "installed-grub" 3))
        (bootcfg (sk:single-record records "bootcfg" 3)))
    (for-each
     (lambda (pair)
       (ensure (hex-sha256? (cadr pair))
               "invalid SHA256 in ~a record" (car pair)))
     `(("channels" ,(list-ref channels 2))
       ("review-input" ,(list-ref review 2))
       ("os-source" ,(list-ref source 2))
       ("current" ,(list-ref current 4))
       ("pins" ,(list-ref pins 2))
       ("installed-grub" ,(list-ref grub 2))))
    (ensure (absolute-file-name? (list-ref current 2))
            "current generation link is not absolute")
    (ensure (string-prefix? "/gnu/store/" (list-ref current 3))
            "current System is not a store item")
    (decimal-string->number (list-ref current 1) "current generation")
    (decimal-string->number (list-ref current 5) "current link timestamp")
    (ensure (absolute-file-name? (list-ref booted 1))
            "booted-System link is not absolute")
    (ensure (string=? (list-ref booted 2) (list-ref current 3))
            "booted System differs from accepted current System")
    (ensure (absolute-file-name? (list-ref bootcfg 1))
            "bootcfg root is not absolute")
    (ensure (string-suffix? "-grub.cfg" (list-ref bootcfg 2))
            "bootcfg target is not a GRUB store item"))
  (for-each
   (lambda (key)
     (let ((profile-record (sk:single-record records key 6)))
       (ensure (absolute-file-name? (list-ref profile-record 1))
               "~a pointer is not absolute" key)
       (decimal-string->number (list-ref profile-record 2)
                               (string-append key " generation"))
       (ensure (absolute-file-name? (list-ref profile-record 3))
               "~a generation link is not absolute" key)
       (ensure (string-prefix? "/gnu/store/" (list-ref profile-record 4))
               "~a current target is not a store item" key)
       (decimal-string->number (list-ref profile-record 5)
                               (string-append key " link count"))))
   '("home-profile" "pull-profile"))
  (let* ((retained (sk:record-values records "retained"))
         (retained-numbers (sk:retained-generations records))
         (candidates
          (generation-list
           (cadr (sk:single-record records "candidate-generations" 2))))
         (expected-count
          (decimal-string->number
           (cadr (sk:single-record records "system-link-count" 2))
           "System link count"))
         (current-number
          (decimal-string->number
           (cadr (sk:single-record records "current" 6))
           "current generation"))
         (profile (cadr (sk:single-record records "profile" 2)))
         (current-record (sk:single-record records "current" 6)))
    (ensure (absolute-file-name? profile)
            "System profile path is not absolute")
    (ensure (pair? retained) "stage specification has no retained generations")
    (ensure (= (length retained-numbers)
               (length (delete-duplicates retained-numbers)))
            "retained generation list contains duplicates")
    (for-each
     (lambda (record)
       (ensure (= (length record) 6)
               "retained record requires exactly six fields")
       (ensure (absolute-file-name? (list-ref record 2))
               "retained generation link is not absolute")
       (ensure (string-prefix? "/gnu/store/" (list-ref record 3))
               "retained System is not a store item")
       (ensure (hex-sha256? (list-ref record 4))
               "retained parameters SHA256 is invalid")
       (decimal-string->number (list-ref record 5)
                               "retained link timestamp"))
     retained)
    (ensure (string=? (list-ref current-record 2)
                      (format #f "~a-~a-link" profile current-number))
            "current generation link does not match profile and generation")
    (for-each
     (lambda (record)
       (let ((number
              (decimal-string->number (list-ref record 1)
                                      "retained generation")))
         (ensure (string=? (list-ref record 2)
                           (format #f "~a-~a-link" profile number))
                 "retained generation link does not match profile and generation")))
     retained)
    (ensure (not (member current-number retained-numbers))
            "current generation leaked into old retained entries")
    (ensure (not (member current-number candidates))
            "current generation leaked into held candidates")
    (ensure (null? (lset-intersection = retained-numbers candidates))
            "retained and candidate generation sets overlap")
    (ensure (= expected-count
               (+ 1 (length retained-numbers) (length candidates)))
            "System link count does not equal current + retained + candidates"))
  records)

(define (sk:file-sha256 file)
  "Return FILE's lowercase SHA256 hexadecimal digest."
  (bytevector->base16-string (file-sha256 file)))

(define (link-name-without-leaf-resolution value relative-to)
  (let* ((absolute
          (if (absolute-file-name? value)
              value
              (string-append (dirname relative-to) "/" value)))
         (leaf (basename absolute)))
    (and (not (member leaf '("." "..")))
         (string-append (canonicalize-path (dirname absolute))
                        "/"
                        leaf))))

(define (sk:symlink-points-to-link? path expected)
  "Return true when symlink PATH names the exact EXPECTED link.

Relative link text is normalized against PATH's directory, but EXPECTED's
final component is deliberately not dereferenced.  This distinguishes two
generation links that happen to resolve to the same immutable store item."
  (catch 'system-error
    (lambda ()
      (and (eq? 'symlink (stat:type (lstat path)))
           (let ((actual
                  (link-name-without-leaf-resolution (readlink path) path))
                 (reviewed
                  (link-name-without-leaf-resolution expected path)))
             (and actual reviewed (string=? actual reviewed)))))
    (lambda _arguments #f)))

(define (keyboard-field value)
  (if value value "-"))

(define (sk:bootcfg-configuration-tuple config)
  "Return a stable review tuple for CONFIG's relevant bootloader fields."
  (let ((loader (bootloader-configuration-bootloader config))
        (theme (bootloader-configuration-theme config))
        (layout (bootloader-configuration-keyboard-layout config)))
    `((bootloader . ,(bootloader-name loader))
      (targets . ,(bootloader-configuration-targets config))
      (default-entry . ,(bootloader-configuration-default-entry config))
      (timeout . ,(bootloader-configuration-timeout config))
      (terminal-outputs
       . ,(bootloader-configuration-terminal-outputs config))
      (terminal-inputs
       . ,(bootloader-configuration-terminal-inputs config))
      (serial-unit . ,(bootloader-configuration-serial-unit config))
      (serial-speed . ,(bootloader-configuration-serial-speed config))
      (device-tree-support?
       . ,(bootloader-configuration-device-tree-support? config))
      (extra-initrd . ,(bootloader-configuration-extra-initrd config))
      (static-menu-entries
       . ,(map menu-entry->sexp
               (bootloader-configuration-menu-entries config)))
      (theme-resolution . ,(and theme (grub-theme-resolution theme)))
      (theme-gfxmodes . ,(and theme (grub-theme-gfxmode theme)))
      (theme-image-present?
       . ,(and theme (if (grub-theme-image theme) #t #f)))
      (theme-color-normal . ,(and theme (grub-theme-color-normal theme)))
      (theme-color-highlight
       . ,(and theme (grub-theme-color-highlight theme)))
      (keyboard-name . ,(and layout (keyboard-layout-name layout)))
      (keyboard-variant
       . ,(and layout (keyboard-layout-variant layout)))
      (keyboard-model . ,(and layout (keyboard-layout-model layout)))
      (keyboard-options
       . ,(and layout (keyboard-layout-options layout))))))

(define (sk:validate-bootloader-configuration config records)
  "Fail unless CONFIG matches the exact bootloader contract in RECORDS."
  (let* ((loader (bootloader-configuration-bootloader config))
         (theme (bootloader-configuration-theme config))
         (layout (bootloader-configuration-keyboard-layout config))
         (keyboard (sk:single-record records "keyboard" 5))
         (resolution (sk:single-record records "resolution" 3))
         (expected-resolution
          (cons (decimal-string->number (list-ref resolution 1)
                                        "theme width")
                (decimal-string->number (list-ref resolution 2)
                                        "theme height")))
         (expected-gfxmodes
          (cdr (sk:single-record records "gfxmodes" 5)))
         (normal (sk:single-record records "theme-color-normal" 3))
         (highlight
          (sk:single-record records "theme-color-highlight" 3))
         (serial (sk:single-record records "serial" 3)))
    (ensure (eq? loader grub-efi-bootloader)
            "source bootloader is not the pinned GRUB EFI object")
    (ensure (string=? (symbol->string (bootloader-name loader))
                      (cadr (sk:single-record records "bootloader" 2)))
            "bootloader name drift")
    (ensure (equal? (bootloader-configuration-targets config)
                    (list (cadr (sk:single-record records "targets" 2))))
            "bootloader target drift")
    (ensure (= (bootloader-configuration-default-entry config)
               (decimal-string->number
                (cadr (sk:single-record records "default-entry" 2))
                "default entry"))
            "bootloader default-entry drift")
    (ensure (= (bootloader-configuration-timeout config)
               (decimal-string->number
                (cadr (sk:single-record records "timeout" 2))
                "timeout"))
            "bootloader timeout drift")
    (ensure (equal? (bootloader-configuration-terminal-outputs config)
                    (map string->symbol
                         (string-split
                          (cadr
                           (sk:single-record records
                                             "terminal-outputs" 2))
                          #\,)))
            "bootloader terminal-output drift")
    (let ((expected-inputs
           (cadr (sk:single-record records "terminal-inputs" 2))))
      (ensure
       (equal? (bootloader-configuration-terminal-inputs config)
               (if (string=? expected-inputs "-")
                   '()
                   (map string->symbol (string-split expected-inputs #\,))))
       "bootloader terminal-input drift"))
    (ensure (= (length (bootloader-configuration-menu-entries config))
               (decimal-string->number
                (cadr (sk:single-record records "static-menu-count" 2))
                "static menu count"))
            "source static menu-entry count drift")
    (ensure (and theme (equal? (grub-theme-resolution theme)
                               expected-resolution))
            "GRUB theme resolution drift")
    (ensure (equal? (grub-theme-gfxmode theme) expected-gfxmodes)
            "GRUB theme gfxmode drift")
    (ensure (and (string=? (cadr
                            (sk:single-record records "theme-image" 2))
                           "PRESENT")
                 (grub-theme-image theme))
            "GRUB theme image drift")
    (ensure (equal? (grub-theme-color-normal theme)
                    `((fg . ,(string->symbol (list-ref normal 1)))
                      (bg . ,(string->symbol (list-ref normal 2)))))
            "GRUB normal-color drift")
    (ensure (equal? (grub-theme-color-highlight theme)
                    `((fg . ,(string->symbol (list-ref highlight 1)))
                      (bg . ,(string->symbol (list-ref highlight 2)))))
            "GRUB highlight-color drift")
    (ensure (and layout
                 (string=? (keyboard-layout-name layout)
                           (list-ref keyboard 1))
                 (string=? (keyboard-field
                            (keyboard-layout-variant layout))
                           (list-ref keyboard 2))
                 (string=? (keyboard-field
                            (keyboard-layout-model layout))
                           (list-ref keyboard 3))
                 (equal? (keyboard-layout-options layout)
                         (if (string=? (list-ref keyboard 4) "-")
                             '()
                             (string-split (list-ref keyboard 4) #\,))))
            "bootloader keyboard-layout drift")
    (ensure
     (and (equal? (bootloader-configuration-serial-unit config)
                  (if (string=? (list-ref serial 1) "-")
                      #f
                      (decimal-string->number (list-ref serial 1)
                                              "serial unit")))
          (equal? (bootloader-configuration-serial-speed config)
                  (if (string=? (list-ref serial 2) "-")
                      #f
                      (decimal-string->number (list-ref serial 2)
                                              "serial speed"))))
     "bootloader serial policy drift")
    (ensure
     (eq? (bootloader-configuration-device-tree-support? config)
          (string=? (cadr
                     (sk:single-record records
                                       "device-tree-support" 2))
                    "TRUE"))
     "bootloader device-tree policy drift")
    (let ((expected-extra
           (cadr (sk:single-record records "extra-initrd" 2))))
      (ensure
       (equal? (bootloader-configuration-extra-initrd config)
               (if (string=? expected-extra "-") #f expected-extra))
       "bootloader extra-initrd drift"))
    (sk:bootcfg-configuration-tuple config)))

(define (sk:make-retained-bootcfg config current-params old-params)
  "Return an inert computed GRUB file using CONFIG and accepted PARAMETERS."
  (let* ((loader (bootloader-configuration-bootloader config))
         (source-menu
          (map menu-entry->sexp
               (bootloader-configuration-menu-entries config)))
         (accepted-menu
          (map menu-entry->sexp
               (boot-parameters-bootloader-menu-entries current-params))))
    (ensure (equal? source-menu accepted-menu)
            "source and accepted-current static menu entries differ")
    (ensure (pair? old-params) "retained old parameter list is empty")
    ((bootloader-configuration-file-generator loader)
     config
     (list (boot-parameters->menu-entry current-params))
     #:locale (boot-parameters-locale current-params)
     #:store-crypto-devices
     (boot-parameters-store-crypto-devices current-params)
     #:store-directory-prefix
     (boot-parameters-store-directory-prefix current-params)
     #:old-entries (map boot-parameters->menu-entry old-params))))

(define (sk:build-retained-bootcfg bootcfg)
  "Lower and realize BOOTCFG, returning its immutable output path."
  (with-store store
    (run-with-store store
      (mlet* %store-monad ((drv (lower-object bootcfg)))
        (mbegin %store-monad
          (built-derivations (list drv))
          (return (derivation->output-path drv)))))))

(define (count-substring text needle)
  (let loop ((start 0)
             (count 0))
    (let ((position (string-contains text needle start)))
      (if position
          (loop (+ position (string-length needle)) (+ count 1))
          count))))

(define (regexp-substrings text pattern group)
  (let ((regexp (make-regexp pattern)))
    (let loop ((start 0)
               (result '()))
      (let ((match (regexp-exec regexp text start)))
        (if match
            (let ((end (match:end match)))
              (ensure (> end start) "zero-width internal regular expression")
              (loop end (cons (match:substring match group) result)))
            (reverse result))))))

(define (compress-adjacent values)
  (reverse
   (fold (lambda (value result)
           (if (and (pair? result) (equal? value (car result)))
               result
               (cons value result)))
         '()
         values)))

(define (old-menu-blocks body)
  (let ((starts
         (let ((regexp
                (make-regexp
                 "menuentry \"[^\"]* \\(#([0-9]+), [^\"]*\\)\" \\{")))
           (let loop ((start 0)
                      (result '()))
             (let ((match (regexp-exec regexp body start)))
               (if match
                   (loop (match:end match)
                         (cons (cons
                                (decimal-string->number
                                 (match:substring match 1)
                                 "GRUB generation")
                                (match:start match))
                               result))
                   (reverse result)))))))
    (ensure (pair? starts) "old GRUB submenu contains no System entries")
    (let loop ((remaining starts)
               (result '()))
      (if (null? remaining)
          (reverse result)
          (let* ((current (car remaining))
                 (generation (car current))
                 (start (cdr current))
                 (rest (cdr remaining))
                 (end (if (null? rest)
                          (string-length body)
                          (cdar rest))))
            (loop rest
                  (cons (cons generation (substring body start end))
                        result)))))))

(define (sk:project-retained-grub installed retained)
  "Project INSTALLED GRUB bytes to RETAINED old generations, preserving bytes."
  (ensure (= (length retained) (length (delete-duplicates retained)))
          "retained projection contains duplicate generations")
  (let ((open-position (string-contains installed %old-submenu-open)))
    (ensure open-position "installed GRUB lacks the old-configurations submenu")
    (let* ((body-start (+ open-position (string-length %old-submenu-open)))
           (close-position
            (string-contains installed %old-submenu-close body-start)))
      (ensure close-position
              "installed GRUB lacks the reviewed old-submenu closing boundary")
      (let* ((prefix (substring installed 0 body-start))
             (body (substring installed body-start close-position))
             (suffix (substring installed close-position))
             (blocks (old-menu-blocks body))
             (available (map car blocks)))
        (ensure (= (length available)
                   (length (delete-duplicates available)))
                "installed GRUB has duplicate old generation entries")
        (for-each
         (lambda (generation)
           (ensure (member generation available)
                   "installed GRUB lacks retained generation ~a" generation))
         retained)
        (string-append
         prefix
         (string-concatenate
          (map (lambda (generation)
                 (cdr (assoc generation blocks)))
               retained))
         suffix)))))

(define (sk:validate-retained-grub text current-system retained)
  "Validate retained-only GRUB TEXT and return a compact semantic tuple."
  (ensure (and (string? current-system)
               (string-prefix? "/gnu/store/" current-system)
               (string-suffix? "-system" current-system))
          "accepted current System path is invalid")
  (ensure (= (count-substring text current-system) 2)
          "accepted current System must occur exactly twice")
  (ensure (= (count-substring
              text (string-append "gnu.system=" current-system))
             1)
          "accepted current gnu.system argument must occur exactly once")
  (ensure (= (count-substring
              text (string-append "gnu.load=" current-system "/boot"))
             1)
          "accepted current gnu.load argument must occur exactly once")
  (ensure (= (count-substring text %old-submenu-open) 1)
          "retained GRUB must contain one old-configurations submenu")
  (let* ((submenu-position (string-contains text %old-submenu-open))
         (body-start (+ submenu-position (string-length %old-submenu-open)))
         (close-position
          (string-contains text %old-submenu-close body-start)))
    (ensure close-position
            "retained GRUB lacks the reviewed old-submenu closing boundary")
    (let* ((main-prefix (substring text 0 submenu-position))
           (submenu-body (substring text body-start close-position))
           (raw-generations
            (map (lambda (value)
                   (decimal-string->number value "rendered generation"))
                 (regexp-substrings
                  text
                  "/var/guix/profiles/system-([0-9]+)-link"
                  1)))
           (rendered-order (compress-adjacent raw-generations)))
      (ensure (= (length raw-generations) (* 2 (length retained)))
              "retained GRUB has an unexpected System-link occurrence count")
      (ensure (equal? rendered-order retained)
              "retained GRUB generation order drift: ~s" rendered-order)
      (ensure (= (count-substring main-prefix current-system) 2)
              "accepted current System is not confined before the old submenu")
      (ensure (= (count-substring
                  main-prefix (string-append "gnu.system=" current-system))
                 1)
              "accepted current gnu.system argument is not in the main entry")
      (ensure (= (count-substring
                  main-prefix
                  (string-append "gnu.load=" current-system "/boot"))
                 1)
              "accepted current gnu.load argument is not in the main entry")
      (for-each
       (lambda (generation)
         (let ((link
                (format #f "/var/guix/profiles/system-~a-link" generation))
               (label-fragment (format #f " (#~a, " generation)))
           (ensure (= (count-substring text link) 2)
                   "generation ~a link must occur exactly twice" generation)
           (ensure (= (count-substring submenu-body link) 2)
                   "generation ~a links are not confined to the old submenu"
                   generation)
           (ensure (= (count-substring
                       submenu-body (string-append "gnu.system=" link))
                      1)
                   "generation ~a gnu.system argument is not in the old submenu"
                   generation)
           (ensure (= (count-substring
                       submenu-body (string-append "gnu.load=" link "/boot"))
                      1)
                   "generation ~a gnu.load argument is not in the old submenu"
                   generation)
           (ensure (= (count-substring submenu-body label-fragment) 1)
                   "generation ~a label is not in the old submenu" generation)))
       retained)
      `((current-system . ,current-system)
        (current-occurrences . 2)
        (retained-generations . ,retained)
        (retained-link-occurrences . ,(length raw-generations))
        (old-submenu-count . 1)))))
