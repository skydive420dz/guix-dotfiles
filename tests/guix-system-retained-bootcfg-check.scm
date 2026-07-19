(use-modules (gnu bootloader)
             (gnu bootloader grub)
             (gnu system)
             (gnu system keyboard)
             (guix build syscalls)
             (ice-9 textual-ports)
             (sk system-retained-bootcfg)
             (srfi srfi-1))

(define arguments (cdr (command-line)))
(unless (= (length arguments) 1)
  (error "expected repository path"))

(define repo (canonicalize-path (car arguments)))
(define fixture-directory
  (string-append
   repo
   "/tests/fixtures/guix-system-retained-bootcfg"))
(define production-spec
  (string-append
   repo
   "/guix/machines/guixpc/p5.2b-d2-retained-bootcfg-stage.tsv"))
(define current-system
  "/gnu/store/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa-current-system")

(define (read-text file)
  (call-with-input-file file get-string-all))

(define (assert condition message)
  (unless condition
    (error message)))

(define (assert-stage-failure thunk label)
  (let ((failed?
         (catch 'sk-retained-bootcfg
           (lambda ()
             (thunk)
             #f)
           (lambda (_key _message) #t))))
    (assert failed? (string-append "expected failure: " label))))

(define (replace-record records key replacement)
  (map (lambda (record)
         (if (string=? (car record) key)
             replacement
             record))
       records))

(define (remove-record records key)
  (remove (lambda (record) (string=? (car record) key))
          records))

(define (replace-all text old new)
  (let loop ((start 0)
             (pieces '()))
    (let ((position (string-contains text old start)))
      (if position
          (loop (+ position (string-length old))
                (cons new
                      (cons (substring text start position) pieces)))
          (string-concatenate-reverse
           (cons (substring text start) pieces))))))

(define records
  (sk:assert-stage-spec (sk:read-stage-spec production-spec)))
(assert (equal? (sk:retained-generations records)
                '(86 85 84 83 81 80 75))
        "production retained generation order changed")

(let* ((template
        (string-copy
         (string-append (or (getenv "TMPDIR") "/tmp")
                        "/retained-bootcfg-link.XXXXXX")))
       (directory (mkdtemp! template))
       (target (string-append directory "/target"))
       (generation-five (string-append directory "/profile-5-link"))
       (generation-four (string-append directory "/profile-4-link"))
       (pointer (string-append directory "/profile")))
  (dynamic-wind
    (lambda ()
      (call-with-output-file target
        (lambda (port) (display "fixture\n" port)))
      (symlink "target" generation-five)
      (symlink "target" generation-four)
      (symlink "profile-5-link" pointer))
    (lambda ()
      (assert (sk:symlink-points-to-link? pointer generation-five)
              "relative profile pointer did not name the reviewed link")
      (assert (not
               (sk:symlink-points-to-link? pointer generation-four))
              "same-target but different generation link was accepted")
      (assert (not (sk:symlink-points-to-link? pointer target))
              "profile pointer was collapsed to the final store object"))
    (lambda ()
      (delete-file pointer)
      (delete-file generation-four)
      (delete-file generation-five)
      (delete-file target)
      (rmdir directory))))

(for-each
 (lambda (case)
   (assert-stage-failure
    (lambda ()
      (sk:assert-stage-spec
       (replace-record records (car case) (cdr case))))
    (car case)))
 `(("schema" . ("schema" "wrong/v1"))
   ("mode" . ("mode" "LIVE"))
   ("authorization" . ("authorization" "GRANTED"))
   ("status" . ("status" "READY"))
   ("timezone" . ("timezone" "UTC"))
   ("guix-revision" . ("guix-revision" "bad"))
   ("implementation-module"
    . ("implementation-module"
       "guix/modules/sk/wrong.scm"
       "0000000000000000000000000000000000000000000000000000000000000000"))
   ("evaluation-input"
    . ("evaluation-input"
       "guix/package-ownership.scm"
       "bad"))
   ("system-link-count" . ("system-link-count" "85"))))

(assert-stage-failure
 (lambda ()
   (sk:assert-stage-spec (remove-record records "installed-grub")))
 "missing installed-grub")
(assert-stage-failure
 (lambda ()
   (sk:assert-stage-spec
    (remove-record records "implementation-driver")))
 "missing implementation-driver")
(assert-stage-failure
 (lambda ()
   (sk:assert-stage-spec
    (cons (sk:single-record records "implementation-launcher" 3)
          records)))
 "duplicate implementation-launcher")
(assert-stage-failure
 (lambda ()
   (sk:assert-stage-spec
    (cons '("mystery" "value") records)))
 "unknown record")
(assert-stage-failure
 (lambda ()
   (sk:assert-stage-spec
    (cons (car (sk:record-values records "retained")) records)))
 "duplicate retained generation")

(define config
  (bootloader-configuration
   (bootloader grub-efi-bootloader)
   (targets '("/boot/efi"))
   (theme
    (grub-theme
     (resolution '(3440 . 1440))
     (gfxmode
      '("3440x1440" "2560x1440" "1920x1080" "auto"))))
   (keyboard-layout
    (keyboard-layout "us" #:options '("caps:escape")))))

(define (parameters label system)
  (boot-parameters
   (label label)
   (root-device #f)
   (bootloader-name 'grub-efi)
   (bootloader-menu-entries '())
   (store-device #f)
   (store-mount-point "/")
   (store-directory-prefix #f)
   (store-crypto-devices '())
   (locale "en_US.utf8")
   (kernel
    "/gnu/store/bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb-linux/bzImage")
   (kernel-arguments
    (list "root=fixture"
          (string-append "gnu.system=" system)
          (string-append "gnu.load=" system "/boot")))
   (initrd
    "/gnu/store/cccccccccccccccccccccccccccccccc-initrd/initrd.img")
   (multiboot-modules '())))

(define current (parameters "GNU current" current-system))
(define old
  (list
   (parameters
    "GNU old (#9, 2026-01-09 09:00)"
    "/var/guix/profiles/system-9-link")
   (parameters
    "GNU old (#5, 2026-01-05 05:00)"
    "/var/guix/profiles/system-5-link")))

(assert (pair? (sk:validate-bootloader-configuration config records))
        "valid synthetic bootloader configuration was rejected")
(assert (sk:make-retained-bootcfg config current old)
        "inert retained bootcfg construction failed")

(for-each
 (lambda (drifted)
   (assert-stage-failure
    (lambda ()
      (sk:validate-bootloader-configuration drifted records))
    "bootloader configuration drift"))
 (list
  (bootloader-configuration
   (inherit config)
   (targets '("/wrong")))
  (bootloader-configuration
   (inherit config)
   (default-entry 1))
  (bootloader-configuration
   (inherit config)
   (timeout 6))
  (bootloader-configuration
   (inherit config)
   (terminal-outputs '(console)))
  (bootloader-configuration
   (inherit config)
   (terminal-inputs '(console)))
  (bootloader-configuration
   (inherit config)
   (serial-unit 0))
  (bootloader-configuration
   (inherit config)
   (device-tree-support? #f))
  (bootloader-configuration
   (inherit config)
   (extra-initrd "/gnu/store/drift-initrd"))
  (bootloader-configuration
   (inherit config)
   (theme
    (grub-theme
     (resolution '(1920 . 1080))
     (gfxmode
      '("3440x1440" "2560x1440" "1920x1080" "auto")))))
  (bootloader-configuration
   (inherit config)
   (theme
    (grub-theme
     (resolution '(3440 . 1440))
     (gfxmode '("1920x1080" "auto")))))
  (bootloader-configuration
   (inherit config)
   (theme
    (grub-theme
     (resolution '(3440 . 1440))
     (gfxmode
      '("3440x1440" "2560x1440" "1920x1080" "auto"))
     (color-normal '((fg . white) (bg . black))))))
  (bootloader-configuration
   (inherit config)
   (keyboard-layout (keyboard-layout "us")))
  (bootloader-configuration
   (inherit config)
   (menu-entries
    (list
     (menu-entry
      (label "unexpected static entry")
      (linux "/gnu/store/linux")
      (linux-arguments '("root=fixture"))
      (initrd "/gnu/store/initrd")))))))

(define current-with-menu
  (boot-parameters
   (inherit current)
   (bootloader-menu-entries
    (list
     (menu-entry
      (label "extra")
      (linux "/gnu/store/linux")
      (linux-arguments '("root=fixture"))
      (initrd "/gnu/store/initrd"))))))
(assert-stage-failure
 (lambda ()
   (sk:make-retained-bootcfg config current-with-menu old))
 "accepted/source menu mismatch")

(define installed
  (read-text (string-append fixture-directory "/installed-grub.cfg")))
(define expected
  (read-text (string-append fixture-directory "/retained-grub.cfg")))
(define projected
  (sk:project-retained-grub installed '(9 5)))

(assert (string=? projected expected)
        "retained byte projection differs from its exact fixture")
(assert (pair?
         (sk:validate-retained-grub projected current-system '(9 5)))
        "valid retained GRUB semantics were rejected")
(assert (not (string-contains projected "system-8-link"))
        "candidate generation 8 survived projection")
(assert (not (string-contains projected "system-2-link"))
        "candidate generation 2 survived projection")

(define retained-five-block
  (string-append
   "menuentry \"GNU old (#5, 2026-01-05 05:00)\" {\n"
   "  linux /gnu/store/linux/bzImage root=fixture "
   "gnu.system=/var/guix/profiles/system-5-link "
   "gnu.load=/var/guix/profiles/system-5-link/boot\n"
   "  initrd /gnu/store/initrd/initrd.img\n"
   "}\n"))

(assert-stage-failure
 (lambda ()
   (sk:validate-retained-grub
    (string-append
     (replace-all projected retained-five-block "")
     retained-five-block)
    current-system
    '(9 5)))
 "retained stanza outside old submenu")

(assert-stage-failure
 (lambda ()
   (sk:validate-retained-grub projected current-system '(5 9)))
 "reordered retained generations")
(assert-stage-failure
 (lambda ()
   (sk:validate-retained-grub
    (replace-all projected "system-5-link" "system-4-link")
    current-system
    '(9 5)))
 "candidate generation reference")
(assert-stage-failure
 (lambda ()
   (sk:validate-retained-grub
    (replace-all projected current-system
                 "/var/guix/profiles/system-10-link")
    current-system
    '(9 5)))
 "link-based current entry")
(assert-stage-failure
 (lambda ()
   (sk:validate-retained-grub
    (replace-all projected " (#5, " " (#9, ")
    current-system
    '(9 5)))
 "duplicate retained label")
(assert-stage-failure
 (lambda ()
   (sk:project-retained-grub installed '(9 7)))
 "missing retained generation")
(assert-stage-failure
 (lambda ()
   (sk:project-retained-grub installed '(9 9)))
 "duplicate projection selector")

(format #t
        "guix-system-retained-bootcfg-check: PASS (~a retained production generations)~%"
        (length (sk:retained-generations records)))
