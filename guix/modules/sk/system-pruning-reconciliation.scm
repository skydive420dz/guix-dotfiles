;;; Synthetic filesystem reconciler for the P5.2b-D4a boundary model.

(define-module (sk system-pruning-reconciliation)
  #:use-module (guix build syscalls)
  #:use-module (guix utils)
  #:use-module (ice-9 ftw)
  #:use-module (ice-9 textual-ports)
  #:use-module (rnrs bytevectors)
  #:use-module ((sk system-pruning-boundary) #:prefix boundary:)
  #:use-module (srfi srfi-1)
  #:use-module (system foreign)
  #:export (sk:reconciliation-error-key
            sk:reconciliation-phase-labels
            sk:assert-reconciliation-config
            sk:make-reconciliation-config
            sk:observe-reconciliation
            sk:classify-reconciliation
            sk:reconcile-synthetic!))

(define sk:reconciliation-error-key 'sk-system-pruning-reconciliation)

(define sk:reconciliation-phase-labels
  '("legacy-remove-transaction-directory"
    "legacy-remove-quarantine"
    "legacy-remove-initial-journal-temporary"
    "write-exact-old-grub-backup"
    "append-BACKUP-DONE"
    "remove-known-GRUB-temporary"
    "remove-known-bootcfg-temporary"))

(define %schema "p5.2b-system-prune-reconciliation/v1")
(define %sentinel-name ".p52b-system-pruning-reconciliation")
(define %sentinel-value "p5.2b-system-pruning-reconciliation/v1\n")
(define %config-keys
  '(schema mode authorization root sentinel manifest metadata paths
    initial-journal old-grub new-grub old-bootcfg new-bootcfg))
(define %metadata-keys '(owner directory-mode file-mode))
(define %path-keys
  '(program-root transaction-base transaction-lock system-lock root-namespace
    durable-roots transaction-dir quarantine journal journal-temporary grub
    grub-temporary bootcfg bootcfg-temporary backup))

(define %fsync
  (pointer->procedure
   int
   (dynamic-func "fsync" (dynamic-link))
   (list int)))

(define (%fail format-string . arguments)
  (throw sk:reconciliation-error-key
         (apply format #f format-string arguments)))

(define (ensure condition format-string . arguments)
  (unless condition
    (apply %fail format-string arguments)))

(define (all predicate values)
  (every predicate values))

(define (alist-value alist key)
  (let ((entry (assq key alist)))
    (ensure entry "missing closed reconciliation record: ~s" key)
    (cdr entry)))

(define (normalized-absolute-path? path)
  (and (string? path)
       (string-prefix? "/" path)
       (not (string=? path "/"))
       (not (string-suffix? "/" path))
       (not (string-contains path "//"))
       (not (any (lambda (component)
                   (member component '("." ".." "")))
                 (cdr (string-split path #\/))))))

(define (descendant? root path)
  (and (normalized-absolute-path? path)
       (string-prefix? (string-append root "/") path)))

(define (path-kind path)
  (catch 'system-error
    (lambda () (stat:type (lstat path)))
    (lambda arguments
      (if (= ENOENT (system-error-errno arguments))
          'absent
          (apply throw arguments)))))

(define (mode-bits metadata)
  (logand (stat:perms metadata) #o777))

(define (safe-directory? path owner mode)
  (and (eq? (path-kind path) 'directory)
       (let ((metadata (lstat path)))
         (and (= (stat:uid metadata) owner)
              (>= (stat:nlink metadata) 2)
              (= (mode-bits metadata) mode)))))

(define (safe-empty-file? path owner mode)
  (and (eq? (path-kind path) 'regular)
       (let ((metadata (lstat path)))
         (and (= (stat:uid metadata) owner)
              (= (stat:nlink metadata) 1)
              (= (mode-bits metadata) mode)
              (zero? (stat:size metadata))))))

(define (read-text path)
  (call-with-input-file path get-string-all))

(define (byte-length text)
  (bytevector-length (string->utf8 text)))

(define (safe-text-file? path owner mode)
  (and (eq? (path-kind path) 'regular)
       (let ((metadata (lstat path)))
         (and (= (stat:uid metadata) owner)
              (= (stat:nlink metadata) 1)
              (= (mode-bits metadata) mode)
              (= (stat:size metadata)
                 (byte-length (read-text path)))))))

(define (safe-exact-text-file? path text owner mode)
  (and (safe-text-file? path owner mode)
       (string=? (read-text path) text)))

(define (safe-symlink? path raw owner)
  (and (eq? (path-kind path) 'symlink)
       (let ((metadata (lstat path)))
         (and (= (stat:uid metadata) owner)
              (= (stat:nlink metadata) 1)
              (string=? (readlink path) raw)))))

(define (directory-entries path)
  (if (eq? (path-kind path) 'directory)
      (scandir path (lambda (name) (not (member name '("." "..")))))
      '()))

(define (exact-entry-set? path allowed)
  (and (eq? (path-kind path) 'directory)
       (every (lambda (name) (member name allowed))
              (directory-entries path))))

(define (sync-directory! directory)
  (let ((descriptor (open-fdes directory O_RDONLY)))
    (dynamic-wind
      (const #t)
      (lambda ()
        (ensure (zero? (%fsync descriptor))
                "cannot fsync reconciliation directory: ~a" directory))
      (lambda () (close-fdes descriptor)))))

(define (atomic-write-text! path text mode)
  (with-atomic-file-output path
    (lambda (port)
      (display text port)
      (force-output port)
      (fdatasync port)
      (chmod port mode)))
  (sync-directory! (dirname path)))

(define (remove-file-durable! path)
  (unless (eq? (path-kind path) 'absent)
    (delete-file path)
    (sync-directory! (dirname path))))

(define (remove-empty-directory-durable! path)
  (unless (eq? (path-kind path) 'absent)
    (ensure (and (eq? (path-kind path) 'directory)
                 (null? (directory-entries path)))
            "reconciliation directory is not safely empty: ~a" path)
    (rmdir path)
    (sync-directory! (dirname path))))

(define (assert-closed-alist alist keys label)
  (ensure (and (list? alist)
               (all pair? alist)
               (equal? (map car alist) keys))
          "~a differs from the closed reconciliation model" label)
  alist)

(define (assert-path-layout root paths manifest)
  (assert-closed-alist paths %path-keys "reconciliation path map")
  (for-each
   (lambda (entry)
     (unless (eq? (car entry) 'durable-roots)
       (ensure (descendant? root (cdr entry))
               "reconciliation path escapes the fixture root: ~s" entry)))
   paths)
  (let* ((durable (alist-value paths 'durable-roots))
         (roots (boundary:sk:boundary-roots manifest))
         (sha (alist-value manifest 'manifest-sha))
         (program (alist-value manifest 'program-root))
         (base (string-append
                root "/var/guix/profiles/.p52b-system-prune-transactions"))
         (namespace (string-append
                     root "/var/guix/gcroots/p52b-system-prune/" sha))
         (transaction-dir (string-append base "/" sha)))
    (ensure (string=? (alist-value paths 'program-root)
                      (string-append root (car program)))
            "program-root path is not the exact fixture mapping")
    (ensure (string=? (alist-value paths 'transaction-base) base)
            "transaction-base path is not the exact fixture mapping")
    (ensure (string=? (alist-value paths 'transaction-lock)
                      (string-append base "/transaction.lock"))
            "transaction-lock path is not the exact fixture mapping")
    (ensure (string=? (alist-value paths 'system-lock)
                      (string-append base "/system.lock"))
            "System-lock path is not the exact fixture mapping")
    (ensure (string=? (alist-value paths 'root-namespace) namespace)
            "root namespace is not the exact manifest-keyed mapping")
    (ensure (string=? (alist-value paths 'transaction-dir) transaction-dir)
            "transaction directory is not the exact manifest-keyed mapping")
    (ensure (string=? (alist-value paths 'quarantine)
                      (string-append transaction-dir "/quarantine"))
            "quarantine path differs from the closed mapping")
    (ensure (string=? (alist-value paths 'journal)
                      (string-append transaction-dir "/journal.tsv"))
            "journal path differs from the closed mapping")
    (ensure (string=? (alist-value paths 'backup)
                      (string-append transaction-dir "/old-grub.backup"))
            "backup path differs from the closed mapping")
    (ensure (string=? (alist-value paths 'grub)
                      (string-append root "/boot/grub/grub.cfg"))
            "installed GRUB path differs from the closed fixture mapping")
    (ensure (string=? (alist-value paths 'bootcfg)
                      (string-append root "/var/guix/gcroots/bootcfg"))
            "bootcfg path differs from the closed fixture mapping")
    (ensure (and (list? durable) (= (length durable) (length roots)))
            "durable-root path map has the wrong closed length")
    (for-each
     (lambda (entry root-record)
       (ensure (and (list? entry) (= (length entry) 3)
                    (string=? (car entry) (cadr root-record))
                    (string=? (cadr entry)
                              (string-append namespace "/" (car entry)))
                    (string=? (caddr entry) (list-ref root-record 3)))
               "durable-root mapping differs from the manifest: ~s" entry))
     durable roots))
  (let ((base (alist-value paths 'transaction-base))
        (transaction-dir (alist-value paths 'transaction-dir))
        (journal (alist-value paths 'journal))
        (grub (alist-value paths 'grub))
        (bootcfg (alist-value paths 'bootcfg)))
    (ensure (string=? (dirname (alist-value paths 'transaction-lock)) base)
            "transaction lock is not a direct transaction-base child")
    (ensure (string=? (dirname (alist-value paths 'system-lock)) base)
            "System lock is not a direct transaction-base child")
    (ensure (string=? (dirname transaction-dir) base)
            "transaction directory is not a direct transaction-base child")
    (for-each
     (lambda (key)
       (ensure (string=? (dirname (alist-value paths key)) transaction-dir)
               "~a is not a direct transaction-directory child" key))
     '(quarantine journal journal-temporary backup))
    (ensure (string=? (alist-value paths 'grub-temporary)
                      (string-append grub ".p52b-new"))
            "GRUB temporary path differs from the closed name")
    (ensure (string=? (alist-value paths 'bootcfg-temporary)
                      (string-append bootcfg ".p52b-new"))
            "bootcfg temporary path differs from the closed name")
    (ensure (string=? (alist-value paths 'journal-temporary)
                      (string-append journal ".initial"))
            "journal temporary path differs from the closed name"))
  paths)

(define (sk:assert-reconciliation-config config)
  "Validate CONFIG without touching any configured transaction path."
  (assert-closed-alist config %config-keys "reconciliation configuration")
  (ensure (string=? (alist-value config 'schema) %schema)
          "reconciliation schema is not ~a" %schema)
  (ensure (string=? (alist-value config 'mode) "FIXTURE-ONLY")
          "reconciliation mode is not FIXTURE-ONLY")
  (ensure (string=? (alist-value config 'authorization) "NOT-GRANTED")
          "reconciliation authorization is not NOT-GRANTED")
  (let* ((root (alist-value config 'root))
         (sentinel (alist-value config 'sentinel))
         (manifest
          (boundary:sk:assert-boundary-manifest
           (alist-value config 'manifest)))
         (metadata
          (assert-closed-alist (alist-value config 'metadata)
                               %metadata-keys
                               "reconciliation metadata"))
         (paths (alist-value config 'paths))
         (initial (alist-value config 'initial-journal))
         (old-grub (alist-value config 'old-grub))
         (new-grub (alist-value config 'new-grub))
         (old-bootcfg (alist-value config 'old-bootcfg))
         (new-bootcfg (alist-value config 'new-bootcfg)))
    (ensure (normalized-absolute-path? root)
            "fixture root is not a normalized non-root absolute path")
    (ensure (equal? sentinel (list %sentinel-name %sentinel-value))
            "fixture sentinel differs from the closed marker")
    (ensure (and (integer? (alist-value metadata 'owner))
                 (>= (alist-value metadata 'owner) 0))
            "fixture owner is invalid")
    (for-each
     (lambda (key)
       (let ((mode (alist-value metadata key)))
         (ensure (and (integer? mode) (>= mode 0) (<= mode #o777))
                 "fixture mode is invalid: ~s" key)))
     '(directory-mode file-mode))
    (assert-path-layout root paths manifest)
    (ensure (string=? initial
                      (boundary:sk:render-journal
                       manifest '(("BEGIN" "-"))))
            "canonical initial-journal bytes differ")
    (for-each
     (lambda (record label)
       (ensure (and (list? record) (= (length record) 2)
                    (string? (car record))
                    (integer? (cadr record))
                    (>= (cadr record) 0)
                    (<= (cadr record) #o777))
               "~a GRUB bytes/metadata record is invalid" label))
     (list old-grub new-grub) '("old" "new"))
    (ensure (not (string=? (car old-grub) (car new-grub)))
            "old and new GRUB bytes are identical")
    (for-each
     (lambda (tuple label)
       (ensure (and (list? tuple) (= (length tuple) 2)
                    (string? (car tuple))
                    (not (string-null? (car tuple)))
                    (descendant? root (cadr tuple)))
               "~a bootcfg tuple is invalid" label))
     (list old-bootcfg new-bootcfg) '("old" "new"))
    (ensure (not (equal? old-bootcfg new-bootcfg))
            "old and new bootcfg tuples are identical"))
  config)

(define (sk:make-reconciliation-config
         root manifest old-grub new-grub old-bootcfg new-bootcfg owner)
  "Build the one closed, pure synthetic reconciliation configuration.

The caller supplies only fixture identity/content records.  Persistent path
layout, sentinel, metadata modes, and canonical initial journal are derived
without touching ROOT."
  (let* ((checked-manifest
          (boundary:sk:assert-boundary-manifest manifest))
         (sha (alist-value checked-manifest 'manifest-sha))
         (program (alist-value checked-manifest 'program-root))
         (roots (boundary:sk:boundary-roots checked-manifest))
         (base
          (string-append
           root "/var/guix/profiles/.p52b-system-prune-transactions"))
         (namespace
          (string-append root "/var/guix/gcroots/p52b-system-prune/" sha))
         (transaction-dir (string-append base "/" sha))
         (journal (string-append transaction-dir "/journal.tsv"))
         (grub (string-append root "/boot/grub/grub.cfg"))
         (bootcfg (string-append root "/var/guix/gcroots/bootcfg"))
         (durable
          (map (lambda (record)
                 (list (cadr record)
                       (string-append namespace "/" (cadr record))
                       (list-ref record 3)))
               roots))
         (config
          `((schema . ,%schema)
            (mode . "FIXTURE-ONLY")
            (authorization . "NOT-GRANTED")
            (root . ,root)
            (sentinel . (,%sentinel-name ,%sentinel-value))
            (manifest . ,checked-manifest)
            (metadata
             . ((owner . ,owner)
                (directory-mode . #o700)
                (file-mode . #o600)))
            (paths
             . ((program-root . ,(string-append root (car program)))
                (transaction-base . ,base)
                (transaction-lock . ,(string-append base "/transaction.lock"))
                (system-lock . ,(string-append base "/system.lock"))
                (root-namespace . ,namespace)
                (durable-roots . ,durable)
                (transaction-dir . ,transaction-dir)
                (quarantine . ,(string-append transaction-dir "/quarantine"))
                (journal . ,journal)
                (journal-temporary . ,(string-append journal ".initial"))
                (grub . ,grub)
                (grub-temporary . ,(string-append grub ".p52b-new"))
                (bootcfg . ,bootcfg)
                (bootcfg-temporary . ,(string-append bootcfg ".p52b-new"))
                (backup
                 . ,(string-append transaction-dir "/old-grub.backup"))))
            (initial-journal
             . ,(boundary:sk:render-journal
                 checked-manifest '(("BEGIN" "-"))))
            (old-grub . ,old-grub)
            (new-grub . ,new-grub)
            (old-bootcfg . ,old-bootcfg)
            (new-bootcfg . ,new-bootcfg))))
    (sk:assert-reconciliation-config config)))

(define (config-ref config key)
  ;; Public observation/reconciliation entry points validate CONFIG once
  ;; before descending into the closed internal path map.  Re-validating for
  ;; every lookup would repeatedly rebuild and hash the canonical journal.
  (alist-value config key))

(define (path-ref config key)
  (alist-value (config-ref config 'paths) key))

(define (metadata-ref config key)
  (alist-value (config-ref config 'metadata) key))

(define (assert-fixture-capability config)
  (let* ((root (config-ref config 'root))
         (owner (metadata-ref config 'owner))
         (directory-mode (metadata-ref config 'directory-mode))
         (file-mode (metadata-ref config 'file-mode))
         (sentinel (string-append root "/" %sentinel-name)))
    (ensure (safe-directory? root owner directory-mode)
            "fixture root is not an exact owned directory")
    (ensure (string=? (canonicalize-path root) root)
            "fixture root has a symlinked or noncanonical identity")
    (ensure (safe-exact-text-file?
             sentinel %sentinel-value owner file-mode)
            "fixture sentinel is absent or differs")
    (for-each
     (lambda (path)
       (let loop ((parent (dirname path)))
         (unless (string=? parent root)
           (case (path-kind parent)
             ((absent) (loop (dirname parent)))
             ((directory)
              (ensure (and (descendant? root parent)
                           (string=? (canonicalize-path parent) parent))
                      "configured path has an unsafe ancestor: ~a" parent)
              (loop (dirname parent)))
             (else
              (%fail "configured path ancestor is not a real directory: ~a"
                     parent))))))
     (append
      (filter-map
       (lambda (entry)
         (and (not (eq? (car entry) 'durable-roots)) (cdr entry)))
       (config-ref config 'paths))
      (map cadr (alist-value (config-ref config 'paths) 'durable-roots))))
    #t))

(define (path-state path predicate)
  (case (path-kind path)
    ((absent) 'absent)
    (else (if (predicate path) 'exact 'foreign))))

(define (directory-state path owner mode)
  (path-state path (lambda (candidate)
                     (safe-directory? candidate owner mode))))

(define (lock-state path owner mode)
  (path-state path (lambda (candidate)
                     (safe-empty-file? candidate owner mode))))

(define (program-state config)
  (let* ((manifest (config-ref config 'manifest))
         (program (alist-value manifest 'program-root))
         (path (path-ref config 'program-root))
         (owner (metadata-ref config 'owner)))
    (path-state path
                (lambda (candidate)
                  (safe-symlink? candidate (cadr program) owner)))))

(define (durable-root-state config)
  (let* ((entries (alist-value (config-ref config 'paths) 'durable-roots))
         (owner (metadata-ref config 'owner)))
    (filter-map
     (lambda (entry)
       (and (safe-symlink? (cadr entry) (caddr entry) owner)
            (car entry)))
     entries)))

(define (durable-root-foreign? config)
  (let ((owner (metadata-ref config 'owner)))
    (any
     (lambda (entry)
       (let ((path (cadr entry)))
         (and (not (eq? (path-kind path) 'absent))
              (not (safe-symlink? path (caddr entry) owner)))))
     (alist-value (config-ref config 'paths) 'durable-roots))))

(define (journal-observation config)
  (let* ((journal (path-ref config 'journal))
         (temporary (path-ref config 'journal-temporary))
         (owner (metadata-ref config 'owner))
         (mode (metadata-ref config 'file-mode))
         (initial (config-ref config 'initial-journal))
         (journal-kind (path-kind journal))
         (temporary-kind (path-kind temporary)))
    (cond
     ((and (eq? journal-kind 'absent) (eq? temporary-kind 'absent))
      (list 'absent '() #f))
     ((and (eq? journal-kind 'absent)
           (safe-text-file? temporary owner mode))
      (let ((bytes (read-text temporary)))
        (cond
         ((string=? bytes initial)
          (list 'initial-temp-equal '() #f))
         ((boundary:sk:exact-byte-prefix? bytes initial)
          (list 'initial-temp-prefix '() #f))
         (else (list 'foreign '() #t)))))
     ((and (safe-text-file? journal owner mode)
           (eq? temporary-kind 'absent))
      (catch boundary:sk:boundary-error-key
        (lambda ()
          (let* ((history
                  (boundary:sk:parse-journal
                   (config-ref config 'manifest)
                   (read-text journal)))
                 (status
                  (boundary:sk:journal-history-status
                   (config-ref config 'manifest) history)))
            (list status history #f)))
        (lambda _ (list 'foreign '() #t))))
     (else (list 'foreign '() #t)))))

(define (grub-state config path)
  (let* ((owner (metadata-ref config 'owner))
         (old (config-ref config 'old-grub))
         (new (config-ref config 'new-grub)))
    (cond
     ((eq? (path-kind path) 'absent) 'absent)
     ((safe-exact-text-file? path (car old) owner (cadr old)) 'old)
     ((safe-exact-text-file? path (car new) owner (cadr new)) 'new)
     (else 'foreign))))

(define (bootcfg-state config path)
  (let ((owner (metadata-ref config 'owner))
        (old (config-ref config 'old-bootcfg))
        (new (config-ref config 'new-bootcfg)))
    (catch 'system-error
      (lambda ()
        (cond
         ((eq? (path-kind path) 'absent) 'absent)
         ((and (safe-symlink? path (car old) owner)
               (string=? (canonicalize-path path) (cadr old)))
          'old)
         ((and (safe-symlink? path (car new) owner)
               (string=? (canonicalize-path path) (cadr new)))
          'new)
         (else 'foreign)))
      (lambda _ 'foreign))))

(define (backup-state config history)
  (let* ((path (path-ref config 'backup))
         (owner (metadata-ref config 'owner))
         (old (config-ref config 'old-grub))
         (mode (cadr old)))
    (cond
     ((eq? (path-kind path) 'absent) 'absent)
     ((not (safe-text-file? path owner mode)) 'foreign)
     ((not (boundary:sk:exact-byte-prefix? (read-text path) (car old)))
      'foreign)
     ((not (string=? (read-text path) (car old))) 'partial-prefix)
     ((member '("BACKUP-DONE" "-") history) 'done)
     (else 'exact))))

(define (managed-extra? config)
  (let* ((paths (config-ref config 'paths))
         (base (path-ref config 'transaction-base))
         (namespace (path-ref config 'root-namespace))
         (transaction-dir (path-ref config 'transaction-dir))
         (grub (path-ref config 'grub))
         (bootcfg (path-ref config 'bootcfg))
         (durable (alist-value paths 'durable-roots))
         (base-allowed
          (map (lambda (key) (basename (path-ref config key)))
               '(transaction-lock system-lock transaction-dir)))
         (namespace-allowed (map (lambda (entry) (basename (cadr entry)))
                                 durable))
         (transaction-allowed
          (map (lambda (key) (basename (path-ref config key)))
               '(quarantine journal journal-temporary backup))))
    (or
     (and (eq? (path-kind base) 'directory)
          (not (exact-entry-set? base base-allowed)))
     (and (eq? (path-kind namespace) 'directory)
          (not (exact-entry-set? namespace namespace-allowed)))
     (and (eq? (path-kind transaction-dir) 'directory)
          (not (exact-entry-set? transaction-dir transaction-allowed)))
     (and (eq? (path-kind (path-ref config 'quarantine)) 'directory)
          (pair? (directory-entries (path-ref config 'quarantine))))
     (any
      (lambda (pair)
        (let* ((target (car pair))
               (temporary (cdr pair))
               (parent (dirname target))
               (prefix (string-append (basename target) ".p52b-")))
          (and (eq? (path-kind parent) 'directory)
               (any (lambda (name)
                      (and (string-prefix? prefix name)
                           (not (string=? name (basename temporary)))))
                    (directory-entries parent)))))
      (list (cons grub (path-ref config 'grub-temporary))
            (cons bootcfg (path-ref config 'bootcfg-temporary)))))))

(define (bootstrap-observation config)
  (assert-fixture-capability config)
  (let* ((owner (metadata-ref config 'owner))
         (directory-mode (metadata-ref config 'directory-mode))
         (file-mode (metadata-ref config 'file-mode))
         (journal-row (journal-observation config))
         (journal (car journal-row))
         (history (cadr journal-row))
         (live-grub (grub-state config (path-ref config 'grub)))
         (live-bootcfg (bootcfg-state config (path-ref config 'bootcfg)))
         (grub-temp (grub-state config (path-ref config 'grub-temporary)))
         (bootcfg-temp
          (bootcfg-state config (path-ref config 'bootcfg-temporary)))
         (foreign?
          (or (caddr journal-row)
              (managed-extra? config)
              (durable-root-foreign? config)
              (member 'foreign (list live-grub live-bootcfg
                                     grub-temp bootcfg-temp)))))
    `((protected? . #t)
      (foreign? . ,(and foreign? #t))
      (program-root . ,(program-state config))
      (transaction-base
       . ,(directory-state (path-ref config 'transaction-base)
                           owner directory-mode))
      (transaction-lock
       . ,(lock-state (path-ref config 'transaction-lock) owner file-mode))
      (system-lock
       . ,(lock-state (path-ref config 'system-lock) owner file-mode))
      (root-namespace
       . ,(directory-state (path-ref config 'root-namespace)
                           owner directory-mode))
      (durable-roots . ,(durable-root-state config))
      (transaction-dir
       . ,(directory-state (path-ref config 'transaction-dir)
                           owner directory-mode))
      (quarantine
       . ,(directory-state (path-ref config 'quarantine)
                           owner directory-mode))
      (journal . ,journal)
      (journal-history . ,history)
      (live-grub . ,live-grub)
      (live-bootcfg . ,live-bootcfg)
      (grub-temporary
       . ,(case grub-temp
            ((absent) 'absent)
            ((old) 'exact-old)
            ((new) 'exact-new)
            (else 'foreign)))
      (bootcfg-temporary
       . ,(case bootcfg-temp
            ((absent) 'absent)
            ((old) 'exact-old)
            ((new) 'exact-new)
            (else 'foreign)))
      (backup . ,(backup-state config history)))))

(define (legacy-observation config bootstrap)
  `((protected? . ,(alist-value bootstrap 'protected?))
    (foreign? . ,(alist-value bootstrap 'foreign?))
    (program-root . ,(alist-value bootstrap 'program-root))
    (roots . ,(alist-value bootstrap 'durable-roots))
    (transaction-dir . ,(alist-value bootstrap 'transaction-dir))
    (quarantine . ,(alist-value bootstrap 'quarantine))
    (journal-temp
     . ,(case (alist-value bootstrap 'journal)
          ((absent) 'absent)
          ((initial-temp-prefix) 'prefix)
          ((initial-temp-equal) 'equal)
          (else 'foreign)))
    (backup
     . ,(case (alist-value bootstrap 'backup)
          ((absent) 'absent)
          (else 'foreign)))))

(define (legacy-layout? bootstrap)
  (and (eq? (alist-value bootstrap 'program-root) 'absent)
       (null? (alist-value bootstrap 'durable-roots))
       (eq? (alist-value bootstrap 'root-namespace) 'absent)
       (eq? (alist-value bootstrap 'transaction-lock) 'absent)
       (eq? (alist-value bootstrap 'system-lock) 'absent)
       (eq? (alist-value bootstrap 'transaction-base) 'exact)
       (member (alist-value bootstrap 'transaction-dir) '(absent exact))))

(define (sk:observe-reconciliation config)
  "Return (bootstrap|legacy SNAPSHOT) from actual fixture-root metadata."
  (sk:assert-reconciliation-config config)
  (let ((bootstrap (bootstrap-observation config)))
    (if (legacy-layout? bootstrap)
        (list 'legacy (legacy-observation config bootstrap))
        (list 'bootstrap bootstrap))))

(define (classify-observation config observation)
  (case (car observation)
    ((legacy)
     (boundary:sk:classify-legacy-gap (cadr observation)))
    ((bootstrap)
     (boundary:sk:classify-bootstrap
      (config-ref config 'manifest) (cadr observation)))
    (else (%fail "unknown reconciliation observation kind"))))

(define (sk:classify-reconciliation config)
  "Classify the current real synthetic fixture without mutation."
  (classify-observation config (sk:observe-reconciliation config)))

(define (unchecked-effect-for config observation classification)
  (let ((kind (car observation))
        (snapshot (cadr observation))
        (result (car classification))
        (next (cadr classification)))
    (cond
     ((and (eq? kind 'legacy) (string=? result "RESUME"))
      (cond
       ((string=? next "remove-empty-transaction-directory")
        (list "legacy-remove-transaction-directory"
              (lambda ()
                (remove-empty-directory-durable!
                 (path-ref config 'transaction-dir)))))
       ((string=? next "remove-empty-quarantine-and-directory")
        (list "legacy-remove-quarantine"
              (lambda ()
                (remove-empty-directory-durable!
                 (path-ref config 'quarantine)))))
       ((string=? next "reconcile-legacy-initial-journal")
        (list "legacy-remove-initial-journal-temporary"
              (lambda ()
                (ensure
                 (member (alist-value snapshot 'journal-temp) '(prefix equal))
                 "legacy journal temporary changed before removal")
                (remove-file-durable!
                 (path-ref config 'journal-temporary)))))
       (else #f)))
     ((and (eq? kind 'bootstrap) (string=? result "RESUME"))
      (cond
       ((member next '("old-grub-backup" "replace-partial-backup"))
        (list "write-exact-old-grub-backup"
              (lambda ()
                (let ((old (config-ref config 'old-grub)))
                  (atomic-write-text!
                   (path-ref config 'backup) (car old) (cadr old))))))
       ((string=? next "append-BACKUP-DONE")
        (list "append-BACKUP-DONE"
              (lambda ()
                (let* ((journal (path-ref config 'journal))
                       (history
                        (alist-value (cadr (sk:observe-reconciliation config))
                                     'journal-history))
                       (successor '("BACKUP-DONE" "-")))
                  (boundary:sk:assert-legal-journal-successor
                   (config-ref config 'manifest) history successor)
                  (atomic-write-text!
                   journal
                   (boundary:sk:append-journal-event
                    (config-ref config 'manifest)
                    (read-text journal)
                    successor)
                   (metadata-ref config 'file-mode))))))
       (else #f)))
     ((and (eq? kind 'bootstrap)
           (string=? result "JOURNAL-RECOVERY"))
      (cond
       ((not (eq? (alist-value snapshot 'grub-temporary) 'absent))
        (list "remove-known-GRUB-temporary"
              (lambda ()
                (remove-file-durable! (path-ref config 'grub-temporary)))))
       ((not (eq? (alist-value snapshot 'bootcfg-temporary) 'absent))
        (list "remove-known-bootcfg-temporary"
              (lambda ()
                (remove-file-durable! (path-ref config 'bootcfg-temporary)))))
       (else #f)))
     (else #f))))

(define (effect-for config observation classification)
  (let ((effect
         (unchecked-effect-for config observation classification)))
    (when effect
      (ensure (member (car effect) sk:reconciliation-phase-labels)
              "reconciliation emitted an unregistered phase label: ~a"
              (car effect)))
    effect))

(define (sk:reconcile-synthetic! config phase-runner)
  "Run accepted fixture-only effects through PHASE-RUNNER and return final class.

PHASE-RUNNER receives (LABEL THUNK).  It must explicitly invoke THUNK.  A
REVIEW-REQUIRED result never calls it.  Production bootstrap prefixes are
classification/resume-only and therefore also return without an effect."
  (sk:assert-reconciliation-config config)
  (ensure (procedure? phase-runner) "reconciliation phase runner is not callable")
  (let loop ((remaining 16))
    (ensure (> remaining 0) "reconciliation exceeded its closed effect bound")
    (let* ((observation (sk:observe-reconciliation config))
           (classification (classify-observation config observation))
           (effect (effect-for config observation classification)))
      (if effect
          (begin
            (phase-runner
             (car effect)
             (lambda ()
               (let* ((current-observation
                       (sk:observe-reconciliation config))
                      (current-classification
                       (classify-observation config current-observation))
                      (current-effect
                       (effect-for config current-observation
                                   current-classification)))
                 (ensure (and current-effect
                              (string=? (car current-effect) (car effect)))
                         "reconciliation state changed before effect: ~a"
                         (car effect))
                 ((cadr current-effect)))))
            (loop (- remaining 1)))
          classification))))
