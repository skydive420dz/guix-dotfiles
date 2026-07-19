;;; Stage-only retained System GRUB builder.

(use-modules (gnu bootloader)
             (gnu system)
             (guix scripts system)
             (ice-9 format)
             (ice-9 ftw)
             (ice-9 regex)
             (ice-9 textual-ports)
             (sk system-retained-bootcfg)
             (srfi srfi-1))

(define %program "guix-system-retained-bootcfg")
(define %repository-input-records
  '("implementation-module"
    "implementation-driver"
    "implementation-launcher"
    "evaluation-input"
    "os-source"
    "channels"
    "review-input"
    "pins"))

(define (fail format-string . arguments)
  (format (current-error-port)
          "~a: FAIL: ~a~%"
          %program
          (apply format #f format-string arguments))
  (exit 1))

(define (guard thunk)
  (catch 'sk-retained-bootcfg
    thunk
    (lambda (_key message)
      (fail "~a" message))))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply fail format-string arguments)))

(define (commit-id? value)
  (and (= (string-length value) 40)
       (every (lambda (character)
                (or (char-numeric? character)
                    (and (char>=? character #\a)
                         (char<=? character #\f))))
              (string->list value))))

(define (read-text file)
  (call-with-input-file file get-string-all))

(define (record records key count)
  (sk:single-record records key count))

(define (canonical-repository value)
  (ensure (absolute-file-name? value)
          "repository path is not absolute: ~s" value)
  (let ((canonical (canonicalize-path value)))
    (ensure (eq? 'directory (stat:type (stat canonical)))
            "repository path is not a directory: ~a" canonical)
    canonical))

(define (repository-file repo relative)
  (ensure (and (not (absolute-file-name? relative))
               (not (string-contains relative ".."))
               (not (string-contains relative "//")))
          "unsafe repository-relative path: ~s" relative)
  (string-append repo "/" relative))

(define (readlink= path expected label)
  (ensure (eq? 'symlink (stat:type (lstat path)))
          "~a is not a symlink: ~a" label path)
  (let ((actual (readlink path)))
    (ensure (string=? actual expected)
            "~a target drift: expected ~a, got ~a"
            label expected actual)))

(define (mtime= path expected label)
  (let ((actual (stat:mtime (lstat path))))
    (ensure (= actual expected)
            "~a timestamp drift: expected ~a, got ~a"
            label expected actual)))

(define (hash= path expected label)
  (ensure (eq? 'regular (stat:type (stat path)))
          "~a is not a regular file: ~a" label path)
  (let ((actual (sk:file-sha256 path)))
    (ensure (string=? actual expected)
            "~a SHA256 drift: expected ~a, got ~a"
            label expected actual)))

(define (repository-hash= repo input-record)
  (let* ((key (car input-record))
         (path
          (repository-file repo (list-ref input-record 1)))
         (expected (list-ref input-record 2)))
    (ensure (eq? 'regular (stat:type (lstat path)))
            "~a is not a repository-owned regular file: ~a" key path)
    (hash= path expected key)))

(define (repository-input-snapshot records repo)
  (map (lambda (key)
         (let* ((input-record (record records key 3))
                (path
                 (repository-file repo (list-ref input-record 1))))
           (list key
                 (list-ref input-record 1)
                 (sk:file-sha256 path))))
       %repository-input-records))

(define (generation-number file)
  (let ((match
         (regexp-exec
          (make-regexp "^system-([0-9]+)-link$")
          file)))
    (and match
         (string->number (match:substring match 1) 10))))

(define (system-link-snapshot profile)
  (let* ((directory (dirname profile))
         (names (scandir directory generation-number))
         (records
          (map (lambda (name)
                 (let ((number (generation-number name))
                       (path (string-append directory "/" name)))
                   (list number
                         (readlink path)
                         (stat:mtime (lstat path)))))
               names)))
    (sort records (lambda (left right) (< (car left) (car right))))))

(define (profile-pointer-snapshot path)
  (and (file-exists? path)
       (list path
             (if (eq? 'symlink (stat:type (lstat path)))
                 (readlink path)
                 "-")
             (canonicalize-path path))))

(define (numbered-profile-links pointer)
  (let* ((directory (dirname pointer))
         (base (basename pointer))
         (regexp
          (make-regexp
           (string-append "^" base "-[0-9]+-link$"))))
    (sort
     (map (lambda (name)
            (let ((path (string-append directory "/" name)))
              (list name (readlink path) (stat:mtime (lstat path)))))
          (scandir directory
                   (lambda (name) (regexp-exec regexp name))))
     (lambda (left right) (string<? (car left) (car right))))))

(define (validate-secondary-profile profile-record label)
  (let ((pointer (list-ref profile-record 1))
        (generation (list-ref profile-record 2))
        (generation-path (list-ref profile-record 3))
        (target (list-ref profile-record 4))
        (expected-count (string->number (list-ref profile-record 5) 10)))
    (ensure (sk:symlink-points-to-link? pointer generation-path)
            "~a profile pointer does not name exact link ~a"
            label generation-path)
    (readlink= generation-path target
               (string-append label " generation " generation))
    (ensure (= (length (numbered-profile-links pointer)) expected-count)
            "~a generation-link count drift" label)))

(define (surface-snapshot records repo)
  (let* ((current (record records "current" 6))
         (booted (record records "booted" 3))
         (grub (record records "installed-grub" 3))
         (bootcfg (record records "bootcfg" 3))
         (home (record records "home-profile" 6))
         (pull (record records "pull-profile" 6))
         (profile (cadr (record records "profile" 2))))
    `((repository-inputs . ,(repository-input-snapshot records repo))
      (installed-grub . ,(sk:file-sha256 (list-ref grub 1)))
      (bootcfg . ,(readlink (list-ref bootcfg 1)))
      (system-profile . ,(readlink profile))
      (system-links . ,(system-link-snapshot profile))
      (booted . ,(canonicalize-path (list-ref booted 1)))
      (home-profile . ,(profile-pointer-snapshot (list-ref home 1)))
      (home-links . ,(numbered-profile-links (list-ref home 1)))
      (pull-profile . ,(profile-pointer-snapshot (list-ref pull 1)))
      (pull-links . ,(numbered-profile-links (list-ref pull 1)))
      (current-link . ,(readlink (list-ref current 2))))))

(define (validate-stage-state records repo)
  (let* ((profile (cadr (record records "profile" 2)))
         (current (record records "current" 6))
         (booted (record records "booted" 3))
         (grub (record records "installed-grub" 3))
         (bootcfg (record records "bootcfg" 3))
         (home (record records "home-profile" 6))
         (pull (record records "pull-profile" 6))
         (retained (sk:record-values records "retained"))
         (retained-numbers (sk:retained-generations records))
         (candidate-numbers
          (map (lambda (value) (string->number value 10))
               (string-split
                (cadr (record records "candidate-generations" 2))
                #\,)))
         (current-number (string->number (list-ref current 1) 10))
         (expected-numbers
          (sort (append (list current-number)
                        retained-numbers
                        candidate-numbers)
                <))
         (snapshot (system-link-snapshot profile))
         (actual-numbers (map car snapshot)))
    (for-each
     (lambda (key)
       (repository-hash= repo (record records key 3)))
     %repository-input-records)
    (ensure (string=? (or (getenv "SK_GUIX_REVISION") "")
                      (cadr (record records "guix-revision" 2)))
            "running Guix revision differs from the stage specification")
    (ensure (eq? 'symlink (stat:type (lstat profile)))
            "System profile pointer is not a symlink")
    (readlink= profile (list-ref current 2) "System profile pointer")
    (readlink= (list-ref current 2)
               (list-ref current 3)
               "accepted current generation")
    (mtime= (list-ref current 2)
            (string->number (list-ref current 5) 10)
            "accepted current generation")
    (hash= (string-append (list-ref current 2) "/parameters")
           (list-ref current 4)
           "accepted current parameters")
    (ensure (string=? (canonicalize-path (list-ref booted 1))
                      (list-ref booted 2))
            "booted System drift")
    (validate-secondary-profile home "Home")
    (validate-secondary-profile pull "Pull")
    (for-each
     (lambda (retained-record)
       (let ((generation (list-ref retained-record 1))
             (generation-path (list-ref retained-record 2))
             (target (list-ref retained-record 3))
             (parameters-sha (list-ref retained-record 4))
             (timestamp (string->number (list-ref retained-record 5) 10)))
         (readlink= generation-path target
                    (string-append "retained generation " generation))
         (mtime= generation-path timestamp
                 (string-append "retained generation " generation))
         (hash= (string-append generation-path "/parameters")
                parameters-sha
                (string-append "retained parameters " generation))))
     retained)
    (ensure (= (length snapshot)
               (string->number
                (cadr (record records "system-link-count" 2))
                10))
            "System generation-link count drift")
    (ensure (equal? actual-numbers expected-numbers)
            "System generation-number set drift")
    (hash= (list-ref grub 1) (list-ref grub 2) "installed GRUB")
    (readlink= (list-ref bootcfg 1)
               (list-ref bootcfg 2)
               "live bootcfg root")
    (surface-snapshot records repo)))

(define (assert-parameter-contract config current old retained)
  (let ((source-menu
         (map menu-entry->sexp
              (bootloader-configuration-menu-entries config)))
        (accepted-menu
         (map menu-entry->sexp
              (boot-parameters-bootloader-menu-entries current))))
    (ensure (equal? source-menu accepted-menu)
            "source and accepted-current static menu entries differ")
    (ensure (= (length old) (length retained))
            "retained boot-parameter count drift")
    (ensure (eq? (boot-parameters-bootloader-name current) 'grub-efi)
            "accepted current parameters do not name grub-efi")
    (for-each
     (lambda (params generation)
       (ensure (eq? (boot-parameters-bootloader-name params) 'grub-efi)
               "generation ~a parameters do not name grub-efi" generation)
       (ensure (string-contains
                (boot-parameters-label params)
                (format #f " (#~a, " generation))
               "generation ~a boot label drift" generation))
     old retained)))

(define (stage spec-file repository)
  (ensure (not (= (getuid) 0))
          "stage action refuses uid 0")
  (let* ((repo (canonical-repository repository))
         (records (guard
                   (lambda ()
                     (sk:assert-stage-spec
                      (sk:read-stage-spec spec-file)))))
         (timezone (cadr (record records "timezone" 2)))
         (source-record (record records "os-source" 3))
         (source (repository-file repo (list-ref source-record 1)))
         (profile (cadr (record records "profile" 2)))
         (current-record (record records "current" 6))
         (current-system (list-ref current-record 3))
         (source-checkpoint
          (or (getenv "SK_D2A_SOURCE_CHECKPOINT") ""))
         (retained (sk:retained-generations records))
         (before (validate-stage-state records repo)))
    (ensure (commit-id? source-checkpoint)
            "D2a source checkpoint is missing or invalid")
    (setenv "TZ" timezone)
    (tzset)
    (let* ((os (read-operating-system source))
           (config (operating-system-bootloader os)))
      (guard
       (lambda ()
         (sk:validate-bootloader-configuration config records)))
      (let* ((current (read-boot-parameters-file current-system))
           (old (profile-boot-parameters profile retained)))
        (assert-parameter-contract config current old retained)
        (let* ((bootcfg
              (guard
               (lambda ()
                 (sk:make-retained-bootcfg config current old))))
             (output
              (guard
               (lambda ()
                 (sk:build-retained-bootcfg bootcfg))))
             (staged (read-text output))
             (installed-path
              (list-ref (record records "installed-grub" 3) 1))
             (installed (read-text installed-path))
             (projection
              (guard
               (lambda ()
                 (sk:project-retained-grub installed retained))))
             (semantics
              (guard
               (lambda ()
                 (sk:validate-retained-grub
                  staged current-system retained))))
             (after (validate-stage-state records repo)))
        (ensure (string=? staged projection)
                "generated GRUB differs from the retained-only byte projection")
        (ensure (equal? before after)
                "reviewed live surfaces changed during stage build")
        (format #t "schema\tp5.2b-retained-bootcfg-result/v1~%")
        (format #t "mode\tSTAGE-ONLY~%")
        (format #t "authorization\tNOT-GRANTED~%")
        (format #t "source-checkpoint\t~a~%" source-checkpoint)
        (format #t "guix-revision\t~a~%"
                (cadr (record records "guix-revision" 2)))
        (format #t "source-sha256\t~a~%"
                (list-ref source-record 2))
        (for-each
         (lambda (key)
           (let ((input-record (record records key 3)))
             (format #t "~a-sha256\t~a~%"
                     key
                     (list-ref input-record 2))))
         '("implementation-module"
           "implementation-driver"
           "implementation-launcher"
           "evaluation-input"))
        (format #t "output\t~a~%" output)
        (format #t "output-sha256\t~a~%" (sk:file-sha256 output))
        (format #t "output-bytes\t~a~%" (stat:size (stat output)))
        (format #t "projection-equals-output\tTRUE~%")
        (format #t "retained-generations\t~a~%"
                (string-join (map number->string retained) ","))
        (format #t "semantic-result\tPASS~%")
        (format #t "byte-projection-result\tPASS~%")
        (format #t "reviewed-surfaces-pre-post\tIDENTICAL~%")
        (format #t "store-effect\tIMMUTABLE-BUILD-OUTPUT-REALIZED~%")
        (format #t "configuration-tuple\t")
        (write (sk:bootcfg-configuration-tuple config))
        (newline)
        (format #t "semantic-tuple\t")
        (write semantics)
          (newline))))))

(define (usage)
  (format (current-error-port)
          "usage: ~a stage ABSOLUTE-SPEC ABSOLUTE-REPOSITORY~%"
          %program)
  (exit 64))

(let ((arguments (cdr (command-line))))
  (if (and (= (length arguments) 3)
           (string=? (car arguments) "stage"))
      (stage (cadr arguments) (caddr arguments))
      (usage)))
