;;; Pure bounded review-manifest protocol for P5.2b-D4c.1a.

(define-module (sk system-pruning-live-manifest)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (ice-9 rdelim)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:export (sk:live-manifest-error-key
            sk:live-manifest-schema
            sk:live-manifest-program-root-formula
            sk:live-manifest-recovery-namespace-formula
            sk:live-manifest-transaction-directory-formula
            sk:read-live-manifest-string
            sk:assert-live-manifest
            sk:render-live-manifest
            sk:live-manifest-text-sha256
            sk:live-manifest-records-with-key
            sk:live-manifest-single-record
            sk:live-manifest-source-inputs
            sk:live-manifest-selected-generations
            sk:live-manifest-retained-generations
            sk:live-manifest-recovery-roots))

(define sk:live-manifest-error-key
  'sk-system-pruning-live-manifest)

(define sk:live-manifest-schema
  "p5.2b-system-prune-live-manifest/v1")

;; These formulas deliberately contain no manifest digest or future store
;; target.  D4c.2 substitutes the externally published manifest SHA256 only
;; after the D4c.1 bytes have become immutable.
(define sk:live-manifest-program-root-formula
  "/var/guix/gcroots/p52b-system-prune-program-{manifest-sha256}")

(define sk:live-manifest-recovery-namespace-formula
  "/var/guix/gcroots/p52b-system-prune/{manifest-sha256}")

(define sk:live-manifest-transaction-directory-formula
  "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}")

(define %guix-base32-alphabet
  "0123456789abcdfghijklmnpqrsvwxyz")

(define %record-order
  '("schema"
    "mode"
    "status"
    "authorization"
    "host"
    "user"
    "uid"
    "capture-epoch"
    "boot-id"
    "source-checkpoint"
    "evidence-checkpoint"
    "validator-checkpoint"
    "guix-identity"
    "guile-identity"
    "source-input-policy"
    "generation-policy"
    "system-transition"
    "source-input"
    "profile"
    "generation"
    "pointer"
    "pins"
    "pin"
    "installed-grub"
    "retained-grub"
    "retained-grub-semantics"
    "old-bootcfg"
    "new-bootcfg"
    "efi-root"
    "efi-surface"
    "efi-variable-policy"
    "efi-variable"
    "efi-variable-absence"
    "program-root-formula"
    "recovery-namespace-formula"
    "transaction-directory-formula"
    "surface"
    "recovery-root"
    "selector"
    "action"
    "grant-token"
    "expected-postflight"
    "prohibition"
    "capture-result"
    "program-build"
    "lowering"
    "realization"
    "live-action"))

(define %record-shapes
  '(("schema" . 2)
    ("mode" . 2)
    ("status" . 2)
    ("authorization" . 2)
    ("host" . 2)
    ("user" . 2)
    ("uid" . 2)
    ("capture-epoch" . 2)
    ("boot-id" . 2)
    ("source-checkpoint" . 2)
    ("evidence-checkpoint" . 2)
    ("validator-checkpoint" . 2)
    ("guix-identity" . 4)
    ("guile-identity" . 3)
    ("source-input-policy" . 2)
    ("generation-policy" . 3)
    ("system-transition" . 6)
    ("source-input" . 5)
    ("profile" . 6)
    ("generation" . 8)
    ("pointer" . 5)
    ("pins" . 4)
    ("pin" . 6)
    ("installed-grub" . 7)
    ("retained-grub" . 4)
    ("retained-grub-semantics" . 6)
    ("old-bootcfg" . 4)
    ("new-bootcfg" . 6)
    ("efi-root" . 4)
    ("efi-surface" . 9)
    ("efi-variable-policy" . 5)
    ("efi-variable" . 9)
    ("efi-variable-absence" . 4)
    ("program-root-formula" . 2)
    ("recovery-namespace-formula" . 2)
    ("transaction-directory-formula" . 2)
    ("surface" . 5)
    ("recovery-root" . 5)
    ("selector" . 3)
    ("action" . 2)
    ("grant-token" . 4)
    ("expected-postflight" . 4)
    ("prohibition" . 2)
    ("capture-result" . 3)
    ("program-build" . 2)
    ("lowering" . 2)
    ("realization" . 2)
    ("live-action" . 2)))

(define %multiple-keys
  '("source-input"
    "profile"
    "generation"
    "pointer"
    "pin"
    "efi-surface"
    "efi-variable"
    "efi-variable-absence"
    "surface"
    "recovery-root"
    "action"
    "grant-token"
    "expected-postflight"
    "prohibition"))

(define %profile-order '("system" "home" "pull"))

(define %profile-spec
  '(("system" "/var/guix/profiles/system")
    ("home"
     "/var/guix/profiles/per-user/skydive420dz/guix-home")
    ("pull"
     "/var/guix/profiles/per-user/skydive420dz/current-guix")))

(define %pointer-spec
  '(("system-profile" "/var/guix/profiles/system")
    ("current-system" "/run/current-system")
    ("booted-system" "/run/booted-system")
    ("home-profile"
     "/var/guix/profiles/per-user/skydive420dz/guix-home")
    ("pull-profile"
     "/var/guix/profiles/per-user/skydive420dz/current-guix")
    ("user-current" "/home/skydive420dz/.config/guix/current")))

(define %surface-spec
  `(("transaction-base"
     "/var/guix/profiles/.p52b-system-prune-transactions")
    ("transaction-lock"
     "/var/guix/profiles/.p52b-system-prune-transactions/transaction.lock")
    ("system-lock" "/var/guix/profiles/system.lock")
    ("transaction-directory"
     ,sk:live-manifest-transaction-directory-formula)
    ("quarantine"
     "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/quarantine")
    ("journal"
     "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/journal.tsv")
    ("journal-temporary"
     "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/journal.tsv.tmp")
    ("recovery-root-base" "/var/guix/gcroots/p52b-system-prune")
    ("obsolete-program-root-directory"
     "/var/guix/gcroots/p52b-system-prune-program")
    ("direct-program-root-family"
     "/var/guix/gcroots/p52b-system-prune-program-*")
    ("recovery-namespace"
     ,sk:live-manifest-recovery-namespace-formula)
    ("grub-temporary" "/boot/grub/grub.cfg.p52b-new")
    ("bootcfg-temporary" "/var/guix/gcroots/bootcfg.p52b-new")))

(define %expected-postflight-labels
  '("system-count"
    "selected-links"
    "installed-grub"
    "bootcfg"
    "protected-surfaces"
    "efi-surfaces"
    "efi-variables"
    "transaction-base"
    "transaction-directory"
    "terminal-journal"
    "old-grub-backup"
    "quarantine"
    "journal-temporaries"
    "grub-temporary"
    "bootcfg-temporary"
    "recovery-namespace"
    "recovery-roots"
    "program-root"
    "transaction-lock"
    "system-lock"
    "temporary-roots"))

(define %prohibitions
  '("live-action"
    "root-creation"
    "transaction-mutation"
    "generation-link-mutation"
    "grub-mutation"
    "bootcfg-mutation"
    "efi-mutation"
    "gc"
    "dead-live-enumeration"
    "collection"
    "activation"
    "reconfiguration"
    "bootloader-installation"
    "profile-switch"
    "reboot"
    "unlisted-action"))

(define %efi-global-variable-guid
  "8be4df61-93ca-11d2-aa0d-00e098032b8c")

(define %efi-loader-variable-guid
  "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f")

(define %efi-fixed-variable-names
  '("BootCurrent"
    "BootOptionSupport"
    "BootOrder"
    "OsIndications"
    "Timeout"))

(define %efi-absent-variable-spec
  `(("BootNext" ,%efi-global-variable-guid)
    ("LoaderEntryOneShot" ,%efi-loader-variable-guid)))

(define %pins-path
  "guix/machines/guixpc/generation-pins.tsv")

(define %pins-header
  "# kind\tgeneration\tcanonical-store-target\trole\treason\n")

(define %pin-roles
  '("promotion-rollback"
    "preferred-rollback"
    "emergency-rollback"
    "last-known-good"))

(define (%fail format-string . arguments)
  (throw sk:live-manifest-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (safe-field? value)
  (and (string? value)
       (not (string-null? value))
       (all (lambda (character)
              (and (not (char=? character #\tab))
                   (not (char=? character #\newline))
                   (not (char=? character #\return))
                   (char>=? character #\space)))
            (string->list value))))

(define (ascii-decimal-digit? character)
  (and (char>=? character #\0)
       (char<=? character #\9)))

(define (ascii-letter? character)
  (or (and (char>=? character #\a)
           (char<=? character #\z))
      (and (char>=? character #\A)
           (char<=? character #\Z))))

(define (safe-name? value)
  (and (safe-field? value)
       (all (lambda (character)
              (or (ascii-letter? character)
                  (ascii-decimal-digit? character)
                  (memv character '(#\- #\_ #\.))))
            (string->list value))
       (not (member value '("." "..")))))

(define (decimal-string? value)
  (and (safe-field? value)
       (all ascii-decimal-digit? (string->list value))))

(define (canonical-decimal-string? value)
  (and (decimal-string? value)
       (or (string=? value "0")
           (not (char=? (string-ref value 0) #\0)))))

(define (canonical-positive-decimal-string? value)
  (and (canonical-decimal-string? value)
       (not (string=? value "0"))))

(define (hex-string? value length)
  (and (string? value)
       (= (string-length value) length)
       (all (lambda (character)
              (or (ascii-decimal-digit? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (boot-id? value)
  (and (string? value)
       (= (string-length value) 36)
       (all (lambda (position)
              (char=? (string-ref value position) #\-))
            '(8 13 18 23))
       (let ((hex
              (string-delete (lambda (character)
                               (char=? character #\-))
                             value)))
         (hex-string? hex 32))))

(define (boot-option-variable-name? value)
  (and (string? value)
       (= (string-length value) 8)
       (string-prefix? "Boot" value)
       (all (lambda (character)
              (or (ascii-decimal-digit? character)
                  (and (char>=? character #\A)
                       (char<=? character #\F))))
            (string->list (substring value 4)))))

(define (efi-variable-path name guid)
  (string-append
   "/sys/firmware/efi/efivars/"
   name
   "-"
   guid))

(define (normalized-absolute-path? path)
  (and (safe-field? path)
       (string-prefix? "/" path)
       (not (string=? path "/"))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not
        (any (lambda (component)
               (member component '("" "." "..")))
             (cdr (string-split path #\/))))))

(define (safe-relative-path? path)
  (and (safe-field? path)
       (not (string-prefix? "/" path))
       (not (string-prefix? "./" path))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not
        (any (lambda (component)
               (member component '("" "." "..")))
             (string-split path #\/)))))

(define (store-item? path suffix)
  (and (normalized-absolute-path? path)
       (string-prefix? "/gnu/store/" path)
       (let* ((name
               (substring path (string-length "/gnu/store/")))
              (dash (string-index name #\-)))
         (and dash
              (= dash 32)
              (not (string-contains name "/"))
              (> (string-length name) 33)
              (all (lambda (character)
                     (string-index %guix-base32-alphabet character))
                   (string->list (substring name 0 dash)))
              (string-suffix? suffix name)))))

(define (mode-string? value)
  (and (string? value)
       (<= 3 (string-length value) 4)
       (or (= (string-length value) 3)
           (not (char=? (string-ref value 0) #\0)))
       (all (lambda (character)
              (and (char>=? character #\0)
                   (char<=? character #\7)))
            (string->list value))))

(define (basename-string value)
  (let ((slash (string-rindex value #\/)))
    (if slash
        (substring value (+ slash 1))
        value)))

(define (relative-parent value)
  (let ((slash (string-rindex value #\/)))
    (and slash (substring value 0 slash))))

(define (relative-store-target prefix canonical)
  (string-append prefix (basename-string canonical)))

(define (canonical-guile-version? value)
  (and (safe-field? value)
       (let ((components (string-split value #\.)))
         (and (= (length components) 3)
              (canonical-positive-decimal-string? (car components))
              (all canonical-decimal-string? (cdr components))))))

(define (record-rank key)
  (list-index (lambda (candidate)
                (string=? candidate key))
              %record-order))

(define (record-shape key)
  (assoc-ref %record-shapes key))

(define (unique? values)
  (= (length values)
     (length (delete-duplicates values))))

(define (row->text row)
  (string-append (string-join row "\t") "\n"))

(define (rows->text rows)
  (string-concatenate (map row->text rows)))

(define (sk:live-manifest-text-sha256 text)
  "Return the lowercase SHA256 digest of UTF-8 TEXT."
  (ensure (string? text) "SHA256 input is not text")
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 text)
    (hash-algorithm sha256))))

(define (sk:live-manifest-records-with-key records key)
  "Return RECORDS whose first field is KEY."
  (ensure (string? key) "record key is not text")
  (filter (lambda (record)
            (and (pair? record)
                 (string=? (car record) key)))
          records))

(define (sk:live-manifest-single-record records key)
  "Return the unique KEY record from RECORDS."
  (let ((matches (sk:live-manifest-records-with-key records key)))
    (ensure (= (length matches) 1)
            "expected one ~a record, found ~a"
            key
            (length matches))
    (car matches)))

(define (record-value records key)
  (cadr (sk:live-manifest-single-record records key)))

(define (read-tsv-port port source)
  (let loop ((line-number 1)
             (records '()))
    (let ((line (read-line port)))
      (if (eof-object? line)
          (reverse records)
          (begin
            (ensure (not (string-null? line))
                    "blank TSV row at ~a:~a"
                    source
                    line-number)
            (ensure (not (string-index line #\return))
                    "carriage return at ~a:~a"
                    source
                    line-number)
            (loop (+ line-number 1)
                  (cons (string-split line #\tab)
                        records)))))))

(define (sk:read-live-manifest-string text)
  "Parse strict D4c.1 TSV TEXT and return its validated records."
  (ensure (and (string? text)
               (not (string-null? text)))
          "live manifest input is empty or non-text")
  (ensure (char=? (string-ref text (- (string-length text) 1))
                  #\newline)
          "live manifest lacks its canonical final newline")
  (sk:assert-live-manifest
   (call-with-input-string text
     (lambda (port)
       (read-tsv-port port "live manifest")))))

(define (assert-record-envelope records)
  (ensure (and (list? records) (pair? records))
          "live manifest is empty or not a proper list")
  (let loop ((remaining records)
             (previous-rank -1))
    (unless (null? remaining)
      (let* ((record (car remaining))
             (key (and (pair? record) (car record)))
             (rank (and (string? key) (record-rank key)))
             (shape (and (string? key) (record-shape key))))
        (ensure (and (list? record) (pair? record))
                "malformed live-manifest record: ~s"
                record)
        (ensure (all safe-field? record)
                "unsafe or empty live-manifest field: ~s"
                record)
        (ensure rank "unknown live-manifest record: ~s" key)
        (ensure shape "live-manifest record has no shape: ~s" key)
        (ensure (= (length record) shape)
                "~a record has wrong field count"
                key)
        (ensure (>= rank previous-rank)
                "live-manifest record order is not canonical at ~a"
                key)
        (loop (cdr remaining) rank))))
  (for-each
   (lambda (key)
     (let ((count
            (length
             (sk:live-manifest-records-with-key records key))))
       (if (member key %multiple-keys)
           (ensure (> count 0)
                   "live manifest requires at least one ~a record"
                   key)
           (ensure (= count 1)
                   "live manifest requires exactly one ~a record"
                   key))))
   %record-order))

(define (assert-fixed-prefix records)
  (ensure (string=? (record-value records "schema")
                    sk:live-manifest-schema)
          "live manifest schema drift")
  (ensure (string=? (record-value records "mode")
                    "LIVE-REVIEW-ONLY")
          "live manifest mode is not LIVE-REVIEW-ONLY")
  (ensure (string=? (record-value records "status")
                    "REVIEW-ONLY")
          "live manifest status is not REVIEW-ONLY")
  (ensure (string=? (record-value records "authorization")
                    "NOT-GRANTED")
          "live manifest authorization is not NOT-GRANTED")
  (ensure (string=? (record-value records "host") "guixpc")
          "host identity is not guixpc")
  (ensure (string=? (record-value records "user") "skydive420dz")
          "user identity is not skydive420dz")
  (ensure (string=? (record-value records "uid") "1000")
          "UID identity is not 1000")
  (ensure (canonical-positive-decimal-string?
           (record-value records "capture-epoch"))
          "capture epoch is not canonical positive decimal")
  (ensure (boot-id? (record-value records "boot-id"))
          "boot ID is not canonical lowercase UUID text")
  (for-each
   (lambda (key)
     (ensure (hex-string? (record-value records key) 40)
             "~a is not a full lowercase commit"
             key))
   '("source-checkpoint"
     "evidence-checkpoint"
     "validator-checkpoint"))
  (let ((guix (sk:live-manifest-single-record records "guix-identity"))
        (guile (sk:live-manifest-single-record records "guile-identity")))
    (ensure (store-item? (list-ref guix 1) "-profile")
            "Guix frontend is not a top-level store profile")
    (ensure (store-item? (list-ref guix 2) "-guix-command")
            "Guix program is not the pinned command store item")
    (ensure (hex-string? (list-ref guix 3) 40)
            "Guix revision is not a full lowercase commit")
    (let* ((program (list-ref guile 1))
           (descendant "/bin/guile")
           (wrapper
            (and (string-suffix? descendant program)
                 (substring program
                            0
                            (- (string-length program)
                               (string-length descendant))))))
      (ensure (and wrapper
                   (store-item? wrapper "-guile-wrapper")
                   (string=? program
                             (string-append wrapper descendant)))
              "Guile program is not the exact store wrapper descendant"))
    (ensure (canonical-guile-version? (list-ref guile 2))
            "Guile version is not three canonical dotted decimals"))
  (ensure (string=?
           (record-value records "source-input-policy")
           "PUBLISHED-REGULAR-FILES-SHA256-SIZE")
          "source-input policy drift")
  (let ((policy
         (sk:live-manifest-single-record records "generation-policy")))
    (ensure (string=? (list-ref policy 1)
                      "ADDITIONAL-DISTINCT-CLOSURES")
            "generation policy name drift")
    (ensure (string=? (list-ref policy 2) "5")
            "generation retention floor is not exactly five")))

(define (assert-source-inputs records)
  (let ((inputs
         (sk:live-manifest-records-with-key records "source-input")))
    (for-each
     (lambda (input)
       (ensure (safe-name? (list-ref input 1))
               "source-input label is unsafe")
       (ensure (safe-relative-path? (list-ref input 2))
               "source-input path is unsafe")
       (ensure (hex-string? (list-ref input 3) 64)
               "source-input SHA256 is invalid")
       (ensure (canonical-positive-decimal-string? (list-ref input 4))
               "source-input size is not canonical positive decimal"))
     inputs)
    (ensure (unique? (map (lambda (input) (list-ref input 1)) inputs))
            "source-input labels are duplicated")
    (ensure (unique? (map (lambda (input) (list-ref input 2)) inputs))
            "source-input paths are duplicated")
    (ensure (equal?
             (map (lambda (input) (list-ref input 1)) inputs)
             (sort
              (map (lambda (input) (list-ref input 1)) inputs)
              string<?))
            "source-input records are not in canonical label order")))

(define (profile-record records kind)
  (find (lambda (record)
          (string=? (list-ref record 1) kind))
        (sk:live-manifest-records-with-key records "profile")))

(define (generation-records records kind)
  (filter
   (lambda (record)
     (string=? (list-ref record 1) kind))
   (sk:live-manifest-records-with-key records "generation")))

(define (generation-number record)
  (string->number (list-ref record 2) 10))

(define (generation-target-suffix kind)
  (cond
   ((string=? kind "system") "-system")
   ((string=? kind "home") "-home")
   ((string=? kind "pull") "-profile")
   (else #f)))

(define (generation-link kind generation)
  (cond
   ((string=? kind "system")
    (string-append "/var/guix/profiles/system-"
                   generation
                   "-link"))
   ((string=? kind "home")
    (string-append
     "/var/guix/profiles/per-user/skydive420dz/guix-home-"
     generation
     "-link"))
   ((string=? kind "pull")
    (string-append
     "/var/guix/profiles/per-user/skydive420dz/current-guix-"
     generation
     "-link"))
   (else #f)))

(define (assert-profiles-and-generations records)
  (let ((profiles
         (sk:live-manifest-records-with-key records "profile"))
        (generations
         (sk:live-manifest-records-with-key records "generation")))
    (ensure
     (equal?
      (map (lambda (profile)
             (list (list-ref profile 1)
                   (list-ref profile 2)))
           profiles)
      %profile-spec)
     "profile kind/path records differ from the closed contract")
    (for-each
     (lambda (profile)
       (let* ((kind (list-ref profile 1))
              (pointer (list-ref profile 2))
              (count (list-ref profile 3))
              (current (list-ref profile 4))
              (target (list-ref profile 5))
              (kind-generations (generation-records records kind)))
         (ensure (normalized-absolute-path? pointer)
                 "~a profile pointer is unsafe"
                 kind)
         (ensure (canonical-positive-decimal-string? count)
                 "~a profile count is not canonical positive decimal"
                 kind)
         (ensure (canonical-positive-decimal-string? current)
                 "~a current generation is not canonical positive decimal"
                 kind)
         (ensure (store-item? target (generation-target-suffix kind))
                 "~a current target has an invalid store suffix"
                 kind)
         (ensure (= (string->number count 10)
                    (length kind-generations))
                 "~a profile count differs from generation rows"
                 kind)
         (let ((current-record
                (find
                 (lambda (generation)
                   (string=? (list-ref generation 2) current))
                 kind-generations)))
           (ensure current-record
                   "~a current generation is absent"
                   kind)
           (ensure (string=? (list-ref current-record 5) target)
                   "~a current generation target drift"
                   kind))))
     profiles)
    (let loop ((remaining generations)
               (previous-kind -1)
               (previous-generation #f))
      (unless (null? remaining)
        (let* ((record (car remaining))
               (kind (list-ref record 1))
               (kind-rank
                (list-index
                 (lambda (candidate)
                   (string=? candidate kind))
                 %profile-order))
               (generation (list-ref record 2))
               (number
                (and (canonical-positive-decimal-string? generation)
                     (string->number generation 10)))
               (link (list-ref record 3))
               (raw (list-ref record 4))
               (target (list-ref record 5))
               (disposition (list-ref record 6))
               (reason (list-ref record 7)))
          (ensure kind-rank "unknown generation kind: ~a" kind)
          (ensure number "generation number is not canonical positive decimal")
          (ensure (or (> kind-rank previous-kind)
                      (and (= kind-rank previous-kind)
                           previous-generation
                           (> number previous-generation)))
                  "generation records are not in canonical numeric order")
          (ensure (string=? link (generation-link kind generation))
                  "~a generation/link tuple drift: ~a"
                  kind
                  generation)
          (ensure (store-item? target (generation-target-suffix kind))
                  "~a generation target has an invalid store suffix"
                  kind)
          (ensure
           (string=?
            raw
            (relative-store-target
             (if (string=? kind "system")
                 "../../../gnu/store/"
                 "../../../../../gnu/store/")
             target))
           "~a generation raw target is not the exact closed indirection"
                  kind)
          (if (string=? kind "system")
              (ensure (member disposition '("selected" "retained"))
                      "System generation disposition is not selected/retained")
              (ensure (string=? disposition "protected")
                      "~a generation is not protected"
                      kind))
          (ensure (safe-field? reason)
                  "generation reason is unsafe")
          (loop (cdr remaining) kind-rank number))))
    (ensure (unique? (map (lambda (generation)
                            (list-ref generation 3))
                          generations))
            "generation link paths are duplicated")
    (let* ((system (generation-records records "system"))
           (selected
            (filter (lambda (record)
                      (string=? (list-ref record 6) "selected"))
                    system))
           (retained
            (filter (lambda (record)
                      (string=? (list-ref record 6) "retained"))
                    system))
           (transition
            (sk:live-manifest-single-record records
                                            "system-transition"))
           (profile (profile-record records "system"))
           (before (string->number (list-ref transition 2) 10))
           (selected-count (string->number (list-ref transition 3) 10))
           (retained-count (string->number (list-ref transition 4) 10))
           (after (string->number (list-ref transition 5) 10))
           (current (list-ref profile 4)))
      (ensure (string=? (list-ref transition 1)
                        "/var/guix/profiles/system")
              "System transition profile path drift")
      (ensure (all canonical-decimal-string? (drop transition 2))
              "System transition count is not canonical decimal")
      (ensure (> selected-count 0)
              "System selection is empty")
      (ensure (= before (length system))
              "System before count differs from generation rows")
      (ensure (= selected-count (length selected))
              "System selected count differs from selected rows")
      (ensure (= retained-count (length retained))
              "System retained count differs from retained rows")
      (ensure (= before (+ selected-count retained-count))
              "System partition does not cover the before count")
      (ensure (= after retained-count)
              "System after count differs from retained count")
      (ensure
       (find (lambda (record)
               (and (string=? (list-ref record 2) current)
                    (string=? (list-ref record 6) "retained")))
             system)
       "current System is not retained"))))

(define (pointer-record records label)
  (find (lambda (record)
          (string=? (list-ref record 1) label))
        (sk:live-manifest-records-with-key records "pointer")))

(define (assert-pointers records)
  (let ((pointers
         (sk:live-manifest-records-with-key records "pointer")))
    (ensure (equal?
             (map (lambda (pointer)
                    (list (list-ref pointer 1)
                          (list-ref pointer 2)))
                  pointers)
             %pointer-spec)
            "pointer label/path records differ from the closed contract")
    (for-each
     (lambda (pointer)
       (ensure (safe-field? (list-ref pointer 3))
               "pointer raw target is unsafe")
       (ensure (normalized-absolute-path? (list-ref pointer 4))
               "pointer canonical target is unsafe"))
     pointers)
    (let* ((system (profile-record records "system"))
           (home (profile-record records "home"))
           (pull (profile-record records "pull"))
           (system-target (list-ref system 5))
           (home-target (list-ref home 5))
           (pull-target (list-ref pull 5))
           (system-current (list-ref system 4))
           (home-current (list-ref home 4))
           (pull-current (list-ref pull 4))
           (booted
            (list-ref (pointer-record records "booted-system") 4))
           (retained-targets
            (map (lambda (record) (list-ref record 5))
                 (filter
                  (lambda (record)
                    (string=? (list-ref record 6) "retained"))
                  (generation-records records "system")))))
      (for-each
       (lambda (label)
         (ensure
          (string=? (list-ref (pointer-record records label) 4)
                    system-target)
          "~a does not resolve to the current System"
          label))
       '("system-profile" "current-system"))
      (ensure (member booted retained-targets)
              "booted System is not among retained System targets")
      (ensure (string=?
               (list-ref (pointer-record records "home-profile") 4)
               home-target)
              "Home pointer target drift")
      (for-each
       (lambda (label)
         (ensure
          (string=? (list-ref (pointer-record records label) 4)
                    pull-target)
          "~a target drift"
          label))
       '("pull-profile" "user-current"))

    (ensure
     (string=?
      (list-ref (pointer-record records "system-profile") 3)
      (basename-string (generation-link "system" system-current)))
     "System profile raw target is not its exact current generation link")
    (ensure
     (string=?
      (list-ref (pointer-record records "current-system") 3)
      (relative-store-target "../gnu/store/" system-target))
     "current System raw target is not its exact store indirection")
    (ensure
     (string=?
      (list-ref (pointer-record records "booted-system") 3)
      (relative-store-target "../gnu/store/" booted))
     "booted System raw target is not its exact store indirection")
    (ensure
     (string=?
      (list-ref (pointer-record records "home-profile") 3)
      (basename-string (generation-link "home" home-current)))
     "Home profile raw target is not its exact current generation link")
    (ensure
     (string=?
      (list-ref (pointer-record records "pull-profile") 3)
      (basename-string (generation-link "pull" pull-current)))
     "Pull profile raw target is not its exact current generation link")
    (ensure
     (string=?
      (list-ref (pointer-record records "user-current") 3)
      "../../../../var/guix/profiles/per-user/skydive420dz/current-guix")
     "user-current raw target is not the closed Pull profile indirection"))))

(define (pin-records records)
  (sk:live-manifest-records-with-key records "pin"))

(define (pin-source-text pins)
  (string-append %pins-header
                 (rows->text (map cdr pins))))

(define (assert-pins records)
  (let* ((metadata
          (sk:live-manifest-single-record records "pins"))
         (pins (pin-records records))
         (source (pin-source-text pins)))
    (ensure (string=? (list-ref metadata 1) %pins-path)
            "pins path differs from the closed source path")
    (ensure (hex-string? (list-ref metadata 2) 64)
            "pins SHA256 is invalid")
    (ensure (canonical-positive-decimal-string? (list-ref metadata 3))
            "pins size is not canonical positive decimal")
    (ensure
     (string=? (list-ref metadata 2)
               (sk:live-manifest-text-sha256 source))
     "pins SHA256 differs from reconstructed canonical source bytes")
    (ensure
     (= (string->number (list-ref metadata 3) 10)
        (bytevector-length (string->utf8 source)))
     "pins size differs from reconstructed canonical source bytes")
    (let loop ((remaining pins)
               (previous-kind -1)
               (previous-generation #f))
      (unless (null? remaining)
        (let* ((pin (car remaining))
               (kind (list-ref pin 1))
               (kind-rank
                (list-index
                 (lambda (candidate)
                   (string=? candidate kind))
                 %profile-order))
               (generation (list-ref pin 2))
               (number
                (and (canonical-positive-decimal-string? generation)
                     (string->number generation 10)))
               (target (list-ref pin 3))
               (role (list-ref pin 4))
               (kind-generations (generation-records records kind))
               (generation-record
                (and kind-rank
                     (find
                      (lambda (record)
                        (string=? (list-ref record 2) generation))
                      kind-generations))))
          (ensure kind-rank "unknown pin kind: ~a" kind)
          (ensure number "pin generation is not canonical positive decimal")
          (ensure (or (> kind-rank previous-kind)
                      (and (= kind-rank previous-kind)
                           previous-generation
                           (< number previous-generation)))
                  "pin records are not in canonical kind/generation order")
          (ensure generation-record
                  "pin generation is absent from its exact profile inventory")
          (ensure (string=? target (list-ref generation-record 5))
                  "pin generation/target tuple drift")
          (ensure (member role %pin-roles)
                  "pin role is outside the closed role set")
          (loop (cdr remaining) kind-rank number))))
    (ensure
     (unique?
      (map (lambda (pin)
             (string-append (list-ref pin 1)
                            ":"
                            (list-ref pin 2)))
           pins))
     "pin kind/generation tuples are duplicated")
    (for-each
     (lambda (kind)
       (let ((kind-pins
              (filter (lambda (pin)
                        (string=? (list-ref pin 1) kind))
                      pins)))
         (for-each
          (lambda (role)
            (ensure
             (= 1
                (count (lambda (pin)
                         (string=? (list-ref pin 4) role))
                       kind-pins))
             "~a pins require exactly one ~a role"
             kind
             role))
          '("promotion-rollback" "preferred-rollback"))))
     %profile-order)))

(define (newest-records-by-target generations)
  (let loop ((remaining
              (sort (append generations '())
                    (lambda (left right)
                      (> (generation-number left)
                         (generation-number right)))))
             (seen '())
             (result '()))
    (if (null? remaining)
        (reverse result)
        (let* ((record (car remaining))
               (target (list-ref record 5)))
          (if (member target seen)
              (loop (cdr remaining) seen result)
              (loop (cdr remaining)
                    (cons target seen)
                    (cons record result)))))))

(define (generation-record-for records kind generation)
  (find (lambda (record)
          (and (string=? (list-ref record 1) kind)
               (string=? (list-ref record 2) generation)))
        (sk:live-manifest-records-with-key records "generation")))

(define (assert-system-retention-policy records)
  (let* ((system (generation-records records "system"))
         (newest-by-target (newest-records-by-target system))
         (profile (profile-record records "system"))
         (current-generation (list-ref profile 4))
         (current-target (list-ref profile 5))
         (current-record
          (generation-record-for records "system" current-generation))
         (booted-target
          (list-ref (pointer-record records "booted-system") 4))
         (booted-records
          (filter (lambda (record)
                    (string=? (list-ref record 5) booted-target))
                  system))
         (distinct-booted?
          (not (string=? booted-target current-target)))
         (additional
          (take
           (filter
            (lambda (record)
              (let ((target (list-ref record 5)))
                (and (not (string=? target current-target))
                     (not (string=? target booted-target)))))
            newest-by-target)
           (min 5
                (length
                 (filter
                  (lambda (record)
                    (let ((target (list-ref record 5)))
                      (and (not (string=? target current-target))
                           (not (string=? target booted-target)))))
                  newest-by-target)))))
         (system-pin-records
          (map
           (lambda (pin)
             (generation-record-for records "system" (list-ref pin 2)))
           (filter (lambda (pin)
                     (string=? (list-ref pin 1) "system"))
                   (pin-records records))))
         (retained-closure-targets
          (delete-duplicates
           (append
            (list current-target)
            (if distinct-booted? (list booted-target) '())
            (map (lambda (record) (list-ref record 5)) additional)
            (map (lambda (record) (list-ref record 5))
                 system-pin-records))))
         (closure-survivors
          (map
           (lambda (target)
             (find (lambda (record)
                     (string=? (list-ref record 5) target))
                   newest-by-target))
           retained-closure-targets))
         (required-records
          (delete-duplicates
           (append
            (list current-record)
            (if distinct-booted? booted-records '())
            additional
            system-pin-records
            closure-survivors)))
         (required-generations
          (map (lambda (record) (list-ref record 2))
               required-records)))
    (ensure current-record
            "current System generation is absent from D-34 inventory")
    (ensure (pair? booted-records)
            "booted System closure is absent from D-34 inventory")
    (ensure (all identity system-pin-records)
            "System pin is absent from D-34 inventory")
    (ensure (all identity closure-survivors)
            "retained closure lacks a newest generation survivor")
    (for-each
     (lambda (record)
       (let ((generation (list-ref record 2))
             (disposition (list-ref record 6)))
         (ensure
          (string=?
           disposition
           (if (member generation required-generations)
               "retained"
               "selected"))
          "System generation ~a disposition differs from exact D-34"
          generation)))
     system)))

(define (comma-positive-decimals value)
  (and (safe-field? value)
       (let ((fields (string-split value #\,)))
         (and (pair? fields)
              (all canonical-positive-decimal-string? fields)
              (map (lambda (field)
                     (string->number field 10))
                   fields)))))

(define (assert-grub-and-bootcfg records)
  (let* ((installed
          (sk:live-manifest-single-record records "installed-grub"))
         (retained-grub
          (sk:live-manifest-single-record records "retained-grub"))
         (semantics
          (sk:live-manifest-single-record
           records
           "retained-grub-semantics"))
         (old (sk:live-manifest-single-record records "old-bootcfg"))
         (new (sk:live-manifest-single-record records "new-bootcfg"))
         (system (profile-record records "system"))
         (current-generation (list-ref system 4))
         (current-target (list-ref system 5))
         (retained-old
          (reverse
           (sort
            (map generation-number
                 (filter
                  (lambda (record)
                    (and (string=?
                          (list-ref record 6)
                          "retained")
                         (not (string=?
                               (list-ref record 2)
                               current-generation))))
                  (generation-records records "system")))
            <)))
         (semantic-generations
          (comma-positive-decimals (list-ref semantics 2))))
    (ensure (string=? (list-ref installed 1)
                      "/boot/grub/grub.cfg")
            "installed GRUB path drift")
    (ensure (hex-string? (list-ref installed 2) 64)
            "installed GRUB SHA256 is invalid")
    (ensure (canonical-positive-decimal-string? (list-ref installed 3))
            "installed GRUB size is not canonical positive decimal")
    (ensure (mode-string? (list-ref installed 4))
            "installed GRUB mode is invalid")
    (ensure (and (canonical-decimal-string? (list-ref installed 5))
                 (canonical-decimal-string? (list-ref installed 6)))
            "installed GRUB ownership is invalid")
    (ensure (safe-relative-path? (list-ref retained-grub 1))
            "retained GRUB repository path is unsafe")
    (ensure (hex-string? (list-ref retained-grub 2) 64)
            "retained GRUB SHA256 is invalid")
    (ensure (canonical-positive-decimal-string? (list-ref retained-grub 3))
            "retained GRUB size is not canonical positive decimal")
    (ensure (string=? (list-ref semantics 1) current-target)
            "retained GRUB current System drift")
    (ensure semantic-generations
            "retained GRUB generation CSV is invalid")
    (ensure (equal? semantic-generations retained-old)
            "retained GRUB old-generation order drift")
    (ensure (string=? (list-ref semantics 3) "2")
            "retained GRUB current occurrence contract drift")
    (ensure (and (canonical-decimal-string? (list-ref semantics 4))
                 (= (string->number (list-ref semantics 4) 10)
                    (* 2 (length retained-old))))
            "retained GRUB old-link occurrence count drift")
    (ensure (string=? (list-ref semantics 5) "1")
            "retained GRUB old-submenu count drift")
    (for-each
     (lambda (record label)
       (ensure (string=? (list-ref record 1)
                         "/var/guix/gcroots/bootcfg")
               "~a bootcfg path drift"
               label)
       (ensure (store-item? (list-ref record 3) "-grub.cfg")
               "~a bootcfg target is not a grub.cfg store item"
               label)
       (ensure
        (string=?
         (list-ref record 2)
         (relative-store-target
          "../../../gnu/store/"
          (list-ref record 3)))
        "~a bootcfg raw target is not the exact closed indirection"
               label))
     (list old new)
     '("old" "new"))
    (ensure (not (string=? (list-ref old 3)
                           (list-ref new 3)))
            "old and new bootcfg targets are identical")
    (ensure (string=? (list-ref new 4)
                      (list-ref retained-grub 2))
            "new bootcfg SHA256 differs from retained GRUB")
    (ensure (string=? (list-ref new 5)
                      (list-ref retained-grub 3))
            "new bootcfg size differs from retained GRUB")))

(define (assert-efi records)
  (let* ((root (sk:live-manifest-single-record records "efi-root"))
         (surfaces
          (sk:live-manifest-records-with-key records "efi-surface"))
         (variable-policy
          (sk:live-manifest-single-record records
                                          "efi-variable-policy"))
         (variables
          (sk:live-manifest-records-with-key records "efi-variable"))
         (absences
          (sk:live-manifest-records-with-key
           records
           "efi-variable-absence"))
         (relative-paths
          (map (lambda (surface) (list-ref surface 1))
               surfaces))
         (boot-options
          (take-while
           (lambda (record)
             (boot-option-variable-name? (list-ref record 1)))
           variables))
         (fixed-variables (drop variables (length boot-options)))
         (variable-bytes (rows->text (append variables absences))))
    (ensure (string=? (list-ref root 1) "/boot/efi")
            "EFI root path drift")
    (ensure (hex-string? (list-ref root 2) 64)
            "EFI tree SHA256 is invalid")
    (ensure (and (canonical-positive-decimal-string? (list-ref root 3))
                 (= (string->number (list-ref root 3) 10)
                    (length surfaces)))
            "EFI surface count drift")
    (ensure (equal? relative-paths
                    (sort relative-paths string<?))
            "EFI surfaces are not in canonical path order")
    (ensure (unique? relative-paths)
            "EFI surface paths are duplicated")
    (for-each
     (lambda (surface)
       (let ((relative (list-ref surface 1))
             (kind (list-ref surface 2))
             (mode (list-ref surface 3))
             (uid (list-ref surface 4))
             (gid (list-ref surface 5))
             (size (list-ref surface 6))
             (sha (list-ref surface 7))
             (raw (list-ref surface 8)))
         (ensure (safe-relative-path? relative)
                 "EFI relative path is unsafe")
         (ensure (member kind '("directory" "regular" "symlink"))
                 "EFI surface kind is not closed")
         (ensure (mode-string? mode)
                 "EFI surface mode is invalid")
         (ensure (and (canonical-decimal-string? uid)
                      (canonical-decimal-string? gid)
                      (canonical-decimal-string? size))
                 "EFI surface metadata is invalid")
         (cond
          ((string=? kind "regular")
           (ensure (and (hex-string? sha 64)
                        (string=? raw "-"))
                   "EFI regular-file digest/raw contract drift"))
          ((string=? kind "directory")
           (ensure (and (string=? sha "-")
                        (string=? raw "-"))
                   "EFI directory digest/raw contract drift"))
          (else
           (ensure (and (string=? sha "-")
                        (safe-field? raw)
                        (not (string=? raw "-")))
                   "EFI symlink digest/raw contract drift")
           (ensure (= (string->number size 10)
                      (bytevector-length (string->utf8 raw)))
                   "EFI symlink size differs from raw-target UTF-8 bytes")))))
     surfaces)
    (for-each
     (lambda (surface)
       (let* ((relative (list-ref surface 1))
              (parent (relative-parent relative))
              (parent-row
               (and parent
                    (find (lambda (candidate)
                            (string=? (list-ref candidate 1) parent))
                          surfaces))))
         (when parent
           (ensure parent-row
                   "EFI surface immediate parent is absent: ~a"
                   parent)
           (ensure (string=? (list-ref parent-row 2) "directory")
                   "EFI surface immediate parent is not a directory: ~a"
                   parent))))
     surfaces)
    (ensure (string=? (list-ref root 2)
                      (sk:live-manifest-text-sha256
                       (rows->text surfaces)))
            "EFI tree digest differs from canonical surface rows")
    (ensure (equal? (take variable-policy 3)
                    '("efi-variable-policy"
                      "SELECTED-FIRMWARE-BOOT-VARIABLES"
                      "BROADER-EFIVARS-EVIDENCE-ONLY"))
            "EFI variable protection/evidence policy drift")
    (ensure (and (hex-string? (list-ref variable-policy 3) 64)
                 (canonical-positive-decimal-string?
                  (list-ref variable-policy 4))
                 (= (string->number
                     (list-ref variable-policy 4)
                     10)
                    (+ (length variables)
                       (length absences))))
            "EFI protected-variable set metadata drift")
    (ensure (pair? boot-options)
            "EFI protected variables contain no selected Boot#### option")
    (ensure
     (equal? (map (lambda (record) (list-ref record 1))
                  boot-options)
             (sort
              (map (lambda (record) (list-ref record 1))
                   boot-options)
              string<?))
     "EFI Boot#### variables are not in canonical name order")
    (ensure
     (unique? (map (lambda (record) (list-ref record 1))
                   boot-options))
     "EFI Boot#### variable names are duplicated")
    (ensure
     (equal? (map (lambda (record) (list-ref record 1))
                  fixed-variables)
             %efi-fixed-variable-names)
     "EFI fixed protected-variable names or order drift")
    (for-each
     (lambda (record)
       (let ((name (list-ref record 1))
             (guid (list-ref record 2))
             (path (list-ref record 3))
             (sha (list-ref record 4))
             (size (list-ref record 5))
             (mode (list-ref record 6))
             (uid (list-ref record 7))
             (gid (list-ref record 8)))
         (ensure (or (boot-option-variable-name? name)
                     (member name %efi-fixed-variable-names))
                 "EFI protected-variable name is outside the closed set")
         (ensure (string=? guid %efi-global-variable-guid)
                 "EFI protected variable is outside the global GUID")
         (ensure (string=? path (efi-variable-path name guid))
                 "EFI protected-variable path drift")
         (ensure (hex-string? sha 64)
                 "EFI protected-variable SHA256 is invalid")
         (ensure (canonical-positive-decimal-string? size)
                 "EFI protected-variable size is not canonical positive decimal")
         (ensure (mode-string? mode)
                 "EFI protected-variable mode is invalid")
         (ensure (and (canonical-decimal-string? uid)
                      (canonical-decimal-string? gid))
                 "EFI protected-variable ownership is invalid")))
     variables)
    (ensure
     (equal?
      (map (lambda (record)
             (list (list-ref record 1)
                   (list-ref record 2)))
           absences)
      %efi-absent-variable-spec)
     "EFI variable-absence names, GUIDs, or order drift")
    (for-each
     (lambda (record)
       (ensure
        (string=? (list-ref record 3)
                  (efi-variable-path
                   (list-ref record 1)
                   (list-ref record 2)))
        "EFI variable-absence path drift"))
     absences)
    (ensure (string=? (list-ref variable-policy 3)
                      (sk:live-manifest-text-sha256
                       variable-bytes))
            "EFI protected-variable set digest drift")))

(define (assert-formulas-and-surfaces records)
  (ensure (string=?
           (record-value records "program-root-formula")
           sk:live-manifest-program-root-formula)
          "program-root formula drift")
  (ensure (string=?
           (record-value records "recovery-namespace-formula")
           sk:live-manifest-recovery-namespace-formula)
          "recovery-namespace formula drift")
  (ensure (string=?
           (record-value records "transaction-directory-formula")
           sk:live-manifest-transaction-directory-formula)
          "transaction-directory formula drift")
  (let ((surfaces
         (sk:live-manifest-records-with-key records "surface")))
    (ensure (equal?
             (map (lambda (surface)
                    (list (list-ref surface 1)
                          (list-ref surface 2)))
                  surfaces)
             %surface-spec)
            "prestate surface label/locator contract drift")
    (for-each
     (lambda (surface)
       (ensure (and (string=? (list-ref surface 3) "absent")
                    (string=? (list-ref surface 4) "-"))
               "D4c.1 requires an exact absent prestate: ~a"
               (list-ref surface 1)))
     surfaces)))

(define (selected-system-records records)
  (filter
   (lambda (record)
     (and (string=? (list-ref record 1) "system")
          (string=? (list-ref record 6) "selected")))
   (sk:live-manifest-records-with-key records "generation")))

(define (selector-for records)
  (string-join
   (map (lambda (record) (list-ref record 2))
        (selected-system-records records))
   ","))

(define (assert-recovery-and-action records)
  (let* ((selected (selected-system-records records))
         (roots
          (sk:live-manifest-records-with-key records "recovery-root"))
         (candidate-count (length selected))
         (candidates (take roots candidate-count))
         (trailing (drop roots candidate-count))
         (old (sk:live-manifest-single-record records "old-bootcfg"))
         (new (sk:live-manifest-single-record records "new-bootcfg"))
         (selector-record
          (sk:live-manifest-single-record records "selector"))
         (actions
          (sk:live-manifest-records-with-key records "action"))
         (grant-tokens
          (sk:live-manifest-records-with-key records "grant-token"))
         (selector (selector-for records)))
    (ensure (= (length roots) (+ candidate-count 2))
            "recovery-root count is not selected plus old/new bootcfg")
    (for-each
     (lambda (root selected-record)
       (let ((generation (list-ref selected-record 2))
             (target (list-ref selected-record 5)))
         (ensure
          (equal?
           root
           (list "recovery-root"
                 "candidate"
                 (string-append "candidate-g" generation)
                 generation
                 target))
          "candidate recovery-root tuple drift for generation ~a"
          generation)))
     candidates
     selected)
    (ensure
     (equal?
      trailing
      (list
       (list "recovery-root"
             "bootcfg-old"
             "old-bootcfg"
             "-"
             (list-ref old 3))
       (list "recovery-root"
             "bootcfg-new"
             "new-bootcfg"
             "-"
             (list-ref new 3))))
     "old/new bootcfg recovery-root order or target drift")
    (ensure (unique? (map (lambda (root) (list-ref root 2))
                          roots))
            "recovery-root names are duplicated")
    (ensure (comma-positive-decimals (list-ref selector-record 2))
            "System selector is not canonical positive decimal CSV")
    (ensure (equal? selector-record
                    (list "selector" "system" selector))
            "exact System selector drift")
    (ensure (equal? actions
                    '(("action" "live-verify")
                      ("action" "live-apply")
                      ("action" "live-recover")))
            "closed zero-argument action set or order drift")
    (ensure (equal? grant-tokens
                    '(("grant-token"
                       "execution"
                       "SK_P52B_D5_EXECUTION_GRANT"
                       "ABSENT")
                      ("grant-token"
                       "recovery"
                       "SK_P52B_D5_RECOVERY_GRANT"
                       "ABSENT")))
            "execution/recovery grant-token absence drift")))

(define (expected-row records label)
  (find (lambda (record)
          (string=? (list-ref record 1) label))
        (sk:live-manifest-records-with-key
         records
         "expected-postflight")))

(define (assert-expected-postflight records)
  (let* ((expected
          (sk:live-manifest-records-with-key
           records
           "expected-postflight"))
         (transition
          (sk:live-manifest-single-record records "system-transition"))
         (retained-grub
          (sk:live-manifest-single-record records "retained-grub"))
         (installed
          (sk:live-manifest-single-record records "installed-grub"))
         (new (sk:live-manifest-single-record records "new-bootcfg"))
         (efi (sk:live-manifest-single-record records "efi-root"))
         (efi-variables
          (sk:live-manifest-single-record records
                                          "efi-variable-policy"))
         (selector (selector-for records)))
    (ensure (equal? (map (lambda (record) (list-ref record 1))
                         expected)
                    %expected-postflight-labels)
            "expected-postflight labels or order drift")
    (ensure
     (equal? (expected-row records "system-count")
             (list "expected-postflight"
                   "system-count"
                   (list-ref transition 5)
                   (list-ref transition 1)))
     "expected System postflight count drift")
    (ensure
     (equal? (expected-row records "selected-links")
             (list "expected-postflight"
                   "selected-links"
                   "absent"
                   selector))
     "expected selected-link postflight drift")
    (ensure
     (equal? (expected-row records "installed-grub")
             (list "expected-postflight"
                   "installed-grub"
                   (string-join
                    (append (drop retained-grub 2)
                            (drop installed 4))
                    ":")
                   "/boot/grub/grub.cfg"))
     "expected installed-GRUB postflight drift")
    (ensure
     (equal? (expected-row records "bootcfg")
             (list "expected-postflight"
                   "bootcfg"
                   (list-ref new 2)
                   (list-ref new 3)))
     "expected bootcfg postflight drift")
    (ensure
     (equal? (expected-row records "protected-surfaces")
             '("expected-postflight"
               "protected-surfaces"
               "unchanged"
               "all-manifest-protected"))
     "protected-surface postflight policy drift")
    (ensure
     (equal? (expected-row records "efi-surfaces")
             (list "expected-postflight"
                   "efi-surfaces"
                   "unchanged"
                   (list-ref efi 2)))
     "EFI postflight digest drift")
    (ensure
     (equal? (expected-row records "efi-variables")
             (list "expected-postflight"
                   "efi-variables"
                   "unchanged"
                   (list-ref efi-variables 3)))
     "EFI protected-variable postflight digest drift")
    (let ((transaction-base
           "/var/guix/profiles/.p52b-system-prune-transactions")
          (journal
           (string-append
            sk:live-manifest-transaction-directory-formula
            "/journal.tsv"))
          (backup
           (string-append
            sk:live-manifest-transaction-directory-formula
            "/old-grub.cfg"))
          (quarantine
           (string-append
            sk:live-manifest-transaction-directory-formula
            "/quarantine"))
          (journal-temporaries
           (string-append
            sk:live-manifest-transaction-directory-formula
            "/journal.tsv.*"))
          (old-grub-identity
           (string-join (drop installed 2) ":")))
      (for-each
       (lambda (expected-record label)
         (ensure (equal? (expected-row records label)
                         expected-record)
                 "~a terminal postflight drift"
                 label))
       (list
        (list "expected-postflight"
              "transaction-base"
              "retained"
              transaction-base)
        (list "expected-postflight"
              "transaction-directory"
              "retained"
              sk:live-manifest-transaction-directory-formula)
        (list "expected-postflight"
              "terminal-journal"
              "retained-COMPLETE"
              journal)
        (list "expected-postflight"
              "old-grub-backup"
              old-grub-identity
              backup)
        (list "expected-postflight"
              "quarantine"
              "absent"
              quarantine)
        (list "expected-postflight"
              "journal-temporaries"
              "absent"
              journal-temporaries)
        '("expected-postflight"
          "grub-temporary"
          "absent"
          "/boot/grub/grub.cfg.p52b-new")
        '("expected-postflight"
          "bootcfg-temporary"
          "absent"
          "/var/guix/gcroots/bootcfg.p52b-new")
        (list "expected-postflight"
              "recovery-namespace"
              "absent"
              sk:live-manifest-recovery-namespace-formula)
        '("expected-postflight" "recovery-roots" "absent" "-")
        '("expected-postflight" "program-root" "absent" "-")
        '("expected-postflight"
          "transaction-lock"
          "retained-created-inode"
          "-")
        '("expected-postflight"
          "system-lock"
          "retained-created-inode"
          "-")
        '("expected-postflight"
          "temporary-roots"
          "release-on-connection-close"
          "all-session-temporary-roots"))
       (drop %expected-postflight-labels 7)))))

(define (assert-footer records)
  (ensure
   (equal?
    (map cadr
         (sk:live-manifest-records-with-key records "prohibition"))
    %prohibitions)
   "mutation prohibitions are incomplete or out of canonical order")
  (ensure
   (equal?
    (sk:live-manifest-single-record records "capture-result")
    '("capture-result" "protected-pre-post" "IDENTICAL"))
   "capture result is not exact protected pre/post identity")
  (ensure (string=? (record-value records "program-build") "NOT-RUN")
          "program build was not recorded as NOT-RUN")
  (ensure (string=? (record-value records "lowering") "NOT-RUN")
          "lowering was not recorded as NOT-RUN")
  (ensure (string=? (record-value records "realization") "NOT-RUN")
          "realization was not recorded as NOT-RUN")
  (ensure (string=? (record-value records "live-action") "NOT-GRANTED")
          "live action was not recorded as NOT-GRANTED"))

(define (sk:assert-live-manifest records)
  "Validate and return the exact ordered D4c.1 review RECORDS.

This operation is pure.  It accepts no manifest self-hash, future fused
program target, execution grant, or mutable capability."
  (assert-record-envelope records)
  (assert-fixed-prefix records)
  (assert-source-inputs records)
  (assert-profiles-and-generations records)
  (assert-pointers records)
  (assert-pins records)
  (assert-system-retention-policy records)
  (assert-grub-and-bootcfg records)
  (assert-efi records)
  (assert-formulas-and-surfaces records)
  (assert-recovery-and-action records)
  (assert-expected-postflight records)
  (assert-footer records)
  records)

(define (sk:render-live-manifest records)
  "Render validated RECORDS as canonical final-newline TSV."
  (rows->text (sk:assert-live-manifest records)))

(define (sk:live-manifest-source-inputs records)
  "Return the exact ordered fused-program source-input records."
  (sk:live-manifest-records-with-key
   (sk:assert-live-manifest records)
   "source-input"))

(define (sk:live-manifest-selected-generations records)
  "Return selected System generation records in numeric order."
  (selected-system-records (sk:assert-live-manifest records)))

(define (sk:live-manifest-retained-generations records)
  "Return retained System generation records in numeric order."
  (filter
   (lambda (record)
     (and (string=? (list-ref record 1) "system")
          (string=? (list-ref record 6) "retained")))
   (sk:live-manifest-records-with-key
    (sk:assert-live-manifest records)
    "generation")))

(define (sk:live-manifest-recovery-roots records)
  "Return the exact ordered candidate/old/new recovery-root specifications."
  (sk:live-manifest-records-with-key
   (sk:assert-live-manifest records)
   "recovery-root"))
