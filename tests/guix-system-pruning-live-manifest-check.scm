;;; Pure positive and negative tests for the P5.2b-D4c.1 manifest.

(use-modules (sk system-pruning-live-manifest)
             (rnrs bytevectors)
             (srfi srfi-1))

(define %program "guix-system-pruning-live-manifest-check")
(define %checks 0)

(define (check condition label)
  (set! %checks (+ %checks 1))
  (unless condition
    (error %program label)))

(define (expect-failure thunk label)
  (set! %checks (+ %checks 1))
  (let ((failed?
         (catch sk:live-manifest-error-key
           (lambda ()
             (thunk)
             #f)
           (lambda _arguments #t))))
    (unless failed?
      (error %program
             (string-append "expected failure: " label)))))

(define (replace-row records key replacement)
  (map (lambda (record)
         (if (string=? (car record) key)
             replacement
             record))
       records))

(define (replace-group-row records key index replacement)
  (let ((seen 0))
    (map
     (lambda (record)
       (if (string=? (car record) key)
           (let ((current seen))
             (set! seen (+ seen 1))
             (if (= current index) replacement record))
           record))
     records)))

(define (remove-group-row records key index)
  (let ((seen 0))
    (filter-map
     (lambda (record)
       (if (string=? (car record) key)
           (let ((current seen))
             (set! seen (+ seen 1))
             (and (not (= current index)) record))
           record))
     records)))

(define (insert-before records key row)
  (let loop ((remaining records)
             (result '())
             (inserted? #f))
    (cond
     ((null? remaining)
      (reverse (if inserted? result (cons row result))))
     ((and (not inserted?)
           (string=? (caar remaining) key))
      (loop remaining (cons row result) #t))
     (else
      (loop (cdr remaining)
            (cons (car remaining) result)
            inserted?)))))

(define %system-a
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system")
(define %system-b
  "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system")
(define %system-c
  "/gnu/store/cccccccccccccccccccccccccccccccc-system")
(define %system-d
  "/gnu/store/dddddddddddddddddddddddddddddddd-system")
(define %system-f
  "/gnu/store/ffffffffffffffffffffffffffffffff-system")
(define %system-g
  "/gnu/store/gggggggggggggggggggggggggggggggg-system")
(define %system-h
  "/gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-system")
(define %home
  "/gnu/store/dddddddddddddddddddddddddddddddd-home")
(define %home-old
  "/gnu/store/11111111111111111111111111111111-home")
(define %pull
  "/gnu/store/ffffffffffffffffffffffffffffffff-profile")
(define %pull-old
  "/gnu/store/00000000000000000000000000000000-profile")
(define %old-bootcfg
  "/gnu/store/gggggggggggggggggggggggggggggggg-grub.cfg")
(define %new-bootcfg
  "/gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-grub.cfg")
(define %retained-grub-sha
  "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")

(define %pins-header
  "# kind\tgeneration\tcanonical-store-target\trole\treason\n")

 (define %pin-rows
  `(("pin"
     "system"
     "7"
     ,%system-c
     "promotion-rollback"
     "fixture current System")
    ("pin"
     "system"
     "2"
     ,%system-b
     "preferred-rollback"
     "fixture older duplicate System fallback")
    ("pin"
     "home"
     "2"
     ,%home
     "promotion-rollback"
     "fixture current Home")
    ("pin"
     "home"
     "1"
     ,%home-old
     "preferred-rollback"
     "fixture Home fallback")
    ("pin"
     "pull"
     "5"
     ,%pull
     "promotion-rollback"
     "fixture current Pull")
    ("pin"
     "pull"
     "4"
     ,%pull-old
     "preferred-rollback"
     "fixture Pull fallback")))

(define (rows->text rows)
  (string-concatenate
   (map (lambda (row)
          (string-append (string-join row "\t") "\n"))
        rows)))

(define (pin-source-text records)
  (string-append
   %pins-header
   (rows->text
    (map cdr
         (filter (lambda (record)
                   (string=? (car record) "pin"))
                 records)))))

(define %pins-text
  (string-append %pins-header
                 (rows->text (map cdr %pin-rows))))

(define %pins-sha
  (sk:live-manifest-text-sha256 %pins-text))

(define %pins-size
  (number->string
   (bytevector-length (string->utf8 %pins-text))))

(define (refresh-pins-metadata records)
  (let ((text (pin-source-text records)))
    (replace-row
     records
     "pins"
     (list
      "pins"
      "guix/machines/guixpc/generation-pins.tsv"
      (sk:live-manifest-text-sha256 text)
      (number->string
       (bytevector-length (string->utf8 text)))))))

(define %efi-surfaces
  '(("efi-surface" "EFI" "directory" "755" "0" "0" "0" "-" "-")
    ("efi-surface"
     "EFI/Guix"
     "directory"
     "755"
     "0"
     "0"
     "0"
     "-"
     "-")
    ("efi-surface"
     "EFI/Guix/grub.cfg"
     "symlink"
     "777"
     "0"
     "0"
     "11"
     "-"
     "grubx64.efi")
    ("efi-surface"
     "EFI/Guix/grubx64.efi"
     "regular"
     "644"
     "0"
     "0"
     "4096"
     "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
     "-")))

(define %efi-text
  (string-concatenate
   (map (lambda (record)
          (string-append (string-join record "\t") "\n"))
        %efi-surfaces)))

(define %efi-sha
  (sk:live-manifest-text-sha256 %efi-text))

(define %efi-global-guid
  "8be4df61-93ca-11d2-aa0d-00e098032b8c")

(define %efi-loader-guid
  "4a67b082-0a4c-41cf-b6c7-440b29bb8c4f")

(define (efi-variable-row name digest size)
  (list "efi-variable"
        name
        %efi-global-guid
        (string-append
         "/sys/firmware/efi/efivars/"
         name
         "-"
         %efi-global-guid)
        digest
        size
        "644"
        "0"
        "0"))

(define %efi-variables
  (map
   (lambda (spec)
     (efi-variable-row
      (car spec)
      (cadr spec)
      (caddr spec)))
   '(("Boot0001"
      "1111111111111111111111111111111111111111111111111111111111111111"
      "128")
     ("BootCurrent"
      "2222222222222222222222222222222222222222222222222222222222222222"
      "6")
     ("BootOptionSupport"
      "3333333333333333333333333333333333333333333333333333333333333333"
      "8")
     ("BootOrder"
      "4444444444444444444444444444444444444444444444444444444444444444"
      "8")
     ("OsIndications"
      "5555555555555555555555555555555555555555555555555555555555555555"
      "12")
     ("Timeout"
      "6666666666666666666666666666666666666666666666666666666666666666"
      "6"))))

(define %efi-variable-absences
  `(("efi-variable-absence"
     "BootNext"
     ,%efi-global-guid
     ,(string-append
       "/sys/firmware/efi/efivars/BootNext-"
       %efi-global-guid))
    ("efi-variable-absence"
     "LoaderEntryOneShot"
     ,%efi-loader-guid
     ,(string-append
       "/sys/firmware/efi/efivars/LoaderEntryOneShot-"
       %efi-loader-guid))))

(define %efi-variable-sha
  (sk:live-manifest-text-sha256
   (string-concatenate
    (map (lambda (record)
           (string-append (string-join record "\t") "\n"))
         (append %efi-variables %efi-variable-absences)))))

(define (refresh-efi-variable-policy records)
  (let* ((variables
          (filter (lambda (record)
                    (string=? (car record) "efi-variable"))
                  records))
         (absences
          (filter (lambda (record)
                    (string=? (car record) "efi-variable-absence"))
                  records))
         (text (rows->text (append variables absences))))
    (replace-row
     records
     "efi-variable-policy"
     (list "efi-variable-policy"
           "SELECTED-FIRMWARE-BOOT-VARIABLES"
           "BROADER-EFIVARS-EVIDENCE-ONLY"
           (sk:live-manifest-text-sha256 text)
           (number->string (+ (length variables)
                              (length absences)))))))

(define (refresh-efi-root records)
  (let* ((surfaces
          (filter (lambda (record)
                    (string=? (car record) "efi-surface"))
                  records))
         (digest (sk:live-manifest-text-sha256 (rows->text surfaces)))
         (count (number->string (length surfaces))))
    (replace-group-row
     (replace-row records
                  "efi-root"
                  (list "efi-root" "/boot/efi" digest count))
     "expected-postflight"
     5
     (list "expected-postflight"
           "efi-surfaces"
           "unchanged"
           digest))))

(define %manifest
  (append
   `(("schema" ,sk:live-manifest-schema)
     ("mode" "LIVE-REVIEW-ONLY")
     ("status" "REVIEW-ONLY")
     ("authorization" "NOT-GRANTED")
     ("host" "guixpc")
     ("user" "skydive420dz")
     ("uid" "1000")
     ("capture-epoch" "1784567890")
     ("boot-id" "01234567-89ab-cdef-0123-456789abcdef")
     ("source-checkpoint"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa")
     ("evidence-checkpoint"
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb")
     ("validator-checkpoint"
      "cccccccccccccccccccccccccccccccccccccccc")
     ("guix-identity"
      "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-profile"
      "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-guix-command"
      "dddddddddddddddddddddddddddddddddddddddd")
     ("guile-identity"
      "/gnu/store/cccccccccccccccccccccccccccccccc-guile-wrapper/bin/guile"
      "3.0.11")
     ("source-input-policy" "PUBLISHED-REGULAR-FILES-SHA256-SIZE")
     ("generation-policy" "ADDITIONAL-DISTINCT-CLOSURES" "5")
     ("system-transition" "/var/guix/profiles/system" "7" "1" "6" "6")
     ("source-input"
      "boundary"
      "guix/modules/sk/system-pruning-boundary.scm"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      "37613")
     ("source-input"
      "live-manifest"
      "guix/modules/sk/system-pruning-live-manifest.scm"
      "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
      "42000")
     ("profile" "system" "/var/guix/profiles/system" "7" "7" ,%system-c)
     ("profile"
      "home"
      "/var/guix/profiles/per-user/skydive420dz/guix-home"
      "2"
      "2"
      ,%home)
     ("profile"
      "pull"
      "/var/guix/profiles/per-user/skydive420dz/current-guix"
      "2"
      "5"
      ,%pull)
     ("generation"
      "system"
      "1"
      "/var/guix/profiles/system-1-link"
      "../../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
      ,%system-a
      "selected"
      "outside-five-closure-floor")
     ("generation"
      "system"
      "2"
      "/var/guix/profiles/system-2-link"
      "../../../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system"
      ,%system-b
      "retained"
      "exact-older-pin")
     ("generation"
      "system"
      "3"
      "/var/guix/profiles/system-3-link"
      "../../../gnu/store/dddddddddddddddddddddddddddddddd-system"
      ,%system-d
      "retained"
      "newest-additional-closure")
     ("generation"
      "system"
      "4"
      "/var/guix/profiles/system-4-link"
      "../../../gnu/store/ffffffffffffffffffffffffffffffff-system"
      ,%system-f
      "retained"
      "newest-additional-closure")
     ("generation"
      "system"
      "5"
      "/var/guix/profiles/system-5-link"
      "../../../gnu/store/gggggggggggggggggggggggggggggggg-system"
      ,%system-g
      "retained"
      "newest-additional-closure")
     ("generation"
      "system"
      "6"
      "/var/guix/profiles/system-6-link"
      "../../../gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-system"
      ,%system-h
      "retained"
      "newest-additional-closure")
     ("generation"
      "system"
      "7"
      "/var/guix/profiles/system-7-link"
      "../../../gnu/store/cccccccccccccccccccccccccccccccc-system"
      ,%system-c
      "retained"
      "current")
     ("generation"
      "home"
      "1"
      "/var/guix/profiles/per-user/skydive420dz/guix-home-1-link"
      "../../../../../gnu/store/11111111111111111111111111111111-home"
      ,%home-old
      "protected"
      "home-fallback")
     ("generation"
      "home"
      "2"
      "/var/guix/profiles/per-user/skydive420dz/guix-home-2-link"
      "../../../../../gnu/store/dddddddddddddddddddddddddddddddd-home"
      ,%home
      "protected"
      "home-surface")
     ("generation"
      "pull"
      "4"
      "/var/guix/profiles/per-user/skydive420dz/current-guix-4-link"
      "../../../../../gnu/store/00000000000000000000000000000000-profile"
      ,%pull-old
      "protected"
      "pull-fallback")
     ("generation"
      "pull"
      "5"
      "/var/guix/profiles/per-user/skydive420dz/current-guix-5-link"
      "../../../../../gnu/store/ffffffffffffffffffffffffffffffff-profile"
      ,%pull
      "protected"
      "pull-surface")
     ("pointer"
     "system-profile"
      "/var/guix/profiles/system"
      "system-7-link"
      ,%system-c)
     ("pointer"
      "current-system"
      "/run/current-system"
      "../gnu/store/cccccccccccccccccccccccccccccccc-system"
      ,%system-c)
     ("pointer"
      "booted-system"
      "/run/booted-system"
      "../gnu/store/cccccccccccccccccccccccccccccccc-system"
      ,%system-c)
     ("pointer"
      "home-profile"
      "/var/guix/profiles/per-user/skydive420dz/guix-home"
      "guix-home-2-link"
      ,%home)
     ("pointer"
      "pull-profile"
      "/var/guix/profiles/per-user/skydive420dz/current-guix"
      "current-guix-5-link"
      ,%pull)
     ("pointer"
      "user-current"
      "/home/skydive420dz/.config/guix/current"
      "../../../../var/guix/profiles/per-user/skydive420dz/current-guix"
      ,%pull)
     ("pins"
      "guix/machines/guixpc/generation-pins.tsv"
      ,%pins-sha
      ,%pins-size))
   %pin-rows
   `(("installed-grub"
      "/boot/grub/grub.cfg"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
      "9000"
      "644"
      "0"
      "0")
     ("retained-grub"
      "docs/audits/data/2026-07-20-p5.2b-d4c1-retained-grub.cfg"
      ,%retained-grub-sha
      "5000")
     ("retained-grub-semantics" ,%system-c "6,5,4,3,2" "2" "10" "1")
     ("old-bootcfg"
      "/var/guix/gcroots/bootcfg"
      "../../../gnu/store/gggggggggggggggggggggggggggggggg-grub.cfg"
      ,%old-bootcfg)
     ("new-bootcfg"
      "/var/guix/gcroots/bootcfg"
      "../../../gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-grub.cfg"
      ,%new-bootcfg
      ,%retained-grub-sha
      "5000")
     ("efi-root" "/boot/efi" ,%efi-sha "4"))
   %efi-surfaces
   `(("efi-variable-policy"
      "SELECTED-FIRMWARE-BOOT-VARIABLES"
      "BROADER-EFIVARS-EVIDENCE-ONLY"
      ,%efi-variable-sha
      "8"))
   %efi-variables
   %efi-variable-absences
   `(("program-root-formula" ,sk:live-manifest-program-root-formula)
     ("recovery-namespace-formula"
      ,sk:live-manifest-recovery-namespace-formula)
     ("transaction-directory-formula"
      ,sk:live-manifest-transaction-directory-formula)
     ("surface"
      "transaction-base"
      "/var/guix/profiles/.p52b-system-prune-transactions"
      "absent"
      "-")
     ("surface"
      "transaction-lock"
      "/var/guix/profiles/.p52b-system-prune-transactions/transaction.lock"
      "absent"
      "-")
     ("surface"
      "system-lock"
      "/var/guix/profiles/system.lock"
      "absent"
      "-")
     ("surface"
      "transaction-directory"
      ,sk:live-manifest-transaction-directory-formula
      "absent"
      "-")
     ("surface"
      "quarantine"
      "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/quarantine"
      "absent"
      "-")
     ("surface"
      "journal"
      "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/journal.tsv"
      "absent"
      "-")
     ("surface"
      "journal-temporary"
      "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/journal.tsv.tmp"
      "absent"
      "-")
     ("surface"
      "recovery-root-base"
      "/var/guix/gcroots/p52b-system-prune"
      "absent"
      "-")
     ("surface"
      "obsolete-program-root-directory"
      "/var/guix/gcroots/p52b-system-prune-program"
      "absent"
      "-")
     ("surface"
      "direct-program-root-family"
      "/var/guix/gcroots/p52b-system-prune-program-*"
      "absent"
      "-")
     ("surface"
      "recovery-namespace"
      ,sk:live-manifest-recovery-namespace-formula
      "absent"
      "-")
     ("surface"
      "grub-temporary"
      "/boot/grub/grub.cfg.p52b-new"
      "absent"
      "-")
     ("surface"
      "bootcfg-temporary"
      "/var/guix/gcroots/bootcfg.p52b-new"
      "absent"
      "-")
     ("recovery-root" "candidate" "candidate-g1" "1" ,%system-a)
     ("recovery-root"
      "bootcfg-old"
      "old-bootcfg"
      "-"
      ,%old-bootcfg)
     ("recovery-root"
      "bootcfg-new"
      "new-bootcfg"
      "-"
      ,%new-bootcfg)
     ("selector" "system" "1")
     ("action" "live-verify")
     ("action" "live-apply")
     ("action" "live-recover")
     ("grant-token"
      "execution"
      "SK_P52B_D5_EXECUTION_GRANT"
      "ABSENT")
     ("grant-token"
      "recovery"
      "SK_P52B_D5_RECOVERY_GRANT"
      "ABSENT")
     ("expected-postflight"
      "system-count"
      "6"
      "/var/guix/profiles/system")
     ("expected-postflight" "selected-links" "absent" "1")
     ("expected-postflight"
      "installed-grub"
      ,(string-append %retained-grub-sha ":5000:644:0:0")
      "/boot/grub/grub.cfg")
     ("expected-postflight"
      "bootcfg"
      "../../../gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-grub.cfg"
      ,%new-bootcfg)
     ("expected-postflight"
      "protected-surfaces"
      "unchanged"
      "all-manifest-protected")
     ("expected-postflight" "efi-surfaces" "unchanged" ,%efi-sha)
     ("expected-postflight"
      "efi-variables"
      "unchanged"
      ,%efi-variable-sha)
     ("expected-postflight"
      "transaction-base"
      "retained"
      "/var/guix/profiles/.p52b-system-prune-transactions")
     ("expected-postflight"
      "transaction-directory"
      "retained"
      ,sk:live-manifest-transaction-directory-formula)
     ("expected-postflight"
      "terminal-journal"
      "retained-COMPLETE"
      ,(string-append
        sk:live-manifest-transaction-directory-formula
        "/journal.tsv"))
     ("expected-postflight"
      "old-grub-backup"
      "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa:9000:644:0:0"
      ,(string-append
        sk:live-manifest-transaction-directory-formula
        "/old-grub.cfg"))
     ("expected-postflight"
      "quarantine"
      "absent"
      ,(string-append
        sk:live-manifest-transaction-directory-formula
        "/quarantine"))
     ("expected-postflight"
      "journal-temporaries"
      "absent"
      ,(string-append
        sk:live-manifest-transaction-directory-formula
        "/journal.tsv.*"))
     ("expected-postflight"
      "grub-temporary"
      "absent"
      "/boot/grub/grub.cfg.p52b-new")
     ("expected-postflight"
      "bootcfg-temporary"
      "absent"
      "/var/guix/gcroots/bootcfg.p52b-new")
     ("expected-postflight"
      "recovery-namespace"
      "absent"
      ,sk:live-manifest-recovery-namespace-formula)
     ("expected-postflight" "recovery-roots" "absent" "-")
     ("expected-postflight" "program-root" "absent" "-")
     ("expected-postflight"
      "transaction-lock"
      "retained-created-inode"
      "-")
     ("expected-postflight"
      "system-lock"
      "retained-created-inode"
      "-")
     ("expected-postflight"
      "temporary-roots"
      "release-on-connection-close"
      "all-session-temporary-roots")
     ("prohibition" "live-action")
     ("prohibition" "root-creation")
     ("prohibition" "transaction-mutation")
     ("prohibition" "generation-link-mutation")
     ("prohibition" "grub-mutation")
     ("prohibition" "bootcfg-mutation")
     ("prohibition" "efi-mutation")
     ("prohibition" "gc")
     ("prohibition" "dead-live-enumeration")
     ("prohibition" "collection")
     ("prohibition" "activation")
     ("prohibition" "reconfiguration")
     ("prohibition" "bootloader-installation")
     ("prohibition" "profile-switch")
     ("prohibition" "reboot")
     ("prohibition" "unlisted-action")
     ("capture-result" "protected-pre-post" "IDENTICAL")
     ("program-build" "NOT-RUN")
     ("lowering" "NOT-RUN")
     ("realization" "NOT-RUN")
     ("live-action" "NOT-GRANTED"))))

(define %rendered (sk:render-live-manifest %manifest))

(check (equal? (sk:assert-live-manifest %manifest) %manifest)
       "valid manifest was not returned exactly")
(check (char=? (string-ref %rendered (- (string-length %rendered) 1))
               #\newline)
       "renderer omitted canonical final newline")
(check (equal? (sk:read-live-manifest-string %rendered) %manifest)
       "render/parse round trip drift")
(check (= (string-length
           (sk:live-manifest-text-sha256 %rendered))
          64)
       "manifest text SHA256 length drift")
(check (= (length (sk:live-manifest-source-inputs %manifest)) 2)
       "source-input accessor drift")
(check (equal?
        (map (lambda (record) (list-ref record 2))
             (sk:live-manifest-selected-generations %manifest))
        '("1"))
       "selected-generation accessor drift")
(check (equal?
        (map (lambda (record) (list-ref record 2))
             (sk:live-manifest-retained-generations %manifest))
        '("2" "3" "4" "5" "6" "7"))
       "retained-generation accessor drift")
(check (= (length (sk:live-manifest-recovery-roots %manifest)) 3)
       "recovery-root accessor drift")

;; Closed prefix and byte grammar.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest "mode" '("mode" "LIVE"))))
 "mode widening")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest
                 "authorization"
                 '("authorization" "GRANTED"))))
 "authorization widening")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest "host" '("host" "other-host"))))
 "host identity drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest "user" '("user" "other-user"))))
 "user identity drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest "uid" '("uid" "1001"))))
 "UID identity drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "capture-epoch"
     '("capture-epoch" "01784567890"))))
 "capture epoch leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "capture-epoch"
     '("capture-epoch" "١784567890"))))
 "capture epoch non-ASCII decimal")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "guile-identity"
     '("guile-identity"
       "/gnu/store/cccccccccccccccccccccccccccccccc-other-wrapper/bin/guile"
       "3.0.11"))))
 "Guile wrapper store suffix")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "guile-identity"
     '("guile-identity"
       "/gnu/store/cccccccccccccccccccccccccccccccc-guile-wrapper/lib/guile"
       "3.0.11"))))
 "Guile wrapper descendant")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "guile-identity"
     '("guile-identity"
       "/gnu/store/cccccccccccccccccccccccccccccccc-guile-wrapper/bin/guile"
       "3..11"))))
 "Guile version empty component")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "guile-identity"
     '("guile-identity"
       "/gnu/store/cccccccccccccccccccccccccccccccc-guile-wrapper/bin/guile"
       "3.00.11"))))
 "Guile version leading-zero component")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "guile-identity"
     '("guile-identity"
       "/gnu/store/cccccccccccccccccccccccccccccccc-guile-wrapper/bin/guile"
       "0.0.11"))))
 "Guile version zero major")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (insert-before
     %manifest
     "mode"
     '("manifest-sha"
       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"))))
 "manifest self hash")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (insert-before
     %manifest
     "surface"
     '("program-root"
       "/var/guix/gcroots/program"
       "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-program"))))
 "future program target")
(expect-failure
 (lambda ()
   (sk:read-live-manifest-string
    (substring %rendered 0 (- (string-length %rendered) 1))))
 "missing final newline")
(expect-failure
 (lambda ()
   (sk:read-live-manifest-string
    (string-append "schema\t" sk:live-manifest-schema "\r\n")))
 "carriage return")
(expect-failure
 (lambda ()
   (sk:read-live-manifest-string
    (string-append "schema\t" sk:live-manifest-schema "\n\n")))
 "blank TSV row")

;; Source provenance and canonical order.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "source-input"
     1
     '("source-input"
       "boundary"
       "guix/modules/sk/other.scm"
       "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
       "1"))))
 "duplicate source label")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "source-input"
     0
            '("source-input"
              "z-last"
              "guix/modules/sk/system-pruning-boundary.scm"
              "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
              "37613"))))
 "source-input order")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "source-input"
     0
     '("source-input"
       "boundary"
       "guix/modules/sk/system-pruning-boundary.scm"
       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
       "037613"))))
 "source-input size leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "source-input"
     0
     '("source-input"
       "boundarý"
       "guix/modules/sk/system-pruning-boundary.scm"
       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
       "37613"))))
 "source-input Unicode label")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "source-input"
     0
     (list
      "source-input"
      "boundary"
      "guix/modules/sk/system-pruning-boundary.scm"
      (string-append (make-string 63 #\a) "١")
      "37613"))))
 "source-input non-ASCII digest")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "generation-policy"
     '("generation-policy" "ADDITIONAL-DISTINCT-CLOSURES" "4"))))
 "generation retention floor drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "profile"
     0
     `("profile"
       "system"
       "/var/guix/profiles/other-system"
       "4"
               "4"
               ,%system-c))))
 "System profile path drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "profile"
     0
     `("profile"
       "system"
       "/var/guix/profiles/system"
       "07"
       "7"
       ,%system-c))))
 "profile count leading zero")

;; Complete generation partition and pointer protection.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "system-transition"
     '("system-transition"
       "/var/guix/profiles/system"
       "3"
       "2"
               "1"
               "1"))))
 "partition count drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "system-transition"
     '("system-transition"
       "/var/guix/profiles/system"
       "07"
       "1"
       "6"
       "6"))))
 "transition count leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "generation"
     0
     `("generation"
       "system"
       "01"
       "/var/guix/profiles/system-1-link"
       "../../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
       ,%system-a
       "selected"
       "remaining-duplicate"))))
 "generation number leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "generation"
     0
     `("generation"
       "system"
       "0"
       "/var/guix/profiles/system-0-link"
       "../../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
       ,%system-a
       "selected"
       "remaining-duplicate"))))
 "generation zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "generation"
     6
     `("generation"
       "system"
       "7"
       "/var/guix/profiles/system-7-link"
       "../../../gnu/store/cccccccccccccccccccccccccccccccc-system"
       ,%system-c
       "selected"
       "current"))))
 "selected current System")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "generation"
     0
     `("generation"
       "system"
       "1"
       "/var/guix/profiles/system-1-link"
       "../../../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system"
       ,%system-a
       "selected"
       "outside-floor"))))
 "generation raw/canonical mismatch")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "generation"
     0
     `("generation"
       "system"
       "1"
       "/var/guix/profiles/system-1-link"
       "../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
       ,%system-a
       "selected"
       "outside-five-closure-floor"))))
 "generation raw target wrong relative prefix")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     0
     `("pointer"
       "system-profile"
       "/var/guix/profiles/system"
       "../system-7-link"
       ,%system-c))))
 "System profile raw target wrong indirection")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     1
     `("pointer"
       "current-system"
       "/run/current-system"
       "../../gnu/store/cccccccccccccccccccccccccccccccc-system"
       ,%system-c))))
 "current System raw target wrong relative prefix")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     3
     `("pointer"
       "home-profile"
       "/var/guix/profiles/per-user/skydive420dz/guix-home"
       "../guix-home-2-link"
       ,%home))))
 "Home profile raw target wrong indirection")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     5
     `("pointer"
       "user-current"
       "/home/skydive420dz/.config/guix/current"
       "../../../var/guix/profiles/per-user/skydive420dz/current-guix"
       ,%pull))))
 "user-current raw target wrong relative prefix")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     1
     `("pointer"
       "current-system"
       "/run/current-system"
       "../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system"
       ,%system-b))))
 "current-System pointer drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     1
     `("pointer"
       "booted-system"
       "/run/booted-system"
       "../gnu/store/cccccccccccccccccccccccccccccccc-system"
       ,%system-c))))
 "pointer order drift")

;; Canonical pin bytes, exact pin tuples, and exact D-34 selection.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "pins"
     (list "pins"
           "guix/machines/guixpc/generation-pins.tsv"
           %pins-sha
           (string-append "0" %pins-size)))))
 "pins size leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pin"
     1
     `("pin"
       "system"
       "2"
       ,%system-b
       "preferred-rollback"
       "changed fixture reason"))))
 "pin source digest/size binding")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-pins-metadata
     (replace-group-row
      %manifest
      "pin"
      1
      `("pin"
        "system"
        "2"
        ,%system-c
        "preferred-rollback"
        "fixture target mismatch")))))
 "pin generation/target binding with recomputed source digest")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-pins-metadata
     (replace-group-row
      %manifest
      "pin"
      1
      `("pin"
        "system"
        "2"
        ,%system-b
        "last-known-good"
        "fixture role-count mismatch")))))
 "pin required roles with recomputed source digest")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-pins-metadata
     (replace-group-row
      (replace-group-row
       %manifest
       "pin"
       0
       (list-ref %pin-rows 1))
      "pin"
      1
      (list-ref %pin-rows 0)))))
 "pin canonical order with recomputed source digest")
(expect-failure
 (lambda ()
   (let* ((wrong-sixth
           (replace-group-row
            %manifest
            "generation"
            0
            `("generation"
              "system"
              "1"
              "/var/guix/profiles/system-1-link"
              "../../../gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-system"
              ,%system-a
              "retained"
              "wrong sixth eligible closure retained")))
          (wrong-fifth
           (replace-group-row
            wrong-sixth
            "generation"
            1
            `("generation"
              "system"
              "2"
              "/var/guix/profiles/system-2-link"
              "../../../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system"
              ,%system-b
              "selected"
              "wrong fifth newest closure selected")))
          (wrong-semantics
           (replace-row
            wrong-fifth
            "retained-grub-semantics"
            `("retained-grub-semantics"
              ,%system-c
              "6,5,4,3,1"
              "2"
              "10"
              "1")))
          (wrong-root
           (replace-group-row
            wrong-semantics
            "recovery-root"
            0
            `("recovery-root"
              "candidate"
              "candidate-g2"
              "2"
              ,%system-b)))
          (wrong-selector
           (replace-row
            wrong-root
            "selector"
            '("selector" "system" "2")))
          (wrong-postflight
           (replace-group-row
            wrong-selector
            "expected-postflight"
            1
            '("expected-postflight"
              "selected-links"
              "absent"
              "2"))))
     (sk:assert-live-manifest wrong-postflight)))
 "D-34 retained sixth closure with dependents recomputed")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "pointer"
     2
     `("pointer"
       "booted-system"
       "/run/booted-system"
       "../gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-system"
       ,%system-b))))
 "distinct booted closure requires all ambiguous generation links")

;; GRUB, bootcfg, and EFI are exact protected data.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "retained-grub-semantics"
     `("retained-grub-semantics" ,%system-c "1" "2" "2" "1"))))
 "retained GRUB generation drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "new-bootcfg"
     `("new-bootcfg"
       "/var/guix/gcroots/bootcfg"
       "../../../gnu/store/gggggggggggggggggggggggggggggggg-grub.cfg"
       ,%old-bootcfg
       ,%retained-grub-sha
       "5000"))))
 "identical old/new bootcfg")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "new-bootcfg"
     `("new-bootcfg"
       "/var/guix/gcroots/bootcfg"
       "../../../gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-grub.cfg"
       ,%new-bootcfg
       "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
       "5000"))))
 "new bootcfg/retained GRUB digest drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "new-bootcfg"
     `("new-bootcfg"
       "/var/guix/gcroots/bootcfg"
       "../../gnu/store/hhhhhhhhhhhhhhhhhhhhhhhhhhhhhhhh-grub.cfg"
       ,%new-bootcfg
       ,%retained-grub-sha
       "5000"))))
 "new bootcfg raw target wrong relative prefix")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "efi-root"
     `("efi-root"
       "/boot/efi"
       "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
       "4"))))
 "EFI tree digest drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-root
     (replace-group-row
      %manifest
      "efi-surface"
      0
      '("efi-surface"
        "EFI"
        "directory"
        "755"
        "0"
        "0"
        "00"
        "-"
        "-")))))
 "zero-allowed EFI size leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-root
     (remove-group-row %manifest "efi-surface" 1))))
 "EFI nested surface missing immediate parent")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-root
     (replace-group-row
      %manifest
      "efi-surface"
      1
      '("efi-surface"
        "EFI/Guix"
        "regular"
        "644"
        "0"
        "0"
        "0"
        "dddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddddd"
        "-")))))
 "EFI nested surface child under non-directory")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-root
     (replace-group-row
      %manifest
      "efi-surface"
      2
      '("efi-surface"
        "EFI/Guix/grub.cfg"
        "symlink"
        "777"
        "0"
        "0"
        "12"
        "-"
        "grubx64.efi")))))
 "EFI symlink raw-target byte-size drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-root
     (replace-group-row
      %manifest
      "efi-surface"
      3
      '("efi-surface"
        "EFI/Guix/grubx64.efi"
        "regular"
        "0644"
        "0"
        "0"
        "4096"
        "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
        "-")))))
 "EFI mode leading zero")
(let ((setuid-mode
       (refresh-efi-root
        (replace-group-row
         %manifest
         "efi-surface"
         3
         '("efi-surface"
           "EFI/Guix/grubx64.efi"
           "regular"
           "4755"
           "0"
           "0"
           "4096"
           "cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc"
           "-")))))
  (check (equal? (sk:assert-live-manifest setuid-mode) setuid-mode)
         "nonzero four-digit EFI mode was rejected"))
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "efi-surface"
     3
     '("efi-surface"
       "EFI/Guix/grubx64.efi"
       "regular"
       "644"
       "0"
       "0"
       "4096"
       "-"
       "-"))))
 "EFI regular-file digest omission")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "efi-variable-policy"
     `("efi-variable-policy"
       "ALL-EFIVARS-PROTECTED"
       "BROADER-EFIVARS-EVIDENCE-ONLY"
       ,%efi-variable-sha
       "8"))))
 "EFI variable protection-scope widening")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
            (replace-group-row
             %manifest
             "efi-variable"
     0
     (efi-variable-row
      "Boot0001"
      "7777777777777777777777777777777777777777777777777777777777777777"
              "128"))))
 "EFI protected-variable digest/set drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-variable-policy
     (replace-group-row
      %manifest
      "efi-variable"
      0
      (efi-variable-row
       "Boot000١"
       "1111111111111111111111111111111111111111111111111111111111111111"
       "128")))))
 "EFI Boot option non-ASCII decimal")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (refresh-efi-variable-policy
     (insert-before
      %manifest
      "efi-variable"
      (efi-variable-row
       "Boot0001"
       "7777777777777777777777777777777777777777777777777777777777777777"
       "128")))))
 "duplicate Boot option with recomputed count and digest")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (remove-group-row %manifest "efi-variable-absence" 0)))
 "missing BootNext absence")

;; Formula-only program identity, absent prestate, exact roots/action.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "program-root-formula"
     '("program-root-formula"
       "/var/guix/gcroots/fixed-program-root"))))
 "program-root formula drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "surface"
     2
     '("surface"
       "system-lock"
       "/var/guix/profiles/system.lock"
       "regular"
       "inode-1"))))
 "occupied prestate surface")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (remove-group-row %manifest "recovery-root" 0)))
 "missing candidate recovery root")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "recovery-root"
     0
     `("recovery-root"
       "candidate"
               "candidate-g1"
               "1"
               ,%system-b))))
 "candidate recovery target drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
            (replace-row
             %manifest
             "selector"
             '("selector" "system" "1,2"))))
 "System selector drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "selector"
     '("selector" "system" "01"))))
 "System selector leading zero")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (remove-group-row %manifest "action" 1)))
 "missing live-apply action")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "grant-token"
     0
     '("grant-token"
       "execution"
       "SK_P52B_D5_EXECUTION_GRANT"
       "PRESENT"))))
 "execution grant token")

;; Expected terminal state and all explicit non-authorization rows.
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     0
     '("expected-postflight"
       "system-count"
               "1"
               "/var/guix/profiles/system"))))
 "expected postflight count drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     2
     (list "expected-postflight"
           "installed-grub"
           (string-append %retained-grub-sha ":5000:600:0:0")
           "/boot/grub/grub.cfg"))))
 "expected installed-GRUB mode identity drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     9
     '("expected-postflight"
       "terminal-journal"
       "retained-ROLLED-BACK"
       "/var/guix/profiles/.p52b-system-prune-transactions/{manifest-sha256}/journal.tsv"))))
 "forward terminal drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     7
     '("expected-postflight"
       "transaction-base"
       "absent"
       "/var/guix/profiles/.p52b-system-prune-transactions"))))
 "terminal transaction-base retention drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     10
     `("expected-postflight"
       "old-grub-backup"
       "retained-unverified"
       ,(string-append
         sk:live-manifest-transaction-directory-formula
         "/old-grub.cfg")))))
 "terminal old-GRUB backup identity drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     15
     `("expected-postflight"
       "recovery-namespace"
       "retained"
       ,sk:live-manifest-recovery-namespace-formula))))
 "terminal recovery-namespace absence drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-group-row
     %manifest
     "expected-postflight"
     20
     '("expected-postflight"
       "temporary-roots"
       "retained"
       "all-session-temporary-roots"))))
 "temporary-root release policy drift")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (remove-group-row %manifest "prohibition" 7)))
 "missing GC prohibition")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "program-build"
     '("program-build" "RUN"))))
 "program build claim")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row %manifest "lowering" '("lowering" "RUN"))))
 "lowering claim")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "realization"
     '("realization" "RUN"))))
 "realization claim")
(expect-failure
 (lambda ()
   (sk:assert-live-manifest
    (replace-row
     %manifest
     "live-action"
     '("live-action" "GRANTED"))))
 "live-action grant")

(format #t "~a: PASS (~a checks)~%" %program %checks)
