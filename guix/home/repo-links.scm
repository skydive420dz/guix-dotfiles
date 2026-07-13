;; Shared two-pass link activation used by Guix Home and its focused tests.

(define (sk:path-stat path)
  (false-if-exception (lstat path)))

(define (sk:symlink-path? path)
  (let ((entry (sk:path-stat path)))
    (and entry (eq? (stat:type entry) 'symlink))))

(define (sk:directory-path? path)
  (let ((entry (false-if-exception (stat path))))
    (and entry (eq? (stat:type entry) 'directory))))

(define (sk:nearest-parent-problem target-path)
  (let loop ((path (dirname target-path)))
    (let ((entry (sk:path-stat path)))
      (cond
       ((and entry (sk:directory-path? path)) #f)
       ((and entry (sk:symlink-path? path))
        (list 'dangling-parent path))
       (entry
        (list 'blocked-parent path))
       ((string=? path (dirname path)) #f)
       (else (loop (dirname path)))))))

(define (sk:repo-link-problem home repo link)
  (let* ((target-path (string-append home "/" (car link)))
         (source-path (string-append repo "/" (cadr link)))
         (parent-problem (sk:nearest-parent-problem target-path))
         (target-entry (sk:path-stat target-path)))
    (cond
     ((not (file-exists? source-path))
      (list 'dangling-source target-path source-path))
     (parent-problem
      (list (car parent-problem) target-path (cadr parent-problem)))
     ((not target-entry) #f)
     ((not (sk:symlink-path? target-path))
      (list 'blocked target-path source-path))
     ((not (file-exists? target-path))
      (list 'dangling target-path (readlink target-path)))
     (else #f))))

(define (sk:report-repo-link-problem problem)
  (let ((port (current-error-port)))
    (case (car problem)
      ((dangling-source)
       (format port "repo-links: DANGLING source for ~a: ~a~%"
               (cadr problem) (caddr problem)))
      ((dangling-parent)
       (format port "repo-links: DANGLING parent for ~a: ~a~%"
               (cadr problem) (caddr problem)))
      ((blocked-parent)
       (format port "repo-links: BLOCKED parent for ~a: ~a is not a directory~%"
               (cadr problem) (caddr problem)))
      ((blocked)
       (format port "repo-links: BLOCKED ~a: existing path is not a symlink~%"
               (cadr problem)))
      ((dangling)
       (format port "repo-links: DANGLING ~a -> ~a~%"
               (cadr problem) (caddr problem))))))

(define (sk:mkdir-p path)
  (unless (sk:directory-path? path)
    (let ((parent (dirname path)))
      (unless (string=? parent path)
        (sk:mkdir-p parent))
      (mkdir path))))

(define (sk:install-repo-link home repo link)
  (let* ((target-path (string-append home "/" (car link)))
         (source-path (string-append repo "/" (cadr link)))
         (target-entry (sk:path-stat target-path)))
    (sk:mkdir-p (dirname target-path))
    (cond
     ((and (sk:symlink-path? target-path)
           (string=? (readlink target-path) source-path))
      #t)
     ((sk:symlink-path? target-path)
      (delete-file target-path)
      (symlink source-path target-path)
      (format #t "Updated symlink ~a -> ~a~%" target-path source-path))
     ((not target-entry)
      (symlink source-path target-path)
      (format #t "Created symlink ~a -> ~a~%" target-path source-path))
     (else
      ;; The validation/apply boundary was raced.  Fail instead of replacing it.
      (error "repo link became blocked during activation" target-path)))))

(define (sk:repo-link-problems home repo links)
  (let loop ((remaining links) (problems '()))
    (if (null? remaining)
        (reverse problems)
        (let ((problem (sk:repo-link-problem home repo (car remaining))))
          (loop (cdr remaining)
                (if problem (cons problem problems) problems))))))

(define (sk:check-repo-links home repo links)
  "Validate all LINKS without changing any target."
  (let ((problems (sk:repo-link-problems home repo links)))
    (if (null? problems)
        #t
        (begin
          (for-each sk:report-repo-link-problem problems)
          (error "repo link preflight refused; no links were changed")))))

(define (sk:activate-repo-links home repo links)
  "Validate all LINKS, then install them only when no path is blocked/dangling."
  (sk:check-repo-links home repo links)
  (for-each
   (lambda (link) (sk:install-repo-link home repo link))
   links))
