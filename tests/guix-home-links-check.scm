(use-modules (ice-9 textual-ports))

(define helper (list-ref (command-line) 1))
(define root (list-ref (command-line) 2))
(define home (string-append root "/home"))
(define repo (string-append root "/repo"))
(define links
  '((".config/example/one" "source/one")
    (".config/example/two" "source/two")))
(define parent-links
  '((".config/blocked/child" "source/one")
    (".config/other/child" "source/two")))
(define retired-links
  '((".config/retired/item"
     "source/legacy"
     "expected/retired")))

(primitive-load helper)

(define (assert condition message)
  (unless condition
    (format (current-error-port) "FAIL: ~a~%" message)
    (exit 1)))

(define (write-file path contents)
  (sk:mkdir-p (dirname path))
  (call-with-output-file path
    (lambda (port) (display contents port))))

(define (read-file path)
  (call-with-input-file path get-string-all))

(define (delete-path path)
  (when (sk:path-stat path)
    (delete-file path)))

(define (replace-with-link target source)
  (delete-path target)
  (symlink source target))

(define (activation-fails? selected-links)
  (catch #t
    (lambda ()
      (sk:activate-repo-links home repo selected-links)
      #f)
    (lambda _ #t)))

(define (preflight-fails? selected-links)
  (catch #t
    (lambda ()
      (sk:check-repo-links home repo selected-links)
      #f)
    (lambda _ #t)))

(define (retired-preflight-fails? selected-links store-root)
  (catch #t
    (lambda ()
      (sk:check-retired-repo-links
       home repo selected-links store-root)
      #f)
    (lambda _ #t)))

(define source-one (string-append repo "/source/one"))
(define source-two (string-append repo "/source/two"))
(define target-one (string-append home "/.config/example/one"))
(define target-two (string-append home "/.config/example/two"))

(write-file source-one "one\n")
(write-file source-two "two\n")
(sk:mkdir-p home)

;; Missing links are created only after the complete validation pass.
(sk:check-repo-links home repo links)
(assert (not (sk:path-stat target-one))
        "read-only preflight created the first missing link")
(assert (not (sk:path-stat target-two))
        "read-only preflight created the second missing link")
(sk:activate-repo-links home repo links)
(assert (string=? (readlink target-one) source-one)
        "first missing link was not created")
(assert (string=? (readlink target-two) source-two)
        "second missing link was not created")

;; A live but wrong managed symlink is safe to repair.
(write-file (string-append root "/other") "other\n")
(replace-with-link target-one (string-append root "/other"))
(sk:activate-repo-links home repo links)
(assert (string=? (readlink target-one) source-one)
        "wrong managed symlink was not repaired")

;; A regular-file conflict is preserved, raises, and prevents partial changes.
(delete-path target-one)
(write-file target-one "preserve me\n")
(delete-path target-two)
(assert (preflight-fails? links) "regular-file conflict passed preflight")
(assert (string=? (read-file target-one) "preserve me\n")
        "preflight overwrote a regular-file conflict")
(assert (not (sk:path-stat target-two))
        "preflight partially created a sibling link")
(assert (activation-fails? links) "regular-file conflict did not fail activation")
(assert (string=? (read-file target-one) "preserve me\n")
        "regular-file conflict was overwritten")
(assert (not (sk:path-stat target-two))
        "activation partially created a link after a conflict")

;; A dangling target is reported before any managed link is changed.
(delete-path target-one)
(sk:activate-repo-links home repo links)
(replace-with-link target-one (string-append root "/absent"))
(delete-path target-two)
(assert (activation-fails? links) "dangling target did not fail activation")
(assert (string=? (readlink target-one) (string-append root "/absent"))
        "dangling target was overwritten")
(assert (not (sk:path-stat target-two))
        "activation partially created a link after a dangling target")

;; A missing managed source also fails before changing any target.
(delete-path target-one)
(sk:activate-repo-links home repo links)
(delete-path source-one)
(delete-path target-two)
(assert (activation-fails? links) "missing managed source did not fail activation")
(assert (not (sk:path-stat target-two))
        "activation partially changed links after a missing source")

;; Parent blockers are also diagnosed before a sibling link can be created.
(write-file source-one "one\n")
(define blocked-parent (string-append home "/.config/blocked"))
(define other-child (string-append home "/.config/other/child"))
(write-file blocked-parent "parent blocker\n")
(assert (activation-fails? parent-links)
        "regular-file parent did not fail activation")
(assert (string=? (read-file blocked-parent) "parent blocker\n")
        "regular-file parent was overwritten")
(assert (not (sk:path-stat other-child))
        "activation partially changed links after a blocked parent")

(delete-path blocked-parent)
(replace-with-link blocked-parent (string-append root "/absent-parent"))
(assert (activation-fails? parent-links)
        "dangling parent did not fail activation")
(assert (string=? (readlink blocked-parent)
                  (string-append root "/absent-parent"))
        "dangling parent was overwritten")
(assert (not (sk:path-stat other-child))
        "activation partially changed links after a dangling parent")

;; A retiring target may be absent, the exact legacy link, or an immutable
;; store-backed link whose bytes match the reviewed golden.
(define retired-target
  (string-append home "/.config/retired/item"))
(define retired-legacy
  (string-append repo "/source/legacy"))
(define retired-golden
  (string-append repo "/expected/retired"))
(define fake-store
  (string-append root "/store"))
(define matching-store-file
  (string-append fake-store "/theme/kitty.conf"))
(define wrong-store-file
  (string-append fake-store "/theme/wrong.conf"))
(define matching-nonstore-file
  (string-append root "/outside/kitty.conf"))

(write-file retired-legacy "legacy\n")
(write-file retired-golden "production\n")
(write-file matching-store-file "production\n")
(write-file wrong-store-file "wrong\n")
(write-file matching-nonstore-file "production\n")

(sk:check-retired-repo-links home repo retired-links fake-store)
(sk:mkdir-p (dirname retired-target))
(replace-with-link retired-target retired-legacy)
(sk:check-retired-repo-links home repo retired-links fake-store)

(replace-with-link retired-target matching-store-file)
(sk:check-retired-repo-links home repo retired-links fake-store)

(replace-with-link retired-target wrong-store-file)
(assert (retired-preflight-fails? retired-links fake-store)
        "wrong store-backed retired bytes passed preflight")

(replace-with-link retired-target matching-nonstore-file)
(assert (retired-preflight-fails? retired-links fake-store)
        "matching bytes outside the store passed retired preflight")

(replace-with-link retired-target (string-append root "/absent-retired"))
(assert (retired-preflight-fails? retired-links fake-store)
        "dangling retired link passed preflight")

(delete-path retired-target)
(write-file retired-target "blocked retired target\n")
(assert (retired-preflight-fails? retired-links fake-store)
        "regular retired target passed preflight")
(assert (string=? (read-file retired-target) "blocked retired target\n")
        "retired preflight changed a blocked target")

(format #t "PASS: Guix Home repo-link activation safety~%")
