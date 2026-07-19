;;; Fixture-only recovery transaction for reviewed Guix System pruning.

(define-module (sk system-pruning-transaction)
  #:use-module (gcrypt hash)
  #:use-module (guix base16)
  #:use-module (guix build syscalls)
  #:use-module (guix utils)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 match)
  #:use-module (ice-9 rdelim)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module (srfi srfi-1)
  #:use-module (system foreign)
  #:export (sk:assert-transaction-manifest
            sk:file-sha256
            sk:read-tsv
            sk:run-fixture-transaction))

(define %error-key 'sk-system-pruning-transaction)
(define %manifest-schema "p5.2b-system-prune-transaction/v1")
(define %journal-schema "p5.2b-system-prune-journal/v1")
(define %registry-schema "p5.2b-system-prune-crash-registry/v1")
(define %fixture-sentinel ".p52b-system-transaction-fixture")
(define %fixture-sentinel-value "p5.2b-system-transaction-fixture/v1")
(define %d2b-checkpoint "abcf2efceb2bb2c797ddf00bdd02c4fe7a42c96f")
(define %d2b-artifact
  "docs/audits/data/2026-07-19-p5.2b-d2b-retained-grub.cfg")
(define %d2b-artifact-sha
  "70965414824c26e1712c6a7a51efd9517633eb3c83f36f88927565c87807496b")
(define %d2b-artifact-size 5163)
(define %guix-revision "a8391f2d7451c2463ba253ffa9872fa6f27485d7")
(define %crash-registry-path
  "tests/fixtures/guix-system-pruning-transaction/phase-registry.tsv")
(define %crash-registry-sha
  "bd17a2423d9a0fcea86f3eba23cbb52699379b54853eae510597ed7a160aba86")
(define %profile-record
  '("profile" "/var/guix/profiles/system" "10" "2" "8" "8"))
(define %installed-grub-record
  '("installed-grub" "/boot/grub/grub.cfg"
    "1ac81963a8c65596be9ca3b196396a2025c30cbf3a56b189045756158bf4ef13"
    "874" "420"))
(define %old-bootcfg-record
  '("old-bootcfg" "/var/guix/gcroots/bootcfg"
    "../../../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-grub.cfg"
    "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-grub.cfg"))
(define %new-bootcfg-record
  '("new-bootcfg" "/var/guix/gcroots/bootcfg"
    "../../../gnu/store/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn-grub.cfg"
    "/gnu/store/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn-grub.cfg"))
(define %new-grub-store-record
  '("new-grub-store"
    "/gnu/store/nnnnnnnnnnnnnnnnnnnnnnnnnnnnnnnn-grub.cfg"
    "70965414824c26e1712c6a7a51efd9517633eb3c83f36f88927565c87807496b"
    "5163"))
(define %store-names-record
  '("store-names" "13"
    "5d4b1e49bd8090b41d5fb50129695b005aa2af554e6d0c38bc33737efbc2450f"))
(define %expected-implementation-inputs
  '(("module" "guix/modules/sk/system-pruning-transaction.scm")
    ("driver" "scripts/guix-system-pruning-transaction.scm")
    ("launcher" "scripts/guix-system-pruning-transaction")
    ("profile-lock-holder"
     "tests/fixtures/guix-system-pruning-transaction/profile-lock-holder.scm")
    ("old-grub-fixture"
     "tests/fixtures/guix-system-pruning-transaction/old-grub.cfg")
    ("pins-fixture"
     "tests/fixtures/guix-system-pruning-transaction/generation-pins.tsv")
    ("efi-fixture"
     "tests/fixtures/guix-system-pruning-transaction/efi-sentinel.txt")))
(define %expected-protected-files
  '(("protected-file" "/repo/generation-pins.tsv"
     "cffa2f01a6a8083753b71add5624fba25cee6c74e703c77593e35573268dbee4")
    ("protected-file" "/boot/efi/fixture-sentinel.txt"
     "069c1ed4a330dfd29e78e7ad208cee06316370f341dc3b7029ab6ff44dff4509")))
(define %expected-protected-symlinks
  '(("protected-symlink" "/var/guix/profiles/system" "system-87-link"
     "/gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system")
    ("protected-symlink" "/run/current-system"
     "../gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system"
     "/gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system")
    ("protected-symlink" "/run/booted-system"
     "../gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system"
     "/gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system")
    ("protected-symlink"
     "/var/guix/profiles/per-user/fixture/guix-home-1-link"
     "../../../../../gnu/store/84pm5bd8kpm6gylx0378dcgdsazh6a49-home"
     "/gnu/store/84pm5bd8kpm6gylx0378dcgdsazh6a49-home")
    ("protected-symlink" "/var/guix/profiles/per-user/fixture/guix-home"
     "guix-home-1-link"
     "/gnu/store/84pm5bd8kpm6gylx0378dcgdsazh6a49-home")
    ("protected-symlink"
     "/var/guix/profiles/per-user/fixture/current-guix-5-link"
     "../../../../../gnu/store/mm52g4iy2hx36vn27h7y13cgc8zqzv5c-profile"
     "/gnu/store/mm52g4iy2hx36vn27h7y13cgc8zqzv5c-profile")
    ("protected-symlink" "/var/guix/profiles/per-user/fixture/current-guix"
     "current-guix-5-link"
     "/gnu/store/mm52g4iy2hx36vn27h7y13cgc8zqzv5c-profile")
    ("protected-symlink" "/home/fixture/.config/guix/current"
     "../../../../var/guix/profiles/per-user/fixture/current-guix"
     "/gnu/store/mm52g4iy2hx36vn27h7y13cgc8zqzv5c-profile")))
(define %expected-retained
  '(("retain" "75" "/var/guix/profiles/system-75-link"
     "../../../gnu/store/8zvbahq7s52fm1f27rc3qhbp02kj0zxh-system"
     "/gnu/store/8zvbahq7s52fm1f27rc3qhbp02kj0zxh-system")
    ("retain" "80" "/var/guix/profiles/system-80-link"
     "../../../gnu/store/jk1793wbqbn68y2s8ccpnpqicibrf8nz-system"
     "/gnu/store/jk1793wbqbn68y2s8ccpnpqicibrf8nz-system")
    ("retain" "81" "/var/guix/profiles/system-81-link"
     "../../../gnu/store/6f67kj6ix8n8wf10b3ic78r73c7r26v7-system"
     "/gnu/store/6f67kj6ix8n8wf10b3ic78r73c7r26v7-system")
    ("retain" "83" "/var/guix/profiles/system-83-link"
     "../../../gnu/store/y9ybn9c3yq3g2nqr38ag5kli2hc819xb-system"
     "/gnu/store/y9ybn9c3yq3g2nqr38ag5kli2hc819xb-system")
    ("retain" "84" "/var/guix/profiles/system-84-link"
     "../../../gnu/store/jl9k89bivsjrw41lm9j7xq6v2d61s7p4-system"
     "/gnu/store/jl9k89bivsjrw41lm9j7xq6v2d61s7p4-system")
    ("retain" "85" "/var/guix/profiles/system-85-link"
     "../../../gnu/store/m5znrpyizvkkz77nn5nc7swl1jfhp7mf-system"
     "/gnu/store/m5znrpyizvkkz77nn5nc7swl1jfhp7mf-system")
    ("retain" "86" "/var/guix/profiles/system-86-link"
     "../../../gnu/store/qwy0gwwfbaw6x187hh4jh0sk1vr0lry7-system"
     "/gnu/store/qwy0gwwfbaw6x187hh4jh0sk1vr0lry7-system")
    ("retain" "87" "/var/guix/profiles/system-87-link"
     "../../../gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system"
     "/gnu/store/gz53dagd09rr97k0ffhkx40rz0am4c88-system")))
(define %expected-deleted
  '(("delete" "1" "/var/guix/profiles/system-1-link"
     "../../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
     "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system")
    ("delete" "2" "/var/guix/profiles/system-2-link"
     "../../../gnu/store/8zvbahq7s52fm1f27rc3qhbp02kj0zxh-system"
     "/gnu/store/8zvbahq7s52fm1f27rc3qhbp02kj0zxh-system")))

(define (%fail format-string . arguments)
  (throw %error-key (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (exact-record-set? actual expected)
  (and (= (length actual) (length expected))
       (all (lambda (record) (member record expected)) actual)
       (all (lambda (record) (member record actual)) expected)))

(define (decimal-string? value)
  (and (not (string-null? value))
       (all char-numeric? (string->list value))))

(define (hex-string? value length)
  (and (= (string-length value) length)
       (all (lambda (character)
              (or (char-numeric? character)
                  (and (char>=? character #\a)
                       (char<=? character #\f))))
            (string->list value))))

(define (safe-name? value)
  (and (not (string-null? value))
       (all (lambda (character)
              (or (char-alphabetic? character)
                  (char-numeric? character)
                  (memv character '(#\- #\_ #\.))))
            (string->list value))
       (not (member value '("." "..")))
       (not (and (string-suffix? "-link" value)
                 (let* ((without-suffix
                         (substring value 0
                                    (- (string-length value)
                                       (string-length "-link"))))
                        (dash (string-rindex without-suffix #\-)))
                   (and dash
                        (decimal-string?
                         (substring without-suffix (+ dash 1)))))))))

(define (normalized-absolute-path? path)
  (and (absolute-file-name? path)
       (not (string=? path "/"))
       (not (string-contains path "//"))
       (not (string-contains path "/./"))
       (not (string-contains path "/../"))
       (not (string-suffix? "/." path))
       (not (string-suffix? "/.." path))))

(define (safe-relative-path? path)
  (and (not (string-null? path))
       (not (absolute-file-name? path))
       (not (string-contains path "//"))
       (not (string-prefix? "../" path))
       (not (string-contains path "/../"))
       (not (string-suffix? "/.." path))
       (not (string-prefix? "./" path))
       (not (string-contains path "/./"))
       (not (string-suffix? "/." path))))

(define (store-item? path suffix)
  (and (string-prefix? "/gnu/store/" path)
       (string-suffix? suffix path)
       (let* ((name (substring path (string-length "/gnu/store/")))
              (dash (string-index name #\-)))
         (and dash
              (= dash 32)
              (all (lambda (character)
                     (or (char-numeric? character)
                         (and (char>=? character #\a)
                              (char<=? character #\z))))
                   (string->list (substring name 0 dash)))
              (not (string-contains name "/"))))))

(define (sk:read-tsv file)
  (call-with-input-file file
    (lambda (port)
      (let loop ((line-number 1)
                 (result '()))
        (let ((line (read-line port)))
          (if (eof-object? line)
              (reverse result)
              (begin
                (ensure (not (string-null? line))
                        "blank TSV row at ~a:~a" file line-number)
                (ensure (not (string-index line #\return))
                        "carriage return in TSV row at ~a:~a"
                        file line-number)
                (loop (+ line-number 1)
                      (cons (string-split line #\tab) result)))))))))

(define (records-with-key records key)
  (filter (lambda (record)
            (and (pair? record) (string=? (car record) key)))
          records))

(define (single-record records key fields)
  (let ((matches (records-with-key records key)))
    (ensure (= (length matches) 1)
            "expected one ~a record, found ~a" key (length matches))
    (ensure (= (length (car matches)) fields)
            "~a record has the wrong field count" key)
    (car matches)))

(define (multi-records records key fields)
  (let ((matches (records-with-key records key)))
    (for-each
     (lambda (record)
       (ensure (= (length record) fields)
               "~a record has the wrong field count" key))
     matches)
    matches))

(define (record-value records key)
  (cadr (single-record records key 2)))

(define (read-text file)
  (call-with-input-file file get-string-all))

(define (sk:file-sha256 file)
  (bytevector->base16-string (file-sha256 file)))

(define (string-sha256 value)
  (bytevector->base16-string
   (bytevector-hash
    (string->utf8 value)
    (hash-algorithm sha256))))

(define %fsync
  (pointer->procedure
   int
   (dynamic-func "fsync" (dynamic-link))
   (list int)))

(define (sync-directory! directory)
  ;; with-atomic-file-output synchronizes the temporary file.  This explicit
  ;; fsync closes the parent-directory rename durability gap on Linux.
  (let ((descriptor (open-fdes directory O_RDONLY)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (ensure (zero? (%fsync descriptor))
                "cannot fsync directory: ~a" directory))
      (lambda ()
        (close-fdes descriptor)))))

(define (atomic-write-text! file text)
  (with-atomic-file-output file
    (lambda (port)
      (display text port)))
  (sync-directory! (dirname file)))

(define (write-file-durable! file text mode)
  (ensure (eq? 'absent (path-kind file))
          "transaction temporary path is occupied: ~a" file)
  (let ((port (open file (logior O_WRONLY O_CREAT O_EXCL) mode)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (display text port)
        (fdatasync port)
        (chmod port mode)
        (ensure (zero? (%fsync (fileno port)))
                "cannot fsync transaction file metadata: ~a" file))
      (lambda ()
        (close-port port))))
  (sync-directory! (dirname file)))

(define (path-kind path)
  (catch 'system-error
    (lambda () (stat:type (lstat path)))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          'absent
          (apply throw arguments)))))

(define (real-directory? path)
  (eq? 'directory (path-kind path)))

(define (same-inode? left right)
  (and (= (stat:dev left) (stat:dev right))
       (= (stat:ino left) (stat:ino right))))

(define (canonical-directory path label)
  (ensure (normalized-absolute-path? path)
          "~a is not a normalized absolute path: ~s" label path)
  (ensure (real-directory? path)
          "~a is not a real directory: ~a" label path)
  (let ((canonical (canonicalize-path path)))
    (ensure (string=? canonical path)
            "~a contains a symlinked or noncanonical ancestor: ~a"
            label path)
    canonical))

(define (repository-file repository relative)
  (ensure (safe-relative-path? relative)
          "unsafe repository-relative path: ~s" relative)
  (string-append repository "/" relative))

(define (fixture-path root logical)
  (ensure (normalized-absolute-path? logical)
          "unsafe logical fixture path: ~s" logical)
  (string-append root logical))

(define (logical-canonical root physical)
  (let ((canonical
         (catch 'system-error
           (lambda () (canonicalize-path physical))
           (lambda _arguments #f))))
    (and canonical
         (string-prefix? (string-append root "/") canonical)
         (string-append "/" (substring canonical (+ (string-length root) 1))))))

(define (ensure-real-logical-directory root logical label)
  (let ((physical (fixture-path root logical)))
    (ensure (real-directory? physical)
            "~a is not a real fixture directory: ~a" label logical)
    (ensure (string=? (canonicalize-path physical) physical)
            "~a has a symlinked or escaped ancestor: ~a" label logical)
    physical))

(define (ensure-file-hash path expected label)
  (ensure (eq? 'regular (path-kind path))
          "~a is not a regular file: ~a" label path)
  (let ((actual (sk:file-sha256 path)))
    (ensure (string=? actual expected)
            "~a SHA256 drift: expected ~a, got ~a"
            label expected actual)))

(define (ensure-file-size path expected label)
  (let ((actual (stat:size (stat path))))
    (ensure (= actual expected)
            "~a size drift: expected ~a, got ~a"
            label expected actual)))

(define (ensure-file-mode path expected label)
  (let ((actual (stat:perms (lstat path))))
    (ensure (= actual expected)
            "~a mode drift: expected ~o, got ~o"
            label expected actual)))

(define (ensure-symlink-tuple root logical raw canonical label)
  (let ((physical (fixture-path root logical)))
    (ensure (eq? 'symlink (path-kind physical))
            "~a is not a symlink: ~a" label logical)
    (ensure (string=? (readlink physical) raw)
            "~a raw target drift: ~a" label logical)
    (ensure (equal? (logical-canonical root physical) canonical)
            "~a canonical target drift: ~a" label logical)))

(define (delete-file-if-exact! path predicate label)
  (case (path-kind path)
    ((absent) #f)
    ((symlink regular)
     (ensure (predicate path)
             "~a temporary path has unknown contents: ~a" label path)
     (delete-file path)
     (sync-directory! (dirname path))
     #t)
    (else
     (%fail "~a temporary path has an unsafe type: ~a" label path))))

(define %singleton-shapes
  '(("schema" . 2)
    ("mode" . 2)
    ("authorization" . 2)
    ("status" . 2)
    ("guix-revision" . 2)
    ("base-checkpoint" . 2)
    ("transaction-base" . 2)
    ("recovery-base" . 2)
    ("profile" . 6)
    ("installed-grub" . 5)
    ("old-bootcfg" . 4)
    ("new-bootcfg" . 4)
    ("new-grub-source" . 4)
    ("new-grub-store" . 4)
    ("crash-registry" . 3)
    ("store-names" . 3)))

(define %multiple-shapes
  '(("implementation-input" . 4)
    ("protected-file" . 3)
    ("protected-symlink" . 4)
    ("retain" . 5)
    ("delete" . 5)
    ("recovery-root" . 3)))

(define (shape-for key shapes)
  (assoc-ref shapes key))

(define (strictly-increasing? numbers)
  (or (null? numbers)
      (null? (cdr numbers))
      (and (< (car numbers) (cadr numbers))
           (strictly-increasing? (cdr numbers)))))

(define (tuple-generation tuple)
  (string->number (list-ref tuple 1) 10))

(define (tuple-link tuple)
  (list-ref tuple 2))

(define (tuple-raw tuple)
  (list-ref tuple 3))

(define (tuple-target tuple)
  (list-ref tuple 4))

(define (assert-tuple-set records key)
  (let ((tuples (multi-records records key 5)))
    (for-each
     (lambda (tuple)
       (let ((generation (list-ref tuple 1))
             (link (tuple-link tuple))
             (target (tuple-target tuple)))
         (ensure (decimal-string? generation)
                 "~a generation is not decimal: ~s" key generation)
         (ensure (string=?
                  link
                  (string-append
                   "/var/guix/profiles/system-" generation "-link"))
                 "~a generation/link mismatch: ~a" key link)
         (ensure (normalized-absolute-path? link)
                 "~a link path is unsafe: ~a" key link)
         (ensure (store-item? target "-system")
                 "~a target is not a System store item: ~a" key target)
         (ensure (not (string-null? (tuple-raw tuple)))
                 "~a raw target is empty for generation ~a"
                 key generation)))
     tuples)
    (let ((numbers (map tuple-generation tuples)))
      (ensure (strictly-increasing? numbers)
              "~a generations are not strictly increasing" key))
    tuples))

(define (assert-protected-records records)
  (for-each
   (lambda (record)
     (ensure (normalized-absolute-path? (list-ref record 1))
             "protected file path is unsafe: ~s" (list-ref record 1))
     (ensure (hex-string? (list-ref record 2) 64)
             "protected file digest is invalid: ~s" (list-ref record 2)))
   (multi-records records "protected-file" 3))
  (for-each
   (lambda (record)
     (ensure (normalized-absolute-path? (list-ref record 1))
             "protected symlink path is unsafe: ~s" (list-ref record 1))
     (ensure (not (string-null? (list-ref record 2)))
             "protected symlink raw target is empty")
     (ensure (normalized-absolute-path? (list-ref record 3))
             "protected symlink canonical target is unsafe: ~s"
             (list-ref record 3)))
   (multi-records records "protected-symlink" 4)))

(define (sk:assert-transaction-manifest records)
  "Validate RECORDS as the closed D3a fixture-only transaction manifest."
  (for-each
   (lambda (record)
     (ensure (pair? record) "empty transaction manifest record")
     (let* ((key (car record))
            (singleton (shape-for key %singleton-shapes))
            (multiple (shape-for key %multiple-shapes))
            (fields (or singleton multiple)))
       (ensure fields "unknown transaction manifest record: ~a" key)
       (ensure (= (length record) fields)
               "~a transaction manifest record has wrong field count" key)))
   records)
  (for-each
   (lambda (shape)
     (single-record records (car shape) (cdr shape)))
   %singleton-shapes)
  (ensure (string=? (record-value records "schema") %manifest-schema)
          "transaction manifest schema is not ~a" %manifest-schema)
  (ensure (string=? (record-value records "mode") "FIXTURE-ONLY")
          "transaction mode is not FIXTURE-ONLY")
  (ensure (string=? (record-value records "authorization") "NOT-GRANTED")
          "transaction authorization is not NOT-GRANTED")
  (ensure (string=? (record-value records "status") "FIXTURE-ONLY")
          "transaction status is not FIXTURE-ONLY")
  (ensure (string=? (record-value records "guix-revision") %guix-revision)
          "transaction Guix revision differs from the pinned fixture revision")
  (ensure (string=? (record-value records "base-checkpoint") %d2b-checkpoint)
          "transaction base is not the published D2b checkpoint")
  (ensure (string=?
           (record-value records "transaction-base")
           "/var/guix/profiles/.p52b-system-prune-transactions")
          "transaction directory base is outside the accepted fixture design")
  (ensure (string=?
           (record-value records "recovery-base")
           "/var/guix/gcroots/p52b-system-prune")
          "recovery-root base is outside the accepted fixture design")
  (let* ((profile (single-record records "profile" 6))
         (before (string->number (list-ref profile 2) 10))
         (selected (string->number (list-ref profile 3) 10))
         (retained-count (string->number (list-ref profile 4) 10))
         (after (string->number (list-ref profile 5) 10))
         (retained (assert-tuple-set records "retain"))
         (deleted (assert-tuple-set records "delete"))
         (all-generations
          (append (map tuple-generation retained)
                  (map tuple-generation deleted))))
    (ensure (equal? profile %profile-record)
            "profile tuple differs from the reviewed fixture")
    (ensure (exact-record-set? retained %expected-retained)
            "retained generation tuples differ from the reviewed fixture")
    (ensure (exact-record-set? deleted %expected-deleted)
            "deleted generation tuples differ from the reviewed fixture")
    (ensure (string=? (list-ref profile 1) "/var/guix/profiles/system")
            "transaction profile is not the System profile")
    (ensure (all decimal-string? (drop profile 2))
            "profile counts are not decimal")
    (ensure (= before (+ selected retained-count))
            "profile before count differs from selected plus retained")
    (ensure (= after retained-count)
            "profile after count differs from retained")
    (ensure (= selected (length deleted))
            "delete tuple count differs from selected count")
    (ensure (= retained-count (length retained))
            "retain tuple count differs from retained count")
    (ensure (= (length all-generations)
               (length (delete-duplicates all-generations)))
            "retain/delete generations overlap"))
  (let ((installed (single-record records "installed-grub" 5))
        (source (single-record records "new-grub-source" 4))
        (new-store (single-record records "new-grub-store" 4))
        (old-bootcfg (single-record records "old-bootcfg" 4))
        (new-bootcfg (single-record records "new-bootcfg" 4)))
    (ensure (equal? installed %installed-grub-record)
            "installed GRUB tuple differs from the reviewed fixture")
    (ensure (equal? old-bootcfg %old-bootcfg-record)
            "old bootcfg tuple differs from the reviewed fixture")
    (ensure (equal? new-bootcfg %new-bootcfg-record)
            "new bootcfg tuple differs from the reviewed fixture")
    (ensure (equal? new-store %new-grub-store-record)
            "new GRUB store tuple differs from the reviewed fixture")
    (ensure (string=? (list-ref installed 1) "/boot/grub/grub.cfg")
            "installed GRUB path differs from the fixture contract")
    (ensure (and (hex-string? (list-ref installed 2) 64)
                 (decimal-string? (list-ref installed 3))
                 (decimal-string? (list-ref installed 4)))
            "installed GRUB metadata is invalid")
    (ensure (string=? (list-ref source 1) %d2b-artifact)
            "new GRUB source is not the tracked D2b artifact")
    (ensure (string=? (list-ref source 2) %d2b-artifact-sha)
            "new GRUB source digest differs from D2b")
    (ensure (= (string->number (list-ref source 3) 10)
               %d2b-artifact-size)
            "new GRUB source size differs from D2b")
    (ensure (store-item? (list-ref new-store 1) "-grub.cfg")
            "new GRUB fixture target is not a grub.cfg store item")
    (ensure (and (string=? (list-ref new-store 2) %d2b-artifact-sha)
                 (= (string->number (list-ref new-store 3) 10)
                    %d2b-artifact-size))
            "new GRUB store tuple differs from the D2b artifact")
    (ensure (string=? (list-ref old-bootcfg 1)
                      "/var/guix/gcroots/bootcfg")
            "old bootcfg path differs from the fixture contract")
    (ensure (string=? (list-ref new-bootcfg 1)
                      "/var/guix/gcroots/bootcfg")
            "new bootcfg path differs from the fixture contract")
    (ensure (store-item? (list-ref old-bootcfg 3) "-grub.cfg")
            "old bootcfg target is not a grub.cfg store item")
    (ensure (string=? (list-ref new-bootcfg 3)
                      (list-ref new-store 1))
            "new bootcfg and new GRUB store targets differ")
    (ensure (not (string=? (list-ref old-bootcfg 3)
                           (list-ref new-bootcfg 3)))
            "old and new bootcfg targets are identical"))
  (let ((roots (multi-records records "recovery-root" 3))
        (deleted (records-with-key records "delete"))
        (old-target (list-ref (single-record records "old-bootcfg" 4) 3))
        (new-target (list-ref (single-record records "new-bootcfg" 4) 3)))
    (ensure (= (length roots) (+ (length deleted) 2))
            "recovery-root count is not selected generations plus old/new bootcfg")
    (for-each
     (lambda (root)
       (ensure (safe-name? (list-ref root 1))
               "unsafe recovery-root name: ~s" (list-ref root 1))
       (ensure (or (store-item? (list-ref root 2) "-system")
                   (store-item? (list-ref root 2) "-grub.cfg"))
               "unsafe recovery-root target: ~s" (list-ref root 2)))
     roots)
    (ensure (= (length (map cadr roots))
               (length (delete-duplicates (map cadr roots))))
            "duplicate recovery-root names")
    (for-each
     (lambda (tuple)
       (let ((name
              (string-append "candidate-g" (number->string
                                             (tuple-generation tuple)))))
         (ensure (find (lambda (root)
                         (and (string=? (list-ref root 1) name)
                              (string=? (list-ref root 2)
                                        (tuple-target tuple))))
                       roots)
                 "delete tuple lacks exact per-generation recovery root: ~a"
                 name)))
     deleted)
    (ensure (find (lambda (root)
                    (and (string=? (list-ref root 1) "old-bootcfg")
                         (string=? (list-ref root 2) old-target)))
                  roots)
            "old bootcfg recovery root is missing")
    (ensure (find (lambda (root)
                    (and (string=? (list-ref root 1) "new-bootcfg")
                         (string=? (list-ref root 2) new-target)))
                  roots)
            "new bootcfg recovery root is missing"))
  (assert-protected-records records)
  (ensure
   (exact-record-set? (records-with-key records "protected-file")
                      %expected-protected-files)
   "protected-file tuples differ from the reviewed fixture")
  (ensure
   (exact-record-set? (records-with-key records "protected-symlink")
                      %expected-protected-symlinks)
   "protected-symlink tuples differ from the reviewed fixture")
  (let ((store (single-record records "store-names" 3))
        (registry (single-record records "crash-registry" 3))
        (inputs (multi-records records "implementation-input" 4)))
    (ensure (equal? store %store-names-record)
            "store-name inventory differs from the reviewed fixture")
    (ensure (and (string=? (list-ref registry 1) %crash-registry-path)
                 (string=? (list-ref registry 2) %crash-registry-sha))
            "crash registry differs from the reviewed fixture")
    (ensure (and (decimal-string? (list-ref store 1))
                 (hex-string? (list-ref store 2) 64))
            "store-name inventory tuple is invalid")
    (ensure (and (safe-relative-path? (list-ref registry 1))
                 (hex-string? (list-ref registry 2) 64))
            "crash registry tuple is invalid")
    (ensure (pair? inputs) "transaction implementation inputs are empty")
    (for-each
     (lambda (input)
       (ensure (safe-name? (list-ref input 1))
               "unsafe implementation-input label: ~s" (list-ref input 1))
       (ensure (safe-relative-path? (list-ref input 2))
               "unsafe implementation-input path: ~s" (list-ref input 2))
       (ensure (hex-string? (list-ref input 3) 64)
               "invalid implementation-input digest"))
     inputs)
    (ensure (= (length (map cadr inputs))
               (length (delete-duplicates (map cadr inputs))))
            "duplicate implementation-input labels")
    (ensure (= (length (map (lambda (input) (list-ref input 2)) inputs))
               (length
                (delete-duplicates
                 (map (lambda (input) (list-ref input 2)) inputs))))
            "duplicate implementation-input paths")
    (ensure
     (exact-record-set?
      (map (lambda (input)
             (list (list-ref input 1) (list-ref input 2)))
           inputs)
      %expected-implementation-inputs)
     "implementation-input label/path mappings differ from the reviewed fixture"))
  records)

(define (context-ref context key)
  (let ((entry (assq key context)))
    (ensure entry "internal transaction context lacks ~s" key)
    (cdr entry)))

(define (manifest-record context key fields)
  (single-record (context-ref context 'records) key fields))

(define (manifest-records context key fields)
  (multi-records (context-ref context 'records) key fields))

(define (make-context manifest root repository)
  (let* ((canonical-root (canonical-directory root "fixture root"))
         (canonical-repository
          (canonical-directory repository "repository"))
         (records
          (sk:assert-transaction-manifest (sk:read-tsv manifest)))
         (expected-sha (or (getenv "SK_P52B_D3_MANIFEST_SHA") ""))
         (actual-sha (sk:file-sha256 manifest))
         (transaction-base
          (fixture-path canonical-root
                        (record-value records "transaction-base")))
         (recovery-base
          (fixture-path canonical-root
                        (record-value records "recovery-base"))))
    (ensure (hex-string? expected-sha 64)
            "SK_P52B_D3_MANIFEST_SHA must bind the fixture manifest")
    (ensure (string=? expected-sha actual-sha)
            "fixture manifest SHA256 mismatch")
    (ensure (string=?
             (read-text (string-append canonical-root "/"
                                       %fixture-sentinel))
             (string-append %fixture-sentinel-value "\n"))
            "fixture sentinel is missing or invalid")
    `((manifest . ,manifest)
      (manifest-sha . ,actual-sha)
      (root . ,canonical-root)
      (repository . ,canonical-repository)
      (records . ,records)
      (transaction-base . ,transaction-base)
      (transaction-dir
       . ,(string-append transaction-base "/" actual-sha))
      (recovery-base . ,recovery-base)
      (recovery-dir
       . ,(string-append recovery-base "/" actual-sha))
      (profile-dir
       . ,(fixture-path canonical-root "/var/guix/profiles"))
      (journal
       . ,(string-append transaction-base "/" actual-sha "/journal.tsv"))
      (backup
       . ,(string-append transaction-base "/" actual-sha "/old-grub.cfg"))
      (quarantine
       . ,(string-append transaction-base "/" actual-sha "/quarantine")))))

(define (assert-repository-inputs context)
  (let ((repository (context-ref context 'repository)))
    (for-each
     (lambda (record)
       (let ((label (list-ref record 1))
             (path (repository-file repository (list-ref record 2)))
             (expected (list-ref record 3)))
         (ensure-file-hash path expected label)))
     (manifest-records context "implementation-input" 4))
    (let* ((source (manifest-record context "new-grub-source" 4))
           (path (repository-file repository (list-ref source 1))))
      (ensure-file-hash path (list-ref source 2) "tracked D2b GRUB artifact")
      (ensure-file-size path
                        (string->number (list-ref source 3) 10)
                        "tracked D2b GRUB artifact"))
    (let* ((registry (manifest-record context "crash-registry" 3))
           (path (repository-file repository (list-ref registry 1))))
      (ensure-file-hash path (list-ref registry 2) "crash-point registry"))))

(define (store-name-digest directory)
  (let* ((names
          (sort
           (scandir directory
                    (lambda (name)
                      (not (member name '("." "..")))))
           string<?))
         (text
          (if (null? names)
              ""
              (string-append (string-join names "\n") "\n"))))
    (cons (length names) (string-sha256 text))))

(define (assert-store-inputs context)
  (let* ((root (context-ref context 'root))
         (store-directory
          (ensure-real-logical-directory
           root "/gnu/store" "synthetic store"))
         (store-record (manifest-record context "store-names" 3))
         (snapshot (store-name-digest store-directory))
         (old (manifest-record context "old-bootcfg" 4))
         (new-store (manifest-record context "new-grub-store" 4))
         (installed (manifest-record context "installed-grub" 5))
         (old-file (fixture-path root (list-ref old 3)))
         (new-file (fixture-path root (list-ref new-store 1))))
    (ensure (= (car snapshot)
               (string->number (list-ref store-record 1) 10))
            "synthetic store-name count drift")
    (ensure (string=? (cdr snapshot) (list-ref store-record 2))
            "synthetic store-name digest drift")
    (ensure-file-hash old-file (list-ref installed 2)
                      "old bootcfg store item")
    (ensure-file-size old-file
                      (string->number (list-ref installed 3) 10)
                      "old bootcfg store item")
    (ensure-file-hash new-file (list-ref new-store 2)
                      "new bootcfg store item")
    (ensure-file-size new-file
                      (string->number (list-ref new-store 3) 10)
                      "new bootcfg store item")
    (ensure (string=?
             (read-text new-file)
             (read-text
              (repository-file
               (context-ref context 'repository)
               (list-ref (manifest-record context "new-grub-source" 4) 1))))
            "new bootcfg store item differs byte-for-byte from tracked D2b")
    (for-each
     (lambda (tuple)
       (ensure-real-logical-directory
        root
        (tuple-target tuple)
        (string-append
         "System store target generation "
         (number->string (tuple-generation tuple)))))
     (append (manifest-records context "retain" 5)
             (manifest-records context "delete" 5)))))

(define (assert-protected-surfaces context)
  (let ((root (context-ref context 'root)))
    (for-each
     (lambda (record)
       (ensure-file-hash (fixture-path root (list-ref record 1))
                         (list-ref record 2)
                         (string-append "protected file "
                                        (list-ref record 1))))
     (manifest-records context "protected-file" 3))
    (for-each
     (lambda (record)
       (ensure-symlink-tuple
        root
        (list-ref record 1)
        (list-ref record 2)
        (list-ref record 3)
        (string-append "protected symlink " (list-ref record 1))))
     (manifest-records context "protected-symlink" 4))))

(define (assert-fixture-layout context)
  (let ((root (context-ref context 'root)))
    (for-each
     (lambda (entry)
       (ensure-real-logical-directory
        root (car entry) (cdr entry)))
     '(("/var" . "fixture /var")
       ("/var/guix" . "fixture /var/guix")
       ("/var/guix/profiles" . "fixture profiles")
       ("/var/guix/gcroots" . "fixture GC roots")
       ("/boot" . "fixture /boot")
       ("/boot/grub" . "fixture GRUB directory")
       ("/gnu" . "fixture /gnu")
       ("/gnu/store" . "fixture store")))
    (ensure (real-directory? (context-ref context 'transaction-base))
            "fixture transaction base is missing")
    (ensure (real-directory? (context-ref context 'recovery-base))
            "fixture recovery-root base is missing")
    (ensure (= (stat:dev (stat (context-ref context 'transaction-base)))
               (stat:dev (stat (context-ref context 'profile-dir))))
            "fixture transaction quarantine and System profile cross filesystems")))

(define (system-inventory context)
  (let* ((directory (context-ref context 'profile-dir))
         (root (context-ref context 'root))
         (names
          (scandir
           directory
           (lambda (name)
             (and (string-prefix? "system-" name)
                  (string-suffix? "-link" name)
                  (let ((middle
                         (substring name
                                    (string-length "system-")
                                    (- (string-length name)
                                       (string-length "-link")))))
                    (decimal-string? middle)))))))
    (sort
     (map
      (lambda (name)
        (let* ((path (string-append directory "/" name))
               (generation-text
                (substring name
                           (string-length "system-")
                           (- (string-length name)
                              (string-length "-link")))))
          (ensure (eq? 'symlink (path-kind path))
                  "System generation path is not a symlink: ~a" name)
          (let ((canonical (logical-canonical root path)))
            (ensure canonical
                    "System generation is dangling or escaped: ~a" name)
            (list (string->number generation-text 10)
                  (string-append "/var/guix/profiles/" name)
                  (readlink path)
                  canonical))))
      names)
     (lambda (left right) (< (car left) (car right))))))

(define (expected-inventory context kind)
  (sort
   (map (lambda (tuple)
          (list (tuple-generation tuple)
                (tuple-link tuple)
                (tuple-raw tuple)
                (tuple-target tuple)))
        (manifest-records context kind 5))
   (lambda (left right) (< (car left) (car right)))))

(define (profile-state context)
  (let ((actual (system-inventory context))
        (prepared
         (sort
          (append (expected-inventory context "retain")
                  (expected-inventory context "delete"))
          (lambda (left right) (< (car left) (car right)))))
        (applied (expected-inventory context "retain")))
    (cond
     ((equal? actual prepared) 'prepared)
     ((equal? actual applied) 'applied)
     (else 'partial))))

(define (grub-state context)
  (let* ((root (context-ref context 'root))
         (record (manifest-record context "installed-grub" 5))
         (new-store (manifest-record context "new-grub-store" 4))
         (path (fixture-path root (list-ref record 1)))
         (old-sha (list-ref record 2))
         (old-size (string->number (list-ref record 3) 10))
         (mode (string->number (list-ref record 4) 10))
         (new-sha (list-ref new-store 2))
         (new-size (string->number (list-ref new-store 3) 10)))
    (ensure (eq? 'regular (path-kind path))
            "installed fixture GRUB is not a regular file")
    (let ((actual (sk:file-sha256 path)))
      (cond
       ((string=? actual old-sha)
        (ensure-file-size path old-size "installed old fixture GRUB")
        (ensure-file-mode path mode "installed old fixture GRUB")
        'old)
       ((string=? actual new-sha)
        (ensure-file-size path new-size "installed new fixture GRUB")
        (ensure-file-mode path mode "installed new fixture GRUB")
        'new)
       (else (%fail "installed fixture GRUB has unknown bytes: ~a" actual))))))

(define (bootcfg-state context)
  (let* ((root (context-ref context 'root))
         (old (manifest-record context "old-bootcfg" 4))
         (new (manifest-record context "new-bootcfg" 4))
         (path (fixture-path root (list-ref old 1))))
    (ensure (eq? 'symlink (path-kind path))
            "fixture bootcfg is not a symlink")
    (let ((raw (readlink path))
          (canonical (logical-canonical root path)))
      (cond
       ((and (string=? raw (list-ref old 2))
             (equal? canonical (list-ref old 3)))
        'old)
       ((and (string=? raw (list-ref new 2))
             (equal? canonical (list-ref new 3)))
        'new)
       (else
        (%fail "fixture bootcfg has an unknown raw/canonical tuple"))))))

(define (recovery-root-path context root-record)
  (string-append (context-ref context 'recovery-dir)
                 "/"
                 (list-ref root-record 1)))

(define (expected-root-physical-target context root-record)
  (fixture-path (context-ref context 'root) (list-ref root-record 2)))

(define (root-state context root-record)
  (let ((path (recovery-root-path context root-record))
        (target (expected-root-physical-target context root-record)))
    (case (path-kind path)
      ((absent) 'absent)
      ((symlink)
       (if (and (string=? (readlink path) target)
                (string=? (or (logical-canonical
                               (context-ref context 'root)
                               path)
                              "")
                          (list-ref root-record 2)))
           'exact
           'foreign))
      (else 'foreign))))

(define (recovery-state context)
  (let ((directory (context-ref context 'recovery-dir))
        (roots (manifest-records context "recovery-root" 3)))
    (case (path-kind directory)
      ((absent)
       (if (all (lambda (root)
                  (eq? 'absent (root-state context root)))
                roots)
           'absent
           'foreign))
      ((directory)
       (let* ((names
               (sort (scandir directory
                              (lambda (name)
                                (not (member name '("." "..")))))
                     string<?))
              (expected (sort (map (lambda (root) (list-ref root 1)) roots)
                              string<?))
              (states (map (lambda (root) (root-state context root)) roots)))
         (cond
          ((not (all (lambda (name) (member name expected)) names)) 'foreign)
          ((all (lambda (state) (eq? state 'exact)) states) 'exact)
          ((any (lambda (state) (eq? state 'foreign)) states) 'foreign)
          (else 'partial))))
      (else 'foreign))))

(define (expanded-crash-points context)
  (let* ((registry-record
          (manifest-record context "crash-registry" 3))
         (registry-file
          (repository-file (context-ref context 'repository)
                           (list-ref registry-record 1)))
         (records (sk:read-tsv registry-file))
         (roots
          (map (lambda (record) (list-ref record 1))
               (manifest-records context "recovery-root" 3)))
         (generations
          (map (lambda (record) (list-ref record 1))
               (manifest-records context "delete" 5))))
    (ensure (and (pair? records)
                 (= (length (car records)) 2)
                 (string=? (caar records) "schema")
                 (string=? (cadar records) %registry-schema))
            "crash-point registry schema is invalid")
    (let ((points
           (append-map
            (lambda (record)
              (ensure (and (list? record)
                           (= (length record) 3)
                           (member (car record)
                                   '("point" "root-point" "link-point")))
                      "unknown crash-point registry row: ~s" record)
              (match record
                (("point" category label)
                  (ensure (member category '("forward" "rollback"))
                          "unknown crash-point category: ~a" category)
                  (list (list category label)))
                (("root-point" category label)
                  (ensure (member category '("forward" "rollback"))
                          "unknown root crash-point category: ~a" category)
                  (map (lambda (root)
                         (list category (string-append label ":" root)))
                       roots))
                (("link-point" category label)
                  (ensure (member category '("forward" "rollback"))
                          "unknown link crash-point category: ~a" category)
                  (map (lambda (generation)
                         (list category (string-append label ":" generation)))
                       generations))))
            (cdr records))))
      (ensure (= (length (map cadr points))
                 (length (delete-duplicates (map cadr points))))
              "crash-point registry expands to duplicate labels")
      points)))

(define (maybe-stop! context label)
  (ensure (member label (map cadr (expanded-crash-points context)))
          "implementation crash point is undeclared: ~a" label)
  (when (string=? (or (getenv "SK_P52B_D3_STOP_AFTER") "") label)
    (format (current-error-port)
            "guix-system-pruning-transaction: STOP: ~a~%" label)
    (force-output (current-error-port))
    (case (string->symbol
           (or (getenv "SK_P52B_D3_STOP_MODE") "exit"))
      ((exit) (primitive-exit 97))
      ((term)
       (kill (getpid) SIGTERM)
       (primitive-exit 143))
      ((kill)
       (kill (getpid) SIGKILL)
       (primitive-exit 137))
      (else
       (%fail "unknown fixture stop mode")))))

(define %journal-events
  '("BEGIN"
    "BACKUP-DONE"
    "ROOT-CREATE-INTENT"
    "ROOT-CREATE-DONE"
    "ROOTS-READY"
    "GRUB-REPLACE-INTENT"
    "GRUB-REPLACE-DONE"
    "BOOTCFG-PROMOTE-INTENT"
    "BOOTCFG-PROMOTE-DONE"
    "LINK-EXCLUDE-INTENT"
    "LINK-EXCLUDE-DONE"
    "LINKS-STAGED"
    "LINK-DISCARD-INTENT"
    "LINK-DISCARD-DONE"
    "LINKS-COMMITTED"
    "POSTFLIGHT-VERIFIED"
    "COMMITTED"
    "ROOT-REMOVE-INTENT"
    "ROOT-REMOVE-DONE"
    "COMPLETE"
    "ROLLBACK-BEGIN"
    "ROOT-ENSURE-INTENT"
    "ROOT-ENSURE-DONE"
    "LINK-RESTORE-INTENT"
    "LINK-RESTORE-DONE"
    "LINKS-RESTORED"
    "GRUB-RESTORE-INTENT"
    "GRUB-RESTORE-DONE"
    "BOOTCFG-RESTORE-INTENT"
    "BOOTCFG-RESTORE-DONE"
    "PRESTATE-VERIFIED"
    "ROLLBACK-ROOT-REMOVE-INTENT"
    "ROLLBACK-ROOT-REMOVE-DONE"
    "ROLLED-BACK"
    "FORWARD-RECOVERY-BEGIN"))

(define (journal-header context)
  (list
   (list "schema" %journal-schema)
   (list "manifest" (context-ref context 'manifest-sha))
   (list "mode" "FIXTURE-ONLY")
   (list "transaction" (context-ref context 'manifest-sha))))

(define (tsv-line record)
  (string-append (string-join record "\t") "\n"))

(define (journal-header-text context)
  (string-concatenate (map tsv-line (journal-header context))))

(define (journal-payload sequence event subject previous)
  (string-join
   (list (number->string sequence) event subject previous)
   "\t"))

(define (journal-record sequence event subject previous)
  (let ((payload (journal-payload sequence event subject previous)))
    (list "event"
          (number->string sequence)
          event
          subject
          previous
          (string-sha256 payload))))

(define (event-subject-valid? context event subject)
  (let ((root-names
         (map (lambda (record) (list-ref record 1))
              (manifest-records context "recovery-root" 3)))
        (generations
         (map (lambda (record) (list-ref record 1))
              (manifest-records context "delete" 5))))
    (cond
     ((member event
              '("ROOT-CREATE-INTENT" "ROOT-CREATE-DONE"
                "ROOT-REMOVE-INTENT" "ROOT-REMOVE-DONE"
                "ROOT-ENSURE-INTENT" "ROOT-ENSURE-DONE"
                "ROLLBACK-ROOT-REMOVE-INTENT"
                "ROLLBACK-ROOT-REMOVE-DONE"))
      (member subject root-names))
     ((member event
              '("LINK-EXCLUDE-INTENT" "LINK-EXCLUDE-DONE"
                "LINK-DISCARD-INTENT" "LINK-DISCARD-DONE"
                "LINK-RESTORE-INTENT" "LINK-RESTORE-DONE"))
      (member subject generations))
     (else (string=? subject "-")))))

(define (read-journal context)
  (let* ((file (context-ref context 'journal))
         (records (sk:read-tsv file))
         (header (journal-header context)))
    (ensure (>= (length records) 5)
            "transaction journal is truncated")
    (ensure (equal? (take records 4) header)
            "transaction journal header or identity drift")
    (let loop ((remaining (drop records 4))
               (expected-sequence 1)
               (previous (string-sha256 (journal-header-text context)))
               (result '()))
      (if (null? remaining)
          (reverse result)
          (let ((record (car remaining)))
            (ensure (and (list? record)
                         (= (length record) 6)
                         (string=? (car record) "event"))
                    "journal row has an invalid closed shape: ~s"
                    record)
            (match record
              (("event" sequence-text event subject prior digest)
               (ensure (decimal-string? sequence-text)
                       "journal sequence is not decimal")
               (let ((sequence (string->number sequence-text 10)))
                 (ensure (= sequence expected-sequence)
                         "journal sequence is missing, duplicated, or reordered")
                 (ensure (member event %journal-events)
                         "journal contains unknown event: ~a" event)
                 (ensure (event-subject-valid? context event subject)
                         "journal event subject is invalid: ~a ~a"
                         event subject)
                 (ensure (string=? prior previous)
                         "journal hash chain predecessor drift")
                 (ensure (string=?
                          digest
                          (string-sha256
                           (journal-payload sequence event subject prior)))
                         "journal event digest drift")
                 (loop (cdr remaining)
                       (+ expected-sequence 1)
                       digest
                       (cons record result))))))))))

(define (journal-event? events name)
  (any (lambda (record) (string=? (list-ref record 2) name))
       events))

(define (journal-last-event events)
  (and (pair? events) (list-ref (last events) 2)))

(define (write-initial-journal! context)
  (let* ((header (journal-header-text context))
         (seed (string-sha256 header))
         (begin (journal-record 1 "BEGIN" "-" seed))
         (text (string-append header (tsv-line begin))))
    (atomic-write-text! (context-ref context 'journal) text)
    (maybe-stop! context "journal-BEGIN")))

(define (append-journal! context event subject)
  (ensure (member event %journal-events)
          "internal unknown journal event: ~a" event)
  (ensure (event-subject-valid? context event subject)
          "internal invalid journal subject: ~a ~a" event subject)
  (let* ((events (read-journal context))
         (sequence (+ (length events) 1))
         (previous (list-ref (last events) 5))
         (record (journal-record sequence event subject previous))
         (text (string-append (journal-header-text context)
                              (string-concatenate (map tsv-line events))
                              (tsv-line record))))
    (atomic-write-text! (context-ref context 'journal) text)
    (let ((written (read-journal context)))
      (ensure (and (= (length written) sequence)
                   (equal? (last written) record))
              "journal append did not persist the exact validated event"))))

(define (assert-no-orphan-journal-files context)
  (let ((directory (context-ref context 'transaction-dir)))
    (when (real-directory? directory)
      (for-each
       (lambda (name)
         (when (string-prefix? "journal.tsv." name)
           (%fail "orphaned atomic journal temporary requires review: ~a"
                  name)))
       (scandir directory
                (lambda (name) (not (member name '("." "..")))))))))

(define (grub-path context)
  (fixture-path
   (context-ref context 'root)
   (list-ref (manifest-record context "installed-grub" 5) 1)))

(define (bootcfg-path context)
  (fixture-path
   (context-ref context 'root)
   (list-ref (manifest-record context "old-bootcfg" 4) 1)))

(define (grub-temporary context)
  (string-append (grub-path context) ".p52b-new"))

(define (bootcfg-temporary context)
  (string-append (bootcfg-path context) ".p52b-new"))

(define (quarantine-link context tuple)
  (string-append (context-ref context 'quarantine)
                 "/"
                 (basename (fixture-path
                            (context-ref context 'root)
                            (tuple-link tuple)))))

(define (exact-file-sha? path expected)
  (and (eq? 'regular (path-kind path))
       (string=? (sk:file-sha256 path) expected)))

(define (exact-bootcfg-temporary? context path)
  (and (eq? 'symlink (path-kind path))
       (let* ((old (manifest-record context "old-bootcfg" 4))
              (new (manifest-record context "new-bootcfg" 4))
              (raw (readlink path)))
         (or (string=? raw (list-ref old 2))
             (string=? raw (list-ref new 2))))))

(define (reconcile-temporaries! context)
  (let* ((old-sha
          (list-ref (manifest-record context "installed-grub" 5) 2))
         (new-sha
          (list-ref (manifest-record context "new-grub-store" 4) 2))
         (grub-temp (grub-temporary context))
         (bootcfg-temp (bootcfg-temporary context)))
    (delete-file-if-exact!
     grub-temp
     (lambda (path)
       (or (exact-file-sha? path old-sha)
           (exact-file-sha? path new-sha)))
     "GRUB")
    (delete-file-if-exact!
     bootcfg-temp
     (lambda (path) (exact-bootcfg-temporary? context path))
     "bootcfg")))

(define (assert-static-surfaces context)
  (assert-fixture-layout context)
  (assert-repository-inputs context)
  (assert-store-inputs context)
  (assert-protected-surfaces context)
  (ensure (not (eq? 'foreign (recovery-state context)))
          "fixture recovery-root directory has foreign state"))

(define (assert-profile-prepared context)
  (ensure (eq? 'prepared (profile-state context))
          "System profile is not in exact PREPARED state")
  (for-each
   (lambda (tuple)
     (ensure-symlink-tuple
      (context-ref context 'root)
      (tuple-link tuple)
      (tuple-raw tuple)
      (tuple-target tuple)
      (string-append "System generation "
                     (number->string (tuple-generation tuple)))))
   (append (manifest-records context "retain" 5)
           (manifest-records context "delete" 5))))

(define (assert-profile-applied context)
  (ensure (eq? 'applied (profile-state context))
          "System profile is not in exact APPLIED state")
  (for-each
   (lambda (tuple)
     (ensure-symlink-tuple
      (context-ref context 'root)
      (tuple-link tuple)
      (tuple-raw tuple)
      (tuple-target tuple)
      (string-append "retained System generation "
                     (number->string (tuple-generation tuple)))))
   (manifest-records context "retain" 5)))

(define (assert-prestate context roots)
  (assert-static-surfaces context)
  (assert-profile-prepared context)
  (ensure (eq? 'old (grub-state context))
          "installed GRUB is not the exact old bytes")
  (ensure (eq? 'old (bootcfg-state context))
          "bootcfg is not the exact old tuple")
  (when roots
    (ensure (eq? 'absent (recovery-state context))
            "transaction recovery roots remain in prestate"))
  #t)

(define (assert-forward-state context roots)
  (assert-static-surfaces context)
  (assert-profile-applied context)
  (ensure (eq? 'new (grub-state context))
          "installed GRUB is not the exact new bytes")
  (ensure (eq? 'new (bootcfg-state context))
          "bootcfg is not the exact new tuple")
  (when roots
    (ensure (eq? 'exact (recovery-state context))
            "transaction recovery roots are not exact"))
  #t)

(define (begin-transaction! context)
  (ensure (eq? 'absent (path-kind (context-ref context 'transaction-dir)))
          "transaction directory already exists")
  (ensure (eq? 'absent (recovery-state context))
          "recovery-root transaction directory already exists")
  (assert-prestate context #t)
  (mkdir (context-ref context 'transaction-dir))
  (sync-directory! (context-ref context 'transaction-base))
  (mkdir (context-ref context 'quarantine))
  (sync-directory! (context-ref context 'transaction-dir))
  (write-initial-journal! context)
  (let* ((installed (manifest-record context "installed-grub" 5))
         (source (grub-path context))
         (backup (context-ref context 'backup))
         (mode (string->number (list-ref installed 4) 10)))
    (write-file-durable! backup (read-text source) mode)
    (ensure-file-hash backup (list-ref installed 2) "durable old GRUB backup")
    (ensure-file-size backup
                      (string->number (list-ref installed 3) 10)
                      "durable old GRUB backup")
    (ensure-file-mode backup mode "durable old GRUB backup")
    (append-journal! context "BACKUP-DONE" "-")
    (maybe-stop! context "after-backup")))

(define (create-recovery-directory! context)
  (case (path-kind (context-ref context 'recovery-dir))
    ((absent)
     (mkdir (context-ref context 'recovery-dir))
     (sync-directory! (context-ref context 'recovery-base)))
    ((directory) #t)
    (else (%fail "recovery-root transaction path is not a directory"))))

(define (create-recovery-root! context root-record prefix)
  (let* ((name (list-ref root-record 1))
         (path (recovery-root-path context root-record))
         (target (expected-root-physical-target context root-record))
         (logical-target (list-ref root-record 2)))
    (ensure (not (eq? 'absent (path-kind target)))
            "recovery-root target is missing: ~a" logical-target)
    (case (root-state context root-record)
      ((exact) #f)
      ((absent)
       (append-journal!
        context
        (if (string=? prefix "rollback")
            "ROOT-ENSURE-INTENT"
            "ROOT-CREATE-INTENT")
        name)
       (maybe-stop!
        context
        (string-append
         (if (string=? prefix "rollback")
             "before-rollback-root-ensure:"
             "before-root-create:")
         name))
       (symlink target path)
       (sync-directory! (context-ref context 'recovery-dir))
       (maybe-stop!
        context
        (string-append
         (if (string=? prefix "rollback")
             "after-rollback-root-ensure:"
             "after-root-create:")
         name))
       (ensure (eq? 'exact (root-state context root-record))
               "created recovery root does not match: ~a" name)
       (append-journal!
        context
        (if (string=? prefix "rollback")
            "ROOT-ENSURE-DONE"
            "ROOT-CREATE-DONE")
        name)
       (maybe-stop!
        context
        (string-append
         (if (string=? prefix "rollback")
             "journal-rollback-root-ensure-done:"
             "journal-root-create-done:")
         name)))
      (else
       (%fail "recovery-root path is occupied or retargeted: ~a" name)))))

(define (create-forward-roots! context)
  (create-recovery-directory! context)
  (for-each
   (lambda (root-record)
     (create-recovery-root! context root-record "forward"))
   (manifest-records context "recovery-root" 3))
  (ensure (eq? 'exact (recovery-state context))
          "recovery roots did not reach exact state")
  (append-journal! context "ROOTS-READY" "-")
  (maybe-stop! context "journal-ROOTS-READY"))

(define (install-grub-bytes! context direction)
  (let* ((forward? (eq? direction 'forward))
         (installed (manifest-record context "installed-grub" 5))
         (new-store (manifest-record context "new-grub-store" 4))
         (source
          (if forward?
              (fixture-path (context-ref context 'root)
                            (list-ref new-store 1))
              (context-ref context 'backup)))
         (expected
          (if forward? (list-ref new-store 2) (list-ref installed 2)))
         (expected-size
          (string->number
           (if forward? (list-ref new-store 3) (list-ref installed 3))
           10))
         (target (grub-path context))
         (temporary (grub-temporary context))
         (mode (string->number (list-ref installed 4) 10))
         (intent
          (if forward? "GRUB-REPLACE-INTENT" "GRUB-RESTORE-INTENT"))
         (done
          (if forward? "GRUB-REPLACE-DONE" "GRUB-RESTORE-DONE"))
         (before-temp
          (if forward? "before-grub-temp" "before-grub-restore-temp"))
         (after-temp
          (if forward? "after-grub-temp" "after-grub-restore-temp"))
         (before-rename
          (if forward? "before-grub-rename" "before-grub-restore-rename"))
         (after-rename
          (if forward? "after-grub-rename" "after-grub-restore-rename"))
         (journal-point
          (if forward? "journal-GRUB-REPLACED" "journal-GRUB-RESTORED")))
    (append-journal! context intent "-")
    (maybe-stop! context before-temp)
    (write-file-durable! temporary (read-text source) mode)
    (maybe-stop! context after-temp)
    (ensure-file-hash temporary expected "staged GRUB replacement")
    (ensure-file-size temporary expected-size "staged GRUB replacement")
    (ensure-file-mode temporary mode "staged GRUB replacement")
    (maybe-stop! context before-rename)
    (rename-file temporary target)
    (sync-directory! (dirname target))
    (maybe-stop! context after-rename)
    (ensure-file-hash target expected "installed GRUB replacement")
    (ensure-file-size target expected-size "installed GRUB replacement")
    (ensure-file-mode target mode "installed GRUB replacement")
    (append-journal! context done "-")
    (maybe-stop! context journal-point)))

(define (promote-bootcfg! context direction)
  (let* ((forward? (eq? direction 'forward))
         (record
          (manifest-record context
                           (if forward? "new-bootcfg" "old-bootcfg")
                           4))
         (target (bootcfg-path context))
         (temporary (bootcfg-temporary context))
         (raw (list-ref record 2))
         (canonical (list-ref record 3))
         (intent
          (if forward? "BOOTCFG-PROMOTE-INTENT"
              "BOOTCFG-RESTORE-INTENT"))
         (done
          (if forward? "BOOTCFG-PROMOTE-DONE"
              "BOOTCFG-RESTORE-DONE"))
         (before-temp
          (if forward? "before-bootcfg-temp"
              "before-bootcfg-restore-temp"))
         (after-temp
          (if forward? "after-bootcfg-temp"
              "after-bootcfg-restore-temp"))
         (before-rename
          (if forward? "before-bootcfg-rename"
              "before-bootcfg-restore-rename"))
         (after-rename
          (if forward? "after-bootcfg-rename"
              "after-bootcfg-restore-rename"))
         (journal-point
          (if forward? "journal-BOOTCFG-PROMOTED"
              "journal-BOOTCFG-RESTORED")))
    (append-journal! context intent "-")
    (maybe-stop! context before-temp)
    (ensure (eq? 'absent (path-kind temporary))
            "bootcfg transaction temporary is occupied")
    (symlink raw temporary)
    (sync-directory! (dirname temporary))
    (maybe-stop! context after-temp)
    (ensure-symlink-tuple
     (context-ref context 'root)
     (string-append
      (list-ref record 1)
      ".p52b-new")
     raw canonical "staged bootcfg replacement")
    (maybe-stop! context before-rename)
    (rename-file temporary target)
    (sync-directory! (dirname target))
    (maybe-stop! context after-rename)
    (ensure-symlink-tuple
     (context-ref context 'root)
     (list-ref record 1)
     raw canonical "active bootcfg replacement")
    (append-journal! context done "-")
    (maybe-stop! context journal-point)))

(define (exclude-link! context tuple)
  (let* ((generation (number->string (tuple-generation tuple)))
         (live (fixture-path (context-ref context 'root)
                             (tuple-link tuple)))
         (saved (quarantine-link context tuple)))
    (ensure-symlink-tuple
     (context-ref context 'root)
     (tuple-link tuple)
     (tuple-raw tuple)
     (tuple-target tuple)
     (string-append "candidate System generation " generation))
    (ensure (eq? 'absent (path-kind saved))
            "candidate quarantine path is occupied: ~a" generation)
    (append-journal! context "LINK-EXCLUDE-INTENT" generation)
    (maybe-stop! context (string-append "before-link-exclude:" generation))
    (ensure (eq? 'exact (recovery-state context))
            "recovery roots are not exact before candidate link exclusion")
    (rename-file live saved)
    (sync-directory! (context-ref context 'profile-dir))
    (sync-directory! (context-ref context 'quarantine))
    (maybe-stop! context (string-append "after-link-exclude:" generation))
    (ensure (and (eq? 'absent (path-kind live))
                 (eq? 'symlink (path-kind saved))
                 (string=? (readlink saved) (tuple-raw tuple)))
            "candidate link exclusion did not preserve exact tuple: ~a"
            generation)
    (append-journal! context "LINK-EXCLUDE-DONE" generation)
    (maybe-stop!
     context (string-append "journal-link-exclude-done:" generation))))

(define (exclude-links! context)
  (for-each
   (lambda (tuple) (exclude-link! context tuple))
   (manifest-records context "delete" 5))
  (ensure (eq? 'applied (profile-state context))
          "profile did not exclude exactly the selected links")
  (append-journal! context "LINKS-STAGED" "-")
  (maybe-stop! context "journal-LINKS-STAGED"))

(define (discard-link! context tuple)
  (let* ((generation (number->string (tuple-generation tuple)))
         (saved (quarantine-link context tuple)))
    (ensure (and (eq? 'symlink (path-kind saved))
                 (string=? (readlink saved) (tuple-raw tuple)))
            "quarantined link tuple drift: ~a" generation)
    (append-journal! context "LINK-DISCARD-INTENT" generation)
    (maybe-stop! context (string-append "before-link-discard:" generation))
    (ensure (eq? 'exact (recovery-state context))
            "recovery roots are not exact before candidate link discard")
    (delete-file saved)
    (sync-directory! (context-ref context 'quarantine))
    (maybe-stop! context (string-append "after-link-discard:" generation))
    (ensure (eq? 'absent (path-kind saved))
            "quarantined candidate remains after discard: ~a" generation)
    (append-journal! context "LINK-DISCARD-DONE" generation)
    (maybe-stop!
     context (string-append "journal-link-discard-done:" generation))))

(define (discard-links! context)
  (for-each
   (lambda (tuple) (discard-link! context tuple))
   (manifest-records context "delete" 5))
  (rmdir (context-ref context 'quarantine))
  (sync-directory! (context-ref context 'transaction-dir))
  (append-journal! context "LINKS-COMMITTED" "-")
  (maybe-stop! context "journal-LINKS-COMMITTED"))

(define (remove-recovery-root! context root-record direction)
  (let* ((forward? (eq? direction 'forward))
         (name (list-ref root-record 1))
         (path (recovery-root-path context root-record))
         (intent
          (if forward? "ROOT-REMOVE-INTENT"
              "ROLLBACK-ROOT-REMOVE-INTENT"))
         (done
          (if forward? "ROOT-REMOVE-DONE"
              "ROLLBACK-ROOT-REMOVE-DONE"))
         (before
          (string-append
           (if forward?
               "before-forward-root-remove:"
               "before-rollback-root-remove:")
           name))
         (after
          (string-append
           (if forward?
               "after-forward-root-remove:"
               "after-rollback-root-remove:")
           name))
         (journal-point
          (string-append
           (if forward?
               "journal-forward-root-remove-done:"
               "journal-rollback-root-remove-done:")
           name)))
    (case (root-state context root-record)
      ((absent) #f)
      ((exact)
       (append-journal! context intent name)
       (maybe-stop! context before)
       (delete-file path)
       (sync-directory! (context-ref context 'recovery-dir))
       (maybe-stop! context after)
       (ensure (eq? 'absent (root-state context root-record))
               "transaction recovery root remains: ~a" name)
       (append-journal! context done name)
       (maybe-stop! context journal-point))
      (else
       (%fail "refusing to remove foreign recovery root: ~a" name)))))

(define (remove-recovery-roots! context direction)
  (for-each
   (lambda (root-record)
     (remove-recovery-root! context root-record direction))
   (manifest-records context "recovery-root" 3))
  (case (path-kind (context-ref context 'recovery-dir))
    ((absent) #t)
    ((directory)
     (ensure (null?
              (scandir (context-ref context 'recovery-dir)
                       (lambda (name)
                         (not (member name '("." ".."))))))
             "recovery-root directory contains foreign entries")
     (rmdir (context-ref context 'recovery-dir))
     (sync-directory! (context-ref context 'recovery-base)))
    (else
     (%fail "recovery-root transaction path has unsafe type"))))

(define (restore-link! context tuple)
  (let* ((generation (number->string (tuple-generation tuple)))
         (root (context-ref context 'root))
         (live (fixture-path root (tuple-link tuple)))
         (saved (quarantine-link context tuple))
         (target (fixture-path root (tuple-target tuple))))
    (append-journal! context "LINK-RESTORE-INTENT" generation)
    (maybe-stop! context (string-append "before-link-restore:" generation))
    (let ((live-kind (path-kind live))
          (saved-kind (path-kind saved)))
      (cond
       ((and (eq? live-kind 'symlink)
             (eq? saved-kind 'absent))
        (ensure (and (string=? (readlink live) (tuple-raw tuple))
                     (equal? (logical-canonical root live)
                             (tuple-target tuple)))
                "occupied rollback link differs from manifest: ~a"
                generation))
       ((and (eq? live-kind 'absent)
             (eq? saved-kind 'symlink))
        (ensure (string=? (readlink saved) (tuple-raw tuple))
                "quarantined rollback tuple drift: ~a" generation)
        (ensure (not (eq? 'absent (path-kind target)))
                "rollback store target is missing: ~a" (tuple-target tuple))
        (rename-file saved live)
        (sync-directory! (context-ref context 'profile-dir))
        (sync-directory! (context-ref context 'quarantine)))
       ((and (eq? live-kind 'absent)
             (eq? saved-kind 'absent))
        (ensure (not (eq? 'absent (path-kind target)))
                "rollback store target is missing: ~a" (tuple-target tuple))
        (symlink (tuple-raw tuple) live)
        (sync-directory! (context-ref context 'profile-dir)))
       ((and (eq? live-kind 'symlink)
             (eq? saved-kind 'symlink))
        (%fail "rollback tuple exists both live and quarantined: ~a"
               generation))
       (else
        (%fail "rollback tuple has an occupied or unsafe path: ~a"
               generation))))
    (maybe-stop! context (string-append "after-link-restore:" generation))
    (ensure-symlink-tuple
     root (tuple-link tuple) (tuple-raw tuple) (tuple-target tuple)
     (string-append "restored System generation " generation))
    (ensure (eq? 'absent (path-kind saved))
            "quarantined tuple remained after restore: ~a" generation)
    (append-journal! context "LINK-RESTORE-DONE" generation)
    (maybe-stop!
     context (string-append "journal-link-restore-done:" generation))))

(define (restore-links! context)
  (for-each
   (lambda (tuple) (restore-link! context tuple))
   (manifest-records context "delete" 5))
  (case (path-kind (context-ref context 'quarantine))
    ((absent) #t)
    ((directory)
     (ensure (null?
              (scandir (context-ref context 'quarantine)
                       (lambda (name)
                         (not (member name '("." ".."))))))
             "quarantine contains foreign paths after rollback")
     (rmdir (context-ref context 'quarantine))
     (sync-directory! (context-ref context 'transaction-dir)))
    (else (%fail "quarantine has an unsafe type")))
  (assert-profile-prepared context)
  (append-journal! context "LINKS-RESTORED" "-")
  (maybe-stop! context "journal-LINKS-RESTORED"))

(define (assert-recoverable-link-state context)
  (let* ((root (context-ref context 'root))
         (expected-names
          (map (lambda (tuple)
                 (basename (fixture-path root (tuple-link tuple))))
               (append (manifest-records context "retain" 5)
                       (manifest-records context "delete" 5))))
         (actual-names
          (map (lambda (row) (basename (list-ref row 1)))
               (system-inventory context))))
    (ensure (all (lambda (name) (member name expected-names)) actual-names)
            "profile contains an unreviewed generation during recovery")
    (for-each
     (lambda (tuple)
       (ensure-symlink-tuple
        root (tuple-link tuple) (tuple-raw tuple) (tuple-target tuple)
        (string-append "retained generation "
                       (number->string (tuple-generation tuple)))))
     (manifest-records context "retain" 5))
    (for-each
     (lambda (tuple)
       (let* ((generation (number->string (tuple-generation tuple)))
              (live (fixture-path root (tuple-link tuple)))
              (saved (quarantine-link context tuple))
              (live-kind (path-kind live))
              (saved-kind (path-kind saved)))
         (ensure
          (or
           (and (eq? live-kind 'symlink)
                (eq? saved-kind 'absent)
                (string=? (readlink live) (tuple-raw tuple))
                (equal? (logical-canonical root live)
                        (tuple-target tuple)))
           (and (eq? live-kind 'absent)
                (eq? saved-kind 'symlink)
                (string=? (readlink saved) (tuple-raw tuple))
                (not (eq? 'absent
                          (path-kind
                           (fixture-path root (tuple-target tuple))))))
           (and (eq? live-kind 'absent)
                (eq? saved-kind 'absent)))
          "candidate generation has ambiguous recovery state: ~a"
          generation)))
     (manifest-records context "delete" 5))))

(define (assert-transaction-layout context events)
  (let* ((directory (context-ref context 'transaction-dir))
         (allowed '("journal.tsv" "old-grub.cfg" "quarantine"))
         (names
          (scandir directory
                   (lambda (name)
                     (not (member name '("." "..")))))))
    (ensure (all (lambda (name) (member name allowed)) names)
            "transaction directory contains foreign paths")
    (ensure (eq? 'regular (path-kind (context-ref context 'journal)))
            "transaction journal is not a regular file")
    (let ((installed (manifest-record context "installed-grub" 5)))
      (case (path-kind (context-ref context 'backup))
        ((absent)
         (ensure (not (journal-event? events "BACKUP-DONE"))
                 "journal records a missing old GRUB backup"))
        ((regular)
         (ensure-file-hash (context-ref context 'backup)
                           (list-ref installed 2)
                           "transaction old GRUB backup")
         (ensure-file-size (context-ref context 'backup)
                           (string->number (list-ref installed 3) 10)
                           "transaction old GRUB backup")
         (ensure-file-mode (context-ref context 'backup)
                           (string->number (list-ref installed 4) 10)
                           "transaction old GRUB backup"))
        (else
         (%fail "transaction old GRUB backup has an unsafe type"))))
    (case (path-kind (context-ref context 'quarantine))
      ((absent) #t)
      ((directory)
       (let ((expected
              (map (lambda (tuple)
                     (basename (fixture-path
                                (context-ref context 'root)
                                (tuple-link tuple))))
                   (manifest-records context "delete" 5))))
         (ensure
          (all (lambda (name) (member name expected))
               (scandir (context-ref context 'quarantine)
                        (lambda (name)
                          (not (member name '("." ".."))))))
          "transaction quarantine contains foreign paths")))
      (else (%fail "transaction quarantine has an unsafe type")))))

(define (ensure-rollback-roots! context)
  (create-recovery-directory! context)
  (for-each
   (lambda (root-record)
     (create-recovery-root! context root-record "rollback"))
   (manifest-records context "recovery-root" 3))
  (ensure (eq? 'exact (recovery-state context))
          "rollback recovery roots are not exact"))

(define (complete-forward-cleanup! context)
  (assert-static-surfaces context)
  (assert-profile-applied context)
  (ensure (eq? 'new (grub-state context))
          "postcommit recovery found non-new GRUB")
  (ensure (eq? 'new (bootcfg-state context))
          "postcommit recovery found non-new bootcfg")
  (remove-recovery-roots! context 'forward)
  (assert-forward-state context #f)
  (append-journal! context "COMPLETE" "-")
  (maybe-stop! context "journal-COMPLETE")
  'complete)

(define (rollback-precommit! context)
  (append-journal! context "ROLLBACK-BEGIN" "-")
  (maybe-stop! context "journal-ROLLBACK-BEGIN")
  (ensure-rollback-roots! context)
  (restore-links! context)
  (case (grub-state context)
    ((old) #t)
    ((new)
     (ensure (eq? 'regular (path-kind (context-ref context 'backup)))
             "old GRUB backup is missing during rollback")
     (install-grub-bytes! context 'rollback))
    (else (%fail "unrecognized GRUB state during rollback")))
  (case (bootcfg-state context)
    ((old) #t)
    ((new) (promote-bootcfg! context 'rollback))
    (else (%fail "unrecognized bootcfg state during rollback")))
  (assert-prestate context #f)
  (append-journal! context "PRESTATE-VERIFIED" "-")
  (maybe-stop! context "journal-PRESTATE-VERIFIED")
  (remove-recovery-roots! context 'rollback)
  (assert-prestate context #t)
  (append-journal! context "ROLLED-BACK" "-")
  (maybe-stop! context "journal-ROLLED-BACK")
  'rolled-back)

(define (assert-requested-crash-point context)
  (let ((requested (or (getenv "SK_P52B_D3_STOP_AFTER") "")))
    (unless (string-null? requested)
      (ensure (member requested (map cadr (expanded-crash-points context)))
              "requested crash point is not declared: ~a" requested))))

(define (assert-recognized-temporaries context)
  (let* ((old-sha
          (list-ref (manifest-record context "installed-grub" 5) 2))
         (new-sha
          (list-ref (manifest-record context "new-grub-store" 4) 2))
         (grub-temp (grub-temporary context))
         (bootcfg-temp (bootcfg-temporary context)))
    (unless (eq? 'absent (path-kind grub-temp))
      (ensure (or (exact-file-sha? grub-temp old-sha)
                  (exact-file-sha? grub-temp new-sha))
              "GRUB transaction temporary has unknown bytes"))
    (unless (eq? 'absent (path-kind bootcfg-temp))
      (ensure (exact-bootcfg-temporary? context bootcfg-temp)
              "bootcfg transaction temporary has unknown tuple"))))

(define (assert-no-terminal-temporaries context)
  (ensure (eq? 'absent (path-kind (grub-temporary context)))
          "terminal transaction retains a GRUB temporary")
  (ensure (eq? 'absent (path-kind (bootcfg-temporary context)))
          "terminal transaction retains a bootcfg temporary"))

(define (verify-transaction-state context)
  (assert-static-surfaces context)
  (assert-recognized-temporaries context)
  (case (path-kind (context-ref context 'transaction-dir))
    ((absent)
     (assert-prestate context #t)
     'prepared)
    ((directory)
     (assert-no-orphan-journal-files context)
     (let ((events (read-journal context)))
       (assert-transaction-layout context events)
       (cond
        ((string=? (or (journal-last-event events) "") "ROLLED-BACK")
         (assert-prestate context #t)
         (assert-no-terminal-temporaries context)
         'rolled-back)
        ((string=? (or (journal-last-event events) "") "COMPLETE")
         (assert-forward-state context #f)
         (ensure (eq? 'absent (recovery-state context))
                 "COMPLETE transaction retains recovery roots")
         (assert-no-terminal-temporaries context)
         'complete)
        (else
         (assert-recoverable-link-state context)
         (grub-state context)
         (bootcfg-state context)
         (ensure (not (eq? 'foreign (recovery-state context)))
                 "transaction recovery roots have foreign state")
         'recovery-required))))
    (else
     (%fail "transaction path has an unsafe type"))))

(define (apply-transaction! context)
  (ensure (eq? 'prepared (verify-transaction-state context))
          "fixture apply requires exact PREPARED state")
  (begin-transaction! context)
  (create-forward-roots! context)
  ;; The retained-only menu is installed while every generation link still
  ;; exists.  bootcfg is then promoted before any selected link is excluded.
  (install-grub-bytes! context 'forward)
  (promote-bootcfg! context 'forward)
  (exclude-links! context)
  (discard-links! context)
  (assert-forward-state context #t)
  (append-journal! context "POSTFLIGHT-VERIFIED" "-")
  (maybe-stop! context "journal-POSTFLIGHT-VERIFIED")
  (append-journal! context "COMMITTED" "-")
  (maybe-stop! context "journal-COMMITTED")
  (complete-forward-cleanup! context))

(define (recover-transaction! context)
  (ensure (eq? 'directory (path-kind (context-ref context 'transaction-dir)))
          "fixture recovery requires a transaction directory")
  (assert-no-orphan-journal-files context)
  (let ((events (read-journal context)))
    (assert-transaction-layout context events)
    (assert-static-surfaces context)
    (assert-recognized-temporaries context)
    (assert-recoverable-link-state context)
    (grub-state context)
    (bootcfg-state context)
    (ensure (not (eq? 'foreign (recovery-state context)))
            "transaction recovery roots have foreign state")
    (cond
     ((string=? (or (journal-last-event events) "") "ROLLED-BACK")
      (assert-prestate context #t)
      (assert-no-terminal-temporaries context)
      'rolled-back-no-op)
     ((string=? (or (journal-last-event events) "") "COMPLETE")
      (assert-forward-state context #f)
      (ensure (eq? 'absent (recovery-state context))
              "COMPLETE transaction retains recovery roots")
      (assert-no-terminal-temporaries context)
      'complete-no-op)
     (else
      (reconcile-temporaries! context)
      (if (journal-event? events "COMMITTED")
          (begin
            (append-journal! context "FORWARD-RECOVERY-BEGIN" "-")
            (complete-forward-cleanup! context))
          (rollback-precommit! context))))))

(define (assert-lock-parent directory label)
  (ensure (eq? 'directory (path-kind directory))
          "~a lock parent is not a real directory: ~a" label directory)
  (ensure (string=? (canonicalize-path directory) directory)
          "~a lock parent has a symlinked or escaped ancestor: ~a"
          label directory)
  (let ((metadata (lstat directory)))
    (ensure (= (stat:uid metadata) (getuid))
            "~a lock parent is not owned by the fixture user: ~a"
            label directory)
    (ensure (zero? (logand (stat:perms metadata) #o022))
            "~a lock parent is group- or world-writable: ~a"
            label directory)))

(define (open-persistent-lock-file file parent label)
  ;; Guix's with-file-lock/no-wait opens with "w0" and unlinks the lock after
  ;; release.  A fixture-controlled link could therefore truncate a file
  ;; outside the synthetic root, while unlink-on-release permits an inode
  ;; handoff race.  Open without truncation or symlink following, reject shared
  ;; inodes, and keep the lock inode in place.
  (case (path-kind file)
    ((absent) #t)
    ((regular)
     (let ((metadata (lstat file)))
       (ensure (= (stat:uid metadata) (getuid))
               "~a lock file is not owned by the fixture user: ~a"
               label file)
       (ensure (= (stat:nlink metadata) 1)
               "~a lock file has multiple hard links: ~a" label file)
       (ensure (zero? (stat:size metadata))
               "~a lock file contains foreign data: ~a" label file)))
    (else
     (%fail "~a lock path has an unsafe pre-open type: ~a" label file)))
  (let ((port
         (catch 'system-error
           (lambda ()
             (open file
                   (logior O_RDWR O_CREAT O_NOFOLLOW O_CLOEXEC O_NONBLOCK)
                   #o600))
           (lambda _arguments
             (%fail "~a lock path cannot be opened safely: ~a" label file)))))
    (catch #t
      (lambda ()
        (let ((opened (stat port))
              (named
               (catch 'system-error
                 (lambda () (lstat file))
                 (lambda _arguments
                   (%fail "~a lock path disappeared during open: ~a"
                          label file)))))
          (ensure (eq? 'regular (stat:type opened))
                  "~a lock path is not a regular file: ~a" label file)
          (ensure (eq? 'regular (stat:type named))
                  "~a lock path changed type during open: ~a" label file)
          (ensure (same-inode? opened named)
                  "~a lock path changed identity during open: ~a" label file)
          (ensure (= (stat:dev opened) (stat:dev (lstat parent)))
                  "~a lock path crosses filesystems: ~a" label file)
          (ensure (= (stat:uid opened) (getuid))
                  "~a lock file is not owned by the fixture user: ~a"
                  label file)
          (ensure (= (stat:nlink opened) 1)
                  "~a lock file has multiple hard links: ~a" label file)
          (ensure (zero? (stat:size opened))
                  "~a lock file contains foreign data: ~a" label file)
          (chmod port #o600)
          port))
      (lambda (key . arguments)
        (false-if-exception (close-port port))
        (apply throw key arguments)))))

(define (call-with-persistent-lock/no-wait file parent label handler thunk)
  (assert-lock-parent parent label)
  (let ((port (open-persistent-lock-file file parent label))
        (locked? #f))
    (dynamic-wind
      (const #t)
      (lambda ()
        (catch 'flock-error
          (lambda ()
            (fcntl-flock port 'write-lock #:wait? #f)
            (set! locked? #t)
            (let ((opened (stat port))
                  (named
                   (catch 'system-error
                     (lambda () (lstat file))
                     (lambda _arguments
                       (%fail "~a lock path disappeared after locking: ~a"
                              label file)))))
              (ensure (and (eq? 'regular (stat:type named))
                           (same-inode? opened named)
                           (= (stat:nlink opened) 1))
                      "~a lock path changed identity after locking: ~a"
                      label file))
            (thunk))
          (lambda arguments
            (apply handler arguments))))
      (lambda ()
        (when locked?
          (fcntl-flock port 'unlock))
        (close-port port)))))

(define (with-transaction-locks context thunk)
  (let ((transaction-lock
         (string-append (context-ref context 'transaction-base)
                        "/transaction.lock"))
        (profile-lock
         (string-append (context-ref context 'profile-dir)
                        "/system.lock")))
    (call-with-persistent-lock/no-wait
     transaction-lock (context-ref context 'transaction-base) "transaction"
     (lambda _ (%fail "fixture transaction lock is held"))
     (lambda ()
       (call-with-persistent-lock/no-wait
        profile-lock (context-ref context 'profile-dir) "System-profile"
        (lambda _
          (%fail "cooperative fixture System-profile lock is held"))
        (lambda ()
          (let ((seconds
                 (string->number
                  (or (getenv "SK_P52B_D3_HOLD_LOCK_SECONDS") "0")
                  10)))
            (ensure (and (integer? seconds)
                         (>= seconds 0)
                         (<= seconds 30))
                    "fixture lock hold must be an integer between 0 and 30 seconds")
            (when (> seconds 0) (sleep seconds))
            (thunk))))))))

(define (print-state action context state)
  (format #t
          "guix-system-pruning-transaction: PASS: action=~a state=~a manifest=~a mode=FIXTURE-ONLY authorization=NOT-GRANTED~%"
          action
          (string-upcase (symbol->string state))
          (context-ref context 'manifest-sha)))

(define (sk:run-fixture-transaction action manifest root repository)
  "Run ACTION against a sentinel-marked synthetic ROOT only."
  (ensure (member action
                  '("fixture-points"
                    "fixture-verify"
                    "fixture-apply"
                    "fixture-recover"))
          "unsupported fixture transaction action: ~a" action)
  (ensure (not (= (getuid) 0))
          "fixture transaction refuses uid 0")
  (let ((context (make-context manifest root repository)))
    (ensure (string=? (or (getenv "SK_GUIX_REVISION") "")
                      (record-value (context-ref context 'records)
                                    "guix-revision"))
            "running Guix revision differs from transaction manifest")
    (assert-requested-crash-point context)
    (with-transaction-locks
     context
     (lambda ()
       (cond
        ((string=? action "fixture-points")
         (for-each
          (lambda (point)
            (format #t "point\t~a\t~a~%" (car point) (cadr point)))
          (expanded-crash-points context))
         'points)
        ((string=? action "fixture-verify")
         (let ((state (verify-transaction-state context)))
           (print-state action context state)
           state))
        ((string=? action "fixture-apply")
         (let ((state (apply-transaction! context)))
           (print-state action context state)
           state))
        (else
         (let ((state (recover-transaction! context)))
           (print-state action context state)
           state)))))))
